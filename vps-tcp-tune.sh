#!/bin/bash

# 脚本原仓库：https://github.com/Eric86777/vps-tcp-tune
# 个性化精简、hosts文件整理

# 颜色定义（保留中文变量名以兼容现有代码）
gl_hong='\033[31m'      # 红色
gl_lv='\033[32m'        # 绿色
gl_huang='\033[33m'     # 黄色
gl_bai='\033[0m'        # 重置
gl_kjlan='\033[96m'     # 亮青色
gl_zi='\033[35m'        # 紫色
gl_hui='\033[90m'       # 灰色

# GitHub 代理设置
gh_proxy="https://"

# 配置文件路径（使用独立文件，不破坏系统配置）
SYSCTL_CONF="/etc/sysctl.d/99-bbr-ultimate.conf"

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${gl_hong}错误: ${gl_bai}此脚本需要 root 权限运行！"
        echo "请使用: sudo bash $0"
        exit 1
    fi
}

break_end() {
    [ "$AUTO_MODE" = "1" ] && return
    [ "${ONE_SHOT_MODE:-}" = "1" ] && return
    echo -e "${gl_lv}操作完成${gl_bai}"
    echo "按任意键继续..."
    read -n 1 -s -r -p ""
    echo ""
}

clean_sysctl_conf() {
    # 备份主配置文件
    if [ -f /etc/sysctl.conf ] && ! [ -f /etc/sysctl.conf.bak.original ]; then
        cp /etc/sysctl.conf /etc/sysctl.conf.bak.original
    fi
    
    # 注释所有冲突参数
    sed -i '/^net\.core\.rmem_max/s/^/# /' /etc/sysctl.conf 2>/dev/null
    sed -i '/^net\.core\.wmem_max/s/^/# /' /etc/sysctl.conf 2>/dev/null
    sed -i '/^net\.ipv4\.tcp_rmem/s/^/# /' /etc/sysctl.conf 2>/dev/null
    sed -i '/^net\.ipv4\.tcp_wmem/s/^/# /' /etc/sysctl.conf 2>/dev/null
    sed -i '/^net\.core\.default_qdisc/s/^/# /' /etc/sysctl.conf 2>/dev/null
    sed -i '/^net\.ipv4\.tcp_congestion_control/s/^/# /' /etc/sysctl.conf 2>/dev/null
}

install_package() {
    local packages=("$@")
    local missing_packages=()
    local os_release="/etc/os-release"
    local os_id=""
    local os_like=""
    local pkg_manager=""
    local update_cmd=()
    local install_cmd=()

    for package in "${packages[@]}"; do
        if ! command -v "$package" &>/dev/null; then
            missing_packages+=("$package")
        fi
    done

    if [ "${#missing_packages[@]}" -eq 0 ]; then
        return 0
    fi

    if [ -r "$os_release" ]; then
        # shellcheck disable=SC1091
        . "$os_release"
        os_id="${ID,,}"
        os_like="${ID_LIKE,,}"
    fi

    local detection="${os_id} ${os_like}"

    if [[ "$detection" =~ (debian|ubuntu) ]]; then
        pkg_manager="apt"
        update_cmd=(apt-get update)
        install_cmd=(apt-get install -y)
    elif [[ "$detection" =~ (rhel|centos|fedora|rocky|alma|redhat) ]]; then
        if command -v dnf &>/dev/null; then
            pkg_manager="dnf"
            update_cmd=(dnf makecache)
            install_cmd=(dnf install -y)
        elif command -v yum &>/dev/null; then
            pkg_manager="yum"
            update_cmd=(yum makecache)
            install_cmd=(yum install -y)
        else
            echo "错误: 未找到可用的 RHEL 系包管理器 (dnf 或 yum)" >&2
            return 1
        fi
    else
        echo "错误: 未支持的 Linux 发行版，无法自动安装依赖。请手动安装: ${missing_packages[*]}" >&2
        return 1
    fi

    if [ ${#update_cmd[@]} -gt 0 ]; then
        echo -e "${gl_huang}正在更新软件仓库...${gl_bai}"
        if ! "${update_cmd[@]}"; then
            echo "错误: 使用 ${pkg_manager} 更新软件仓库失败。" >&2
            return 1
        fi
    fi

    for package in "${missing_packages[@]}"; do
        echo -e "${gl_huang}正在安装 $package...${gl_bai}"
        if ! "${install_cmd[@]}" "$package"; then
            echo "错误: ${pkg_manager} 安装 $package 失败，请检查上方输出信息。" >&2
            return 1
        fi
    done
}

check_disk_space() {
    local required_gb=$1
    local required_space_mb=$((required_gb * 1024))
    local available_space_mb=$(df -m / | awk 'NR==2 {print $4}')

    if [ "$available_space_mb" -lt "$required_space_mb" ]; then
        echo -e "${gl_huang}警告: ${gl_bai}磁盘空间不足！"
        echo "当前可用: $((available_space_mb/1024))G | 最低需求: ${required_gb}G"
        read -e -p "是否继续？(Y/N): " continue_choice
        case "$continue_choice" in
            [Yy]) return 0 ;;
            *) return 1 ;;
        esac
    fi
}

disable_ipv6_permanent() {
    echo -e "${gl_kjlan}=== 永久禁用IPv6 ===${gl_bai}"
    echo ""
    echo "此操作将永久禁用IPv6，重启后仍然生效"
    echo "------------------------------------------------"
    echo ""
    
    # 检查是否已经永久禁用
    if [ -f /etc/sysctl.d/99-disable-ipv6.conf ]; then
        echo -e "${gl_huang}⚠️  检测到已存在永久禁用配置${gl_bai}"
        echo ""
        read -e -p "$(echo -e "${gl_huang}是否重新执行永久禁用？(Y/N): ${gl_bai}")" confirm

        case "$confirm" in
            [Yy])
                ;;
            *)
                echo "已取消"
                return 1
                ;;
        esac
    fi
    
    echo ""
    read -e -p "$(echo -e "${gl_huang}确认永久禁用IPv6？(Y/N): ${gl_bai}")" confirm

    case "$confirm" in
        [Yy])
            echo ""
            echo -e "${gl_zi}[步骤 1/2] 创建永久禁用配置...${gl_bai}"
            
            cat > /etc/sysctl.d/99-disable-ipv6.conf << EOF
# Permanently Disable IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
            
            echo -e "${gl_lv}✅ 配置文件已创建${gl_bai}"
            echo ""
            
            echo -e "${gl_zi}[步骤 2/2] 应用配置...${gl_bai}"
            sysctl --system >/dev/null 2>&1
            
            local ipv6_status=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
            
            echo ""
            if [ "$ipv6_status" = "1" ]; then
                echo -e "${gl_lv}✅ IPv6 已永久禁用${gl_bai}"
                echo ""
                echo -e "${gl_zi}说明：${gl_bai}"
                echo "  - 配置文件: /etc/sysctl.d/99-disable-ipv6.conf"
                echo "  - 重启后此配置仍然生效"
            else
                echo -e "${gl_hong}❌ IPv6 禁用失败${gl_bai}"
                rm -f /etc/sysctl.d/99-disable-ipv6.conf
            fi
            ;;
        *)
            echo "已取消"
            ;;
    esac
    
    echo ""
}

manage_ipv6() {
    while true; do
        echo -e "${gl_kjlan}=== IPv6 管理 ===${gl_bai}"
        echo ""
        
        local ipv6_status=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
        local status_text=""
        local status_color=""
        
        if [ "$ipv6_status" = "0" ]; then
            status_text="启用"
            status_color="${gl_lv}"
        else
            status_text="禁用"
            status_color="${gl_hong}"
        fi
        
        echo -e "当前状态: ${status_color}${status_text}${gl_bai}"
        echo ""
        
        if [ -f /etc/sysctl.d/99-disable-ipv6.conf ]; then
            echo -e "${gl_huang}⚠️  检测到永久禁用配置文件${gl_bai}"
            echo ""
        fi
        
        echo "------------------------------------------------"
        echo "1. 永久禁用IPv6（重启后仍生效）"
        echo "0. 不管理IPv6，继续"
        echo "------------------------------------------------"
        read -e -p "请输入选择: " choice
        
        case "$choice" in
            1)
                disable_ipv6_permanent
                return
                ;;
            0)
                return
                ;;
            *)
                echo "无效选择"
                sleep 2
                ;;
        esac
    done
}

detect_bandwidth() {
    # 所有交互式输出重定向到stderr，避免被命令替换捕获
    echo "" >&2
    echo -e "${gl_kjlan}=== 服务器带宽检测 ===${gl_bai}" >&2
    echo "" >&2

    if [ "$AUTO_MODE" = "1" ]; then
        bw_choice=1
    else
        echo "请选择带宽配置方式：" >&2
        echo "1. 自动检测（推荐，自动选择最近服务器）" >&2
        echo "2. 手动指定测速服务器（指定服务器ID）" >&2
        echo "3. 手动选择预设档位（9个常用带宽档位）" >&2
        echo "" >&2
        
        read -e -p "请输入选择 [1]: " bw_choice
        bw_choice=${bw_choice:-1}
    fi

    case "$bw_choice" in
        1)
            # 自动检测带宽 - 选择最近服务器
            echo "" >&2
            echo -e "${gl_huang}正在运行 speedtest 测速...${gl_bai}" >&2
            echo -e "${gl_zi}提示: 自动选择距离最近的服务器${gl_bai}" >&2
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
            echo "" >&2
            
            # 检查speedtest是否安装
            if ! command -v speedtest &>/dev/null; then
                echo -e "${gl_huang}speedtest 未安装，正在安装...${gl_bai}" >&2
                # 调用脚本中已有的安装逻辑（简化版）
                local cpu_arch=$(uname -m)
                local download_url
                case "$cpu_arch" in
                    x86_64)
                        download_url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-x86_64.tgz"
                        ;;
                    aarch64)
                        download_url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-aarch64.tgz"
                        ;;
                    *)
                        echo -e "${gl_hong}错误: 不支持的架构 ${cpu_arch}${gl_bai}" >&2
                        echo "将使用通用带宽值 500 Mbps" >&2
                        echo "500"
                        return 1
                        ;;
                esac
                
                cd /tmp && \
                wget -q "$download_url" -O speedtest.tgz && \
                tar -xzf speedtest.tgz && \
                mv speedtest /usr/local/bin/ && \
                rm -f speedtest.tgz
                
                if [ $? -ne 0 ]; then
                    echo -e "${gl_hong}安装失败，将使用通用值${gl_bai}" >&2
                    echo "500"
                    return 1
                fi
            fi
            
            # 智能测速：获取附近服务器列表，按距离依次尝试
            echo -e "${gl_zi}正在搜索附近测速服务器...${gl_bai}" >&2
            
            # 获取附近服务器列表（按延迟排序）
            local servers_list=$(speedtest --accept-license --servers 2>/dev/null | sed -nE 's/^[[:space:]]*([0-9]+).*/\1/p' | head -n 10)
            
            if [ -z "$servers_list" ]; then
                echo -e "${gl_huang}无法获取服务器列表，使用自动选择...${gl_bai}" >&2
                servers_list="auto"
            else
                local server_count=$(echo "$servers_list" | wc -l)
                echo -e "${gl_lv}✅ 找到 ${server_count} 个附近服务器${gl_bai}" >&2
            fi
            echo "" >&2
            
            local speedtest_output=""
            local upload_speed=""
            local attempt=0
            local max_attempts=5  # 最多尝试5个服务器
            
            # 逐个尝试服务器
            for server_id in $servers_list; do
                attempt=$((attempt + 1))
                
                if [ $attempt -gt $max_attempts ]; then
                    echo -e "${gl_huang}已尝试 ${max_attempts} 个服务器，停止尝试${gl_bai}" >&2
                    break
                fi
                
                if [ "$server_id" = "auto" ]; then
                    echo -e "${gl_zi}[尝试 ${attempt}] 自动选择最近服务器...${gl_bai}" >&2
                    speedtest_output=$(speedtest --accept-license 2>&1)
                else
                    echo -e "${gl_zi}[尝试 ${attempt}] 测试服务器 #${server_id}...${gl_bai}" >&2
                    speedtest_output=$(speedtest --accept-license --server-id="$server_id" 2>&1)
                fi
                
                echo "$speedtest_output" >&2
                echo "" >&2
                
                # 提取上传速度
                upload_speed=""
                if echo "$speedtest_output" | grep -q "Upload:"; then
                    upload_speed=$(echo "$speedtest_output" | sed -nE 's/.*[Uu]pload:[[:space:]]*([0-9]+(\.[0-9]+)?).*/\1/p' | head -n1)
                fi
                if [ -z "$upload_speed" ]; then
                    upload_speed=$(echo "$speedtest_output" | grep -i "Upload:" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+$/) {print $i; exit}}')
                fi
                
                # 检查是否成功
                if [ -n "$upload_speed" ] && ! echo "$speedtest_output" | grep -qi "FAILED\|error"; then
                    local success_server=$(echo "$speedtest_output" | grep "Server:" | head -n1 | sed 's/.*Server: //')
                    echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}" >&2
                    echo -e "${gl_lv}✅ 测速成功！${gl_bai}" >&2
                    echo -e "${gl_zi}使用服务器: ${success_server}${gl_bai}" >&2
                    echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}" >&2
                    echo "" >&2
                    break
                else
                    local failed_server=$(echo "$speedtest_output" | grep "Server:" | head -n1 | sed 's/.*Server: //' | sed 's/[[:space:]]*$//')
                    if [ -n "$failed_server" ]; then
                        echo -e "${gl_huang}⚠️  失败: ${failed_server}${gl_bai}" >&2
                    else
                        echo -e "${gl_huang}⚠️  此服务器失败${gl_bai}" >&2
                    fi
                    echo -e "${gl_zi}继续尝试下一个服务器...${gl_bai}" >&2
                    echo "" >&2
                fi
            done
            
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
            echo "" >&2
            
            # 所有尝试都失败了
            if [ -z "$upload_speed" ] || echo "$speedtest_output" | grep -qi "FAILED\|error"; then
                echo -e "${gl_huang}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}" >&2
                echo -e "${gl_huang}⚠️  无法自动检测带宽${gl_bai}" >&2
                echo -e "${gl_huang}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}" >&2
                echo "" >&2
                echo -e "${gl_zi}原因: 测速服务器可能暂时不可用${gl_bai}" >&2
                echo "" >&2
                echo -e "${gl_kjlan}默认配置方案：${gl_bai}" >&2
                echo -e "  带宽:       ${gl_huang}1000 Mbps (1 Gbps)${gl_bai}" >&2
                echo -e "  缓冲区:     ${gl_huang}根据地区自动计算${gl_bai}" >&2
                echo -e "  适用场景:   ${gl_zi}标准 1Gbps 服务器（覆盖大多数场景）${gl_bai}" >&2
                echo "" >&2
                echo -e "${gl_huang}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}" >&2
                echo "" >&2
                
                # 询问用户确认
                read -e -p "是否使用默认值 1000 Mbps？(Y/N) [Y]: " use_default
                use_default=${use_default:-Y}
                
                case "$use_default" in
                    [Yy])
                        echo "" >&2
                        echo -e "${gl_lv}✅ 使用默认配置: 1000 Mbps${gl_bai}" >&2
                        echo "1000"
                        return 0
                        ;;
                    [Nn])
                        echo "" >&2
                        echo -e "${gl_zi}请手动输入带宽值${gl_bai}" >&2
                        local manual_bandwidth=""
                        while true; do
                            read -e -p "请输入上传带宽（单位：Mbps，如 500、1000、2000）: " manual_bandwidth
                            if [[ "$manual_bandwidth" =~ ^[0-9]+$ ]] && [ "$manual_bandwidth" -gt 0 ]; then
                                echo "" >&2
                                echo -e "${gl_lv}✅ 使用自定义值: ${manual_bandwidth} Mbps${gl_bai}" >&2
                                echo "$manual_bandwidth"
                                return 0
                            else
                                echo -e "${gl_hong}❌ 请输入有效的数字${gl_bai}" >&2
                            fi
                        done
                        ;;
                    *)
                        echo "" >&2
                        echo -e "${gl_huang}输入无效，使用默认值 1000 Mbps${gl_bai}" >&2
                        echo "1000"
                        return 0
                        ;;
                esac
            fi
            
            # 转为整数并验证
            local upload_mbps=${upload_speed%.*}
            if ! [[ "$upload_mbps" =~ ^[0-9]+$ ]] || [ "$upload_mbps" -le 0 ] 2>/dev/null; then
                echo -e "${gl_huang}⚠️ 检测到的带宽值异常 (${upload_speed})，使用默认值 1000 Mbps${gl_bai}" >&2
                upload_mbps=1000
            fi

            echo -e "${gl_lv}✅ 检测到上传带宽: ${upload_mbps} Mbps${gl_bai}" >&2
            echo "" >&2

            # 返回带宽值
            echo "$upload_mbps"
            return 0
            ;;
        2)
            # 手动指定测速服务器ID
            echo "" >&2
            echo -e "${gl_kjlan}=== 手动指定测速服务器 ===${gl_bai}" >&2
            echo "" >&2
            
            # 检查speedtest是否安装
            if ! command -v speedtest &>/dev/null; then
                echo -e "${gl_huang}speedtest 未安装，正在安装...${gl_bai}" >&2
                local cpu_arch=$(uname -m)
                local download_url
                case "$cpu_arch" in
                    x86_64)
                        download_url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-x86_64.tgz"
                        ;;
                    aarch64)
                        download_url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-aarch64.tgz"
                        ;;
                    *)
                        echo -e "${gl_hong}错误: 不支持的架构 ${cpu_arch}${gl_bai}" >&2
                        echo "将使用通用值 1000 Mbps" >&2
                        echo "1000"
                        return 1
                        ;;
                esac
                
                cd /tmp && \
                wget -q "$download_url" -O speedtest.tgz && \
                tar -xzf speedtest.tgz && \
                mv speedtest /usr/local/bin/ && \
                rm -f speedtest.tgz
                
                if [ $? -ne 0 ]; then
                    echo -e "${gl_hong}安装失败，将使用默认值 1000 Mbps${gl_bai}" >&2
                    echo "1000"
                    return 1
                fi
                echo -e "${gl_lv}✅ speedtest 安装成功${gl_bai}" >&2
                echo "" >&2
            fi
            
            # 显示如何查看服务器列表
            echo -e "${gl_zi}📋 如何查看可用的测速服务器：${gl_bai}" >&2
            echo "" >&2
            echo -e "  方法1：查看所有服务器列表" >&2
            echo -e "  ${gl_huang}speedtest --servers${gl_bai}" >&2
            echo "" >&2
            echo -e "  方法2：只显示附近服务器（推荐）" >&2
            echo -e "  ${gl_huang}speedtest --servers | head -n 20${gl_bai}" >&2
            echo "" >&2
            echo -e "${gl_zi}💡 服务器列表格式说明：${gl_bai}" >&2
            echo -e "  每行开头的数字就是服务器ID" >&2
            echo -e "  例如: ${gl_huang}12345${gl_bai}) 服务商名称 (位置, 距离)" >&2
            echo "" >&2
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
            echo "" >&2
            
            # 询问是否现在查看服务器列表
            read -e -p "是否现在查看附近的测速服务器列表？(Y/N) [Y]: " show_list
            show_list=${show_list:-Y}
            
            if [[ "$show_list" =~ ^[Yy]$ ]]; then
                echo "" >&2
                echo -e "${gl_kjlan}附近的测速服务器列表：${gl_bai}" >&2
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
                speedtest --accept-license --servers 2>/dev/null | head -n 20 >&2
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
                echo "" >&2
            fi
            
            # 输入服务器ID
            local server_id=""
            while true; do
                read -e -p "$(echo -e "${gl_huang}请输入测速服务器ID（纯数字）: ${gl_bai}")" server_id
                
                if [[ "$server_id" =~ ^[0-9]+$ ]]; then
                    break
                else
                    echo -e "${gl_hong}❌ 无效输入，请输入纯数字的服务器ID${gl_bai}" >&2
                fi
            done
            
            # 使用指定服务器测速
            echo "" >&2
            echo -e "${gl_huang}正在使用服务器 #${server_id} 测速...${gl_bai}" >&2
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
            echo "" >&2
            
            local speedtest_output=$(speedtest --accept-license --server-id="$server_id" 2>&1)
            echo "$speedtest_output" >&2
            echo "" >&2
            
            # 提取上传速度
            local upload_speed=""
            if echo "$speedtest_output" | grep -q "Upload:"; then
                upload_speed=$(echo "$speedtest_output" | sed -nE 's/.*[Uu]pload:[[:space:]]*([0-9]+(\.[0-9]+)?).*/\1/p' | head -n1)
            fi
            if [ -z "$upload_speed" ]; then
                upload_speed=$(echo "$speedtest_output" | grep -i "Upload:" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+$/) {print $i; exit}}')
            fi
            
            # 检查测速是否成功
            if [ -n "$upload_speed" ] && ! echo "$speedtest_output" | grep -qi "FAILED\|error"; then
                local upload_mbps=${upload_speed%.*}
                if ! [[ "$upload_mbps" =~ ^[0-9]+$ ]] || [ "$upload_mbps" -le 0 ] 2>/dev/null; then
                    echo -e "${gl_huang}⚠️ 检测到的带宽值异常 (${upload_speed})，使用默认值 1000 Mbps${gl_bai}" >&2
                    upload_mbps=1000
                fi
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
                echo -e "${gl_lv}✅ 测速成功！${gl_bai}" >&2
                echo -e "${gl_lv}检测到上传带宽: ${upload_mbps} Mbps${gl_bai}" >&2
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
                echo "" >&2
                echo "$upload_mbps"
                return 0
            else
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
                echo -e "${gl_hong}❌ 测速失败${gl_bai}" >&2
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
                echo "" >&2
                echo -e "${gl_zi}可能原因：${gl_bai}" >&2
                echo "  - 服务器ID不存在或已下线" >&2
                echo "  - 网络连接问题" >&2
                echo "  - 该服务器暂时不可用" >&2
                echo "" >&2
                
                read -e -p "是否使用默认值 1000 Mbps？(Y/N) [Y]: " use_default
                use_default=${use_default:-Y}
                
                if [[ "$use_default" =~ ^[Yy]$ ]]; then
                    echo "" >&2
                    echo -e "${gl_lv}✅ 使用默认配置: 1000 Mbps${gl_bai}" >&2
                    echo "1000"
                    return 0
                else
                    echo "" >&2
                    echo -e "${gl_zi}请手动输入带宽值${gl_bai}" >&2
                    local manual_bandwidth=""
                    while true; do
                        read -e -p "请输入上传带宽（单位：Mbps，如 500、1000、2000）: " manual_bandwidth
                        if [[ "$manual_bandwidth" =~ ^[0-9]+$ ]] && [ "$manual_bandwidth" -gt 0 ]; then
                            echo "" >&2
                            echo -e "${gl_lv}✅ 使用自定义值: ${manual_bandwidth} Mbps${gl_bai}" >&2
                            echo "$manual_bandwidth"
                            return 0
                        else
                            echo -e "${gl_hong}❌ 请输入有效的数字${gl_bai}" >&2
                        fi
                    done
                fi
            fi
            ;;
        3)
            # 手动选择预设档位
            echo "" >&2
            echo -e "${gl_kjlan}=== 手动选择带宽档位 ===${gl_bai}" >&2
            echo "" >&2
            echo "请选择带宽档位：" >&2
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
            echo "" >&2
            echo -e "${gl_huang}【小带宽 VPS】${gl_bai}" >&2
            echo "1. 100 Mbps   (NAT/极小带宽)" >&2
            echo "2. 200 Mbps   (小型VPS)" >&2
            echo "3. 300 Mbps   (入门服务器)" >&2
            echo "" >&2
            echo -e "${gl_huang}【中等带宽】${gl_bai}" >&2
            echo "4. 500 Mbps   (标准小带宽)" >&2
            echo "5. 700 Mbps   (准千兆)" >&2
            echo "6. 1 Gbps ⭐  (标准VPS/最常见)" >&2
            echo "" >&2
            echo -e "${gl_huang}【高带宽服务器】${gl_bai}" >&2
            echo "7. 1.5 Gbps   (中高端VPS)" >&2
            echo "8. 2 Gbps     (高性能VPS)" >&2
            echo "9. 2.5 Gbps   (准万兆)" >&2
            echo "" >&2
            echo -e "${gl_zi}提示: 缓冲区大小将根据后续选择的地区自动计算${gl_bai}" >&2
            echo "" >&2
            echo -e "${gl_zi}【其他选项】${gl_bai}" >&2
            echo "10. 自定义输入（手动指定任意带宽值）" >&2
            echo "0. 返回上级菜单" >&2
            echo "" >&2
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
            echo "" >&2
            
            # 读取用户选择
            local preset_choice=""
            read -e -p "请输入选择 [6]: " preset_choice
            preset_choice=${preset_choice:-6}  # 默认选择6 (1 Gbps)
            
            case "$preset_choice" in
                1)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 100 Mbps${gl_bai}" >&2
                    echo "100"
                    return 0
                    ;;
                2)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 200 Mbps${gl_bai}" >&2
                    echo "200"
                    return 0
                    ;;
                3)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 300 Mbps${gl_bai}" >&2
                    echo "300"
                    return 0
                    ;;
                4)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 500 Mbps${gl_bai}" >&2
                    echo "500"
                    return 0
                    ;;
                5)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 700 Mbps${gl_bai}" >&2
                    echo "700"
                    return 0
                    ;;
                6)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 1000 Mbps${gl_bai}" >&2
                    echo "1000"
                    return 0
                    ;;
                7)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 1500 Mbps${gl_bai}" >&2
                    echo "1500"
                    return 0
                    ;;
                8)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 2000 Mbps${gl_bai}" >&2
                    echo "2000"
                    return 0
                    ;;
                9)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 2500 Mbps${gl_bai}" >&2
                    echo "2500"
                    return 0
                    ;;
                10)
                    # 自定义输入
                    echo "" >&2
                    echo -e "${gl_zi}=== 自定义输入 ===${gl_bai}" >&2
                    echo "" >&2
                    local manual_bandwidth=""
                    while true; do
                        read -e -p "请输入带宽值（单位：Mbps，如 750、1200）: " manual_bandwidth
                        if [[ "$manual_bandwidth" =~ ^[0-9]+$ ]] && [ "$manual_bandwidth" -gt 0 ]; then
                            echo "" >&2
                            echo -e "${gl_lv}✅ 使用自定义值: ${manual_bandwidth} Mbps${gl_bai}" >&2
                            echo "$manual_bandwidth"
                            return 0
                        else
                            echo -e "${gl_hong}❌ 请输入有效的正整数${gl_bai}" >&2
                        fi
                    done
                    ;;
                0)
                    # 返回上级菜单
                    echo "" >&2
                    echo -e "${gl_huang}已取消选择，返回上级菜单${gl_bai}" >&2
                    echo "1000"  # 返回默认值，避免空值
                    return 1
                    ;;
                *)
                    echo "" >&2
                    echo -e "${gl_hong}无效选择，使用默认值 1000 Mbps${gl_bai}" >&2
                    echo "1000"
                    return 1
                    ;;
            esac
            ;;
        *)
            echo -e "${gl_huang}无效选择，使用默认值 1000 Mbps${gl_bai}" >&2
            echo "1000"
            return 1
            ;;
    esac
}

