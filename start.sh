#!/bin/bash
# ==============================================================================
#  Lan-clip 启动脚本（本机 Linux 版）
#
#  用法:
#    ./start.sh                  # 启动服务（后台常驻，默认端口 5000）
#    ./start.sh 5001             # 指定端口启动
#    ./start.sh status           # 查看运行状态
#    ./start.sh restart          # 重启
#    ./start.sh stop             # 停止（等同 stop.sh）
#    ./start.sh enable           # 安装开机自启（systemd 用户级 + linger，开机即启动）
#    ./start.sh disable          # 取消开机自启
#
#  特点:
#    * 后台常驻，脱离终端；脚本退出/关掉终端不影响服务
#    * 崩溃自动重启（3 秒一次）
#    * enable 后由 systemd 托管，开机自动运行，无需手动启动
#
#  环境变量:
#    LANCLIP_PORT=5001   指定端口
#    LANCLIP_PYTHON=python3
# ==============================================================================

set -u

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${LANCLIP_PORT:-5000}"
PYTHON="${LANCLIP_PYTHON:-python3}"
UNIT_NAME="lanclip"

RUN_DIR="$APP_DIR/run"
LOG_DIR="$APP_DIR/logs"
PID_FILE="$RUN_DIR/lanclip.pid"
LOG_FILE="$LOG_DIR/lanclip.log"
USER_UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
USER_UNIT_FILE="$USER_UNIT_DIR/${UNIT_NAME}.service"
AUTOSTART_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/lan-clip.desktop"

cd "$APP_DIR" || exit 1

# ------------------------------------------------------------------ 基础函数 --

c_red()  { printf '\033[31m%s\033[0m\n' "$*"; }
c_grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
c_yel()  { printf '\033[33m%s\033[0m\n' "$*"; }
c_blu()  { printf '\033[34m%s\033[0m\n' "$*"; }

# 端口是否已被占用（返回 0 = 占用）
port_busy() {
    "$PYTHON" - "$PORT" <<'PY'
import socket, sys
s = socket.socket()
s.settimeout(1)
try:
    s.connect(("127.0.0.1", int(sys.argv[1])))
    sys.exit(0)
except Exception:
    sys.exit(1)
finally:
    s.close()
PY
}

# 健康检查：HTTP 200 才算启动成功
health_check() {
    local i
    for i in $(seq 1 30); do
        if "$PYTHON" - "$PORT" <<'PY'
import sys, urllib.request
try:
    with urllib.request.urlopen("http://127.0.0.1:%s/api/cards" % sys.argv[1], timeout=2) as r:
        sys.exit(0 if r.status == 200 else 1)
except Exception:
    sys.exit(1)
PY
        then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

# 守护进程是否在跑
supervisor_alive() {
    [ -f "$PID_FILE" ] || return 1
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null)"
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null
}

unit_active() {
    systemctl --user is-active --quiet "$UNIT_NAME" 2>/dev/null
}

unit_enabled() {
    systemctl --user is-enabled --quiet "$UNIT_NAME" 2>/dev/null
}

# ------------------------------------------------------------ 守护进程启动 --

