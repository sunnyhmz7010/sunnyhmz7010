#!/usr/bin/env bash

# 上游仓库：https://github.com/edmond1294/GoogleToThisCountry
#
# 本脚本参考 NodeQuality 的临时系统思路：
# - 每次运行自动获取上游 main 分支最新脚本；
# - 下载临时 Alpine minirootfs，并在 chroot 中安装/运行所需工具；
# - 不在宿主机安装 Python/jq/unzip 等运行依赖；
# - 不安装 gttc 快捷指令；
# - 退出后卸载并删除整个临时系统。
#
# GTTC 本身需要持久化 Xray/V2Ray 配置和保活服务才能在脚本退出后继续生效。
# 因此：启用期间仅保留必要状态；执行“关闭”后会恢复启用前的 Xray/V2Ray
# 配置，并删除 GTTC 创建的服务、保活脚本和状态文件。

set -Eeuo pipefail

UPSTREAM_REPO="edmond1294/GoogleToThisCountry"
UPSTREAM_REF="${GTTC_UPSTREAM_REF:-main}"
UPSTREAM_URL="https://raw.githubusercontent.com/${UPSTREAM_REPO}/${UPSTREAM_REF}/gttc.sh"

ALPINE_BASE="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases"

TMP_DIR=""
ROOTFS=""
UPSTREAM_SCRIPT=""
PATCHED_SCRIPT=""
HOST_INIT=""
HOST_XRAY_CONF=""

MOUNTS=()

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

fail() {
    echo -e "${RED}[错误] $*${NC}" >&2
    exit 1
}

require_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        fail "本脚本需要 root 权限运行。"
    fi
}

check_host_tools() {
    local missing=()
    local cmd

    for cmd in bash curl tar mount umount chroot awk grep sed mktemp tail tr sort dirname; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        fail "宿主机缺少基础命令：${missing[*]}。脚本不会自动安装宿主机依赖。"
    fi
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "x86_64" ;;
        aarch64|arm64) echo "aarch64" ;;
        armv7l|armv7) echo "armv7" ;;
        riscv64) echo "riscv64" ;;
        *) fail "暂不支持当前架构：$(uname -m)" ;;
    esac
}

detect_host_init() {
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        HOST_INIT="systemd"
    elif command -v rc-service >/dev/null 2>&1; then
        HOST_INIT="openrc"
    else
        fail "仅支持 systemd 或 OpenRC 宿主机。"
    fi
}

find_host_xray_config() {
    local path
    for path in \
        /etc/xray/config.json \
        /usr/local/etc/xray/config.json \
        /etc/v2ray/config.json \
        /usr/local/etc/v2ray/config.json; do
        if [ -f "$path" ]; then
            HOST_XRAY_CONF="$path"
            return 0
        fi
    done
    return 1
}

resolve_alpine_rootfs() {
    local arch="$1"
    local index url filename

    url="${ALPINE_BASE}/${arch}"
    index=$(curl -fsSL --retry 3 --connect-timeout 10 "${url}/") || \
        fail "无法获取 Alpine 版本信息。"

    filename=$(printf '%s\n' "$index" \
        | grep -oE "alpine-minirootfs-[0-9][0-9A-Za-z._-]*-${arch}\\.tar\\.gz" \
        | grep -v '_rc' \
        | sort -V \
        | tail -n 1)

    [ -n "$filename" ] || fail "无法解析 Alpine minirootfs 文件名。"
    printf '%s/%s\n' "$url" "$filename"
}

add_mount() {
    MOUNTS+=("$1")
}

bind_mount() {
    local src="$1"
    local dst="$2"

    mkdir -p "$dst"
    mount --bind "$src" "$dst"
    add_mount "$dst"
}

rbind_mount() {
    local src="$1"
    local dst="$2"

    mkdir -p "$dst"
    mount --rbind "$src" "$dst"
    mount --make-rslave "$dst"
    add_mount "$dst"
}