calculate_buffer_size() {
    local bandwidth=$1
    local region=${2:-asia}  # asia（亚太）或 overseas（美欧）
    local buffer_mb
    local bandwidth_level

    # 输入验证：确保 bandwidth 是正整数
    if ! [[ "$bandwidth" =~ ^[0-9]+$ ]] || [ "$bandwidth" -le 0 ] 2>/dev/null; then
        local fallback_mb=16
        [ "$region" = "overseas" ] && fallback_mb=64
        echo -e "${gl_huang}⚠️ 带宽值无效 (${bandwidth})，使用默认值 ${fallback_mb}MB${gl_bai}" >&2
        echo "$fallback_mb"
        return 0
    fi

    if [ "$region" = "overseas" ]; then
        # ===== 美国/欧洲档位（RTT ~200ms，buffer ≈ BDP × 2.5，上限 64MB）=====
        if [ "$bandwidth" -eq 100 ]; then
            buffer_mb=8
            bandwidth_level="预设档位（100 Mbps·远距离）"
        elif [ "$bandwidth" -eq 200 ]; then
            buffer_mb=16
            bandwidth_level="预设档位（200 Mbps·远距离）"
        elif [ "$bandwidth" -eq 300 ]; then
            buffer_mb=20
            bandwidth_level="预设档位（300 Mbps·远距离）"
        elif [ "$bandwidth" -eq 500 ]; then
            buffer_mb=32
            bandwidth_level="预设档位（500 Mbps·远距离）"
        elif [ "$bandwidth" -eq 700 ]; then
            buffer_mb=48
            bandwidth_level="预设档位（700 Mbps·远距离）"
        elif [ "$bandwidth" -eq 1000 ]; then
            buffer_mb=64
            bandwidth_level="预设档位（1 Gbps·远距离）"
        elif [ "$bandwidth" -eq 1500 ]; then
            buffer_mb=64
            bandwidth_level="预设档位（1.5 Gbps·远距离）"
        elif [ "$bandwidth" -eq 2000 ]; then
            buffer_mb=64
            bandwidth_level="预设档位（2 Gbps·远距离）"
        elif [ "$bandwidth" -eq 2500 ]; then
            buffer_mb=64
            bandwidth_level="预设档位（2.5 Gbps·远距离）"
        elif [ "$bandwidth" -lt 500 ]; then
            buffer_mb=16
            bandwidth_level="小带宽（< 500 Mbps·远距离）"
        elif [ "$bandwidth" -lt 1000 ]; then
            buffer_mb=48
            bandwidth_level="中等带宽（500-1000 Mbps·远距离）"
        elif [ "$bandwidth" -lt 2000 ]; then
            buffer_mb=64
            bandwidth_level="标准带宽（1-2 Gbps·远距离）"
        else
            buffer_mb=64
            bandwidth_level="高带宽（> 2 Gbps·远距离）"
        fi
    else
        # ===== 亚太地区档位（RTT ~50ms，原有逻辑不变）=====
        if [ "$bandwidth" -eq 100 ]; then
            buffer_mb=6
            bandwidth_level="预设档位（100 Mbps）"
        elif [ "$bandwidth" -eq 200 ]; then
            buffer_mb=8
            bandwidth_level="预设档位（200 Mbps）"
        elif [ "$bandwidth" -eq 300 ]; then
            buffer_mb=10
            bandwidth_level="预设档位（300 Mbps）"
        elif [ "$bandwidth" -eq 500 ]; then
            buffer_mb=12
            bandwidth_level="预设档位（500 Mbps）"
        elif [ "$bandwidth" -eq 700 ]; then
            buffer_mb=14
            bandwidth_level="预设档位（700 Mbps）"
        elif [ "$bandwidth" -eq 1000 ]; then
            buffer_mb=16
            bandwidth_level="预设档位（1 Gbps）"
        elif [ "$bandwidth" -eq 1500 ]; then
            buffer_mb=20
            bandwidth_level="预设档位（1.5 Gbps）"
        elif [ "$bandwidth" -eq 2000 ]; then
            buffer_mb=24
            bandwidth_level="预设档位（2 Gbps）"
        elif [ "$bandwidth" -eq 2500 ]; then
            buffer_mb=28
            bandwidth_level="预设档位（2.5 Gbps）"
        elif [ "$bandwidth" -lt 500 ]; then
            buffer_mb=8
            bandwidth_level="小带宽（< 500 Mbps）"
        elif [ "$bandwidth" -lt 1000 ]; then
            buffer_mb=12
            bandwidth_level="中等带宽（500-1000 Mbps）"
        elif [ "$bandwidth" -lt 2000 ]; then
            buffer_mb=16
            bandwidth_level="标准带宽（1-2 Gbps）"
        elif [ "$bandwidth" -lt 5000 ]; then
            buffer_mb=24
            bandwidth_level="高带宽（2-5 Gbps）"
        elif [ "$bandwidth" -lt 10000 ]; then
            buffer_mb=28
            bandwidth_level="超高带宽（5-10 Gbps）"
        else
            buffer_mb=32
            bandwidth_level="极高带宽（> 10 Gbps）"
        fi
    fi

    # 显示计算结果（输出到stderr）
    local region_label="亚太地区"
    [ "$region" = "overseas" ] && region_label="美国/欧洲"
    echo "" >&2
    echo -e "${gl_kjlan}根据带宽和地区计算最优缓冲区:${gl_bai}" >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo -e "  检测带宽: ${gl_huang}${bandwidth} Mbps${gl_bai}" >&2
    echo -e "  服务地区: ${gl_huang}${region_label}${gl_bai}" >&2
    echo -e "  带宽等级: ${bandwidth_level}" >&2
    echo -e "  推荐缓冲区: ${gl_lv}${buffer_mb} MB${gl_bai}" >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo "" >&2
    
    # 询问确认
    if [ "$AUTO_MODE" = "1" ]; then
        confirm=Y
    else
        read -e -p "$(echo -e "${gl_huang}是否使用推荐值 ${buffer_mb}MB？(Y/N) [Y]: ${gl_bai}")" confirm
        confirm=${confirm:-Y}
    fi

    case "$confirm" in
        [Yy])
            # 返回缓冲区大小（MB）
            echo "$buffer_mb"
            return 0
            ;;
        *)
            local default_mb=16
            [ "$region" = "overseas" ] && default_mb=32
            echo "" >&2
            echo -e "${gl_huang}已取消，将使用通用值 ${default_mb}MB${gl_bai}" >&2
            echo "$default_mb"
            return 1
            ;;
    esac
}

check_and_clean_conflicts() {
    echo -e "${gl_kjlan}=== 检查 sysctl 配置冲突 ===${gl_bai}"
    local conflicts=()
    # 搜索 /etc/sysctl.d/ 下可能覆盖 tcp_rmem/tcp_wmem 的高序号文件
    for conf in /etc/sysctl.d/[0-9]*-*.conf; do
        [ -f "$conf" ] || continue
        [ "$conf" = "$SYSCTL_CONF" ] && continue
        if grep -qE "(^|\s)net\.ipv4\.tcp_(rmem|wmem)" "$conf" 2>/dev/null; then
            base=$(basename "$conf")
            num=$(echo "$base" | sed -n 's/^\([0-9]\+\).*/\1/p')
            # 99 及以上优先生效，可能覆盖本脚本
            if [ -n "$num" ] && [ "$num" -ge 99 ]; then
                conflicts+=("$conf")
            fi
        fi
    done

    # 主配置文件直接设置也会覆盖
    local has_sysctl_conflict=0
    if [ -f /etc/sysctl.conf ] && grep -qE "(^|\s)net\.ipv4\.tcp_(rmem|wmem)" /etc/sysctl.conf 2>/dev/null; then
        has_sysctl_conflict=1
    fi

    if [ ${#conflicts[@]} -eq 0 ] && [ $has_sysctl_conflict -eq 0 ]; then
        echo -e "${gl_lv}✓ 未发现可能的覆盖配置${gl_bai}"
        return 0
    fi

    echo -e "${gl_huang}发现可能的覆盖配置：${gl_bai}"
    for f in "${conflicts[@]}"; do
        echo "  - $f"; grep -E "net\.ipv4\.tcp_(rmem|wmem)" "$f" | sed 's/^/      /'
    done
    [ $has_sysctl_conflict -eq 1 ] && echo "  - /etc/sysctl.conf (含 tcp_rmem/tcp_wmem)"

    if [ "$AUTO_MODE" = "1" ]; then
        ans=Y
    else
        read -e -p "是否自动禁用/注释这些覆盖配置？(Y/N): " ans
    fi
    case "$ans" in
        [Yy])
            # 注释 /etc/sysctl.conf 中相关行
            if [ $has_sysctl_conflict -eq 1 ]; then
                # 先创建一次备份，再用 sed -i 逐行注释（避免多次 .bak 覆盖）
                cp /etc/sysctl.conf /etc/sysctl.conf.bak.conflict 2>/dev/null
                sed -i '/^net\.ipv4\.tcp_wmem/s/^/# /' /etc/sysctl.conf 2>/dev/null
                sed -i '/^net\.ipv4\.tcp_rmem/s/^/# /' /etc/sysctl.conf 2>/dev/null
                sed -i '/^net\.core\.rmem_max/s/^/# /' /etc/sysctl.conf 2>/dev/null
                sed -i '/^net\.core\.wmem_max/s/^/# /' /etc/sysctl.conf 2>/dev/null
                echo -e "${gl_lv}✓ 已注释 /etc/sysctl.conf 中的相关配置（备份: .bak.conflict）${gl_bai}"
            fi
            # 将高优先级冲突文件重命名禁用
            for f in "${conflicts[@]}"; do
                if [ ! -f "$f" ]; then
                    echo -e "${gl_lv}✓ 已跳过: $(basename "$f")（已处理）${gl_bai}"
                    continue
                fi
                if mv "$f" "${f}.disabled.$(date +%Y%m%d_%H%M%S)" 2>/dev/null; then
                    echo -e "${gl_lv}✓ 已禁用: $(basename "$f")${gl_bai}"
                else
                    echo -e "${gl_hong}✗ 无法禁用: $(basename "$f")，请手动处理${gl_bai}"
                fi
            done
            ;;
        *)
            echo -e "${gl_huang}已跳过自动清理，可能导致新配置未完全生效${gl_bai}"
            ;;
    esac
}