start_daemon() {
    mkdir -p "$RUN_DIR" "$LOG_DIR"

    if unit_active; then
        c_blu "服务已由 systemd 托管运行中，无需重复启动。"
        c_blu "如需重启请执行: ./start.sh restart"
        return 0
    fi

    # 已安装开机自启(systemd)但当前没跑: 交给 systemd 拉起，保持单一管理者
    if unit_enabled; then
        systemctl --user start "$UNIT_NAME" >/dev/null 2>&1
        if health_check; then
            c_grn "✔ Lan-clip 已由 systemd 启动 (端口 $PORT)"
            c_blu "  本机访问: http://127.0.0.1:$PORT"
            return 0
        fi
        c_red "systemd 启动后未通过健康检查，请查看: journalctl --user -u $UNIT_NAME -n 30"
        return 1
    fi

    if supervisor_alive; then
        c_yel "服务已在运行 (PID $(cat "$PID_FILE"))，端口 $PORT"
        return 0
    fi

    if port_busy; then
        c_red "端口 $PORT 已被其它进程占用，先停掉它，或换端口: ./start.sh 5080"
        return 1
    fi

    # 依赖检查
    if ! "$PYTHON" -c "import flask, waitress, qrcode" 2>/dev/null; then
        c_red "缺少依赖，请先执行: $PYTHON -m pip install --user flask waitress qrcode"
        return 1
    fi

    # setsid 脱离终端，日志与 PID 落到 run/ logs/
    setsid bash -c '
        set -u
        RUN_DIR="$1"; APP_DIR="$2"; PORT="$3"; PYTHON="$4"; PID_FILE="$5"; LOG_FILE="$6"
        echo $$ > "$PID_FILE"
        cd "$APP_DIR" || exit 1
        while true; do
            echo "[$(date "+%F %T")] 启动 app.py (端口 $PORT)" >> "$LOG_FILE"
            PYSTRAY_BACKEND="${PYSTRAY_BACKEND:-xorg}" "$PYTHON" app.py --port "$PORT" >> "$LOG_FILE" 2>&1
            code=$?
            echo "[$(date "+%F %T")] app.py 已退出 (code=$code)，3 秒后自动重启" >> "$LOG_FILE"
            sleep 3
        done
    ' _ "$RUN_DIR" "$APP_DIR" "$PORT" "$PYTHON" "$PID_FILE" "$LOG_FILE" \
        >> "$LOG_FILE" 2>&1 < /dev/null &
    disown 2>/dev/null

    sleep 1
    if ! supervisor_alive; then
        c_red "启动失败，请查看日志: tail -30 $LOG_FILE"
        return 1
    fi

    if health_check; then
        c_grn "✔ Lan-clip 启动成功 (PID $(cat "$PID_FILE"))"
        c_blu "  本机访问: http://127.0.0.1:$PORT"
        for ip in $(hostname -I 2>/dev/null); do
            case "$ip" in
                127.*|172.1[789].*) continue ;;
            esac
            c_blu "  局域网:   http://$ip:$PORT"
        done
        c_blu "  日志:     $LOG_FILE"
        c_blu "  停止:     ./stop.sh"
        return 0
    fi

    c_red "服务未通过健康检查，请查看日志: tail -30 $LOG_FILE"
    return 1
}

# ------------------------------------------------------------------ 停止 --

stop_daemon() {
    local stopped=0

    # 1) systemd 托管的先停 systemd
    if unit_active; then
        systemctl --user stop "$UNIT_NAME" >/dev/null 2>&1 && \
            { c_blu "已停止 systemd 服务: ${UNIT_NAME}.service"; stopped=1; }
    fi

    # 2) 停自管守护进程（按进程组杀，保证子进程一起收掉）
    if [ -f "$PID_FILE" ]; then
        local pid
        pid="$(cat "$PID_FILE" 2>/dev/null)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill -TERM -- "-$pid" 2>/dev/null
            local i
            for i in $(seq 1 20); do
                kill -0 "$pid" 2>/dev/null || break
                sleep 0.25
            done
            kill -0 "$pid" 2>/dev/null && kill -KILL -- "-$pid" 2>/dev/null
            c_blu "已停止守护进程 (PID $pid)"
            stopped=1
        fi
        rm -f "$PID_FILE"
    fi

    # 3) 兜底：清理可能残留的 app.py 进程
    if pgrep -f "app\.py --port $PORT" >/dev/null 2>&1; then
        pkill -TERM -f "app\.py --port $PORT" 2>/dev/null
        sleep 1
        pkill -KILL -f "app\.py --port $PORT" 2>/dev/null
        c_blu "已清理残留进程 (app.py --port $PORT)"
        stopped=1
    fi

    if port_busy; then
        c_yel "端口 $PORT 仍被占用，请手动检查: ss -ltnp | grep :$PORT"
    elif [ "$stopped" = "1" ]; then
        c_grn "✔ Lan-clip 已停止"
    else
        c_yel "Lan-clip 当前没有运行"
    fi
}

# -------------------------------------------------------------- 开机自启 --

write_user_unit() {
    mkdir -p "$USER_UNIT_DIR" "$LOG_DIR"
    cat > "$USER_UNIT_FILE" <<EOF
[Unit]
Description=Lan-clip 局域网剪贴板共享服务
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR
ExecStart=$PYTHON $APP_DIR/app.py --port $PORT
Environment=PYSTRAY_BACKEND=xorg
Restart=always
RestartSec=3
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

[Install]
WantedBy=default.target
EOF
}