cleanup() {
    local i mp
    trap - EXIT INT TERM HUP

    for ((i=${#MOUNTS[@]}-1; i>=0; i--)); do
        mp="${MOUNTS[$i]}"
        umount -R "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
    done

    if [ -n "${ROOTFS:-}" ] && grep -Fq " ${ROOTFS}/" /proc/self/mountinfo 2>/dev/null; then
        echo -e "${RED}[警告] 临时系统仍存在挂载点，为避免误删宿主机文件，已保留：${TMP_DIR}${NC}" >&2
        return
    fi

    if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
        rm -rf -- "$TMP_DIR"
    fi

    # 未启用或已经关闭 GTTC 时，状态目录应为空，顺手清除。
    rmdir /var/lib/gttc 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP

prepare_rootfs() {
    local arch rootfs_url

    arch=$(detect_arch)
    rootfs_url=$(resolve_alpine_rootfs "$arch")

    TMP_DIR=$(mktemp -d /tmp/gttc.XXXXXX)
    ROOTFS="$TMP_DIR/rootfs"
    UPSTREAM_SCRIPT="$TMP_DIR/gttc-upstream.sh"
    PATCHED_SCRIPT="$ROOTFS/tmp/gttc.sh"

    mkdir -p "$ROOTFS"

    echo -e "${YELLOW}正在加载临时 Alpine 系统...${NC}"
    curl -fL --retry 3 --connect-timeout 10 "$rootfs_url" -o "$TMP_DIR/alpine.tar.gz"
    tar -xzf "$TMP_DIR/alpine.tar.gz" -C "$ROOTFS"

    cp -L /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

    mount -t proc proc "$ROOTFS/proc"
    add_mount "$ROOTFS/proc"

    rbind_mount /sys "$ROOTFS/sys"
    rbind_mount /dev "$ROOTFS/dev"

    chroot "$ROOTFS" /bin/sh -c \
        'apk add --no-cache bash curl python3 jq unzip ca-certificates util-linux-misc >/dev/null'

    # 所有持久化目标均在安装临时依赖之后再挂入，避免 apk 触碰宿主机目录。
    mkdir -p /var/lib/gttc
    bind_mount /var/lib/gttc "$ROOTFS/var/lib/gttc"

    mkdir -p /usr/local/bin
    bind_mount /usr/local/bin "$ROOTFS/usr/local/bin"

    if [ "$HOST_INIT" = "systemd" ]; then
        mkdir -p /etc/systemd/system
        bind_mount /etc/systemd/system "$ROOTFS/etc/systemd/system"
    else
        mkdir -p /etc/init.d /etc/runlevels
        bind_mount /etc/init.d "$ROOTFS/etc/init.d"
        bind_mount /etc/runlevels "$ROOTFS/etc/runlevels"
    fi

    if [ -n "$HOST_XRAY_CONF" ]; then
        local conf_dir
        conf_dir=$(dirname "$HOST_XRAY_CONF")
        mkdir -p "$ROOTFS$conf_dir"
        bind_mount "$conf_dir" "$ROOTFS$conf_dir"
    fi
}

fetch_upstream() {
    echo -e "${YELLOW}正在获取 GTTC 上游最新脚本 (${UPSTREAM_REF})...${NC}"
    curl -fsSL --retry 3 --connect-timeout 10 \
        "${UPSTREAM_URL}?$(date +%s)" -o "$UPSTREAM_SCRIPT" || \
        fail "获取上游脚本失败。"

    [ -s "$UPSTREAM_SCRIPT" ] || fail "获取到的上游脚本为空。"
}

patch_upstream() {
    local tail3

    tail3=$(tail -n 3 "$UPSTREAM_SCRIPT" | tr -d '\r')
    if [ "$tail3" != $'check_warp\ninstall_core\nshow_menu' ]; then
        fail "上游脚本入口结构已变化，已停止执行，避免未经检查地运行新结构。"
    fi

    # 去掉上游自动入口，由下面的覆盖逻辑接管。
    sed '$d' "$UPSTREAM_SCRIPT" | sed '$d' | sed '$d' > "$PATCHED_SCRIPT"

    # 不留下 .bak；真正的“启用前原配置”保存在 /var/lib/gttc 中，关闭时恢复。
    sed -i \
        's|cp "$XRAY_CONF" "${XRAY_CONF}.bak"|cp "$XRAY_CONF" "/tmp/gttc-xray-config.bak"|g' \
        "$PATCHED_SCRIPT"

    sed -i \
        's|一键安装/修复 核心服务与依赖环境|检查宿主机核心服务与运行环境|g' \
        "$PATCHED_SCRIPT"

    sed -i \
        's| 💡 提示：后续可在命令行直接输入 ${GREEN}gttc${NC} 呼出本菜单| 💡 提示：本脚本不会安装 ${GREEN}gttc${NC} 快捷指令|g' \
        "$PATCHED_SCRIPT"

    cat >> "$PATCHED_SCRIPT" <<'OVERRIDES'

GTTC_STATE_DIR="/var/lib/gttc"
GTTC_ORIGINAL_CONFIG="$GTTC_STATE_DIR/original-config.json"
CONFIG_TAG_FILE="$GTTC_STATE_DIR/country.conf"

host_exec() {
    nsenter -t 1 -m -r -- "$@"
}

setup_shortcut() {
    return 0
}

find_config() {
    XRAY_CONF=""
    for path in \
        "/etc/xray/config.json" \
        "/usr/local/etc/xray/config.json" \
        "/etc/v2ray/config.json" \
        "/usr/local/etc/v2ray/config.json"; do
        if [ -f "$path" ]; then
            XRAY_CONF="$path"
            break
        fi
    done
}

install_core() {
    find_config

    if [ -z "$XRAY_CONF" ]; then
        echo -e "${RED}未检测到宿主机现有 Xray/V2Ray 配置。${NC}"
        echo -e "${YELLOW}临时系统不会向宿主机安装 Xray/V2Ray，请先自行安装核心服务。${NC}"
        return 1
    fi

    echo -e "${GREEN}宿主机核心配置：$XRAY_CONF${NC}"
    echo -e "${GREEN}运行依赖位于临时 Alpine 系统，退出后会全部删除。${NC}"
}

create_ping_service() {
    local lang_header="$1"

    cat << EOF > "$PING_SCRIPT"
#!/usr/bin/env bash
UA_MOBILE="Mozilla/5.0 (Linux; Android 14; Pixel 8 Build/UD1A.230803.041) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.6261.119 Mobile Safari/537.36"

endpoints=(
    "https://www.google.com/generate_204"
    "https://connectivitycheck.gstatic.com/generate_204"
    "https://clients3.google.com/generate_204"
    "https://location.services.mozilla.com/v1/geolocate"
    "https://play.googleapis.com/generate_204"
    "https://safebrowsing.googleapis.com/v4/threatListUpdates:fetch"
)

while true; do
    ip=\$(curl -s4 --connect-timeout 5 https://api.ipify.org 2>/dev/null || curl -s4 --connect-timeout 5 https://ifconfig.me 2>/dev/null || echo "")
    if [[ "\$ip" =~ ^104\\.28\\. ]]; then
        echo "Detected WARP environment (\$ip), stopping services."
        exit 1
    fi

    for url in "\${endpoints[@]}"; do
        curl -s -A "\$UA_MOBILE" \
             -H "Accept-Language: ${lang_header}" \
             -H "Cache-Control: no-cache" \
             --connect-timeout 5 \
             "\$url" >/dev/null 2>&1 || true
    done

    sleep 600
done
EOF
    chmod +x "$PING_SCRIPT"

    if [ "$GTTC_HOST_INIT" = "openrc" ]; then
        cat << 'EOF' > "$SERVICE_FILE_OPENRC"
#!/sbin/openrc-run

name="gttc-ping"
description="Google Country Location Keep-Alive Service"
command="/usr/local/bin/gttc_ping.sh"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"

depend() {
    need net
}
EOF
        chmod +x "$SERVICE_FILE_OPENRC"
        host_exec rc-update add gttc-ping default >/dev/null 2>&1 || true
    else
        cat << EOF > "$SERVICE_FILE_SYSTEMD"
[Unit]
Description=Google Country Location Keep-Alive Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/gttc_ping.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        host_exec systemctl daemon-reload >/dev/null 2>&1 || true
    fi
}

restart_service() {
    local action="$1"

    echo -e "${YELLOW}正在操作宿主机相关服务...${NC}"

    if [ "$GTTC_HOST_INIT" = "openrc" ]; then
        host_exec rc-service xray "$action" 2>/dev/null || \
            host_exec rc-service v2ray "$action" 2>/dev/null || true

        if [ "$action" = "restart" ] || [ "$action" = "start" ]; then
            host_exec rc-update add gttc-ping default >/dev/null 2>&1 || true
            host_exec rc-service gttc-ping restart >/dev/null 2>&1 || true
        else
            host_exec rc-service gttc-ping stop >/dev/null 2>&1 || true
            host_exec rc-update del gttc-ping default >/dev/null 2>&1 || true
        fi
    else
        host_exec systemctl "$action" xray 2>/dev/null || \
            host_exec systemctl "$action" v2ray 2>/dev/null || true

        if [ "$action" = "restart" ] || [ "$action" = "start" ]; then
            host_exec systemctl enable gttc-ping.service >/dev/null 2>&1 || true
            host_exec systemctl restart gttc-ping.service >/dev/null 2>&1 || true
        else
            host_exec systemctl stop gttc-ping.service >/dev/null 2>&1 || true
            host_exec systemctl disable gttc-ping.service >/dev/null 2>&1 || true
        fi
    fi
}

cleanup_gttc_artifacts() {
    rm -f "$PING_SCRIPT"

    if [ "$GTTC_HOST_INIT" = "openrc" ]; then
        host_exec rc-service gttc-ping stop >/dev/null 2>&1 || true
        host_exec rc-update del gttc-ping default >/dev/null 2>&1 || true
        rm -f "$SERVICE_FILE_OPENRC"
    else
        host_exec systemctl stop gttc-ping.service >/dev/null 2>&1 || true
        host_exec systemctl disable gttc-ping.service >/dev/null 2>&1 || true
        rm -f "$SERVICE_FILE_SYSTEMD"
        host_exec systemctl daemon-reload >/dev/null 2>&1 || true
    fi
}

eval "$(declare -f enable_target_country | sed '1s/^enable_target_country/original_enable_target_country/')"

enable_target_country() {
    find_config

    if [ -z "$XRAY_CONF" ] || [ ! -f "$XRAY_CONF" ]; then
        echo -e "${RED}错误：未找到宿主机 Xray/V2Ray 配置！${NC}"
        return
    fi

    mkdir -p "$GTTC_STATE_DIR"

    if [ ! -f "$GTTC_ORIGINAL_CONFIG" ]; then
        cp "$XRAY_CONF" "$GTTC_ORIGINAL_CONFIG"
    fi

    original_enable_target_country
}

disable_target_country() {
    find_config

    if [ -z "$XRAY_CONF" ] || [ ! -f "$XRAY_CONF" ]; then
        echo -e "${RED}错误：未找到宿主机 Xray/V2Ray 配置！${NC}"
        return
    fi

    if [ -f "$GTTC_ORIGINAL_CONFIG" ]; then
        cp "$GTTC_ORIGINAL_CONFIG" "$XRAY_CONF"
        rm -f "$GTTC_ORIGINAL_CONFIG"
        echo -e "${GREEN}已恢复开启 GTTC 前的原始核心配置。${NC}"
    else
        echo -e "${YELLOW}未找到 GTTC 保存的原始配置，仅清理 GTTC 服务状态。${NC}"
    fi

    rm -f "$CONFIG_TAG_FILE"
    cleanup_gttc_artifacts

    if [ "$GTTC_HOST_INIT" = "openrc" ]; then
        host_exec rc-service xray restart 2>/dev/null || \
            host_exec rc-service v2ray restart 2>/dev/null || true
    else
        host_exec systemctl restart xray 2>/dev/null || \
            host_exec systemctl restart v2ray 2>/dev/null || true
    fi

    echo -e "${GREEN}✅ 已关闭 GTTC，恢复原配置并清理持久化服务与状态文件。${NC}"
}

check_warp
install_core || true
show_menu
OVERRIDES
}

run_in_temp_system() {
    echo -e "${CYAN}=================================================${NC}"
    echo -e "${CYAN} GTTC 临时系统：运行依赖不会安装到宿主机${NC}"
    echo -e "${CYAN}=================================================${NC}"

    GTTC_HOST_INIT="$HOST_INIT" \
        chroot "$ROOTFS" /usr/bin/env \
        GTTC_HOST_INIT="$HOST_INIT" \
        /bin/bash /tmp/gttc.sh
}

main() {
    require_root
    check_host_tools
    detect_host_init
    find_host_xray_config || true

    prepare_rootfs
    fetch_upstream
    patch_upstream
    run_in_temp_system
}

main "$@"