eligible_ifaces() {
    for d in /sys/class/net/*; do
        [ -e "$d" ] || continue
        dev=$(basename "$d")
        case "$dev" in
            lo|docker*|veth*|br-*|virbr*|zt*|tailscale*|wg*|tun*|tap*) continue;;
        esac
        echo "$dev"
    done
}

apply_tc_fq_now() {
    if ! command -v tc >/dev/null 2>&1; then
        echo -e "${gl_huang}警告: 未检测到 tc（iproute2），跳过 fq 应用${gl_bai}"
        return 0
    fi
    local applied=0
    for dev in $(eligible_ifaces); do
        tc qdisc replace dev "$dev" root fq 2>/dev/null && applied=$((applied+1))
    done
    [ $applied -gt 0 ] && echo -e "${gl_lv}已对 $applied 个网卡应用 fq（即时生效）${gl_bai}" || echo -e "${gl_huang}未发现可应用 fq 的网卡${gl_bai}"
}

apply_mss_clamp() {
    local action=$1  # enable|disable
    if ! command -v iptables >/dev/null 2>&1; then
        echo -e "${gl_huang}警告: 未检测到 iptables，跳过 MSS clamp${gl_bai}"
        return 0
    fi
    if [ "$action" = "enable" ]; then
        iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 \
          || iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    else
        iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 || true
    fi
}

bbr_configure_direct() {
    echo -e "${gl_kjlan}=== 配置 BBR v3 + FQ 直连/落地优化（智能检测版） ===${gl_bai}"
    echo ""
    
    # 带宽检测和缓冲区计算
    echo ""
    echo -e "${gl_zi}[步骤 1/5] 检测服务器带宽并计算最优缓冲区...${gl_bai}"

    local detected_bandwidth=$(detect_bandwidth)

    # 地区选择（影响缓冲区大小：高延迟地区需要更大缓冲区）
    local region="asia"
    local region_choice=""
    echo ""
    echo -e "${gl_kjlan}请选择服务器主要服务的地区：${gl_bai}"
    echo ""
    echo "1. 亚太地区（港/日/新/韩等）⭐ 推荐"
    echo "   延迟较低（RTT < 100ms），使用标准缓冲区"
    echo ""
    echo "2. 美国/欧洲（跨太平洋/大西洋）"
    echo "   延迟较高（RTT 150-300ms），使用大缓冲区"
    echo ""
    read -e -p "请输入选择 [1]: " region_choice
    region_choice=${region_choice:-1}
    case "$region_choice" in
        2) region="overseas" ;;
        *) region="asia" ;;
    esac

    local buffer_mb=$(calculate_buffer_size "$detected_bandwidth" "$region")
    local buffer_bytes=$((buffer_mb * 1024 * 1024))
    
    echo -e "${gl_lv}✅ 将使用 ${buffer_mb}MB 缓冲区配置${gl_bai}"
    sleep 2
    
    echo ""
    echo -e "${gl_zi}[步骤 2/5] 清理配置冲突...${gl_bai}"
    echo "正在检查配置冲突..."
    
    # 备份主配置文件（如果还没备份）
    if [ -f /etc/sysctl.conf ] && ! [ -f /etc/sysctl.conf.bak.original ]; then
        cp /etc/sysctl.conf /etc/sysctl.conf.bak.original
        echo "已备份: /etc/sysctl.conf -> /etc/sysctl.conf.bak.original"
    fi
    
    # 注释掉 /etc/sysctl.conf 中的 TCP 缓冲区配置（避免覆盖）
    if [ -f /etc/sysctl.conf ]; then
        clean_sysctl_conf
        echo "已清理 /etc/sysctl.conf 中的冲突配置"
    fi
    
    # 删除可能存在的软链接
    if [ -L /etc/sysctl.d/99-sysctl.conf ]; then
        rm -f /etc/sysctl.d/99-sysctl.conf
        echo "已删除配置软链接"
    fi
    
    # 检查并清理可能覆盖的新旧配置冲突
    check_and_clean_conflicts

    # 步骤 3：创建独立配置文件（使用动态缓冲区）
    echo ""
    echo -e "${gl_zi}[步骤 3/5] 创建配置文件...${gl_bai}"
    echo "正在创建新配置..."
    
    # 获取物理内存用于虚拟内存参数调整
    local mem_total=$(free -m | awk 'NR==2{print $2}')
    local vm_swappiness=5
    local vm_dirty_ratio=15
    local vm_min_free_kbytes=65536
    
    # 根据内存大小微调虚拟内存参数
    if [ "$mem_total" -lt 2048 ]; then
        vm_swappiness=20
        vm_dirty_ratio=20
        vm_min_free_kbytes=32768
    fi
    
    cat > "$SYSCTL_CONF" << EOF
# BBR v3 Direct/Endpoint Configuration (Intelligent Detection Edition)
# Generated on $(date)
# Bandwidth: ${detected_bandwidth} Mbps | Region: ${region} | Buffer: ${buffer_mb} MB

# 队列调度算法
net.core.default_qdisc=fq

# 拥塞控制算法
net.ipv4.tcp_congestion_control=bbr

# TCP 缓冲区优化（智能检测：${buffer_mb}MB）
net.core.rmem_max=${buffer_bytes}
net.core.wmem_max=${buffer_bytes}
net.ipv4.tcp_rmem=4096 87380 ${buffer_bytes}
net.ipv4.tcp_wmem=4096 65536 ${buffer_bytes}

# ===== 直连/落地优化参数 =====

# TIME_WAIT 重用（启用，提高并发）
net.ipv4.tcp_tw_reuse=1

# 端口范围（最大化）
net.ipv4.ip_local_port_range=1024 65535

# 连接队列（高性能）
net.core.somaxconn=4096
net.ipv4.tcp_max_syn_backlog=8192

# 网络队列（高带宽优化）
net.core.netdev_max_backlog=5000

# 高级TCP优化
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1

# ===== Reality终极优化参数 =====

# 发送低水位（上传速度优化关键）
net.ipv4.tcp_notsent_lowat=16384

# 连接回收优化
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_max_tw_buckets=5000

# TCP Fast Open（节省1个RTT，加速连接建立）
net.ipv4.tcp_fastopen=3

# TCP保活优化（更快检测死连接）
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5

# UDP缓冲区（QUIC/Hysteria 支持）
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192

# TCP安全增强
net.ipv4.tcp_syncookies=1

# 虚拟内存优化（根据物理内存调整）
vm.swappiness=${vm_swappiness}
vm.dirty_ratio=${vm_dirty_ratio}
vm.dirty_background_ratio=5
vm.overcommit_memory=1
vm.min_free_kbytes=${vm_min_free_kbytes}
vm.vfs_cache_pressure=50

# CPU调度优化
kernel.sched_autogroup_enabled=0
kernel.numa_balancing=0
EOF

    # 检查配置文件是否创建成功
    if [ ! -f "$SYSCTL_CONF" ] || [ ! -s "$SYSCTL_CONF" ]; then
        echo -e "${gl_hong}❌ 配置文件创建失败！请检查磁盘空间和权限${gl_bai}"
        return 1
    fi

    # 步骤 4：应用配置
    echo ""
    echo -e "${gl_zi}[步骤 4/5] 应用所有优化参数...${gl_bai}"
    echo "正在应用配置..."
    local sysctl_output
    sysctl_output=$(sysctl -p "$SYSCTL_CONF" 2>&1)
    local sysctl_rc=$?
    if [ $sysctl_rc -ne 0 ]; then
        echo -e "${gl_huang}⚠️ sysctl 部分参数应用失败（可能有不支持的参数）:${gl_bai}"
        echo "$sysctl_output" | grep -i "error\|invalid\|unknown\|cannot" | head -5
        echo -e "${gl_zi}已支持的参数仍然生效，不影响整体优化${gl_bai}"
    else
        echo -e "${gl_lv}✓ 所有 sysctl 参数已成功应用${gl_bai}"
    fi

    # 立即应用 fq，并启用 MSS clamp（无需重启）
    echo "正在应用队列与防分片（无需重启）..."
    apply_tc_fq_now >/dev/null 2>&1
    apply_mss_clamp enable >/dev/null 2>&1

    # 持久化 tc fq 和 iptables MSS clamp（重启后自动恢复）
    echo "正在配置重启持久化..."
    # 创建 systemd 服务实现 tc fq + MSS clamp 开机恢复
    cat > /etc/systemd/system/bbr-optimize-persist.service << 'PERSISTEOF'
[Unit]
Description=BBR Optimize - Restore tc fq and MSS clamp after boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/bbr-optimize-apply.sh

[Install]
WantedBy=multi-user.target
PERSISTEOF

    cat > /usr/local/bin/bbr-optimize-apply.sh << 'APPLYEOF'
#!/bin/bash
# BBR Optimize 重启恢复脚本 - 自动生成，勿手动编辑
# 应用 tc fq 到所有物理网卡
for d in /sys/class/net/*; do
    [ -e "$d" ] || continue
    dev=$(basename "$d")
    case "$dev" in
        lo|docker*|veth*|br-*|virbr*|zt*|tailscale*|wg*|tun*|tap*) continue;;
    esac
    tc qdisc replace dev "$dev" root fq 2>/dev/null
done
# 应用 iptables MSS clamp
if command -v iptables >/dev/null 2>&1; then
    iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 \
      || iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
fi
# 禁用透明大页
if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
    echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
fi
# 优化 TCP 初始拥塞窗口（加速连接起步）
DEF_ROUTE=$(ip route show default 2>/dev/null | head -1)
if [ -n "$DEF_ROUTE" ]; then
    CLEAN_ROUTE=$(echo "$DEF_ROUTE" | sed 's/ initcwnd [0-9]*//g; s/ initrwnd [0-9]*//g')
    ip route change $CLEAN_ROUTE initcwnd 32 initrwnd 32 2>/dev/null
fi
# RPS/RFS 多核网络优化（遍历所有物理网卡）
CPU_COUNT=$(nproc 2>/dev/null || echo 1)
if [ "$CPU_COUNT" -gt 1 ]; then
    RPS_MASK=$(printf '%x' $((2**CPU_COUNT - 1)))
    FLOW_ENTRIES=$((4096 * CPU_COUNT))
    echo "$FLOW_ENTRIES" > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null
    for D in /sys/class/net/*; do
        [ -e "$D" ] || continue
        DEV=$(basename "$D")
        case "$DEV" in
            lo|docker*|veth*|br-*|virbr*|zt*|tailscale*|wg*|tun*|tap*) continue;;
        esac
        [ -d "/sys/class/net/$DEV/queues" ] || continue
        for RXQ in /sys/class/net/$DEV/queues/rx-*/rps_cpus; do
            [ -f "$RXQ" ] && echo "$RPS_MASK" > "$RXQ" 2>/dev/null
        done
        for RXQ_DIR in /sys/class/net/$DEV/queues/rx-*/; do
            [ -f "${RXQ_DIR}rps_flow_cnt" ] && echo "$((FLOW_ENTRIES / CPU_COUNT))" > "${RXQ_DIR}rps_flow_cnt" 2>/dev/null
        done
    done
fi
APPLYEOF
    chmod +x /usr/local/bin/bbr-optimize-apply.sh
    systemctl daemon-reload 2>/dev/null
    systemctl enable bbr-optimize-persist.service 2>/dev/null
    echo -e "${gl_lv}✓ tc fq / MSS clamp / 透明大页 重启持久化已配置${gl_bai}"

    # 配置文件描述符限制
    echo "正在优化文件描述符限制..."
    if ! grep -q "^\* soft nofile 524288" /etc/security/limits.conf 2>/dev/null && \
       ! grep -q "BBR - 文件描述符优化" /etc/security/limits.conf 2>/dev/null; then
        cat >> /etc/security/limits.conf << 'LIMITSEOF'
# BBR - 文件描述符优化
* soft nofile 524288
* hard nofile 524288
LIMITSEOF
    fi
    ulimit -n 524288 2>/dev/null

    # 禁用透明大页面（当前运行时）
    if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
        echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
    fi

    # 优化 TCP 初始拥塞窗口（加速连接起步，节省1-2个RTT）
    echo "正在优化 TCP 初始拥塞窗口..."
    local def_route
    def_route=$(ip route show default 2>/dev/null | head -1)
    if [ -n "$def_route" ]; then
        # 清除已有的 initcwnd/initrwnd 再重新设置，避免重复
        local clean_route
        clean_route=$(echo "$def_route" | sed 's/ initcwnd [0-9]*//g; s/ initrwnd [0-9]*//g')
        if ip route change $clean_route initcwnd 32 initrwnd 32 2>/dev/null; then
            echo -e "${gl_lv}✓ initcwnd=32 initrwnd=32 已应用（加速 TCP 连接起步）${gl_bai}"
        else
            echo -e "${gl_huang}⚠️ initcwnd 设置失败（不影响其他优化）${gl_bai}"
        fi
    else
        echo -e "${gl_huang}⚠️ 未检测到默认路由，跳过 initcwnd 优化${gl_bai}"
    fi

    # RPS/RFS 多核网络优化（将网卡收包分散到所有 CPU 核心）
    local cpu_count
    cpu_count=$(nproc 2>/dev/null || echo 1)
    if [ "$cpu_count" -gt 1 ]; then
        echo "正在配置 RPS/RFS 多核网络优化..."
        # 计算 CPU 掩码（所有核心参与）：2核=3, 4核=f, 8核=ff
        local rps_mask
        rps_mask=$(printf '%x' $((2**cpu_count - 1)))
        local flow_entries=$((4096 * cpu_count))
        echo "$flow_entries" > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null
        # 遍历所有物理网卡（排除虚拟/隧道接口）
        local rps_ok=0
        local rps_devs=""
        local dev
        for d in /sys/class/net/*; do
            [ -e "$d" ] || continue
            dev=$(basename "$d")
            case "$dev" in
                lo|docker*|veth*|br-*|virbr*|zt*|tailscale*|wg*|tun*|tap*) continue;;
            esac
            [ -d "/sys/class/net/$dev/queues" ] || continue
            # 设置 RPS：将收包分散到所有核心
            for rxq in /sys/class/net/$dev/queues/rx-*/rps_cpus; do
                if [ -f "$rxq" ]; then
                    echo "$rps_mask" > "$rxq" 2>/dev/null
                    # 写入后读回验证（有些环境 echo 返回0但内核没接受）
                    local verify_val
                    verify_val=$(cat "$rxq" 2>/dev/null | tr -d ',' | sed 's/^0*//')
                    [ -z "$verify_val" ] && verify_val="0"
                    [ "$verify_val" = "$rps_mask" ] && rps_ok=1
                fi
            done
            # 设置 RFS：同一连接的包尽量在同一核处理（减少 cache miss）
            for rxq_dir in /sys/class/net/$dev/queues/rx-*/; do
                if [ -f "${rxq_dir}rps_flow_cnt" ]; then
                    echo "$((flow_entries / cpu_count))" > "${rxq_dir}rps_flow_cnt" 2>/dev/null
                fi
            done
            rps_devs="${rps_devs} ${dev}"
        done
        if [ $rps_ok -eq 1 ]; then
            echo -e "${gl_lv}✓ RPS/RFS 已启用（${cpu_count} 核，掩码: 0x${rps_mask}，网卡:${rps_devs}）${gl_bai}"
        else
            echo -e "${gl_huang}⚠️ RPS 设置未生效（当前虚拟化环境可能不支持，不影响其他优化）${gl_bai}"
        fi
    else
        echo -e "${gl_zi}ℹ 单核 CPU，跳过 RPS/RFS（单核无需分担）${gl_bai}"
    fi

    # 步骤 5：验证配置是否真正生效
    echo ""
    echo -e "${gl_zi}[步骤 5/5] 验证配置...${gl_bai}"
    
    local actual_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    local actual_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local actual_wmem=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null | awk '{print $3}')
    local actual_rmem=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null | awk '{print $3}')
    
    echo ""
    echo -e "${gl_kjlan}=== 配置验证 ===${gl_bai}"
    
    # 验证队列算法
    if [ "$actual_qdisc" = "fq" ]; then
        echo -e "队列算法: ${gl_lv}$actual_qdisc ✓${gl_bai}"
    else
        echo -e "队列算法: ${gl_huang}$actual_qdisc (期望: fq) ⚠${gl_bai}"
    fi
    
    # 验证拥塞控制
    if [ "$actual_cc" = "bbr" ]; then
        echo -e "拥塞控制: ${gl_lv}$actual_cc ✓${gl_bai}"
    else
        echo -e "拥塞控制: ${gl_huang}$actual_cc (期望: bbr) ⚠${gl_bai}"
    fi
    
    # 验证缓冲区（动态）
    local actual_wmem_mb=$((actual_wmem / 1048576))
    local actual_rmem_mb=$((actual_rmem / 1048576))
    
    if [ "$actual_wmem" = "$buffer_bytes" ]; then
        echo -e "发送缓冲区: ${gl_lv}${buffer_mb}MB ✓${gl_bai}"
    else
        echo -e "发送缓冲区: ${gl_huang}${actual_wmem_mb}MB (期望: ${buffer_mb}MB) ⚠${gl_bai}"
    fi
    
    if [ "$actual_rmem" = "$buffer_bytes" ]; then
        echo -e "接收缓冲区: ${gl_lv}${buffer_mb}MB ✓${gl_bai}"
    else
        echo -e "接收缓冲区: ${gl_huang}${actual_rmem_mb}MB (期望: ${buffer_mb}MB) ⚠${gl_bai}"
    fi

    # 验证 initcwnd
    local actual_initcwnd
    actual_initcwnd=$(ip route show default 2>/dev/null | head -1 | grep -oP 'initcwnd \K[0-9]+')
    if [ "$actual_initcwnd" = "32" ]; then
        echo -e "初始窗口:   ${gl_lv}initcwnd=$actual_initcwnd ✓${gl_bai}"
    elif [ -n "$actual_initcwnd" ]; then
        echo -e "初始窗口:   ${gl_huang}initcwnd=$actual_initcwnd (期望: 32) ⚠${gl_bai}"
    else
        echo -e "初始窗口:   ${gl_huang}未设置 (期望: initcwnd=32) ⚠${gl_bai}"
    fi

    # 验证 RPS
    if [ "$cpu_count" -gt 1 ]; then
        local expected_mask
        expected_mask=$(printf '%x' $((2**cpu_count - 1)))
        local rps_verify_devs=""
        local rps_all_ok=1
        for d in /sys/class/net/*; do
            [ -e "$d" ] || continue
            local vdev=$(basename "$d")
            case "$vdev" in
                lo|docker*|veth*|br-*|virbr*|zt*|tailscale*|wg*|tun*|tap*) continue;;
            esac
            [ -f "/sys/class/net/$vdev/queues/rx-0/rps_cpus" ] || continue
            local rps_val
            # rps_cpus 可能返回 "3" 或 "00000003" 或 "00000000,00000003"
            rps_val=$(cat /sys/class/net/$vdev/queues/rx-0/rps_cpus 2>/dev/null | tr -d ',' | sed 's/^0*//')
            [ -z "$rps_val" ] && rps_val="0"
            if [ "$rps_val" = "$expected_mask" ]; then
                rps_verify_devs="${rps_verify_devs} ${vdev}✓"
            else
                rps_verify_devs="${rps_verify_devs} ${vdev}✗"
                rps_all_ok=0
            fi
        done
        if [ -n "$rps_verify_devs" ]; then
            if [ $rps_all_ok -eq 1 ]; then
                echo -e "RPS/RFS:    ${gl_lv}${cpu_count}核分担 (0x${expected_mask})${rps_verify_devs} ✓${gl_bai}"
            else
                echo -e "RPS/RFS:    ${gl_huang}部分网卡未生效:${rps_verify_devs} ⚠${gl_bai}"
            fi
        else
            echo -e "RPS/RFS:    ${gl_huang}未检测到物理网卡 ⚠${gl_bai}"
        fi
    else
        echo -e "RPS/RFS:    ${gl_zi}单核跳过${gl_bai}"
    fi

    echo ""

    # 最终判断
    if [ "$actual_qdisc" = "fq" ] && [ "$actual_cc" = "bbr" ] && \
       [ "$actual_wmem" = "$buffer_bytes" ] && [ "$actual_rmem" = "$buffer_bytes" ]; then
        echo -e "${gl_lv}✅ BBR v3 直连/落地优化配置完成并已生效！${gl_bai}"
        echo -e "${gl_zi}配置说明: ${buffer_mb}MB 缓冲区（${detected_bandwidth} Mbps 带宽），适合直连/落地场景${gl_bai}"
    else
        echo -e "${gl_huang}⚠️ 配置已保存但部分参数未生效${gl_bai}"
        echo -e "${gl_huang}建议执行以下操作：${gl_bai}"
        echo "1. 检查是否有其他配置文件冲突"
        echo "2. 重启服务器使配置完全生效: reboot"
    fi
}

check_bbr_status() {
    echo -e "${gl_kjlan}=== 当前系统状态 ===${gl_bai}"
    local kernel_release
    kernel_release=$(uname -r)
    echo "内核版本: $kernel_release"
    
    local congestion="未知"
    local qdisc="未知"
    local bbr_version=""
    local bbr_active=0
    
    if command -v sysctl &>/dev/null; then
        congestion=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
        qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
        echo "拥塞控制算法: $congestion"
        echo "队列调度算法: $qdisc"
        
        if command -v modinfo &>/dev/null; then
            bbr_version=$(modinfo tcp_bbr 2>/dev/null | awk '/^version:/ {print $2}')
            if [ -n "$bbr_version" ]; then
                if [ "$bbr_version" = "3" ]; then
                    echo -e "BBR 版本: ${gl_lv}v${bbr_version} ✓${gl_bai}"
                else
                    echo -e "BBR 版本: ${gl_huang}v${bbr_version} (不是 v3)${gl_bai}"
                fi
            fi
        fi
    fi
    
    if [ "$congestion" = "bbr" ] && [ "$bbr_version" = "3" ]; then
        bbr_active=1
    fi
    
    local xanmod_pkg_installed=0
    local dpkg_available=0
    if command -v dpkg &>/dev/null; then
        dpkg_available=1
        if dpkg -l 2>/dev/null | grep -qE '^ii\s+linux-.*xanmod'; then
            xanmod_pkg_installed=1
        fi
    fi
    
    local xanmod_running=0
    if echo "$kernel_release" | grep -qi 'xanmod'; then
        xanmod_running=1
    fi
    
    local status=1
    
    if [ $xanmod_pkg_installed -eq 1 ]; then
        echo -e "XanMod 内核: ${gl_lv}已安装 ✓${gl_bai}"
        status=0
    elif [ $xanmod_running -eq 1 ]; then
        echo -e "XanMod 内核: ${gl_huang}内核包已卸载，但当前运行版本仍为 ${kernel_release}，请重启系统使卸载完全生效${gl_bai}"
    else
        echo -e "XanMod 内核: ${gl_huang}未安装${gl_bai}"
    fi
    
    if [ $status -ne 0 ] && [ $bbr_active -eq 1 ]; then
        echo -e "${gl_kjlan}提示: 当前仍在运行 BBR v3 模块，重启后将恢复系统默认配置${gl_bai}"
    fi
    
    if [ $status -ne 0 ] && [ $dpkg_available -eq 0 ]; then
        # 非 Debian 系统：仅当内核名确实含 xanmod 时才认为已安装
        # BBR v3 活跃不等于 XanMod（用户可能自编译内核），避免误触发 update 流程
        if [ $xanmod_running -eq 1 ]; then
            status=0
        fi
    fi
    
    return $status
}

xanmod_get_repo_suite() {
    local suite=""

    if [ -r /etc/os-release ]; then
        suite=$( ( . /etc/os-release; printf '%s' "${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}" ) )
    fi

    if [ -z "$suite" ] && command -v lsb_release &>/dev/null; then
        suite=$(lsb_release -sc 2>/dev/null)
    fi

    if [ -z "$suite" ]; then
        echo -e "${gl_hong}错误: 无法识别系统发行版 codename，不能添加 XanMod 软件源${gl_bai}" >&2
        return 1
    fi

    case "$suite" in
        bookworm|trixie|forky|sid|noble|plucky|questing|resolute|faye|gigi|wilma|xia|zara|zena)
            ;;
        *)
            echo -e "${gl_huang}警告: 当前发行版 codename 为 ${suite}，可能不在 XanMod 官方支持列表中${gl_bai}" >&2
            ;;
    esac

    echo "$suite"
}

xanmod_write_repo() {
    local gpg_key_file=$1
    local repo_file=$2
    local suite

    suite=$(xanmod_get_repo_suite) || return 1
    echo "deb [signed-by=${gpg_key_file}] https://deb.xanmod.org ${suite} main" | \
        tee "$repo_file" > /dev/null
    echo -e "${gl_lv}✅ XanMod 软件源: ${suite}${gl_bai}"
}

xanmod_select_kernel_package() {
    local version=$1
    local candidates=()

    case "$version" in
        1)
            candidates=("linux-xanmod-lts-x64v1")
            ;;
        2)
            candidates=("linux-xanmod-x64v2" "linux-xanmod-lts-x64v2")
            ;;
        3)
            candidates=("linux-xanmod-x64v3" "linux-xanmod-lts-x64v3")
            ;;
        4)
            # XanMod 官方 mainline 当前不提供 x64v4；v4 CPU 使用 x64v3 更稳妥。
            candidates=("linux-xanmod-x64v3" "linux-xanmod-lts-x64v3")
            ;;
        *)
            candidates=("linux-xanmod-x64v3" "linux-xanmod-lts-x64v3")
            ;;
    esac

    local pkg
    for pkg in "${candidates[@]}"; do
        if apt-cache show "$pkg" >/dev/null 2>&1; then
            echo "$pkg"
            return 0
        fi
    done

    return 1
}

