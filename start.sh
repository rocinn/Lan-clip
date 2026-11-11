#!/bin/bash
# ==============================================================================
#  Lan-clip 启动脚本（本机 Linux 版）
#
#  用法:
#    ./start.sh                  # 启动服务（后台常驻，默认端口 5000）
#    ./start.sh 5001             # 指定端口启动（已 enable 时同步重写 systemd 单元并重启）
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

# loginctl / systemd 用户级自启需要用户名；个别精简环境不会导出 USER
USER="${USER:-$(id -un)}"

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${LANCLIP_PORT:-5000}"
UNIT_NAME="lanclip"

# 解释器选择：优先项目内 .venv。
# 本机（Loongnix 25 / LoongArch）的系统 Python 没有 pip/flask，
# 依赖装在 .venv 里，直接写 python3 会启动失败。
if [ -n "${LANCLIP_PYTHON:-}" ]; then
    PYTHON="$LANCLIP_PYTHON"
elif [ -x "$APP_DIR/.venv/bin/python" ]; then
    PYTHON="$APP_DIR/.venv/bin/python"
else
    PYTHON="python3"
fi

# systemd 的 ExecStart 只接受绝对路径
case "$PYTHON" in
    /*) ;;
    *) PYTHON="$(command -v "$PYTHON" 2>/dev/null || printf '%s' "$PYTHON")" ;;
esac

RUN_DIR="$APP_DIR/run"
LOG_DIR="$APP_DIR/logs"
PID_FILE="$RUN_DIR/lanclip.pid"
LOG_FILE="$LOG_DIR/lanclip.log"
USER_UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
USER_UNIT_FILE="$USER_UNIT_DIR/${UNIT_NAME}.service"
AUTOSTART_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/lan-clip.desktop"
UNIT_PORT_CHANGED=0

cd "$APP_DIR" || exit 1

# ------------------------------------------------------------------ 基础函数 --

c_red()  { printf '\033[31m%s\033[0m\n' "$*"; }
c_grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
c_yel()  { printf '\033[33m%s\033[0m\n' "$*"; }
c_blu()  { printf '\033[34m%s\033[0m\n' "$*"; }

# 打印局域网访问地址（app 的 Waitress 只绑定 IPv4，不展示不可达的 IPv6）
print_lan_urls() {
    local ip
    for ip in $(hostname -I 2>/dev/null); do
        case "$ip" in
            127.*|169.254.*|100.64.*|172.1[789].*|*:*) continue ;;
        esac
        c_blu "  局域网:   http://$ip:$PORT"
    done
}

# firewalld 状态查询（只读，不自动修改防火墙）
firewalld_running() {
    command -v firewall-cmd >/dev/null 2>&1 || return 1
    firewall-cmd --state >/dev/null 2>&1
}

firewall_port_open() {
    firewalld_running || return 1
    firewall-cmd --query-port="$PORT/tcp" >/dev/null 2>&1
}

firewall_port_persistent() {
    firewalld_running || return 1
    firewall-cmd --permanent --query-port="$PORT/tcp" >/dev/null 2>&1
}

warn_if_firewall_closed() {
    firewalld_running || return 0
    if ! firewall_port_open; then
        c_yel "  注意: firewalld 当前未放行 $PORT/tcp，局域网设备会被拦截。"
        c_blu "  放行: firewall-cmd --permanent --add-port=$PORT/tcp && firewall-cmd --reload"
    elif ! firewall_port_persistent; then
        c_yel "  注意: firewalld 未持久化 $PORT/tcp，重启后会失效。"
        c_blu "  持久化: firewall-cmd --permanent --add-port=$PORT/tcp"
    fi
}

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

# 读取已安装 systemd 单元里配置的端口（取第一个 --port）
unit_configured_port() {
    [ -f "$USER_UNIT_FILE" ] || return 1
    sed -n 's/.*--port[= ][[:space:]]*\([0-9][0-9]*\).*/\1/p' "$USER_UNIT_FILE" | head -n1
}

# ------------------------------------------------------------ 守护进程启动 --

