#!/bin/bash
# ==============================================================================
#  Lan-clip 依赖安装脚本（Linux / LoongArch 本机适配）
#
#  用法:
#    ./setup.sh
#
#  说明:
#    * 本机（Loongnix 25 / LoongArch64）的系统 Python 3.13 没有 pip/ensurepip，
#      直接 `pip install` 不可用；这里在项目内创建 .venv，并只安装服务端所需依赖。
#    * 默认使用清华 PyPI 镜像，可用 PIP_INDEX_URL 覆盖。
#    * 托盘模式还需要 Pillow / pystray / pyperclip 和 xclip；
#      LoongArch 上 Pillow 没有 PyPI 轮子、本机也没有 xclip，故本脚本不安装，
#      普通 Web 服务不需要它们。
# ==============================================================================

set -u

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$APP_DIR/.venv"
BASE_PYTHON="${LANCLIP_BASE_PYTHON:-python3}"
INDEX_URL="${PIP_INDEX_URL:-https://pypi.tuna.tsinghua.edu.cn/simple}"

cd "$APP_DIR" || exit 1

c_red() { printf '\033[31m%s\033[0m\n' "$*"; }
c_grn() { printf '\033[32m%s\033[0m\n' "$*"; }
c_blu() { printf '\033[34m%s\033[0m\n' "$*"; }
c_yel() { printf '\033[33m%s\033[0m\n' "$*"; }

core_ready() {
    [ -x "$VENV/bin/python" ] || return 1
    "$VENV/bin/python" -c "import flask, waitress, qrcode" 2>/dev/null
}

if core_ready; then
    c_grn "✔ 依赖已就绪: $VENV"
    "$VENV/bin/python" -c "import flask, waitress, qrcode; print('  flask/waitress/qrcode 可正常导入')"
    exit 0
fi

if ! command -v "$BASE_PYTHON" >/dev/null 2>&1; then
    c_red "找不到基础解释器: $BASE_PYTHON"
    exit 1
fi

c_blu "使用基础解释器: $("$BASE_PYTHON" -V 2>&1) ($BASE_PYTHON)"
c_blu "项目虚拟环境: $VENV"

# ---------------------------------------------------------------- 创建 venv --
if [ ! -x "$VENV/bin/python" ]; then
    rm -rf "$VENV"
    c_blu "创建虚拟环境（优先 python3 -m venv）..."
    if ! "$BASE_PYTHON" -m venv "$VENV" 2>/dev/null; then
        # Debian/Loongnix 的 python3 常常没装 ensurepip，venv 会留下半成品
        rm -rf "$VENV"
        c_yel "python3 -m venv 不可用（缺少 ensurepip），改用 virtualenv..."
        if "$BASE_PYTHON" -m virtualenv "$VENV" 2>/dev/null; then
            :
        elif command -v virtualenv >/dev/null 2>&1 && virtualenv -p "$BASE_PYTHON" "$VENV" 2>/dev/null; then
            :
        else
            c_red "创建虚拟环境失败。请先安装其一："
            c_blu "  sudo apt install python3-venv"
            c_blu "  python3 -m pip install --user virtualenv"
            exit 1
        fi
    fi
fi

PY="$VENV/bin/python"
if ! "$PY" -m pip --version >/dev/null 2>&1; then
    c_red "虚拟环境里没有 pip，无法安装依赖。"
    c_blu "可删除 $VENV 后重试，或安装 python3-venv 后重新执行。"
    exit 1
fi

# ------------------------------------------------------------ 安装依赖 --
c_blu "安装服务端依赖: flask waitress qrcode"
if ! "$PY" -m pip install --disable-pip-version-check -i "$INDEX_URL" \
        flask waitress qrcode; then
    c_red "依赖安装失败，请检查网络或 PIP_INDEX_URL"
    exit 1
fi

if ! core_ready; then
    c_red "安装完成但仍无法导入依赖，请检查 .venv"
    exit 1
fi

c_grn "✔ 依赖安装完成"
c_blu "  启动服务: ./start.sh"
c_blu "  查看状态: ./start.sh status"
c_yel "  提示: 托盘模式（--tray）在 LoongArch 上还需要 Pillow 与 xclip，本脚本未安装。"