install_xanmod_kernel() {
    echo -e "${gl_kjlan}=== 安装 XanMod 内核与 BBR v3 ===${gl_bai}"
    echo "视频教程: https://www.bilibili.com/video/BV14K421x7BS"
    echo "------------------------------------------------"

    # 先检测架构：ARM64 无可安装内容，不应先询问用户是否安装
    local cpu_arch
    cpu_arch=$(uname -m)

    if [ "$cpu_arch" = "aarch64" ]; then
        echo -e "检测到 CPU 架构: ${gl_huang}aarch64 (ARM64)${gl_bai}"
        echo ""
        echo -e "${gl_huang}⚠ ARM64 平台暂无官方 BBR v3 方案${gl_bai}"
        echo ""
        echo "原因：BBR v3 至今未合入 Linux 主线内核，必须使用打过补丁"
        echo "      重新编译的内核；而 XanMod 官方仅提供 x86-64 构建。"
        echo ""
        echo -e "${gl_lv}✅ 但你的 ARM 机器依然可以做网络优化：${gl_bai}"
        echo -e "   请直接使用【${gl_lv}BBR 直连/落地优化${gl_bai}】"
        echo ""
        echo "   ARM 内核自带 BBR + fq 队列算法，配合后续带宽检测"
        echo "   与缓冲区调优，同样能获得明显的网络性能提升。"
        echo ""
        echo "------------------------------------------------"
        break_end
        return 1
    fi

    echo "支持系统: Debian/Ubuntu x86_64（ARM64 可直接进行网络优化）"
    echo -e "${gl_huang}警告: 将升级 Linux 内核，请提前备份重要数据！${gl_bai}"
    echo "------------------------------------------------"
    if [ "$AUTO_MODE" = "1" ]; then
        choice=Y
    else
        read -e -p "确定继续安装吗？(Y/N): " choice
    fi

    case "$choice" in
        [Yy])
            ;;
        *)
            echo "已取消安装"
            return 1
            ;;
    esac

    # 显式检查 x86_64 架构（aarch64 已在前面提前返回，这里兜底其余架构）
    if [ "$cpu_arch" != "x86_64" ]; then
        echo -e "${gl_hong}错误: 不支持的 CPU 架构: ${cpu_arch}${gl_bai}"
        echo "XanMod 内核仅提供 x86_64 构建；其他架构可继续进行网络调优。"
        break_end
        return 1
    fi

    # x86_64 架构安装流程
    # 检查系统支持
    if [ -r /etc/os-release ]; then
        . /etc/os-release
        if [ "$ID" != "debian" ] && [ "$ID" != "ubuntu" ]; then
            echo -e "${gl_hong}错误: 仅支持 Debian 和 Ubuntu 系统${gl_bai}"
            return 1
        fi
    else
        echo -e "${gl_hong}错误: 无法确定操作系统类型${gl_bai}"
        return 1
    fi

    # 环境准备
    check_disk_space 3 || return 1
    install_package wget gnupg || { echo -e "${gl_hong}错误: 无法安装必要依赖 wget/gnupg${gl_bai}"; return 1; }

    # 添加 XanMod GPG 密钥（分步执行，避免管道 $? 只检查最后一条命令）
    echo "正在添加 XanMod 仓库密钥..."
    local gpg_key_file="/usr/share/keyrings/xanmod-archive-keyring.gpg"
    local key_tmp=$(mktemp)
    local gpg_ok=false

    # 尝试1: 从镜像源下载
    if wget -qO "$key_tmp" "${gh_proxy}raw.githubusercontent.com/kejilion/sh/main/archive.key" 2>/dev/null && \
       [ -s "$key_tmp" ]; then
        if gpg --dearmor -o "$gpg_key_file" --yes < "$key_tmp" 2>/dev/null; then
            gpg_ok=true
        fi
    fi

    # 尝试2: 从 XanMod 官方源下载
    if [ "$gpg_ok" = false ]; then
        echo -e "${gl_huang}镜像源失败，尝试 XanMod 官方源...${gl_bai}"
        if wget -qO "$key_tmp" "https://dl.xanmod.org/archive.key" 2>/dev/null && \
           [ -s "$key_tmp" ]; then
            if gpg --dearmor -o "$gpg_key_file" --yes < "$key_tmp" 2>/dev/null; then
                gpg_ok=true
            fi
        fi
    fi

    rm -f "$key_tmp"

    if [ "$gpg_ok" = false ]; then
        echo -e "${gl_hong}错误: GPG 密钥导入失败，无法继续安装${gl_bai}"
        echo "请检查网络连接后重试"
        return 1
    fi
    echo -e "${gl_lv}✅ GPG 密钥导入成功${gl_bai}"

    local xanmod_repo_file="/etc/apt/sources.list.d/xanmod-release.list"

    # 添加 XanMod 仓库（使用系统 codename；旧 releases suite 已为空）
    xanmod_write_repo "$gpg_key_file" "$xanmod_repo_file" || return 1

    # 检测 CPU 架构版本（使用安全临时目录）
    echo "正在检测 CPU 支持的最优内核版本..."
    local detect_dir=$(mktemp -d)
    local detect_script="${detect_dir}/check_x86-64_psabi.sh"
    local version=""

    if wget -qO "$detect_script" "${gh_proxy}raw.githubusercontent.com/kejilion/sh/main/check_x86-64_psabi.sh" 2>/dev/null && \
       [ -s "$detect_script" ]; then
        chmod +x "$detect_script"
        version=$("$detect_script" 2>/dev/null | sed -nE 's/.*x86-64-v([1-4]).*/\1/p' | head -1)
    fi
    rm -rf "$detect_dir"

    # 在线检测失败时，使用本地 /proc/cpuinfo 检测 CPU 支持的最高等级
    if ! [[ "$version" =~ ^[1-4]$ ]]; then
        echo -e "${gl_huang}在线检测脚本不可用，使用本地 CPU 特征检测...${gl_bai}"
        local cpu_flags=$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null)
        if echo "$cpu_flags" | grep -qw 'avx512f'; then
            version="4"
        elif echo "$cpu_flags" | grep -qw 'avx2'; then
            version="3"
        elif echo "$cpu_flags" | grep -qw 'sse4_2'; then
            version="2"
        else
            version="1"
        fi
        echo -e "${gl_lv}本地检测结果: CPU 支持 x86-64-v${version}${gl_bai}"
    fi

    # 安装 XanMod 内核
    echo "正在更新软件包列表..."
    if ! apt-get update; then
        echo -e "${gl_huang}⚠️  apt-get update 部分失败，尝试继续安装...${gl_bai}"
    fi

    local xanmod_package
    xanmod_package=$(xanmod_select_kernel_package "$version")
    if [ -z "$xanmod_package" ]; then
        echo -e "${gl_hong}错误: 未找到适合 x86-64-v${version} 的 XanMod 内核包${gl_bai}"
        echo -e "${gl_huang}可用包参考:${gl_bai}"
        apt-cache search '^linux-xanmod' 2>/dev/null | awk '{print "  - " $1}' | head -20
        rm -f "$xanmod_repo_file"
        return 1
    fi

    echo -e "${gl_lv}将安装: ${xanmod_package}${gl_bai}"
    if [ "$version" = "4" ] && echo "$xanmod_package" | grep -q 'x64v3'; then
        echo -e "${gl_huang}说明: XanMod 官方 mainline 当前不提供 x64v4，x86-64-v4 CPU 使用 x64v3 包${gl_bai}"
    elif [ "$version" = "1" ] && echo "$xanmod_package" | grep -q 'lts'; then
        echo -e "${gl_huang}说明: XanMod 官方 mainline 当前不提供 x64v1，x86-64-v1 CPU 使用 LTS 包${gl_bai}"
    fi

    apt-get install -y "$xanmod_package"

    if [ $? -ne 0 ]; then
        echo -e "${gl_hong}内核安装失败！${gl_bai}"
        rm -f "$xanmod_repo_file"
        return 1
    fi

    # 验证内核是否真正安装成功
    if ! dpkg -l 2>/dev/null | awk -v pkg="$xanmod_package" '$1 == "ii" && $2 == pkg { found=1 } END { exit !found }'; then
        echo -e "${gl_hong}内核包安装验证失败！${gl_bai}"
        rm -f "$xanmod_repo_file"
        return 1
    fi

    echo -e "${gl_lv}XanMod 内核安装成功！${gl_bai}"
    echo -e "${gl_huang}提示: 请先重启系统加载新内核，然后再配置 BBR${gl_bai}"
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━ CPU 架构信息 ━━━━━━━━━━${gl_bai}"
    echo -e "  CPU 架构等级: ${gl_lv}x86-64-v${version}${gl_bai}"
    echo -e "  安装内核包: ${gl_lv}${xanmod_package}${gl_bai}"
    echo -e "  ${gl_huang}说明: 本机 CPU 最高支持 v${version}，已安装官方仓库中最匹配的内核包${gl_bai}"
    echo -e "  ${gl_huang}官方 mainline 当前提供 x64v2/x64v3；x64v1 使用 LTS，x64v4 使用 x64v3${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    echo -e "${gl_kjlan}后续更新: 再次运行选项1即可检查并安装最新内核${gl_bai}"

    rm -f "$xanmod_repo_file"
    echo -e "${gl_lv}已自动清理 XanMod 软件源（如需更新可再次运行选项1）${gl_bai}"

    return 0
}

dns_purify_fix_systemd_resolved() {
    echo -e "${gl_kjlan}正在检测 systemd-resolved 服务状态...${gl_bai}"

    # 检查服务是否已启用且正在运行
    if systemctl is-enabled systemd-resolved &> /dev/null; then
        if systemctl is-active --quiet systemd-resolved; then
            echo -e "${gl_lv}✅ systemd-resolved 服务已启用且运行中${gl_bai}"
            return 0
        else
            # 已启用但未运行（可能 crash 或被手动停止）
            echo -e "${gl_huang}systemd-resolved 已启用但未运行，正在启动...${gl_bai}"
            systemctl start systemd-resolved 2>/dev/null || true
            sleep 2
            if systemctl is-active --quiet systemd-resolved; then
                echo -e "${gl_lv}✅ systemd-resolved 服务已成功启动${gl_bai}"
                return 0
            else
                echo -e "${gl_hong}启动失败，尝试重新启用...${gl_bai}"
                systemctl restart systemd-resolved 2>/dev/null || true
                sleep 2
                if systemctl is-active --quiet systemd-resolved; then
                    echo -e "${gl_lv}✅ systemd-resolved 服务已重启成功${gl_bai}"
                    return 0
                else
                    echo -e "${gl_hong}服务无法启动${gl_bai}"
                    systemctl status systemd-resolved --no-pager || true
                    return 1
                fi
            fi
        fi
    fi

    # 检查是否被 masked
    if systemctl status systemd-resolved 2>&1 | grep -q "masked"; then
        echo -e "${gl_huang}检测到 systemd-resolved 被屏蔽 (masked)，正在修复...${gl_bai}"

        # 解除屏蔽
        if systemctl unmask systemd-resolved 2>/dev/null; then
            echo -e "${gl_lv}✅ 已成功解除 systemd-resolved 的屏蔽状态${gl_bai}"
        else
            echo -e "${gl_hong}解除屏蔽失败，尝试手动修复...${gl_bai}"
            # 手动删除屏蔽链接
            rm -f /etc/systemd/system/systemd-resolved.service 2>/dev/null || true
            systemctl daemon-reload
            echo -e "${gl_lv}✅ 已手动移除屏蔽链接${gl_bai}"
        fi

        # 启用服务
        if systemctl enable systemd-resolved 2>/dev/null; then
            echo -e "${gl_lv}✅ 已启用 systemd-resolved 服务${gl_bai}"
        else
            echo -e "${gl_hong}启用服务失败${gl_bai}"
            return 1
        fi

        # 启动服务
        if systemctl start systemd-resolved 2>/dev/null; then
            echo -e "${gl_lv}✅ 已启动 systemd-resolved 服务${gl_bai}"
        else
            echo -e "${gl_hong}启动服务失败${gl_bai}"
            return 1
        fi

        # 等待服务完全启动
        sleep 2

        # 验证服务状态
        if systemctl is-active --quiet systemd-resolved; then
            echo -e "${gl_lv}✅ systemd-resolved 服务运行正常${gl_bai}"
            return 0
        else
            echo -e "${gl_hong}服务启动后状态异常${gl_bai}"
            systemctl status systemd-resolved --no-pager || true
            return 1
        fi
    else
        echo -e "${gl_huang}systemd-resolved 未启用，正在启用...${gl_bai}"
        systemctl enable systemd-resolved 2>/dev/null || true
        systemctl start systemd-resolved 2>/dev/null || true

        # 等待服务启动并验证
        sleep 2
        if systemctl is-active --quiet systemd-resolved; then
            echo -e "${gl_lv}✅ systemd-resolved 服务已启用并运行${gl_bai}"
            return 0
        else
            echo -e "${gl_hong}systemd-resolved 启动失败${gl_bai}"
            systemctl status systemd-resolved --no-pager || true
            return 1
        fi
    fi
}