start_daemon() {
    mkdir -p "$RUN_DIR" "$LOG_DIR"

    if unit_active; then
        if [ "$UNIT_PORT_CHANGED" = "1" ]; then
            systemctl --user restart "$UNIT_NAME" >/dev/null 2>&1
            if health_check; then
                c_grn "✔ systemd 服务已切换到端口 $PORT"
                c_blu "  本机访问: http://127.0.0.1:$PORT"
                print_lan_urls
                warn_if_firewall_closed
                return 0
            fi
            c_red "切换端口后未通过健康检查，请查看: journalctl --user -u $UNIT_NAME -n 30"
            return 1
        fi
        c_blu "服务已由 systemd 托管运行中，无需重复启动。"
        c_blu "如需重启请执行: ./start.sh restart"
        warn_if_firewall_closed
        return 0
    fi

    # 已安装开机自启(systemd)但当前没跑: 交给 systemd 拉起，保持单一管理者
    if unit_enabled; then
        systemctl --user start "$UNIT_NAME" >/dev/null 2>&1
        if health_check; then
            c_grn "✔ Lan-clip 已由 systemd 启动 (端口 $PORT)"
            c_blu "  本机访问: http://127.0.0.1:$PORT"
            warn_if_firewall_closed
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
        c_red "缺少依赖（当前解释器: $PYTHON）"
        c_blu "  Loongnix/LoongArch 的系统 Python 没有 pip，依赖应装在项目 .venv 中。"
        c_blu "  修复: ./setup.sh"
        c_blu "  或手动: $PYTHON -m pip install flask waitress qrcode"
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
        print_lan_urls
        warn_if_firewall_closed
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
ExecStart="$PYTHON" "$APP_DIR/app.py" --port $PORT
Environment=PYTHONUNBUFFERED=1
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
        warn_if_firewall_closed
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
    warn_if_firewall_closed
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
    printf "  平台    : %s %s\n" "$(uname -s)" "$(uname -m)"
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
        print_lan_urls
        warn_if_firewall_closed
    else
        c_yel "  监听    : 无"
    fi

    echo "  日志    : $LOG_FILE"
    echo "──────────────────────────────────"
}

# ------------------------------------------------------------------ 入口 --

# 参数解析：命令和端口顺序任意，例如 start.sh 5080 enable / start.sh enable 5080
cmd=""
PORT_ARG=""
for arg in "$@"; do
    if [ -z "$PORT_ARG" ] && [[ "$arg" =~ ^[0-9]+$ ]]; then
        PORT_ARG="$arg"
    elif [ -z "$cmd" ]; then
        cmd="$arg"
    fi
done
cmd="${cmd:-start}"
case "$cmd" in
    start|stop|restart|status|enable|disable) ;;
    *) cmd="start" ;;
esac

# 端口是否由用户显式指定（命令行或 LANCLIP_PORT）
PORT_EXPLICIT=0
[ -n "${LANCLIP_PORT:-}" ] && PORT_EXPLICIT=1
if [ -n "$PORT_ARG" ]; then
    PORT="$PORT_ARG"
    PORT_EXPLICIT=1
fi

# systemd 已启用时，单元里的 --port 才是实际端口：
#   * 未显式指定端口 -> 沿用单元端口（避免 status/start 显示错端口）
#   * 显式指定了不同端口 -> 重写单元并重启（让 ./start.sh 5080 真正生效）
if unit_enabled; then
    configured_port="$(unit_configured_port 2>/dev/null || true)"
    if [ -n "${configured_port:-}" ]; then
        case "$cmd" in
            start|restart)
                if [ "$PORT_EXPLICIT" = "1" ] && [ "$configured_port" != "$PORT" ]; then
                    c_blu "更新 systemd 服务端口: $configured_port -> $PORT"
                    write_user_unit
                    if ! systemctl --user daemon-reload >/dev/null 2>&1; then
                        c_red "systemd 配置重载失败，请检查: systemctl --user status $UNIT_NAME"
                        exit 1
                    fi
                    UNIT_PORT_CHANGED=1
                elif [ "$PORT_EXPLICIT" = "0" ]; then
                    PORT="$configured_port"
                fi
                ;;
            status)
                PORT="$configured_port"
                ;;
            stop)
                [ "$PORT_EXPLICIT" = "0" ] && PORT="$configured_port"
                ;;
        esac
    fi
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
