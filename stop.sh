#!/bin/bash
# ==============================================================================
#  Lan-clip 停止脚本（本机 Linux 版）
#
#  用法:
#    ./stop.sh            # 停止服务（默认端口 5000）
#    ./stop.sh 5001       # 停止指定端口的服务
#
#  停止顺序:
#    1. systemd 用户服务（若通过 ./start.sh enable 安装）
#    2. 自管守护进程（按进程组结束，子进程一并回收）
#    3. 兜底清理残留的 app.py 进程
#
#  注意: 本脚本只停止，不会取消开机自启。
#        如需连开机自启一起取消，执行: ./start.sh disable
# ==============================================================================

set -u

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${LANCLIP_PORT:-5000}"
UNIT_NAME="lanclip"
USER_UNIT_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/${UNIT_NAME}.service"

# 与 start.sh 保持一致：优先项目内 .venv（本机系统 Python 没有 flask/依赖）
if [ -n "${LANCLIP_PYTHON:-}" ]; then
    PYTHON="$LANCLIP_PYTHON"
elif [ -x "$APP_DIR/.venv/bin/python" ]; then
    PYTHON="$APP_DIR/.venv/bin/python"
else
    PYTHON="python3"
fi

case "$PYTHON" in
    /*) ;;
    *) PYTHON="$(command -v "$PYTHON" 2>/dev/null || printf '%s' "$PYTHON")" ;;
esac

RUN_DIR="$APP_DIR/run"
PID_FILE="$RUN_DIR/lanclip.pid"
LOG_DIR="$APP_DIR/logs"
LOG_FILE="$LOG_DIR/lanclip.log"

cd "$APP_DIR" || exit 1

c_red() { printf '\033[31m%s\033[0m\n' "$*"; }
c_grn() { printf '\033[32m%s\033[0m\n' "$*"; }
c_yel() { printf '\033[33m%s\033[0m\n' "$*"; }
c_blu() { printf '\033[34m%s\033[0m\n' "$*"; }

PORT_EXPLICIT=0
[ -n "${LANCLIP_PORT:-}" ] && PORT_EXPLICIT=1

if [ $# -gt 0 ] && [[ "${1:-}" =~ ^[0-9]+$ ]]; then
    PORT="$1"
    PORT_EXPLICIT=1
fi

# 未显式指定端口时，沿用 systemd 单元里配置的端口，保证停止后的端口检查准确
if [ "$PORT_EXPLICIT" = "0" ] && [ -f "$USER_UNIT_FILE" ]; then
    configured_port="$(sed -n 's/.*--port[= ][[:space:]]*\([0-9][0-9]*\).*/\1/p' "$USER_UNIT_FILE" | head -n1)"
    [ -n "${configured_port:-}" ] && PORT="$configured_port"
fi

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

stopped=0

# 1) systemd 用户服务
if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    if systemctl --user is-active --quiet "$UNIT_NAME" 2>/dev/null; then
        systemctl --user stop "$UNIT_NAME" >/dev/null 2>&1
        c_blu "已停止 systemd 服务: ${UNIT_NAME}.service"
        stopped=1
    fi
fi

# 2) 自管守护进程（整组结束）
if [ -f "$PID_FILE" ]; then
    pid="$(cat "$PID_FILE" 2>/dev/null)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill -TERM -- "-$pid" 2>/dev/null
        i=0
        while [ "$i" -lt 20 ]; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.25
            i=$((i + 1))
        done
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL -- "-$pid" 2>/dev/null
        fi
        c_blu "已停止守护进程 (PID $pid)"
        stopped=1
    fi
    rm -f "$PID_FILE"
fi

# 3) 兜底清理残留进程
if pgrep -f "app\.py --port $PORT" >/dev/null 2>&1; then
    pkill -TERM -f "app\.py --port $PORT" 2>/dev/null
    sleep 1
    pkill -KILL -f "app\.py --port $PORT" 2>/dev/null
    c_blu "已清理残留进程 (app.py --port $PORT)"
    stopped=1
fi

sleep 0.5
if port_busy; then
    c_red "✘ 端口 $PORT 仍被占用，请手动查看: ss -ltnp | grep :$PORT"
    exit 1
fi

if [ "$stopped" = "1" ]; then
    c_grn "✔ Lan-clip 已停止"
    echo "  日志保留在: $LOG_FILE"
else
    c_yel "Lan-clip 当前没有运行"
fi
exit 0