dns_purify_and_harden() {
    echo -e "${gl_kjlan}╔════════════════════════════════════════════════════════════╗${gl_bai}"
    echo -e "${gl_kjlan}║    DNS净化与安全加固脚本 - SSH安全增强版 v2.0             ║${gl_bai}"
    echo -e "${gl_kjlan}╚════════════════════════════════════════════════════════════╝${gl_bai}"
    echo ""

    # ==================== SSH安全检测 ====================
    local IS_SSH=false
    if [ -n "$SSH_CLIENT" ] || [ -n "$SSH_TTY" ]; then
        IS_SSH=true
        echo -e "${gl_hong}⚠️  检测到您正在通过SSH连接${gl_bai}"
        echo -e "${gl_lv}✅ SSH安全模式已启用：本脚本不会中断您的网络连接${gl_bai}"
        echo ""
    fi

    echo -e "${gl_kjlan}功能说明：${gl_bai}"
    echo "  ✓ 配置安全的DNS服务器（支持国外/国内模式）"
    echo "  ✓ 防止DHCP覆盖DNS配置"
    echo "  ✓ 清除厂商残留的DNS配置"
    echo "  ✓ 启用DNS安全功能（DNSSEC + DNS over TLS）"
    echo ""

    if [ "$IS_SSH" = true ]; then
        echo -e "${gl_lv}SSH安全保证：${gl_bai}"
        echo "  ✓ 不会停止或重启网络服务"
        echo "  ✓ 不会中断SSH连接"
        echo "  ✓ 所有配置立即生效，无需重启"
        echo "  ✓ 提供完整的回滚机制"
        echo ""
    fi

    # ==================== 已有配置检测 ====================
    local dns_has_config=false
    local dns_is_legacy=false
    local dns_all_healthy=true
    local current_mode_name=""
    local svc_file="/etc/systemd/system/dns-purify-persist.service"

    # 第一步：检测是否存在 DNS 净化配置（不管健不健康）
    if systemctl is-enabled --quiet dns-purify-persist.service 2>/dev/null \
       || [ -f "$svc_file" ] \
       || [ -x /usr/local/bin/dns-purify-apply.sh ]; then
        dns_has_config=true
    fi

    # 第二步：如果存在配置，立即检查是新版还是老版（独立于DNS健康状态）
    if [ "$dns_has_config" = true ]; then
        # 老版特征1: 服务文件用 Requires 而非 Wants
        if [ -f "$svc_file" ] && grep -q "Requires=systemd-resolved" "$svc_file" 2>/dev/null; then
            dns_is_legacy=true
        fi
        # 老版特征2: 持久化脚本缺少 resolvectl 可用性检查
        if [ -x /usr/local/bin/dns-purify-apply.sh ] && ! grep -q "command -v resolvectl" /usr/local/bin/dns-purify-apply.sh 2>/dev/null; then
            dns_is_legacy=true
        fi
    fi

    # 第三步：健康检查（仅在有配置时执行）
    if [ "$dns_has_config" = true ]; then
        # 持久化服务已启用？
        if ! systemctl is-enabled --quiet dns-purify-persist.service 2>/dev/null; then
            dns_all_healthy=false
        fi
        # 持久化脚本存在？
        if [ ! -x /usr/local/bin/dns-purify-apply.sh ]; then
            dns_all_healthy=false
        fi
        # resolved 运行中？
        if ! systemctl is-active --quiet systemd-resolved 2>/dev/null; then
            dns_all_healthy=false
        fi
        # resolv.conf 指向 stub？
        if [ ! -L /etc/resolv.conf ] || [[ "$(readlink /etc/resolv.conf 2>/dev/null)" != *"stub-resolv.conf"* ]]; then
            dns_all_healthy=false
        fi
        # DNS 解析正常？
        if [ "$dns_all_healthy" = true ]; then
            local dns_resolve_ok=false
            if command -v getent >/dev/null 2>&1; then
                if getent hosts google.com >/dev/null 2>&1 || getent hosts baidu.com >/dev/null 2>&1; then
                    dns_resolve_ok=true
                fi
            fi
            if [ "$dns_resolve_ok" = false ]; then
                dns_all_healthy=false
            fi
        fi
    fi

    # 检测当前模式
    if [ "$dns_has_config" = true ] && [ -f /etc/systemd/resolved.conf ]; then
        local cur_dot
        cur_dot=$(sed -nE 's/^DNSOverTLS=(.+)/\1/p' /etc/systemd/resolved.conf 2>/dev/null)
        case "$cur_dot" in
            yes)           current_mode_name="纯国外模式（强制DoT）" ;;
            no)            current_mode_name="纯国内模式" ;;
            opportunistic) current_mode_name="混合模式（机会性DoT）" ;;
        esac
    fi

    # ==================== 显示检测结果 ====================
    if [ "$dns_has_config" = true ] && [ "$dns_is_legacy" = true ]; then
        # 老版配置（不管DNS当前是否健康，都必须警告）
        echo -e "${gl_hong}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_hong}  ⚠️  检测到老版 DNS 净化配置，重启后可能导致 DNS 失效！${gl_bai}"
        echo -e "${gl_hong}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        [ -n "$current_mode_name" ] && echo -e "  当前模式:    ${gl_huang}${current_mode_name}${gl_bai}"
        if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
            echo -e "  resolved:    ${gl_lv}✅ 运行中${gl_bai}"
        else
            echo -e "  resolved:    ${gl_hong}❌ 未运行${gl_bai}"
        fi
        if [ "$dns_all_healthy" = true ]; then
            echo -e "  DNS 解析:    ${gl_lv}✅ 当前正常${gl_bai}"
        else
            echo -e "  DNS 解析:    ${gl_hong}❌ 当前异常${gl_bai}"
        fi
        echo -e "  开机持久化:  ${gl_hong}⚠️  老版（重启有风险）${gl_bai}"
        echo ""
        echo -e "${gl_huang}原因：老版持久化服务存在已知bug，重启后可能导致DNS断连${gl_bai}"
        echo -e "${gl_lv}建议：继续执行 DNS 净化，新版会自动替换为安全的持久化机制${gl_bai}"
        echo ""

    elif [ "$dns_has_config" = true ] && [ "$dns_all_healthy" = true ]; then
        # 新版配置 + 全部健康：完美状态
        echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_lv}  ✅ DNS净化已完美配置，无需重复执行！${gl_bai}"
        echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        echo -e "  当前模式:    ${gl_lv}${current_mode_name}${gl_bai}"
        echo -e "  resolved:    ${gl_lv}✅ 运行中${gl_bai}"
        echo -e "  resolv.conf: ${gl_lv}✅ 指向 stub（resolved 托管）${gl_bai}"
        echo -e "  开机持久化:  ${gl_lv}✅ dns-purify-persist 已启用（新版）${gl_bai}"
        echo -e "  DNS 解析:    ${gl_lv}✅ 正常${gl_bai}"
        echo ""
        echo -e "${gl_huang}提示：重启后 DNS 会自动恢复，无需担心${gl_bai}"
        echo ""
        if [ "${ONE_SHOT_MODE:-}" = "1" ]; then
            echo ""
        elif [ "$AUTO_MODE" = "1" ]; then
            return
        else
            read -e -p "$(echo -e "${gl_huang}如需重新配置请输入 y，返回主菜单按回车: ${gl_bai}")" dns_reconfig
            if [[ ! "$dns_reconfig" =~ ^[Yy]$ ]]; then
                return
            fi
            echo ""
        fi
    fi

    # ==================== DNS模式选择 ====================
    echo -e "${gl_kjlan}请选择 DNS 配置模式：${gl_bai}"
    echo ""
    echo "  1. 🌍 纯国外模式（抗污染推荐）"
    echo "     首选：Google DNS + Cloudflare DNS"
    echo "     备用：无"
    echo "     加密：强制 DNS over TLS"
    echo ""
    echo "  2. 🇨🇳 纯国内模式（低延迟推荐）"
    echo "     首选：阿里云 DNS + 腾讯 DNSPod"
    echo "     备用：无"
    echo "     加密：无（国内DNS不支持DoT/DNSSEC）"
    echo ""
    echo "  3. 跳过 DNS 净化"
    echo ""
    if [ "$AUTO_MODE" = "1" ]; then
        dns_mode_choice=1
    else
        read -e -p "$(echo -e "${gl_huang}请选择 (1/2/3，默认1): ${gl_bai}")" dns_mode_choice
        dns_mode_choice=${dns_mode_choice:-1}
    fi

    # 验证输入
    if [[ ! "$dns_mode_choice" =~ ^[1-3]$ ]]; then
        dns_mode_choice=1
    fi

    if [ "$dns_mode_choice" = "3" ]; then
        echo -e "${gl_huang}已跳过 DNS 净化${gl_bai}"
        return
    fi

    echo ""

    if [ "$AUTO_MODE" = "1" ] || [ "${ONE_SHOT_MODE:-}" = "1" ]; then
        confirm=y
    else
        read -e -p "$(echo -e "${gl_huang}是否继续执行？(y/n): ${gl_bai}")" confirm
    fi

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${gl_huang}已取消操作${gl_bai}"
        return
    fi

    # ==================== 终极安全检查 ====================
    echo ""
    echo -e "${gl_kjlan}[安全检查] 正在验证系统环境...${gl_bai}"
    echo ""
    
    local pre_check_failed=false
    
    # 检查1: 磁盘空间（至少需要100MB）
    echo -n "  → 检查磁盘空间... "
    local available_space=$(df -m /etc | awk 'NR==2 {print $4}')
    if [ "$available_space" -lt 100 ]; then
        echo -e "${gl_hong}失败 (可用: ${available_space}MB, 需要: 100MB)${gl_bai}"
        pre_check_failed=true
    else
        echo -e "${gl_lv}通过 (可用: ${available_space}MB)${gl_bai}"
    fi
    
    # 检查2: 内存（至少需要50MB可用）
    echo -n "  → 检查可用内存... "
    local available_mem=$(free -m | awk 'NR==2 {print $7}')
    if [ "$available_mem" -lt 50 ]; then
        echo -e "${gl_hong}失败 (可用: ${available_mem}MB, 需要: 50MB)${gl_bai}"
        pre_check_failed=true
    else
        echo -e "${gl_lv}通过 (可用: ${available_mem}MB)${gl_bai}"
    fi
    
    # 检查3: systemd 是否正常工作
    echo -n "  → 检查 systemd 状态... "
    if ! systemctl --version > /dev/null 2>&1; then
        echo -e "${gl_hong}失败 (systemctl 命令无法执行)${gl_bai}"
        pre_check_failed=true
    else
        echo -e "${gl_lv}通过${gl_bai}"
    fi
    
    # 检查4: 是否有其他包管理器在运行
    echo -n "  → 检查包管理器锁... "
    if lsof /var/lib/dpkg/lock-frontend > /dev/null 2>&1 || \
       lsof /var/lib/apt/lists/lock > /dev/null 2>&1 || \
       lsof /var/cache/apt/archives/lock > /dev/null 2>&1; then
        echo -e "${gl_hong}失败 (其他包管理器正在运行)${gl_bai}"
        pre_check_failed=true
    else
        echo -e "${gl_lv}通过${gl_bai}"
    fi
    
    # 检查5: /run 目录是否可写
    echo -n "  → 检查 /run 目录权限... "
    if ! touch /run/.dns_test 2>/dev/null; then
        echo -e "${gl_hong}失败 (/run 目录不可写)${gl_bai}"
        pre_check_failed=true
    else
        rm -f /run/.dns_test
        echo -e "${gl_lv}通过${gl_bai}"
    fi
    
    # 检查6: 网络连通性（能否访问DNS服务器）
    echo -n "  → 检查网络连通性... "
    if ! ping -c 1 -W 2 8.8.8.8 > /dev/null 2>&1 && \
       ! ping -c 1 -W 2 1.1.1.1 > /dev/null 2>&1; then
        echo -e "${gl_huang}警告 (无法ping通DNS服务器，但继续执行)${gl_bai}"
    else
        echo -e "${gl_lv}通过${gl_bai}"
    fi
    
    echo ""
    
    # 如果有检查失败，拒绝执行
    if [ "$pre_check_failed" = true ]; then
        echo -e "${gl_hong}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_hong}❌ 安全检查未通过！${gl_bai}"
        echo -e "${gl_hong}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        echo -e "${gl_huang}系统环境不满足安全执行条件，拒绝执行以避免风险。${gl_bai}"
        echo ""
        echo "请先解决上述问题，然后重试。"
        echo ""
        break_end
        return 1
    fi
    
    echo -e "${gl_lv}✅ 所有安全检查通过，可以安全执行${gl_bai}"
    echo ""

    # ==================== 创建备份 ====================
    local BACKUP_DIR="/root/.dns_purify_backup/$(date +%Y%m%d_%H%M%S)"
    local PRE_STATE_DIR="$BACKUP_DIR/pre_state"
    mkdir -p "$BACKUP_DIR" "$PRE_STATE_DIR"
    echo ""
    echo -e "${gl_lv}✅ 创建备份目录：$BACKUP_DIR${gl_bai}"
    echo ""

    # 记录/恢复单个路径状态（文件、符号链接或不存在）
    backup_path_state() {
        local src="$1"
        local key="$2"
        if [[ -e "$src" || -L "$src" ]]; then
            cp -a "$src" "$PRE_STATE_DIR/$key" 2>/dev/null || true
        else
            : > "$PRE_STATE_DIR/$key.absent"
        fi
    }

    restore_path_state() {
        local dst="$1"
        local key="$2"
        rm -f "$dst" 2>/dev/null || true
        if [[ -e "$PRE_STATE_DIR/$key" || -L "$PRE_STATE_DIR/$key" ]]; then
            mkdir -p "$(dirname "$dst")"
            cp -a "$PRE_STATE_DIR/$key" "$dst" 2>/dev/null || true
        elif [[ -f "$PRE_STATE_DIR/$key.absent" ]]; then
            rm -f "$dst" 2>/dev/null || true
        fi
    }

    # 解析 DNS 地址中的 SNI 后缀（例如 1.1.1.1#cloudflare-dns.com -> 1.1.1.1）
    plain_dns_ip() {
        local dns_addr="$1"
        echo "${dns_addr%%#*}"
    }

    # 预先快照本次功能可能修改的关键文件
    backup_path_state "/etc/dhcp/dhclient.conf" "dhclient.conf"
    backup_path_state "/etc/network/interfaces" "interfaces"
    backup_path_state "/etc/systemd/resolved.conf" "resolved.conf"
    backup_path_state "/etc/resolv.conf" "resolv.conf"
    backup_path_state "/etc/systemd/system/dns-purify-persist.service" "dns-purify-persist.service"
    backup_path_state "/usr/local/bin/dns-purify-apply.sh" "dns-purify-apply.sh"
    backup_path_state "/etc/systemd/system/systemd-resolved.service.d/dbus-fix.conf" "dbus-fix.conf"
    backup_path_state "/etc/NetworkManager/conf.d/99-dns-purify.conf" "nm-99-dns-purify.conf"

    # 快照 if-up.d/resolved 执行权限状态
    local ifup_script="/etc/network/if-up.d/resolved"
    if [[ -e "$ifup_script" ]]; then
        if [[ -x "$ifup_script" ]]; then
            echo "executable" > "$PRE_STATE_DIR/ifup-resolved.exec"
        else
            echo "not_executable" > "$PRE_STATE_DIR/ifup-resolved.exec"
        fi
    else
        echo "absent" > "$PRE_STATE_DIR/ifup-resolved.exec"
    fi

    # 快照服务启用状态
    if systemctl is-enabled --quiet dns-purify-persist.service 2>/dev/null; then
        echo "true" > "$PRE_STATE_DIR/dns-persist.was-enabled"
    else
        echo "false" > "$PRE_STATE_DIR/dns-persist.was-enabled"
    fi

    # 用文本输出精确记录 enabled/static/disabled/masked 状态（is-enabled --quiet 对 static 也返回 0）
    local resolved_enable_state
    resolved_enable_state=$(systemctl is-enabled systemd-resolved 2>/dev/null || echo "unknown")
    echo "$resolved_enable_state" > "$PRE_STATE_DIR/resolved.enable-state"

    if [[ "$resolved_enable_state" == "masked" || "$resolved_enable_state" == "masked-runtime" ]]; then
        echo "true" > "$PRE_STATE_DIR/resolved.was-masked"
    else
        echo "false" > "$PRE_STATE_DIR/resolved.was-masked"
    fi

    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        echo "true" > "$PRE_STATE_DIR/resolved.was-active"
    else
        echo "false" > "$PRE_STATE_DIR/resolved.was-active"
    fi

    # 快照 resolvconf 包状态（用于 Debian 11 回滚）
    if dpkg -s resolvconf >/dev/null 2>&1; then
        echo "true" > "$PRE_STATE_DIR/had-resolvconf.pkg"
    else
        echo "false" > "$PRE_STATE_DIR/had-resolvconf.pkg"
    fi

    local pre_dns_health="false"
    if command -v getent >/dev/null 2>&1; then
        if getent hosts google.com >/dev/null 2>&1 || getent hosts baidu.com >/dev/null 2>&1; then
            pre_dns_health="true"
        fi
    fi
    echo "$pre_dns_health" > "$PRE_STATE_DIR/pre-dns.health"

    # 快照现有 systemd-networkd DNS drop-in
    : > "$PRE_STATE_DIR/networkd-dropins.map"
    local existing_dropin
    for existing_dropin in /etc/systemd/network/*.network.d/dns-purify-override.conf; do
        [[ -f "$existing_dropin" ]] || continue
        local dropin_key="networkd-$(echo "$existing_dropin" | sed 's|/|__|g')"
        cp -a "$existing_dropin" "$PRE_STATE_DIR/$dropin_key" 2>/dev/null || true
        echo "$existing_dropin|$dropin_key" >> "$PRE_STATE_DIR/networkd-dropins.map"
    done

    # 退出函数时自动清理本函数内动态定义的 helper，避免影响其他功能
    trap 'unset -f backup_path_state restore_path_state plain_dns_ip auto_rollback_dns_purify dns_runtime_health_check can_connect_tcp >/dev/null 2>&1 || true' RETURN

    # 自动回滚函数（失败即恢复，避免遗留DNS隐患）
    auto_rollback_dns_purify() {
        # 恢复关键文件到执行前状态（注意：resolv.conf 延后恢复，避免悬空链接）
        restore_path_state "/etc/dhcp/dhclient.conf" "dhclient.conf"
        restore_path_state "/etc/network/interfaces" "interfaces"
        restore_path_state "/etc/systemd/resolved.conf" "resolved.conf"
        # resolv.conf 在服务状态恢复后再处理（见下方）
        restore_path_state "/etc/systemd/system/dns-purify-persist.service" "dns-purify-persist.service"
        restore_path_state "/usr/local/bin/dns-purify-apply.sh" "dns-purify-apply.sh"
        restore_path_state "/etc/systemd/system/systemd-resolved.service.d/dbus-fix.conf" "dbus-fix.conf"
        restore_path_state "/etc/NetworkManager/conf.d/99-dns-purify.conf" "nm-99-dns-purify.conf"

        # 恢复 if-up.d/resolved 执行权限
        if [[ -f "$PRE_STATE_DIR/ifup-resolved.exec" ]]; then
            case "$(cat "$PRE_STATE_DIR/ifup-resolved.exec" 2>/dev/null)" in
                executable)
                    [[ -e /etc/network/if-up.d/resolved ]] && chmod +x /etc/network/if-up.d/resolved 2>/dev/null || true
                    ;;
                not_executable)
                    [[ -e /etc/network/if-up.d/resolved ]] && chmod -x /etc/network/if-up.d/resolved 2>/dev/null || true
                    ;;
                absent)
                    rm -f /etc/network/if-up.d/resolved 2>/dev/null || true
                    ;;
            esac
        fi

        # 移除本次可能新增的 networkd drop-in（扩展搜索所有可能路径）
        local dropin_file search_dir
        for search_dir in /etc/systemd/network /run/systemd/network /usr/lib/systemd/network; do
            for dropin_file in "$search_dir"/*.network.d/dns-purify-override.conf; do
                [[ -f "$dropin_file" ]] || continue
                rm -f "$dropin_file"
                rmdir "$(dirname "$dropin_file")" 2>/dev/null || true
            done
        done

        # 恢复执行前已有的 networkd drop-in
        if [[ -f "$PRE_STATE_DIR/networkd-dropins.map" ]]; then
            local restore_path restore_key
            while IFS='|' read -r restore_path restore_key; do
                [[ -n "$restore_path" && -n "$restore_key" ]] || continue
                [[ -f "$PRE_STATE_DIR/$restore_key" ]] || continue
                mkdir -p "$(dirname "$restore_path")"
                cp -a "$PRE_STATE_DIR/$restore_key" "$restore_path" 2>/dev/null || true
            done < "$PRE_STATE_DIR/networkd-dropins.map"
        fi

        # 重载 systemd-networkd（使 drop-in 变更生效）
        if systemctl is-active --quiet systemd-networkd 2>/dev/null; then
            networkctl reload 2>/dev/null || systemctl reload systemd-networkd 2>/dev/null || true
        fi

        # 重载 NetworkManager（使配置文件变更生效）
        if systemctl is-active --quiet NetworkManager 2>/dev/null; then
            systemctl reload NetworkManager 2>/dev/null || true
        fi

        # 恢复 dns-purify 持久化服务启用状态
        local dns_persist_was_enabled="false"
        [[ -f "$PRE_STATE_DIR/dns-persist.was-enabled" ]] && dns_persist_was_enabled=$(cat "$PRE_STATE_DIR/dns-persist.was-enabled" 2>/dev/null || echo "false")

        systemctl daemon-reload 2>/dev/null || true
        if [[ -e "$PRE_STATE_DIR/dns-purify-persist.service" || -L "$PRE_STATE_DIR/dns-purify-persist.service" ]]; then
            if [[ "$dns_persist_was_enabled" == "true" ]]; then
                systemctl enable dns-purify-persist.service 2>/dev/null || true
            else
                systemctl disable dns-purify-persist.service 2>/dev/null || true
            fi
        else
            systemctl disable dns-purify-persist.service 2>/dev/null || true
        fi

        # 尝试恢复 resolvconf 包状态（Debian 11 场景）
        local had_resolvconf_pkg="false"
        [[ -f "$PRE_STATE_DIR/had-resolvconf.pkg" ]] && had_resolvconf_pkg=$(cat "$PRE_STATE_DIR/had-resolvconf.pkg" 2>/dev/null || echo "false")
        if [[ "$had_resolvconf_pkg" == "true" ]] && ! dpkg -s resolvconf >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y resolvconf >/dev/null 2>&1 || true
        fi

        # 恢复 systemd-resolved 启用/屏蔽/运行状态（在 resolv.conf 之前）
        local resolved_enable_state="unknown"
        local resolved_was_masked="false"
        local resolved_was_active="false"
        [[ -f "$PRE_STATE_DIR/resolved.enable-state" ]] && resolved_enable_state=$(cat "$PRE_STATE_DIR/resolved.enable-state" 2>/dev/null || echo "unknown")
        # 兼容旧版快照格式
        [[ "$resolved_enable_state" == "unknown" && -f "$PRE_STATE_DIR/resolved.was-enabled" ]] && {
            local old_enabled
            old_enabled=$(cat "$PRE_STATE_DIR/resolved.was-enabled" 2>/dev/null || echo "false")
            [[ "$old_enabled" == "true" ]] && resolved_enable_state="enabled" || resolved_enable_state="disabled"
        }
        [[ -f "$PRE_STATE_DIR/resolved.was-masked" ]] && resolved_was_masked=$(cat "$PRE_STATE_DIR/resolved.was-masked" 2>/dev/null || echo "false")
        [[ -f "$PRE_STATE_DIR/resolved.was-active" ]] && resolved_was_active=$(cat "$PRE_STATE_DIR/resolved.was-active" 2>/dev/null || echo "false")

        if [[ "$resolved_was_masked" == "true" ]]; then
            systemctl mask systemd-resolved 2>/dev/null || true
            systemctl stop systemd-resolved 2>/dev/null || true
        else
            systemctl unmask systemd-resolved 2>/dev/null || true
            case "$resolved_enable_state" in
                enabled|enabled-runtime)
                    systemctl enable systemd-resolved 2>/dev/null || true
                    ;;
                static|indirect|generated)
                    # static/indirect/generated 状态由包管理器控制，不改变
                    ;;
                *)
                    systemctl disable systemd-resolved 2>/dev/null || true
                    ;;
            esac

            if [[ "$resolved_was_active" == "true" ]]; then
                systemctl restart systemd-resolved 2>/dev/null || systemctl start systemd-resolved 2>/dev/null || true
                # 等待 resolved 完全启动，确保 stub 文件可用
                local wait_i
                for wait_i in $(seq 1 5); do
                    [[ -f /run/systemd/resolve/stub-resolv.conf ]] && break
                    sleep 1
                done
            else
                systemctl stop systemd-resolved 2>/dev/null || true
            fi
        fi

        # 最后恢复 resolv.conf（此时 resolved 已恢复运行状态，stub 文件可用）
        # 特殊处理：如果备份是指向 stub 的软链接但 resolved 未运行，则写静态文件
        if [[ -L "$PRE_STATE_DIR/resolv.conf" ]]; then
            local backup_link_target
            backup_link_target=$(readlink "$PRE_STATE_DIR/resolv.conf" 2>/dev/null || echo "")
            if [[ "$backup_link_target" == *"stub-resolv.conf"* ]] && [[ ! -f /run/systemd/resolve/stub-resolv.conf ]]; then
                # resolved 未运行，stub 不存在 — 写入静态 nameserver 避免悬空链接
                rm -f /etc/resolv.conf 2>/dev/null || true
                echo "nameserver 127.0.0.53" > /etc/resolv.conf 2>/dev/null || true
            else
                restore_path_state "/etc/resolv.conf" "resolv.conf"
            fi
        else
            restore_path_state "/etc/resolv.conf" "resolv.conf"
        fi

        # 回滚后验证 — 充分等待 resolved 初始化（最多15秒，每3秒重试）
        local rollback_ok=false
        local pre_dns_health="false"
        [[ -f "$PRE_STATE_DIR/pre-dns.health" ]] && pre_dns_health=$(cat "$PRE_STATE_DIR/pre-dns.health" 2>/dev/null || echo "false")

        local max_wait=5
        for i in $(seq 1 $max_wait); do
            if dns_runtime_health_check "global" || dns_runtime_health_check "cn"; then
                rollback_ok=true
                break
            fi
            sleep 3
        done

        if [ "$rollback_ok" = true ]; then
            echo -e "${gl_lv}  ✅ 回滚后DNS健康校验通过${gl_bai}"
        elif [ "$pre_dns_health" = "true" ]; then
            echo -e "${gl_huang}  ⚠️  回滚后DNS验证超时，但已恢复执行前配置，可能需要等待网络就绪${gl_bai}"
        else
            echo -e "${gl_huang}  ⚠️  执行前DNS即不可用，已恢复原始配置${gl_bai}"
        fi
    }

    # DNS运行时健康检查（多域名，多方法）
    dns_runtime_health_check() {
        local check_mode="${1:-global}"
        local domains=()
        if [[ "$check_mode" == "cn" ]]; then
            domains=("baidu.com" "qq.com" "aliyun.com")
        else
            domains=("google.com" "cloudflare.com" "github.com" "baidu.com")
        fi

        if command -v getent >/dev/null 2>&1; then
            local domain
            for domain in "${domains[@]}"; do
                if getent hosts "$domain" >/dev/null 2>&1; then
                    return 0
                fi
            done
        fi

        if command -v nslookup >/dev/null 2>&1; then
            local domain
            for domain in "${domains[@]}"; do
                if nslookup "$domain" >/dev/null 2>&1; then
                    return 0
                fi
            done
        fi

        local domain
        for domain in "${domains[@]}"; do
            if ping -c 1 -W 2 "$domain" >/dev/null 2>&1; then
                return 0
            fi
        done

        return 1
    }

    # TCP端口探测（用于DoT 853预检）
    can_connect_tcp() {
        local host="$1"
        local port="$2"
        if command -v timeout >/dev/null 2>&1; then
            timeout 3 bash -c "exec 3<>/dev/tcp/${host}/${port} && exec 3>&-" >/dev/null 2>&1
        else
            bash -c "exec 3<>/dev/tcp/${host}/${port} && exec 3>&-" >/dev/null 2>&1
        fi
    }

    # 目标DNS配置（根据用户选择的模式）
    local TARGET_DNS=""
    local FALLBACK_DNS=""
    local DNS_OVER_TLS=""
    local DNSSEC_MODE=""
    local MODE_NAME=""
    # 网卡级 DNS（用于 resolvectl）
    local INTERFACE_DNS_PRIMARY=""
    local INTERFACE_DNS_SECONDARY=""
    case "$dns_mode_choice" in
        1)
            # 纯国外模式
            TARGET_DNS="8.8.8.8#dns.google 1.1.1.1#cloudflare-dns.com"
            FALLBACK_DNS=""
            DNS_OVER_TLS="yes"
            DNSSEC_MODE="no"
            MODE_NAME="纯国外模式"
            # 网卡级使用纯IP，避免个别systemd/resolvectl版本对SNI参数兼容问题
            INTERFACE_DNS_PRIMARY="8.8.8.8"
            INTERFACE_DNS_SECONDARY="1.1.1.1"
            ;;
        2)
            # 纯国内模式（国内DNS和国内域名大多不支持DNSSEC，必须禁用）
            TARGET_DNS="223.5.5.5 119.29.29.29"
            FALLBACK_DNS=""
            DNS_OVER_TLS="no"
            DNSSEC_MODE="no"
            MODE_NAME="纯国内模式"
            INTERFACE_DNS_PRIMARY="223.5.5.5"
            INTERFACE_DNS_SECONDARY="119.29.29.29"
            ;;
    esac

    # strict DoT 预检：若目标机房到853不可达，直接中止（不自动降级）
    if [[ "$dns_mode_choice" == "1" ]]; then
        local dot_reachable_count=0
        can_connect_tcp "8.8.8.8" 853 && dot_reachable_count=$((dot_reachable_count + 1))
        can_connect_tcp "1.1.1.1" 853 && dot_reachable_count=$((dot_reachable_count + 1))

        if [[ "$dot_reachable_count" -eq 0 ]]; then
            echo -e "${gl_hong}❌ 预检失败：当前机房无法连通 DoT(853)，已终止执行（未做任何修改）${gl_bai}"
            echo -e "${gl_huang}建议：改用模式2，或放开到 8.8.8.8/1.1.1.1 的 853 出口后再执行模式1${gl_bai}"
            break_end
            return 1
        fi
    fi
    
    echo -e "${gl_lv}已选择：${MODE_NAME}${gl_bai}"
    echo ""
    
    # 构建配置（动态拼接，避免 FallbackDNS 为空时产生空行）
    local SECURE_RESOLVED_CONFIG="[Resolve]
DNS=${TARGET_DNS}"
    if [[ -n "$FALLBACK_DNS" ]]; then
        SECURE_RESOLVED_CONFIG="${SECURE_RESOLVED_CONFIG}
FallbackDNS=${FALLBACK_DNS}"
    fi
    SECURE_RESOLVED_CONFIG="${SECURE_RESOLVED_CONFIG}
LLMNR=no
MulticastDNS=no
DNSSEC=${DNSSEC_MODE}
DNSOverTLS=${DNS_OVER_TLS}
Cache=yes
DNSStubListener=yes
"

    echo "--- 开始执行DNS净化与安全加固流程 ---"
    echo ""

    local debian_version
    debian_version=$(grep "VERSION_ID" /etc/os-release | cut -d'=' -f2 | tr -d '"' || echo "unknown")

    # ==================== 阶段一：清除DNS冲突源 ====================
    echo -e "${gl_kjlan}[阶段 1/5] 清除DNS冲突源（安全操作）...${gl_bai}"
    echo ""

    # 1. 驯服 DHCP 客户端
    local dhclient_conf="/etc/dhcp/dhclient.conf"
    if [[ -f "$dhclient_conf" ]]; then
        # 备份
        cp "$dhclient_conf" "$BACKUP_DIR/dhclient.conf.bak" 2>/dev/null || true
        
        local dhclient_changed=false
        if ! grep -q "ignore domain-name-servers;" "$dhclient_conf"; then
            echo "" >> "$dhclient_conf"
            echo "# 由DNS净化脚本添加 - $(date)" >> "$dhclient_conf"
            echo "ignore domain-name-servers;" >> "$dhclient_conf"
            dhclient_changed=true
        fi
        if ! grep -q "ignore domain-search;" "$dhclient_conf"; then
            if [ "$dhclient_changed" = false ]; then
                echo "" >> "$dhclient_conf"
                echo "# 由DNS净化脚本添加 - $(date)" >> "$dhclient_conf"
            fi
            echo "ignore domain-search;" >> "$dhclient_conf"
            dhclient_changed=true
        fi
        if [ "$dhclient_changed" = true ]; then
            echo "  → 配置 dhclient 忽略DHCP提供的DNS..."
            echo -e "${gl_lv}  ✅ dhclient 配置完成${gl_bai}"
        else
            echo -e "${gl_lv}  ✅ dhclient 已配置（跳过）${gl_bai}"
        fi
    fi

    # 2. 禁用冲突的 if-up.d 脚本
    local ifup_script="/etc/network/if-up.d/resolved"
    if [[ -f "$ifup_script" ]] && [[ -x "$ifup_script" ]]; then
        echo "  → 禁用 if-up.d/resolved 脚本..."
        chmod -x "$ifup_script"
        echo -e "${gl_lv}  ✅ 已移除可执行权限${gl_bai}"
    fi

    # 3. 注释 /etc/network/interfaces 中的DNS配置
    local interfaces_file="/etc/network/interfaces"
    if [[ -f "$interfaces_file" ]]; then
        # 备份
        cp "$interfaces_file" "$BACKUP_DIR/interfaces.bak" 2>/dev/null || true
        
        if grep -qE '^[[:space:]]*dns-(nameservers|search|domain)' "$interfaces_file"; then
            echo "  → 清除 /etc/network/interfaces 中的DNS配置..."
            sed -i.bak -E 's/^([[:space:]]*dns-(nameservers|search|domain).*)/# \1 # 已被DNS净化脚本禁用/' "$interfaces_file"
            echo -e "${gl_lv}  ✅ 厂商DNS配置已注释${gl_bai}"
        else
            echo -e "${gl_lv}  ✅ /etc/network/interfaces 无DNS配置${gl_bai}"
        fi
    fi

    echo ""

    # ==================== 阶段二：配置 systemd-resolved ====================
    echo -e "${gl_kjlan}[阶段 2/5] 配置 systemd-resolved...${gl_bai}"
    echo ""

    # 检查是否已安装
    if ! command -v resolvectl &> /dev/null; then
        echo "  → 检测到未安装 systemd-resolved"
        echo "  → 安装 systemd-resolved..."
        apt-get update -y > /dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y systemd-resolved > /dev/null 2>&1
        echo -e "${gl_lv}  ✅ systemd-resolved 安装完成${gl_bai}"
    else
        echo -e "${gl_lv}  ✅ systemd-resolved 已安装${gl_bai}"
    fi

    # 处理 Debian 11 的 resolvconf 冲突
    if [[ "$debian_version" == "11" ]] && dpkg -s resolvconf &> /dev/null; then
        echo "  → 检测到 Debian 11 的 resolvconf 冲突"
        
        # 🛡️ 关键修复：在卸载前确保 systemd-resolved 完全就绪
        # 先启动 systemd-resolved
        echo "  → 启动 systemd-resolved（在卸载 resolvconf 之前）..."
        systemctl enable systemd-resolved 2>/dev/null || true
        systemctl start systemd-resolved 2>/dev/null || true
        
        # 等待服务启动
        sleep 2
        
        # 验证 systemd-resolved 正在运行
        if ! systemctl is-active --quiet systemd-resolved; then
            echo -e "${gl_hong}❌ 无法启动 systemd-resolved，中止操作${gl_bai}"
            auto_rollback_dns_purify
            break_end
            return 1
        fi
        
        # 验证 stub-resolv.conf 存在
        if [[ ! -f /run/systemd/resolve/stub-resolv.conf ]]; then
            echo -e "${gl_hong}❌ systemd-resolved stub 文件不存在，中止操作${gl_bai}"
            auto_rollback_dns_purify
            break_end
            return 1
        fi
        
        # 现在可以安全地卸载 resolvconf
        # 备份当前 resolv.conf
        [[ -f /etc/resolv.conf ]] && cp /etc/resolv.conf "$BACKUP_DIR/resolv.conf.pre_remove" 2>/dev/null || true
        
        # 创建临时DNS配置（避免卸载期间DNS中断）
        echo "nameserver $(plain_dns_ip "$INTERFACE_DNS_PRIMARY")" > /etc/resolv.conf.tmp
        echo "nameserver $(plain_dns_ip "$INTERFACE_DNS_SECONDARY")" >> /etc/resolv.conf.tmp
        
        # 使用临时DNS配置
        mv /etc/resolv.conf /etc/resolv.conf.old 2>/dev/null || true
        cp /etc/resolv.conf.tmp /etc/resolv.conf
        
        # 卸载 resolvconf
        echo "  → 卸载 resolvconf..."
        DEBIAN_FRONTEND=noninteractive apt-get remove -y resolvconf > /dev/null 2>&1
        
        # 清理临时文件
        rm -f /etc/resolv.conf.tmp /etc/resolv.conf.old
        
        echo -e "${gl_lv}  ✅ resolvconf 已安全卸载${gl_bai}"
    fi

    # 🔧 调用智能修复函数
    if ! dns_purify_fix_systemd_resolved; then
        echo -e "${gl_hong}❌ 无法修复 systemd-resolved 服务，脚本终止${gl_bai}"
        echo "检测到修复失败，正在自动回滚到执行前状态"
        auto_rollback_dns_purify
        break_end
        return 1
    fi

    # 备份并写入配置
    if [[ -f /etc/systemd/resolved.conf ]]; then
        cp /etc/systemd/resolved.conf "$BACKUP_DIR/resolved.conf.bak" 2>/dev/null || true
    fi

    echo "  → 配置 systemd-resolved..."
    echo -e "${SECURE_RESOLVED_CONFIG}" > /etc/systemd/resolved.conf
    
    echo ""

    # ==================== 阶段三：应用DNS配置（SSH安全方式）====================
    echo -e "${gl_kjlan}[阶段 3/5] 应用DNS配置（SSH安全模式）...${gl_bai}"
    echo ""

    # 先重新加载 systemd-resolved 配置
    echo "  → 重新加载 systemd-resolved 配置..."
    if ! systemctl reload-or-restart systemd-resolved; then
        echo -e "${gl_hong}❌ systemd-resolved 重启失败！${gl_bai}"
        echo "正在自动回滚配置..."
        auto_rollback_dns_purify
        break_end
        return 1
    fi
    
    # 等待服务完全启动
    echo "  → 等待 systemd-resolved 完全启动..."
    sleep 3
    
    # 验证服务状态
    if ! systemctl is-active --quiet systemd-resolved; then
        echo -e "${gl_hong}❌ systemd-resolved 未能正常运行！${gl_bai}"
        echo "正在自动回滚配置..."
        auto_rollback_dns_purify
        break_end
        return 1
    fi
    
    # 验证 stub-resolv.conf 文件存在
    if [[ ! -f /run/systemd/resolve/stub-resolv.conf ]]; then
        echo -e "${gl_hong}❌ systemd-resolved stub 文件不存在！${gl_bai}"
        echo "路径: /run/systemd/resolve/stub-resolv.conf"
        echo "正在自动回滚配置..."
        auto_rollback_dns_purify
        break_end
        return 1
    fi
    
    echo -e "${gl_lv}  ✅ systemd-resolved 配置已重新加载并验证${gl_bai}"

    # 🔧 确保服务开机自启动（修复 #11：某些 Debian 版本服务状态为 static 时不会自启）
    echo "  → 确保 systemd-resolved 开机自启动..."
    systemctl enable systemd-resolved >/dev/null 2>&1 || true
    echo -e "${gl_lv}  ✅ 已设置开机自启动${gl_bai}"

    # 🔒 检测 immutable 属性（云服务商保护机制）
    if [[ -e /etc/resolv.conf ]] && lsattr /etc/resolv.conf 2>/dev/null | grep -q 'i'; then
        echo ""
        echo -e "${gl_hong}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_hong}⚠️  检测到 /etc/resolv.conf 被锁定保护${gl_bai}"
        echo -e "${gl_hong}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        echo "原因：您的服务器设置了不可变属性（通常是云服务商的保护机制）"
        echo ""
        echo "风险：强制修改可能导致机器失联或网络异常"
        echo ""
        echo "建议：如非必要，不建议继续修改"
        echo "      能正常执行的系统不会弹出此提示"
        echo ""
        echo -e "${gl_huang}状态：检测到锁定保护，正在恢复已修改的配置${gl_bai}"
        # 只回滚 resolved.conf（阶段二已修改），不做完整回滚
        # resolv.conf 尚未被修改（软链接替换在此检查之后），无需恢复
        restore_path_state "/etc/systemd/resolved.conf" "resolved.conf"
        systemctl reload-or-restart systemd-resolved 2>/dev/null || true
        echo ""
        break_end
        return 1
    fi
    
    # 🛡️ 关键修复：安全地创建 resolv.conf 链接
    # 备份并创建 resolv.conf 链接（只有在验证通过后才执行）
    if [[ -e /etc/resolv.conf ]] && [[ ! -L /etc/resolv.conf ]]; then
        # 如果是普通文件，备份它
        cp /etc/resolv.conf "$BACKUP_DIR/resolv.conf.bak" 2>/dev/null || true
    fi
    
    # 安全地创建链接
    rm -f /etc/resolv.conf
    ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    
    # 验证链接创建成功
    if [[ ! -L /etc/resolv.conf ]] || [[ ! -e /etc/resolv.conf ]]; then
        echo -e "${gl_hong}❌ resolv.conf 链接创建失败！${gl_bai}"
        echo "正在自动回滚原始配置..."
        auto_rollback_dns_purify
        break_end
        return 1
    fi
    
    echo -e "${gl_lv}  ✅ resolv.conf 链接已安全创建${gl_bai}"
    
    # 🚫 完全移除 networking.service 重启（即使非SSH模式也危险）
    # 注意：不管是SSH还是本地连接，都不重启 networking.service
    # 因为重启网络服务在生产环境中极其危险
    echo -e "${gl_lv}  ✅ 网络服务未受影响（安全模式）${gl_bai}"

    echo ""
    
    # ==================== Debian 13特殊修复：D-Bus接口注册问题 ====================
    echo -e "${gl_kjlan}[特殊修复] 检测并修复 D-Bus 接口注册（Debian 13兼容）...${gl_bai}"
    echo ""
    
    # 检测是否需要修复D-Bus接口
    local need_dbus_fix=false
    # debian_version 已在阶段二前定义，此处直接使用

    echo "  → 检测系统版本：Debian ${debian_version:-未知}"
    
    # 检查resolvectl是否能正常通信
    echo "  → 测试 resolvectl 命令响应..."
    if ! timeout 3 resolvectl status >/dev/null 2>&1; then
        echo -e "${gl_huang}  ⚠️  resolvectl 命令无响应，需要修复 D-Bus 接口${gl_bai}"
        need_dbus_fix=true
    else
        echo -e "${gl_lv}  ✅ resolvectl 响应正常${gl_bai}"
    fi
    
    # 如果需要修复D-Bus接口
    if [ "$need_dbus_fix" = true ]; then
        echo ""
        echo -e "${gl_huang}检测到 D-Bus 接口注册问题（Debian 13已知问题），正在自动修复...${gl_bai}"
        echo ""
        
        # 🛡️ 安全措施：在重启前创建临时DNS配置，确保DNS始终可用
        echo "  → 创建临时DNS配置（防止修复期间DNS中断）..."
        
        # 备份当前resolv.conf
        if [[ -e /etc/resolv.conf ]]; then
            cp /etc/resolv.conf "$BACKUP_DIR/resolv.conf.before_dbus_fix" 2>/dev/null || true
        fi
        
        # 创建临时DNS配置文件
        cat > /etc/resolv.conf.dbus_fix_temp << TEMP_DNS
# 临时DNS配置（D-Bus修复期间使用）
nameserver $INTERFACE_DNS_PRIMARY
nameserver $INTERFACE_DNS_SECONDARY
TEMP_DNS
        
        # 使用临时DNS配置
        rm -f /etc/resolv.conf
        cp /etc/resolv.conf.dbus_fix_temp /etc/resolv.conf
        chmod 644 /etc/resolv.conf
        
        echo -e "${gl_lv}  ✅ 临时DNS配置已创建（确保修复期间DNS可用）${gl_bai}"
        
        # 1. 完全重启systemd-resolved，让它重新注册D-Bus接口
        echo "  → 重启 systemd-resolved 以重新注册 D-Bus 接口..."
        systemctl stop systemd-resolved 2>/dev/null || true
        sleep 2
        systemctl start systemd-resolved 2>/dev/null || true
        sleep 3
        
        # 🛡️ 恢复到 stub-resolv.conf 链接
        echo "  → 恢复 resolv.conf 链接到 stub-resolv.conf..."
        
        # 验证 stub-resolv.conf 存在
        if [[ -f /run/systemd/resolve/stub-resolv.conf ]]; then
            rm -f /etc/resolv.conf
            ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
            echo -e "${gl_lv}  ✅ resolv.conf 链接已恢复${gl_bai}"
        else
            echo -e "${gl_huang}  ⚠️  stub-resolv.conf 不存在，保持临时DNS配置${gl_bai}"
        fi
        
        # 清理临时文件
        rm -f /etc/resolv.conf.dbus_fix_temp
        
        # 2. 验证D-Bus接口是否注册成功
        if command -v busctl &>/dev/null; then
            local dbus_status=$(busctl list 2>/dev/null | grep "org.freedesktop.resolve1" | grep -v "activatable" || echo "")
            if [ -n "$dbus_status" ]; then
                echo -e "${gl_lv}  ✅ D-Bus 接口已成功注册${gl_bai}"
                
                # 3. 创建永久修复配置（确保重启后也能正常工作）
                echo "  → 创建永久修复配置..."
                mkdir -p /etc/systemd/system/systemd-resolved.service.d
                cat > /etc/systemd/system/systemd-resolved.service.d/dbus-fix.conf << 'DBUS_FIX'
# Debian 13 D-Bus接口注册修复
# 确保D-Bus完全启动后再启动systemd-resolved
[Unit]
After=dbus.service
Requires=dbus.service

[Service]
# 启动后等待1秒，确保D-Bus接口注册完成
ExecStartPost=/bin/sleep 1
DBUS_FIX
                
                systemctl daemon-reload 2>/dev/null || true
                echo -e "${gl_lv}  ✅ 永久修复配置已创建${gl_bai}"
                
                # 4. 再次测试resolvectl
                if timeout 3 resolvectl status >/dev/null 2>&1; then
                    echo -e "${gl_lv}  ✅ resolvectl 现在能正常工作了${gl_bai}"
                else
                    echo -e "${gl_huang}  ⚠️  resolvectl 仍无响应（但DNS配置已通过resolved.conf生效）${gl_bai}"
                fi
            else
                echo -e "${gl_huang}  ⚠️  D-Bus 接口注册可能失败${gl_bai}"
                echo -e "${gl_lv}  ✅ 但DNS配置已通过 /etc/systemd/resolved.conf 生效${gl_bai}"
            fi
        else
            echo -e "${gl_huang}  ⚠️  busctl 命令不可用，无法验证 D-Bus 状态${gl_bai}"
            echo -e "${gl_lv}  ✅ 但DNS配置已通过 /etc/systemd/resolved.conf 生效${gl_bai}"
        fi
        
        echo ""
    fi

    echo ""

    # ==================== 阶段四：配置网卡DNS ====================
    echo -e "${gl_kjlan}[阶段 4/5] 配置网卡DNS（立即生效）...${gl_bai}"
    echo ""
    
    # 🔥 强力保障：阶段4执行前二次验证resolvectl（确保100%成功）
    echo "  → 验证 resolvectl 命令状态..."
    local resolvectl_ready=true
    
    # 快速测试resolvectl是否响应（2秒超时）
    if ! timeout 2 resolvectl status >/dev/null 2>&1; then
        echo -e "${gl_huang}  ⚠️  resolvectl 仍无响应${gl_bai}"
        echo ""
        echo -e "${gl_huang}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_huang}检测到 resolvectl 命令无法正常工作${gl_bai}"
        echo -e "${gl_huang}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        echo "这可能导致阶段4的网卡级DNS配置失败。"
        echo ""
        echo "你可以选择："
        echo "  1) 尝试强制修复（会重启systemd-resolved，有临时DNS保护）"
        echo "  2) 跳过网卡配置（安全，全局DNS已生效，推荐）"
        echo ""
        if [ "$AUTO_MODE" = "1" ]; then
            force_fix_choice=2
        else
            read -e -p "$(echo -e "${gl_huang}请选择 (1/2，默认2): ${gl_bai}")" force_fix_choice
            force_fix_choice=${force_fix_choice:-2}
        fi
        
        if [[ "$force_fix_choice" == "1" ]]; then
            echo ""
            echo -e "${gl_kjlan}正在执行强制修复...${gl_bai}"
            resolvectl_ready=false
            
            # 强制修复：重启systemd-resolved重新注册D-Bus
            echo "  → 创建临时DNS保护..."
            
            # 创建临时DNS保护
            cat > /etc/resolv.conf.stage4_temp << STAGE4_TEMP
nameserver $(plain_dns_ip "$INTERFACE_DNS_PRIMARY")
nameserver $(plain_dns_ip "$INTERFACE_DNS_SECONDARY")
STAGE4_TEMP
            cp /etc/resolv.conf /etc/resolv.conf.stage4_backup 2>/dev/null || true
            cp /etc/resolv.conf.stage4_temp /etc/resolv.conf
            
            echo "  → 强制重启 systemd-resolved..."
            # 完全重启服务
            systemctl stop systemd-resolved 2>/dev/null || true
            sleep 2
            systemctl start systemd-resolved 2>/dev/null || true
            sleep 3
            
            # 恢复链接
            echo "  → 恢复 resolv.conf 链接..."
            if [[ -f /run/systemd/resolve/stub-resolv.conf ]]; then
                rm -f /etc/resolv.conf
                ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
            fi
            
            # 清理临时文件
            rm -f /etc/resolv.conf.stage4_temp /etc/resolv.conf.stage4_backup
            
            # 再次验证
            echo "  → 验证修复结果..."
            if timeout 2 resolvectl status >/dev/null 2>&1; then
                echo -e "${gl_lv}  ✅ resolvectl 已修复，可以继续${gl_bai}"
                resolvectl_ready=true
            else
                echo -e "${gl_huang}  ⚠️  resolvectl 仍无法正常工作${gl_bai}"
                echo -e "${gl_lv}  ✅ 将跳过网卡级DNS配置（全局DNS已生效）${gl_bai}"
                resolvectl_ready=false
            fi
            echo ""
        else
            echo ""
            echo -e "${gl_lv}已选择跳过强制修复（安全选择）${gl_bai}"
            echo -e "${gl_lv}将跳过网卡级DNS配置，全局DNS配置已生效${gl_bai}"
            resolvectl_ready=false
            echo ""
        fi
    else
        echo -e "${gl_lv}  ✅ resolvectl 响应正常${gl_bai}"
    fi
    
    echo ""

    # 检测主网卡
    local main_interface=$(ip route | grep '^default' | awk '{print $5}' | head -n1)

    if [[ -n "$main_interface" ]] && command -v resolvectl &> /dev/null && [ "$resolvectl_ready" = true ]; then
        echo "  → 检测到主网卡: ${main_interface}"
        
        # 🛡️ 关键修复：检查timeout命令是否可用
        if ! command -v timeout &> /dev/null; then
            echo -e "${gl_huang}  ⚠️  timeout命令不可用，跳过网卡级DNS配置${gl_bai}"
            echo -e "${gl_lv}  ✅ DNS配置已通过 /etc/systemd/resolved.conf 生效${gl_bai}"
        else
            echo "  → 配置网卡 DNS（立即生效，无需重启）..."
            echo ""
            
            # 🛡️ 修复：添加超时机制防止resolvectl命令hang住
            local resolvectl_timeout=5  # 5秒超时
            local dns_config_success=true
            
            echo "    正在应用DNS服务器配置..."
            if timeout "$resolvectl_timeout" resolvectl dns "$main_interface" "$INTERFACE_DNS_PRIMARY" "$INTERFACE_DNS_SECONDARY" 2>/dev/null; then
                echo -e "    ${gl_lv}✅ DNS服务器配置成功${gl_bai}"
            else
                echo -e "    ${gl_huang}⚠️  DNS服务器配置超时或失败（配置已通过resolved.conf生效）${gl_bai}"
                dns_config_success=false
            fi
            
            echo "    正在应用DNS域配置..."
            if timeout "$resolvectl_timeout" resolvectl domain "$main_interface" ~. 2>/dev/null; then
                echo -e "    ${gl_lv}✅ DNS域配置成功${gl_bai}"
            else
                echo -e "    ${gl_huang}⚠️  DNS域配置超时或失败（配置已通过resolved.conf生效）${gl_bai}"
                dns_config_success=false
            fi
            
            echo "    正在应用默认路由配置..."
            if timeout "$resolvectl_timeout" resolvectl default-route "$main_interface" yes 2>/dev/null; then
                echo -e "    ${gl_lv}✅ 默认路由配置成功${gl_bai}"
            else
                echo -e "    ${gl_huang}⚠️  默认路由配置超时或失败（配置已通过resolved.conf生效）${gl_bai}"
                dns_config_success=false
            fi
            
            echo ""
            if [ "$dns_config_success" = true ]; then
                echo -e "${gl_lv}  ✅ 网卡DNS配置已全部应用${gl_bai}"
            else
                echo -e "${gl_huang}  ⚠️  部分网卡DNS配置未能通过resolvectl应用${gl_bai}"
                echo -e "${gl_lv}  ✅ 但DNS配置已通过 /etc/systemd/resolved.conf 生效${gl_bai}"
            fi
        fi
        echo -e "${gl_lv}  ✅ DNS配置立即生效，无需重启${gl_bai}"
    else
        if [[ -z "$main_interface" ]]; then
            echo -e "${gl_huang}  ⚠️  未检测到默认网卡${gl_bai}"
        else
            echo -e "${gl_huang}  ⚠️  resolvectl 命令不可用${gl_bai}"
        fi
        echo -e "${gl_lv}  ✅ DNS配置已通过 /etc/systemd/resolved.conf 生效${gl_bai}"
    fi

    # ==================== 阶段4.5：持久化前健康检查 ====================
    echo ""
    echo -e "${gl_kjlan}[阶段 4.5/5] 持久化前DNS健康检查...${gl_bai}"
    echo ""
    local precheck_dns_ok=false
    if [[ "$dns_mode_choice" == "2" ]]; then
        if dns_runtime_health_check "cn"; then
            precheck_dns_ok=true
        fi
    else
        if dns_runtime_health_check "global"; then
            precheck_dns_ok=true
        fi
    fi

    # strict 模式下绝不自动降级：解析失败立即回滚并退出
    if [ "$precheck_dns_ok" = false ] && [ "$DNS_OVER_TLS" = "yes" ]; then
        echo -e "${gl_hong}❌ strict DoT 健康检查失败，按严格策略中止并回滚（不降级）${gl_bai}"
        auto_rollback_dns_purify
        break_end
        return 1
    fi

    if [ "$precheck_dns_ok" = false ]; then
        echo -e "${gl_hong}❌ 持久化前DNS健康检查失败，正在自动回滚本次配置${gl_bai}"
        auto_rollback_dns_purify
        echo -e "${gl_huang}已自动回滚，请检查机房网络对上游DNS/DoT(853)连通性后重试${gl_bai}"
        break_end
        return 1
    else
        echo -e "${gl_lv}✅ 持久化前DNS健康检查通过${gl_bai}"
    fi

    # ==================== 阶段五：配置重启持久化 ====================
    echo ""
    echo -e "${gl_kjlan}[阶段 5/5] 配置重启持久化（确保重启后DNS不失效）...${gl_bai}"
    echo ""

    # --- 5a: 创建开机自动恢复脚本 ---
    echo "  → 创建DNS持久化恢复脚本..."
    cat > /usr/local/bin/dns-purify-apply.sh << 'PERSIST_SCRIPT_HEAD'
#!/bin/bash
# DNS净化持久化脚本 - 开机自动恢复网卡级DNS配置
# 由 net-tcp-tune.sh DNS净化功能自动生成
# 安全说明：仅重新应用 resolvectl 运行时配置，不修改网络服务

PERSIST_SCRIPT_HEAD

    # 写入用户选择的DNS（动态替换变量）
    cat >> /usr/local/bin/dns-purify-apply.sh << PERSIST_SCRIPT_VARS
DNS_PRIMARY="${INTERFACE_DNS_PRIMARY}"
DNS_SECONDARY="${INTERFACE_DNS_SECONDARY}"
PERSIST_SCRIPT_VARS

    cat >> /usr/local/bin/dns-purify-apply.sh << 'PERSIST_SCRIPT_BODY'

# 前置检查：resolvectl 是否可用
if ! command -v resolvectl >/dev/null 2>&1; then
    echo "dns-purify: resolvectl 不可用，跳过" | systemd-cat -t dns-purify 2>/dev/null || true
    exit 0
fi

# 检测默认网卡（动态获取，适应网卡名变更）
IFACE=$(ip route | grep '^default' | awk '{print $5}' | head -n1)

if [ -z "$IFACE" ]; then
    echo "dns-purify: 未检测到默认网卡，跳过" | systemd-cat -t dns-purify 2>/dev/null || true
    exit 0
fi

# 等待 systemd-resolved 完全就绪（最多等30秒）
for i in $(seq 1 15); do
    if resolvectl status >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

# 应用网卡级DNS配置
resolvectl dns "$IFACE" "$DNS_PRIMARY" "$DNS_SECONDARY" 2>/dev/null
resolvectl domain "$IFACE" "~." 2>/dev/null
resolvectl default-route "$IFACE" yes 2>/dev/null

# 验证DNS可用性
sleep 2
if getent hosts google.com >/dev/null 2>&1 || getent hosts baidu.com >/dev/null 2>&1; then
    echo "dns-purify: DNS配置恢复成功 (接口: $IFACE, DNS: $DNS_PRIMARY $DNS_SECONDARY)" | systemd-cat -t dns-purify 2>/dev/null || true
else
    echo "dns-purify: DNS验证未通过，但配置已应用 (接口: $IFACE)" | systemd-cat -t dns-purify 2>/dev/null || true
fi
PERSIST_SCRIPT_BODY

    chmod +x /usr/local/bin/dns-purify-apply.sh
    echo -e "${gl_lv}  ✅ 持久化脚本已创建: /usr/local/bin/dns-purify-apply.sh${gl_bai}"

    # --- 5b: 创建 systemd 开机服务 ---
    echo "  → 创建开机自启服务..."
    cat > /etc/systemd/system/dns-purify-persist.service << 'PERSIST_SERVICE'
[Unit]
Description=DNS Purify - Restore DNS Configuration on Boot
Documentation=https://github.com/Eric86777/vps-tcp-tune
After=systemd-resolved.service network-online.target
Wants=network-online.target
Wants=systemd-resolved.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/dns-purify-apply.sh
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
PERSIST_SERVICE

    systemctl daemon-reload
    systemctl enable dns-purify-persist.service >/dev/null 2>&1
    echo -e "${gl_lv}  ✅ 开机自启服务已创建并启用: dns-purify-persist.service${gl_bai}"

    # --- 5c: 阻止 systemd-networkd DHCP 覆盖DNS（最常见的重启失效原因）---
    if systemctl is-active --quiet systemd-networkd 2>/dev/null; then
        echo "  → 检测到 systemd-networkd，配置 DHCP DNS 阻断..."

        # 查找当前网卡对应的 .network 配置文件
        local networkd_file=""
        if command -v networkctl &>/dev/null; then
            networkd_file=$(networkctl status "$main_interface" 2>/dev/null | sed -nE 's/.*Network File:[[:space:]]*(.*)/\1/p' | head -1)
        fi

        if [[ -n "$networkd_file" ]] && [[ -f "$networkd_file" ]]; then
            # 安全方式：创建 drop-in 覆盖，不修改原文件
            local dropin_dir="${networkd_file}.d"
            mkdir -p "$dropin_dir"
            cat > "$dropin_dir/dns-purify-override.conf" << 'NETWORKD_DROPIN'
# DNS净化脚本 - 阻止DHCP覆盖DNS配置
# 仅禁用DHCP下发的DNS，不影响IP地址等其他DHCP功能
[DHCP]
UseDNS=false
UseDomains=false
NETWORKD_DROPIN
            echo -e "${gl_lv}  ✅ systemd-networkd DHCP DNS 阻断已配置（drop-in: ${dropin_dir}/）${gl_bai}"
            echo -e "${gl_lv}     仅阻止DNS覆盖，不影响IP/网关等DHCP功能${gl_bai}"
        else
            # 没找到现有配置文件，创建通用的 drop-in 目录
            echo -e "${gl_huang}  ⚠️  未找到 ${main_interface} 的 .network 文件${gl_bai}"
            echo -e "${gl_lv}  ✅ 已通过开机服务保障重启后DNS恢复${gl_bai}"
        fi
    else
        echo -e "${gl_lv}  ✅ 未使用 systemd-networkd（无需额外配置）${gl_bai}"
    fi

    # --- 5d: 处理 NetworkManager（如果存在）---
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        echo "  → 检测到 NetworkManager，配置DNS保护..."
        mkdir -p /etc/NetworkManager/conf.d
        cat > /etc/NetworkManager/conf.d/99-dns-purify.conf << 'NM_CONF'
# DNS净化脚本 - 让 NetworkManager 使用 systemd-resolved
# 不直接管理 /etc/resolv.conf，交给 systemd-resolved
[main]
dns=systemd-resolved
NM_CONF
        echo -e "${gl_lv}  ✅ NetworkManager 已配置为使用 systemd-resolved${gl_bai}"
    fi

    echo ""
    echo -e "${gl_lv}  ✅ 重启持久化配置完成，重启后DNS不会失效${gl_bai}"

    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_lv}✅ DNS净化完成！${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    # 显示当前DNS状态
    echo -e "${gl_huang}当前DNS配置：${gl_bai}"
    echo "────────────────────────────────────────────────────────"
    if command -v resolvectl &> /dev/null; then
        resolvectl status 2>/dev/null | head -30 || cat /etc/resolv.conf
    else
        cat /etc/resolv.conf
    fi
    echo "────────────────────────────────────────────────────────"
    
    # ==================== 统一验证输出（兼容所有systemd版本）====================
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}[智能验证] 网卡DNS配置状态检测：${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    
    if command -v resolvectl &> /dev/null && [[ -n "$main_interface" ]]; then
        local verify_output=$(resolvectl status "$main_interface" 2>/dev/null || echo "")
        local verify_success=true
        
        # 检测1: Default Route（兼容不同systemd版本）
        if echo "$verify_output" | grep -q "Default Route: yes" || \
           echo "$verify_output" | grep -q "Protocols:.*+DefaultRoute"; then
            echo -e "  ${gl_lv}✅ Default Route: 已启用${gl_bai}"
        else
            echo -e "  ${gl_huang}⚠️  Default Route: 未启用或不支持${gl_bai}"
            verify_success=false
        fi
        
        # 检测2: DNS Servers（根据用户选择的模式动态验证）
        local escaped_dns_primary=$(echo "$INTERFACE_DNS_PRIMARY" | sed 's/\./\\./g')
        local escaped_dns_secondary=$(echo "$INTERFACE_DNS_SECONDARY" | sed 's/\./\\./g')
        if echo "$verify_output" | grep -q "DNS Servers:.*${escaped_dns_primary}" && \
           echo "$verify_output" | grep -q "DNS Servers:.*${escaped_dns_secondary}"; then
            echo -e "  ${gl_lv}✅ DNS Servers: ${INTERFACE_DNS_PRIMARY}, ${INTERFACE_DNS_SECONDARY}${gl_bai}"
        else
            echo -e "  ${gl_huang}⚠️  DNS Servers: 配置可能未完全生效${gl_bai}"
            verify_success=false
        fi
        
        # 检测3: DNS Domain
        if echo "$verify_output" | grep -q "DNS Domain:.*~\."; then
            echo -e "  ${gl_lv}✅ DNS Domain: ~. (所有域名)${gl_bai}"
        else
            echo -e "  ${gl_huang}⚠️  DNS Domain: 未配置${gl_bai}"
            verify_success=false
        fi
        
        echo ""
        
        # 最终判断
        if [ "$verify_success" = true ]; then
            echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
            echo -e "${gl_lv}💯 最终判断: 网卡DNS配置 100% 成功！${gl_bai}"
            echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        else
            echo -e "${gl_huang}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
            echo -e "${gl_huang}⚠️  网卡DNS配置部分未生效${gl_bai}"
            echo -e "${gl_lv}✅ 但全局DNS配置已生效，DNS解析正常工作${gl_bai}"
            echo -e "${gl_huang}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        fi
    else
        echo -e "${gl_huang}  ⚠️  resolvectl 不可用或未检测到网卡${gl_bai}"
        echo -e "${gl_lv}  ✅ 全局DNS配置已生效${gl_bai}"
        echo ""
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    fi
    
    echo ""

    # 测试DNS解析（等待配置生效）
    echo -e "${gl_huang}测试DNS解析：${gl_bai}"
    echo "  → 等待DNS配置生效（3秒）..."
    sleep 3
    
    local dns_test_passed=false
    if [[ "$dns_mode_choice" == "2" ]]; then
        if dns_runtime_health_check "cn"; then
            echo -e "${gl_lv}  ✅ DNS解析正常（国内链路）${gl_bai}"
            dns_test_passed=true
        fi
    else
        if dns_runtime_health_check "global"; then
            echo -e "${gl_lv}  ✅ DNS解析正常（国际链路）${gl_bai}"
            dns_test_passed=true
        fi
    fi
    
    # 如果所有测试都失败
    if [ "$dns_test_passed" = false ]; then
        echo -e "${gl_hong}  ❌ DNS测试未通过，触发自动回滚以避免遗留隐患${gl_bai}"
        auto_rollback_dns_purify
        # 回滚后再次校验，确保脚本退出时机器仍可解析
        local post_rollback_ok=false
        if dns_runtime_health_check "global" || dns_runtime_health_check "cn"; then
            post_rollback_ok=true
        fi
        if [ "$post_rollback_ok" = true ]; then
            echo -e "${gl_lv}  ✅ 回滚后DNS健康校验通过${gl_bai}"
        else
            echo -e "${gl_huang}  ⚠️  回滚后DNS仍异常，请检查上游网络/防火墙策略${gl_bai}"
        fi
        echo -e "${gl_huang}  已自动恢复执行前配置，请检查网络环境后重试${gl_bai}"
        break_end
        return 1
    fi
    echo ""

    # ==================== 生成回滚脚本 ====================
    cat > "$BACKUP_DIR/rollback.sh" << 'ROLLBACK_SCRIPT'
#!/bin/bash
# DNS配置回滚脚本
# 使用方法: bash rollback.sh

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  DNS配置回滚脚本"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

BACKUP_DIR="$(dirname "$0")"
PRE_STATE_DIR="$BACKUP_DIR/pre_state"

# 优先使用增强回滚（精确恢复执行前状态）
if [[ -d "$PRE_STATE_DIR" ]]; then
    echo "检测到增强备份元数据，正在精确恢复执行前状态..."

    restore_path_state() {
        local dst="$1"
        local key="$2"
        rm -f "$dst" 2>/dev/null || true
        if [[ -e "$PRE_STATE_DIR/$key" || -L "$PRE_STATE_DIR/$key" ]]; then
            mkdir -p "$(dirname "$dst")"
            cp -a "$PRE_STATE_DIR/$key" "$dst" 2>/dev/null || true
        elif [[ -f "$PRE_STATE_DIR/$key.absent" ]]; then
            rm -f "$dst" 2>/dev/null || true
        fi
    }

    # 恢复配置文件（resolv.conf 延后，避免悬空链接）
    restore_path_state "/etc/dhcp/dhclient.conf" "dhclient.conf"
    restore_path_state "/etc/network/interfaces" "interfaces"
    restore_path_state "/etc/systemd/resolved.conf" "resolved.conf"
    restore_path_state "/etc/systemd/system/dns-purify-persist.service" "dns-purify-persist.service"
    restore_path_state "/usr/local/bin/dns-purify-apply.sh" "dns-purify-apply.sh"
    restore_path_state "/etc/systemd/system/systemd-resolved.service.d/dbus-fix.conf" "dbus-fix.conf"
    restore_path_state "/etc/NetworkManager/conf.d/99-dns-purify.conf" "nm-99-dns-purify.conf"

    if [[ -f "$PRE_STATE_DIR/ifup-resolved.exec" ]]; then
        case "$(cat "$PRE_STATE_DIR/ifup-resolved.exec" 2>/dev/null)" in
            executable)
                [[ -e /etc/network/if-up.d/resolved ]] && chmod +x /etc/network/if-up.d/resolved 2>/dev/null || true
                ;;
            not_executable)
                [[ -e /etc/network/if-up.d/resolved ]] && chmod -x /etc/network/if-up.d/resolved 2>/dev/null || true
                ;;
            absent)
                rm -f /etc/network/if-up.d/resolved 2>/dev/null || true
                ;;
        esac
    fi

    # 移除 networkd drop-in（扩展搜索所有可能路径）
    for search_dir in /etc/systemd/network /run/systemd/network /usr/lib/systemd/network; do
        for dropin_file in "$search_dir"/*.network.d/dns-purify-override.conf; do
            [[ -f "$dropin_file" ]] || continue
            rm -f "$dropin_file"
            rmdir "$(dirname "$dropin_file")" 2>/dev/null || true
        done
    done

    if [[ -f "$PRE_STATE_DIR/networkd-dropins.map" ]]; then
        while IFS='|' read -r restore_path restore_key; do
            [[ -n "$restore_path" && -n "$restore_key" ]] || continue
            [[ -f "$PRE_STATE_DIR/$restore_key" ]] || continue
            mkdir -p "$(dirname "$restore_path")"
            cp -a "$PRE_STATE_DIR/$restore_key" "$restore_path" 2>/dev/null || true
        done < "$PRE_STATE_DIR/networkd-dropins.map"
    fi

    # 重载 networkd/NM 使配置变更生效
    if systemctl is-active --quiet systemd-networkd 2>/dev/null; then
        networkctl reload 2>/dev/null || systemctl reload systemd-networkd 2>/dev/null || true
    fi
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        systemctl reload NetworkManager 2>/dev/null || true
    fi

    systemctl daemon-reload 2>/dev/null || true

    dns_persist_was_enabled="false"
    [[ -f "$PRE_STATE_DIR/dns-persist.was-enabled" ]] && dns_persist_was_enabled=$(cat "$PRE_STATE_DIR/dns-persist.was-enabled" 2>/dev/null || echo "false")

    if [[ -e "$PRE_STATE_DIR/dns-purify-persist.service" || -L "$PRE_STATE_DIR/dns-purify-persist.service" ]]; then
        if [[ "$dns_persist_was_enabled" == "true" ]]; then
            systemctl enable dns-purify-persist.service 2>/dev/null || true
        else
            systemctl disable dns-purify-persist.service 2>/dev/null || true
        fi
    else
        systemctl disable dns-purify-persist.service 2>/dev/null || true
    fi

    had_resolvconf_pkg="false"
    [[ -f "$PRE_STATE_DIR/had-resolvconf.pkg" ]] && had_resolvconf_pkg=$(cat "$PRE_STATE_DIR/had-resolvconf.pkg" 2>/dev/null || echo "false")
    if [[ "$had_resolvconf_pkg" == "true" ]] && ! dpkg -s resolvconf >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y resolvconf >/dev/null 2>&1 || true
    fi

    # 先恢复 resolved 服务状态（在 resolv.conf 之前，避免悬空链接）
    resolved_enable_state="unknown"
    resolved_was_masked="false"
    resolved_was_active="false"
    [[ -f "$PRE_STATE_DIR/resolved.enable-state" ]] && resolved_enable_state=$(cat "$PRE_STATE_DIR/resolved.enable-state" 2>/dev/null || echo "unknown")
    # 兼容旧版快照
    if [[ "$resolved_enable_state" == "unknown" && -f "$PRE_STATE_DIR/resolved.was-enabled" ]]; then
        old_enabled=$(cat "$PRE_STATE_DIR/resolved.was-enabled" 2>/dev/null || echo "false")
        [[ "$old_enabled" == "true" ]] && resolved_enable_state="enabled" || resolved_enable_state="disabled"
    fi
    [[ -f "$PRE_STATE_DIR/resolved.was-masked" ]] && resolved_was_masked=$(cat "$PRE_STATE_DIR/resolved.was-masked" 2>/dev/null || echo "false")
    [[ -f "$PRE_STATE_DIR/resolved.was-active" ]] && resolved_was_active=$(cat "$PRE_STATE_DIR/resolved.was-active" 2>/dev/null || echo "false")

    if [[ "$resolved_was_masked" == "true" ]]; then
        systemctl mask systemd-resolved 2>/dev/null || true
        systemctl stop systemd-resolved 2>/dev/null || true
    else
        systemctl unmask systemd-resolved 2>/dev/null || true
        case "$resolved_enable_state" in
            enabled|enabled-runtime)
                systemctl enable systemd-resolved 2>/dev/null || true
                ;;
            static|indirect|generated)
                ;;
            *)
                systemctl disable systemd-resolved 2>/dev/null || true
                ;;
        esac

        if [[ "$resolved_was_active" == "true" ]]; then
            systemctl restart systemd-resolved 2>/dev/null || systemctl start systemd-resolved 2>/dev/null || true
            # 等待 stub 文件可用
            for wait_i in $(seq 1 5); do
                [[ -f /run/systemd/resolve/stub-resolv.conf ]] && break
                sleep 1
            done
        else
            systemctl stop systemd-resolved 2>/dev/null || true
        fi
    fi

    # 最后恢复 resolv.conf（此时 resolved 已恢复，stub 文件可用）
    if [[ -L "$PRE_STATE_DIR/resolv.conf" ]]; then
        backup_link=$(readlink "$PRE_STATE_DIR/resolv.conf" 2>/dev/null || echo "")
        if [[ "$backup_link" == *"stub-resolv.conf"* ]] && [[ ! -f /run/systemd/resolve/stub-resolv.conf ]]; then
            rm -f /etc/resolv.conf 2>/dev/null || true
            echo "nameserver 127.0.0.53" > /etc/resolv.conf 2>/dev/null || true
        else
            restore_path_state "/etc/resolv.conf" "resolv.conf"
        fi
    else
        restore_path_state "/etc/resolv.conf" "resolv.conf"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ 回滚完成（增强模式）！"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    exit 0
fi

# ===== 旧版回滚（无 pre_state 目录时的兼容模式）=====

# 恢复 dhclient.conf
if [[ -f "$BACKUP_DIR/dhclient.conf.bak" ]]; then
    echo "恢复 dhclient.conf..."
    cp "$BACKUP_DIR/dhclient.conf.bak" /etc/dhcp/dhclient.conf
    echo "✅ 已恢复 dhclient.conf"
fi

# 恢复 interfaces
if [[ -f "$BACKUP_DIR/interfaces.bak" ]]; then
    echo "恢复 interfaces..."
    cp "$BACKUP_DIR/interfaces.bak" /etc/network/interfaces
    echo "✅ 已恢复 interfaces"
fi

# 恢复 resolved.conf
if [[ -f "$BACKUP_DIR/resolved.conf.bak" ]]; then
    echo "恢复 resolved.conf..."
    cp "$BACKUP_DIR/resolved.conf.bak" /etc/systemd/resolved.conf
    echo "✅ 已恢复 resolved.conf"
fi

# 移除DNS持久化服务
if [[ -f /etc/systemd/system/dns-purify-persist.service ]]; then
    echo "移除 DNS持久化服务..."
    systemctl disable dns-purify-persist.service 2>/dev/null || true
    rm -f /etc/systemd/system/dns-purify-persist.service
    echo "✅ 已移除 dns-purify-persist.service"
fi

# 移除DNS持久化脚本
if [[ -f /usr/local/bin/dns-purify-apply.sh ]]; then
    rm -f /usr/local/bin/dns-purify-apply.sh
    echo "✅ 已移除 dns-purify-apply.sh"
fi

# 移除 D-Bus 修复配置（仅删除本脚本创建的文件，不删整个目录）
if [[ -f /etc/systemd/system/systemd-resolved.service.d/dbus-fix.conf ]]; then
    rm -f /etc/systemd/system/systemd-resolved.service.d/dbus-fix.conf
    rmdir /etc/systemd/system/systemd-resolved.service.d 2>/dev/null || true
    echo "✅ 已移除 D-Bus 修复配置"
fi

# 移除 systemd-networkd DNS阻断 drop-in（扩展搜索路径）
for search_dir in /etc/systemd/network /run/systemd/network /usr/lib/systemd/network; do
    for dropin_dir in "$search_dir"/*.network.d; do
        if [[ -f "$dropin_dir/dns-purify-override.conf" ]]; then
            rm -f "$dropin_dir/dns-purify-override.conf"
            rmdir "$dropin_dir" 2>/dev/null || true
            echo "✅ 已移除 systemd-networkd DNS阻断配置"
        fi
    done
done

# 移除 NetworkManager DNS配置
if [[ -f /etc/NetworkManager/conf.d/99-dns-purify.conf ]]; then
    rm -f /etc/NetworkManager/conf.d/99-dns-purify.conf
    echo "✅ 已移除 NetworkManager DNS配置"
fi

# 恢复 if-up.d/resolved 可执行权限
if [[ -f /etc/network/if-up.d/resolved ]] && [[ ! -x /etc/network/if-up.d/resolved ]]; then
    echo "恢复 if-up.d/resolved 可执行权限..."
    chmod +x /etc/network/if-up.d/resolved
    echo "✅ 已恢复 if-up.d/resolved 可执行权限"
fi

# 重新加载 systemd
systemctl daemon-reload 2>/dev/null || true

# 重载 networkd/NM
if systemctl is-active --quiet systemd-networkd 2>/dev/null; then
    networkctl reload 2>/dev/null || systemctl reload systemd-networkd 2>/dev/null || true
fi
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    systemctl reload NetworkManager 2>/dev/null || true
fi

# 重新加载 systemd-resolved
echo "重新加载 systemd-resolved..."
systemctl reload-or-restart systemd-resolved 2>/dev/null || true
echo "✅ systemd-resolved 已重新加载"

# 恢复 resolv.conf（在 resolved 重启之后，保留软链接特性）
if [[ -f "$BACKUP_DIR/resolv.conf.bak" ]]; then
    echo "恢复 resolv.conf..."
    rm -f /etc/resolv.conf
    cp -a "$BACKUP_DIR/resolv.conf.bak" /etc/resolv.conf
    echo "✅ 已恢复 resolv.conf"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ 回滚完成！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ROLLBACK_SCRIPT

    chmod +x "$BACKUP_DIR/rollback.sh"

    # 显示备份信息
    echo -e "${gl_kjlan}备份与回滚信息：${gl_bai}"
    echo "  所有原始配置已备份到："
    echo "  $BACKUP_DIR"
    echo ""
    echo -e "${gl_huang}如需回滚，执行：${gl_bai}"
    echo "  bash $BACKUP_DIR/rollback.sh"
    echo ""

    echo -e "${gl_lv}DNS净化脚本执行完成${gl_bai}"
    echo "原作者：NSdesk"
    echo "安全增强：SSH防断连优化"
    echo "更多信息：https://www.nodeseek.com/space/23129#/general"
    echo "════════════════════════════════════════════════════════"
    echo ""

    break_end
}

update_xanmod_kernel() {
    echo -e "${gl_kjlan}=== 更新 XanMod 内核 ===${gl_bai}"
    echo "------------------------------------------------"
    
    # 获取当前内核版本
    local current_kernel=$(uname -r)
    echo -e "当前内核版本: ${gl_huang}${current_kernel}${gl_bai}"
    echo ""
    
    # 检测 CPU 架构
    local cpu_arch=$(uname -m)
    
    # ARM 架构提示：XanMod 无 ARM64 构建，此处不存在可更新的内核
    if [ "$cpu_arch" = "aarch64" ]; then
        echo -e "${gl_huang}ARM64 平台无 XanMod 内核可更新${gl_bai}"
        echo "BBR v3 未合入主线内核，XanMod 官方仅提供 x86-64 构建。"
        echo -e "ARM 机器请使用【${gl_lv}BBR 直连/落地优化${gl_bai}】做网络调优。"
        break_end
        return 1
    fi
    
    # x86_64 架构更新流程
    echo "正在检查可用更新..."
    
    local xanmod_repo_file="/etc/apt/sources.list.d/xanmod-release.list"

    # 添加/修正 XanMod 仓库（旧 releases suite 已为空）
    if [ ! -f "$xanmod_repo_file" ] || grep -qE 'deb\.xanmod\.org[[:space:]]+releases[[:space:]]+' "$xanmod_repo_file" 2>/dev/null; then
        echo "正在添加 XanMod 仓库..."

        # 添加密钥（分步执行，避免管道 $? 问题）
        local gpg_key_file="/usr/share/keyrings/xanmod-archive-keyring.gpg"
        local key_tmp=$(mktemp)
        local gpg_ok=false

        if wget -qO "$key_tmp" "${gh_proxy}raw.githubusercontent.com/kejilion/sh/main/archive.key" 2>/dev/null && \
           [ -s "$key_tmp" ]; then
            if gpg --dearmor -o "$gpg_key_file" --yes < "$key_tmp" 2>/dev/null; then
                gpg_ok=true
            fi
        fi

        if [ "$gpg_ok" = false ]; then
            if wget -qO "$key_tmp" "https://dl.xanmod.org/archive.key" 2>/dev/null && \
               [ -s "$key_tmp" ]; then
                if gpg --dearmor -o "$gpg_key_file" --yes < "$key_tmp" 2>/dev/null; then
                    gpg_ok=true
                fi
            fi
        fi

        rm -f "$key_tmp"

        if [ "$gpg_ok" = false ]; then
            echo -e "${gl_hong}错误: GPG 密钥导入失败${gl_bai}"
            break_end
            return 1
        fi

        # 添加仓库（使用系统 codename；旧 releases suite 已为空）
        xanmod_write_repo "$gpg_key_file" "$xanmod_repo_file" || { break_end; return 1; }
    fi

    # 更新软件包列表
    echo "正在更新软件包列表..."
    if ! apt-get update > /dev/null 2>&1; then
        echo -e "${gl_huang}⚠️  apt-get update 部分失败，尝试继续...${gl_bai}"
    fi

    # 检查已安装的 XanMod 内核包（使用 ^ii 过滤，排除已卸载残留）
    local installed_packages=$(dpkg -l | grep -E '^ii\s+linux-.*xanmod' | awk '{print $2}')
    
    if [ -z "$installed_packages" ]; then
        echo -e "${gl_hong}错误: 未检测到已安装的 XanMod 内核${gl_bai}"
        break_end
        return 1
    fi
    
    echo -e "已安装的内核包:"
    echo "$installed_packages" | while read pkg; do
        echo "  - $pkg"
    done
    echo ""
    
    # 检查是否有可用更新
    local upgradable=$(apt list --upgradable 2>/dev/null | grep xanmod)
    
    if [ -z "$upgradable" ]; then
        local cpu_level
        cpu_level=$(echo "$installed_packages" | sed -nE 's/.*x64v([1-4]).*/\1/p' | head -1)
        [ -z "$cpu_level" ] && cpu_level="3"

        # 获取已安装的最新 XanMod 内核版本（从 linux-image 包名提取版本号并取最大值）
        local latest_installed
        latest_installed=$(echo "$installed_packages" \
            | sed -nE 's/^linux-image-([0-9]+\.[0-9]+\.[0-9]+-x64v[1-4]-xanmod[0-9]+)$/\1/p' \
            | sort -V | tail -1)

        local running_latest=0
        if [ -n "$latest_installed" ] && [ "$current_kernel" = "$latest_installed" ]; then
            running_latest=1
        fi

        if [ $running_latest -eq 1 ]; then
            echo -e "${gl_lv}✅ 当前运行内核已是最新版本！${gl_bai}"
        else
            echo -e "${gl_lv}✅ XanMod 内核包已是最新，但当前运行内核尚未切换！${gl_bai}"
            echo -e "  正在运行: ${gl_hong}${current_kernel}${gl_bai}"
            if [ -n "$latest_installed" ]; then
                echo -e "  最新已装: ${gl_lv}${latest_installed}${gl_bai}"
            else
                echo -e "  ${gl_huang}提示: 未能解析最新已装内核版本，请重启后再检查${gl_bai}"
            fi
            echo -e "  ${gl_huang}请重启系统 (reboot) 以切换到最新内核${gl_bai}"
        fi
        echo ""

        echo -e "${gl_kjlan}━━━━━━━━━━ CPU 架构信息 ━━━━━━━━━━${gl_bai}"
        echo -e "  CPU 架构等级: ${gl_lv}x86-64-v${cpu_level}${gl_bai}"
        echo -e "  当前运行内核: ${gl_lv}${current_kernel}${gl_bai}"
        if [ -n "$latest_installed" ] && [ $running_latest -ne 1 ]; then
            echo -e "  最新已装内核: ${gl_lv}${latest_installed}${gl_bai}"
        fi
        if [ $running_latest -eq 1 ]; then
            echo -e "  ${gl_huang}说明: 本机 CPU 最高支持 v${cpu_level}，当前已运行该等级最新内核${gl_bai}"
        else
            echo -e "  ${gl_huang}说明: 本机 CPU 最高支持 v${cpu_level}，最新内核已安装，重启后生效${gl_bai}"
        fi
        echo -e "  ${gl_huang}不同等级(v1-v4)的内核更新进度可能不同，以 XanMod 官方仓库为准${gl_bai}"
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"

        rm -f "$xanmod_repo_file"
        echo -e "${gl_lv}已自动清理 XanMod 软件源（如需更新可再次运行选项1）${gl_bai}"
        break_end
        return 0
    fi
    
    echo -e "${gl_huang}发现可用更新:${gl_bai}"
    echo "$upgradable"
    echo ""
    
    if [ "$AUTO_MODE" = "1" ]; then
        confirm=Y
    else
        read -e -p "确定更新 XanMod 内核吗？(Y/N): " confirm
    fi
    
    case "$confirm" in
        [Yy])
            echo ""
            echo "正在更新内核..."
            echo "$installed_packages" | xargs -r apt install --only-upgrade -y
            
            if [ $? -eq 0 ]; then
                echo ""
                echo -e "${gl_lv}✅ XanMod 内核更新成功！${gl_bai}"
                echo -e "${gl_huang}⚠️  请重启系统以加载新内核${gl_bai}"
                echo ""
                local cpu_level
                cpu_level=$(echo "$installed_packages" | sed -nE 's/.*x64v([1-4]).*/\1/p' | head -1)
                [ -z "$cpu_level" ] && cpu_level="3"
                local latest_installed
                latest_installed=$(dpkg -l 2>/dev/null | awk '/^ii\s+linux-image-[0-9].*xanmod/ {print $2}' | sed 's/^linux-image-//' | sort -V | tail -1)
                echo -e "${gl_kjlan}━━━━━━━━━━ CPU 架构信息 ━━━━━━━━━━${gl_bai}"
                echo -e "  CPU 架构等级: ${gl_lv}x86-64-v${cpu_level}${gl_bai}"
                if [ -n "$latest_installed" ]; then
                    echo -e "  最新已装内核: ${gl_lv}${latest_installed}${gl_bai}"
                else
                    echo -e "  已更新内核包: ${gl_lv}$(echo "$installed_packages" | head -1)${gl_bai}"
                fi
                echo -e "  ${gl_huang}说明: 本机 CPU 最高支持 v${cpu_level}，已更新至该等级的最新内核${gl_bai}"
                echo -e "  ${gl_huang}不同等级(v1-v4)的内核更新进度可能不同，以 XanMod 官方仓库为准${gl_bai}"
                echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
                echo ""
                echo -e "${gl_kjlan}后续更新: 再次运行选项1即可检查并安装最新内核${gl_bai}"

                rm -f "$xanmod_repo_file"
                echo -e "${gl_lv}已自动清理 XanMod 软件源（如需更新可再次运行选项1）${gl_bai}"
                return 0
            else
                echo ""
                echo -e "${gl_hong}❌ 内核更新失败${gl_bai}"
                break_end
                return 1
            fi
            ;;
        *)
            echo "已取消更新"
            break_end
            return 1
            ;;
    esac
}