enable_autostart() {
    mkdir -p "$RUN_DIR" "$LOG_DIR"

    if ! command -v systemctl >/dev/null 2>&1 || ! systemctl --user show-environment >/dev/null 2>&1; then
        c_yel "systemd 用户服务不可用，改用桌面自启动 (登录后启动)"
        # 避免两套机制同时拉起造成端口冲突：先卸掉已装的 systemd 单元
        if command -v systemctl >/dev/null 2>&1; then
            systemctl --user disable --now "$UNIT_NAME" >/dev/null 2>&1
            rm -f "$USER_UNIT_FILE"
            systemctl --user daemon-reload >/dev/null 2>&1
        fi
        mkdir -p "$(dirname "$AUTOSTART_FILE")"
        cat > "$AUTOSTART_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=Lan-clip
Comment=局域网剪贴板共享
Exec=$APP_DIR/start.sh
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
        c_grn "✔ 已安装桌面自启动: $AUTOSTART_FILE"
        c_blu "  说明: 该方式在桌面登录后启动；如需开机(未登录)即启动，请用 systemd 方案"
        return 0
    fi

    write_user_unit
    systemctl --user daemon-reload >/dev/null 2>&1

    # 交给 systemd 托管前，先停掉自管守护进程，避免端口冲突
    if supervisor_alive; then
        local pid; pid="$(cat "$PID_FILE")"
        kill -TERM -- "-$pid" 2>/dev/null; sleep 1
        kill -KILL -- "-$pid" 2>/dev/null
        rm -f "$PID_FILE"
        c_blu "已停用自管守护进程，改由 systemd 托管"
    fi

    systemctl --user enable "$UNIT_NAME" >/dev/null 2>&1
    systemctl --user restart "$UNIT_NAME" >/dev/null 2>&1

    # linger：允许未登录时开机启动
    if loginctl enable-linger "$USER" >/dev/null 2>&1; then
        c_grn "✔ 已开启 linger：开机后无需登录即可自动运行"
    else
        c_yel "提示: 未开启 linger，开机需登录后才启动。可执行: sudo loginctl enable-linger $USER"
    fi

    c_grn "✔ 开机自启已安装: $USER_UNIT_FILE"
    c_blu "  开机/重启后自动运行，崩溃自动拉起"
    c_blu "  查看日志: journalctl --user -u $UNIT_NAME -f"
    c_blu "  取消自启: ./start.sh disable"
}

disable_autostart() {
    if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
        systemctl --user disable --now "$UNIT_NAME" >/dev/null 2>&1
        rm -f "$USER_UNIT_FILE"
        systemctl --user daemon-reload >/dev/null 2>&1
        c_grn "✔ 已取消 systemd 开机自启"
    fi
    rm -f "$AUTOSTART_FILE"
    c_grn "✔ 已取消桌面自启动"
}

# ------------------------------------------------------------------ 状态 --

show_status() {
    echo "───────── Lan-clip 状态 ─────────"
    printf "  目录    : %s\n" "$APP_DIR"
    printf "  端口    : %s\n" "$PORT"
    printf "  Python  : %s (%s)\n" "$PYTHON" "$("$PYTHON" -V 2>&1)"

    if unit_active; then
        c_grn "  运行中  : systemd 服务 ${UNIT_NAME}.service (开机自启: $(unit_enabled && echo 已启用 || echo 未启用))"
    elif supervisor_alive; then
        c_grn "  运行中  : 守护进程 PID $(cat "$PID_FILE")"
    else
        c_yel "  运行中  : 否"
    fi

    if port_busy; then
        c_grn "  监听    : 0.0.0.0:$PORT ✔"
        c_blu "  本机    : http://127.0.0.1:$PORT"
        for ip in $(hostname -I 2>/dev/null); do
            case "$ip" in
                127.*|172.1[789].*) continue ;;
            esac
            c_blu "  局域网  : http://$ip:$PORT"
        done
    else
        c_yel "  监听    : 无"
    fi

    echo "  日志    : $LOG_FILE"
    echo "──────────────────────────────────"
}

# ------------------------------------------------------------------ 入口 --

cmd="${1:-start}"
case "$cmd" in
    start|stop|restart|status|enable|disable) ;;
    *) cmd="start" ;;
esac

if [ $# -gt 0 ] && [[ "${1:-}" =~ ^[0-9]+$ ]]; then
    PORT="$1"
    shift
fi
export LANCLIP_PORT="$PORT"

case "$cmd" in
    start)   start_daemon ;;
    stop)    stop_daemon ;;
    restart) stop_daemon; sleep 1; start_daemon ;;
    status)  show_status ;;
    enable)  enable_autostart ;;
    disable) disable_autostart ;;
esac
