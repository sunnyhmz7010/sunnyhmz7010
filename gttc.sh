#!/usr/bin/env bash

# 上游仓库：https://github.com/edmond1294/GoogleToThisCountry
#
# 本脚本仅作为轻量包装器：
# - 每次运行自动获取上游 main 分支最新脚本；
# - 不安装 gttc 快捷指令；
# - 使用临时 Python venv，退出后自动删除，不污染全局 Python 环境；
# - 不自动通过 apt/apk/yum 安装系统依赖，也不自动安装 Xray/V2Ray。
#
# 注意：GTTC 的实际功能仍会按上游逻辑修改现有 Xray/V2Ray 配置，
# 并创建/管理 gttc-ping 保活服务；这些属于功能本身必须的系统级操作。

set -Ee -o pipefail

UPSTREAM_REPO="edmond1294/GoogleToThisCountry"
UPSTREAM_REF="${GTTC_UPSTREAM_REF:-main}"
UPSTREAM_URL="https://raw.githubusercontent.com/${UPSTREAM_REPO}/${UPSTREAM_REF}/gttc.sh"

TMP_DIR=""
VENV_DIR=""
UPSTREAM_SCRIPT=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

cleanup() {
    if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT INT TERM

fail() {
    echo -e "${RED}[错误] $*${NC}" >&2
    exit 1
}

prepare_workspace() {
    command -v python3 >/dev/null 2>&1 || \
        fail "未检测到 python3。为避免改动本机环境，本脚本不会自动安装，请先自行安装。"

    TMP_DIR=$(mktemp -d) || fail "无法创建临时目录。"
    VENV_DIR="$TMP_DIR/venv"
    UPSTREAM_SCRIPT="$TMP_DIR/gttc-upstream.sh"

    if ! python3 -m venv --without-pip "$VENV_DIR" >/dev/null 2>&1; then
        fail "无法创建 Python venv。请确认当前 Python 支持 venv；本脚本不会自动安装 python3-venv 等系统包。"
    fi

    export VIRTUAL_ENV="$VENV_DIR"
    export PATH="$VIRTUAL_ENV/bin:$PATH"
    unset PYTHONHOME 2>/dev/null || true
}

fetch_upstream() {
    echo -e "${YELLOW}正在获取上游最新脚本 (${UPSTREAM_REF})...${NC}"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --connect-timeout 10 \
            "${UPSTREAM_URL}?$(date +%s)" -o "$UPSTREAM_SCRIPT" || \
            fail "获取上游脚本失败。"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$UPSTREAM_SCRIPT" "${UPSTREAM_URL}?$(date +%s)" || \
            fail "获取上游脚本失败。"
    else
        fail "未检测到 curl 或 wget。为避免改动本机环境，本脚本不会自动安装。"
    fi

    [ -s "$UPSTREAM_SCRIPT" ] || fail "获取到的上游脚本为空。"
}

prepare_upstream() {
    "$VENV_DIR/bin/python" - "$UPSTREAM_SCRIPT" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

# 上游脚本当前会在文件末尾直接执行以下三步。
# 包装器需要先只加载函数，再覆盖安装行为，因此必须去掉自动入口。
entry = re.compile(r"\ncheck_warp\s*\ninstall_core\s*\nshow_menu\s*\Z")
if not entry.search(text):
    raise SystemExit(
        "上游脚本结构已发生变化，未找到预期入口。为避免未经检查地执行新结构，已停止运行。"
    )
text = entry.sub("\n", text)

# 仅调整菜单文案；实际行为由包装器中的同名函数覆盖。
text = text.replace(
    "一键安装/修复 核心服务与依赖环境",
    "检查运行环境（不自动安装系统依赖）",
)
text = text.replace(
    " 💡 提示：后续可在命令行直接输入 ${GREEN}gttc${NC} 呼出本菜单",
    " 💡 提示：本包装脚本不会安装 ${GREEN}gttc${NC} 快捷指令",
)

path.write_text(text, encoding="utf-8")
PY
}

prepare_workspace
fetch_upstream
prepare_upstream

# shellcheck disable=SC1090
source "$UPSTREAM_SCRIPT"

# 覆盖上游快捷指令安装：始终不做任何持久化安装。
setup_shortcut() {
    return 0
}

# 覆盖上游环境安装：只检查，不自动修改系统软件环境。
install_core() {
    local missing=()
    local cmd

    for cmd in bash python3; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        missing+=("curl/wget")
    fi

    if [ "${#missing[@]}" -gt 0 ]; then
        echo -e "${RED}缺少运行依赖：${missing[*]}${NC}"
        echo -e "${YELLOW}为避免改动本机环境，本脚本不会自动安装，请自行补齐后重试。${NC}"
        return 1
    fi

    find_config
    if [ -z "$XRAY_CONF" ]; then
        echo -e "${YELLOW}未检测到现有 Xray/V2Ray 配置。${NC}"
        echo -e "${YELLOW}为避免改动本机环境，本脚本不会自动安装核心服务。${NC}"
        return 1
    fi

    echo -e "${GREEN}运行环境检查通过：$XRAY_CONF${NC}"
    echo -e "${GREEN}Python 临时虚拟环境：$VIRTUAL_ENV${NC}"
}

check_warp
install_core || true
show_menu