optimize_hosts_file() {
    echo -e "${gl_kjlan}=== hosts 文件优化 ===${gl_bai}"

    local hosts_file="/etc/hosts"
    local backup_file="/etc/hosts.bak.original"
    local hostname_value
    local temp_file

    hostname_value=$(hostname 2>/dev/null | tr -d '\r\n')

    if [ ! -e "$hosts_file" ]; then
        touch "$hosts_file" || {
            echo -e "${gl_hong}错误: 无法创建 /etc/hosts${gl_bai}"
            return 1
        }
    fi

    if [ ! -f "$backup_file" ]; then
        cp -a "$hosts_file" "$backup_file" 2>/dev/null || true
    fi

    temp_file=$(mktemp /tmp/hosts.XXXXXX) || {
        echo -e "${gl_hong}错误: 无法创建临时文件${gl_bai}"
        return 1
    }

    awk '
        {
            sub(/\r$/, "")
        }
        /^[[:space:]]*$/ {
            if (!blank) print ""
            blank=1
            next
        }
        {
            blank=0
        }
        /^[[:space:]]*#/ {
            print
            next
        }
        !seen[$0]++ {
            print
        }
    ' "$hosts_file" > "$temp_file"

    if ! awk '
        $1 !~ /^#/ {
            for (i = 2; i <= NF; i++) {
                if ($i == "localhost") found=1
            }
        }
        END { exit !found }
    ' "$temp_file"; then
        printf '127.0.0.1\tlocalhost\n' >> "$temp_file"
    fi

    if [ -n "$hostname_value" ] && ! awk -v host="$hostname_value" '
        $1 !~ /^#/ {
            for (i = 2; i <= NF; i++) {
                if ($i == host) found=1
            }
        }
        END { exit !found }
    ' "$temp_file"; then
        printf '127.0.1.1\t%s\n' "$hostname_value" >> "$temp_file"
    fi

    if cat "$temp_file" > "$hosts_file"; then
        echo -e "${gl_lv}✅ hosts 文件优化完成${gl_bai}"
    else
        echo -e "${gl_hong}❌ hosts 文件写入失败${gl_bai}"
        rm -f "$temp_file"
        return 1
    fi

    rm -f "$temp_file"
}

run_personalized_tune() {
    AUTO_MODE=1

    check_bbr_status
    local is_installed=$?
    if [ $is_installed -eq 0 ]; then
        update_xanmod_kernel
    else
        install_xanmod_kernel
    fi

    bbr_configure_direct

    AUTO_MODE=""
    ONE_SHOT_MODE=1
    dns_purify_and_harden

    manage_ipv6
    ONE_SHOT_MODE=""

    optimize_hosts_file
}

main() {
    check_root
    run_personalized_tune
}

main "$@"
