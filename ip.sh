#!/bin/bash
#
# IP-Bandwidth-Limiter (Optimized - Include All IPs)
# 一键为每个连接的 IP 设置带宽限制
# 适用于运行 X-UI 和 Hysteria 2 的 Debian/Ubuntu 服务器
# 修改版：限制所有检测到的公共 IP 带宽
#

# --- 配置参数 (可编辑) ---
# 自动检测网卡名称
IFACE_DEFAULT=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'dev \K\S+' || ip link | grep -E '^[0-9]+: ' | grep -v 'lo:' | head -n1 | awk '{print $2}' | cut -d: -f1)
# 可选：手动指定网卡 (取消注释并替换)
# IFACE_DEFAULT="eth0"

RATE=${RATE:-"150mbit"}  # 每个 IP 的带宽限制 (e.g., 100mbit, 500kbit)
BURST=${BURST:-"15k"}    # 突发流量 (e.g., 15k)
LOG_FILE="/var/log/bandwidth-limit.log"
# EXCLUDED_IP is NOT used in this version
TIMER_INTERVAL="5" # 定时器运行频率（秒）

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# --- 脚本功能 ---

# 检查网卡
check_interface() {
    if [ -z "$IFACE_DEFAULT" ]; then
        echo -e "${RED}错误：${PLAIN}无法自动检测到有效的网络接口。"
        read -p "请输入您的主网络接口名称 (例如 eth0): " IFACE_MANUAL
        if [ -z "$IFACE_MANUAL" ] || ! ip link show "$IFACE_MANUAL" &>/dev/null; then
             echo -e "${RED}错误：${PLAIN}无效的接口名称。退出。"
             exit 1
        fi
        IFACE_DEFAULT=$IFACE_MANUAL
        echo -e "${YELLOW}信息：${PLAIN}将使用手动指定的接口: $IFACE_DEFAULT"
    else
         echo -e "${BLUE}信息：${PLAIN}自动检测到的网络接口: $IFACE_DEFAULT"
    fi
}

# 检查 root 权限
check_root() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}错误：${PLAIN}必须使用 root 用户运行此脚本！\n" && exit 1
}

# 检查操作系统
check_os() {
    if [[ -f /etc/debian_version ]]; then
        release="debian"
    elif [[ -f /etc/lsb-release || -f /etc/ubuntu-release ]]; then
        release="ubuntu"
    else
        echo -e "${RED}错误：${PLAIN}不支持的操作系统！仅支持 Debian/Ubuntu。\n" && exit 1
    fi
    echo -e "${BLUE}信息：${PLAIN}检测到的操作系统: $release"
}

# 检查并安装必要的软件包
check_install() {
    echo -e "${BLUE}[信息]${PLAIN} 检查并安装必要的软件包 (iproute2, vnstat)..."
    local missing_pkgs=""
    command -v tc &>/dev/null || missing_pkgs+=" iproute2"
    command -v ss &>/dev/null || missing_pkgs+=" iproute2" # ss is part of iproute2
    command -v vnstat &>/dev/null || missing_pkgs+=" vnstat" # vnstat is optional for monitoring script

    # Trim leading space
    missing_pkgs=$(echo "$missing_pkgs" | sed 's/^ *//')

    if [ -n "$missing_pkgs" ]; then
        echo -e "${YELLOW}警告：${PLAIN} 缺少软件包: $missing_pkgs. 正在尝试安装..."
        if command -v apt-get &>/dev/null; then
            apt-get update -y && apt-get install -y $missing_pkgs
        elif command -v apt &>/dev/null; then
            apt update -y && apt install -y $missing_pkgs
        else
            echo -e "${RED}[错误]${PLAIN} 未找到支持的包管理器 (apt/apt-get)。请手动安装: $missing_pkgs" && exit 1
        fi

        if [ $? -ne 0 ]; then
            echo -e "${RED}[错误]${PLAIN} 安装软件包失败。请检查网络或手动安装: $missing_pkgs"
            exit 1
        fi
        # Re-check after installation
         command -v tc &>/dev/null || { echo -e "${RED}[错误]${PLAIN} iproute2 (tc) 安装后仍未找到。"; exit 1; }
         command -v ss &>/dev/null || { echo -e "${RED}[错误]${PLAIN} iproute2 (ss) 安装后仍未找到。"; exit 1; }
         if [[ "$MONITOR_INSTALL" = "y" ]]; then
             command -v vnstat &>/dev/null || echo -e "${YELLOW}[警告]${PLAIN} vnstat 安装后仍未找到。监控脚本可能功能受限。"
         fi
    fi

    if command -v vnstat &>/dev/null; then
        systemctl enable vnstat &>/dev/null
        systemctl start vnstat &>/dev/null
    fi

    echo -e "${GREEN}[成功]${PLAIN} 所有必要的软件包已就绪。"
}

# 创建限速脚本
create_limiter_script() {
    echo -e "${BLUE}[信息]${PLAIN} 创建限速脚本..."
    mkdir -p /usr/local/scripts

    # Note: The inner script inherits IFACE_DEFAULT, RATE, BURST, LOG_FILE from the outer script context
    cat > /usr/local/scripts/ip-bandwidth-limiter.sh << EOF
#!/bin/bash
#
# IP-Bandwidth-Limiter (Worker Script - Limit All IPs)
# 为每个连接的 IP 设置带宽限制
#

# --- 配置 (从主脚本继承/设置) ---
IFACE="$IFACE_DEFAULT"
RATE="$RATE"
BURST="$BURST"
LOG_FILE="$LOG_FILE"
# EXCLUDED_IP is NOT used in this version

# --- 内部函数 ---
# 记录日志函数
log() {
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - \$1" >> \$LOG_FILE
}

# --- 主逻辑 ---
log "开始执行带宽限制 (限制所有检测到的IP), 网卡: \$IFACE, 速率: \$RATE"

# 检查网卡是否有效
if ! ip link show "\$IFACE" &>/dev/null; then
    log "错误：网卡 \$IFACE 不存在或无效。"
    exit 1
fi

# 清理旧规则并初始化 HTB qdisc
tc qdisc del dev \$IFACE root 2>/dev/null
tc qdisc add dev \$IFACE root handle 1: htb default 999 || {
    log "错误：创建根 tc qdisc 失败"
    exit 1
}
# 默认类，用于未匹配的流量 (速率设置较高，基本不限速)
tc class add dev \$IFACE parent 1: classid 1:999 htb rate 10000mbit || {
    log "错误：创建默认 tc class 失败"
    # 不退出，尝试继续
}

# 获取当前所有已建立连接的唯一公共 IP 地址 (TCP 和 UDP)
# 排除 SSH 端口 (22) 和私有/特殊 IP
TCP_IPS=\$(ss -tn state established '( dport != :22 )' | awk 'NR>1 {print \$4}' | cut -d: -f1)
UDP_IPS=\$(ss -un state established | awk 'NR>1 {print \$5}' | cut -d: -f1) # UDP 'established' state is less strict but useful for protocols like Hysteria

# Combine, filter, and sort unique IPs
CONNECTED_IPS=\$(echo -e "\$TCP_IPS\n\$UDP_IPS" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -vE '^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.|127\.|0\.0\.0\.0)' | sort -u)

# Filter IPv6 if needed (adjust regex as necessary)
# CONNECTED_IPV6=$(ss -t6n state established '( dport != :22 )' | awk 'NR>1 {print $4}' | sed -e 's/\[//' -e 's/\]:.*$//' | grep -vE '^(::1|fe80::|fc00::|fd00::|ff00::)' | sort -u)
# COMBINED_IPS="\${CONNECTED_IPS}\n\${CONNECTED_IPV6}"
# CONNECTED_IPS=\$(echo -e "\$COMBINED_IPS" | sort -u)

# log "检测到的 IP 列表: \$CONNECTED_IPS" # Debugging: uncomment to see all IPs

# 为检测到的 IP 创建限速类和过滤器
IP_COUNT=0
CLASS_NUM=10 # Starting class number to avoid conflicts (must be > 0)

for IP in \$CONNECTED_IPS; do
    # --- NO EXCLUSION CHECK IN THIS VERSION ---

    CLASS_ID="1:\$CLASS_NUM" # Format like 1:10, 1:11, ...

    # Add HTB class for this IP with the specified rate limit
    tc class add dev \$IFACE parent 1: classid \$CLASS_ID htb rate \$RATE burst \$BURST || {
        log "错误: 为 IP \$IP 创建 tc class \$CLASS_ID 失败"
        continue # Skip to next IP if class creation fails
    }

    # Add SFQ for fair queuing within the limited class
    tc qdisc add dev \$IFACE parent \$CLASS_ID handle \$CLASS_NUM: sfq perturb 10 || {
        log "警告: 为 IP \$IP (Class \$CLASS_ID) 创建 tc qdisc sfq \$CLASS_NUM: 失败"
        # Don't exit, limiting might still work without SFQ, just less fair
    }

    # Add filters to direct traffic FROM and TO this IP into its class
    # Priority 1 catches all IP traffic (TCP, UDP, ICMP etc.) for this IP
    tc filter add dev \$IFACE parent 1: protocol ip prio 1 u32 match ip dst \$IP/32 flowid \$CLASS_ID || log "错误: 为 IP \$IP 添加 dst 过滤器失败"
    tc filter add dev \$IFACE parent 1: protocol ip prio 1 u32 match ip src \$IP/32 flowid \$CLASS_ID || log "错误: 为 IP \$IP 添加 src 过滤器失败"

    IP_COUNT=\$((IP_COUNT + 1))
    CLASS_NUM=\$((CLASS_NUM + 1))
done

log "已为 \$IP_COUNT 个 IP 设置 \$RATE 限速"
EOF

    chmod +x /usr/local/scripts/ip-bandwidth-limiter.sh
    echo -e "${GREEN}[成功]${PLAIN} 限速脚本已创建: /usr/local/scripts/ip-bandwidth-limiter.sh"
}

# 创建监控脚本 (可选) - (Identical to Version 1)
create_monitor_script() {
    echo -e "${BLUE}[信息]${PLAIN} 创建监控脚本..."
    mkdir -p /usr/local/scripts

    cat > /usr/local/scripts/monitor-bandwidth.sh << EOF
#!/bin/bash
#
# 带宽监控脚本
#

IFACE="$IFACE_DEFAULT"

clear
echo "===================================="
echo "      实时带宽使用情况监控"
echo "===================================="
echo "网卡: \$IFACE"
echo "按 Ctrl+C 退出监控"
echo "===================================="
echo ""

echo "当前活动的限速规则 (Class ID, Rate):"
# Try to extract relevant info: classid and rate
tc -s class show dev \$IFACE | grep -E 'class htb 1:[0-9]+ ' | sed -E 's/.*class htb (1:[0-9]+).* rate ([0-9]+[GgMmKk]bit).*/  Class: \1, Rate: \2/' || echo "  未找到活动的 tc class 规则或 tc 命令失败。"
echo ""
echo "实时流量 (需要 vnstat 或 iftop):"
echo "------------------------------------"

if command -v vnstat &>/dev/null; then
    echo "使用 vnstat 监控 (按 Ctrl+C 退出)..."
    vnstat -l -i \$IFACE
elif command -v iftop &>/dev/null; then
    echo "未找到 vnstat，尝试使用 iftop (按 Q 退出)..."
    iftop -i \$IFACE -N -P -t -L 100 # -N: no dns, -P: show ports, -t: text mode, -L: lines
else
    echo "未安装 vnstat 或 iftop。请运行:"
    echo "  apt install vnstat"
    echo "或"
    echo "  apt install iftop"
fi
EOF

    chmod +x /usr/local/scripts/monitor-bandwidth.sh
    echo -e "${GREEN}[成功]${PLAIN} 监控脚本已创建: /usr/local/scripts/monitor-bandwidth.sh"
}

# 设置 systemd 服务和定时器 - (Identical to Version 1)
setup_service() {
    echo -e "${BLUE}[信息]${PLAIN} 设置系统服务和定时器..."

    # Ensure log file exists and has correct permissions
    touch "$LOG_FILE"
    chown root:root "$LOG_FILE" # Or appropriate user/group if needed
    chmod 644 "$LOG_FILE"

    # Create systemd service unit
    cat > /etc/systemd/system/ip-bandwidth-limiter.service << EOF
[Unit]
Description=IP Bandwidth Limiter Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/scripts/ip-bandwidth-limiter.sh
Restart=on-failure
RestartSec=15s
# User=root (Default)
# Environment variables used by the script are set within the script itself

[Install]
WantedBy=multi-user.target
EOF

    # Create systemd timer unit
    cat > /etc/systemd/system/ip-bandwidth-limiter.timer << EOF
[Unit]
Description=Run IP Bandwidth Limiter periodically (every $TIMER_INTERVAL seconds)

[Timer]
# Run N seconds after boot, and then every N seconds
OnBootSec=${TIMER_INTERVAL}s
OnUnitActiveSec=${TIMER_INTERVAL}s
AccuracySec=1s # Allow some tolerance
Unit=ip-bandwidth-limiter.service # Specifies the service unit to activate

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload

    # Stop any potentially old running instances before enabling/starting timer
    systemctl stop ip-bandwidth-limiter.service 2>/dev/null
    systemctl stop ip-bandwidth-limiter.timer 2>/dev/null

    # Enable and start the TIMER only. The timer will trigger the service.
    systemctl enable ip-bandwidth-limiter.timer || {
        echo -e "${RED}[错误]${PLAIN} 无法启用定时器 ip-bandwidth-limiter.timer"
        exit 1
    }
    systemctl start ip-bandwidth-limiter.timer || {
        echo -e "${RED}[错误]${PLAIN} 无法启动定时器 ip-bandwidth-limiter.timer"
        # Attempt to show status for debugging
        sleep 2
        systemctl status ip-bandwidth-limiter.timer
        journalctl -u ip-bandwidth-limiter.timer -n 10
        exit 1
    }

    echo -e "${GREEN}[成功]${PLAIN} 系统定时器 ip-bandwidth-limiter.timer 已设置并启动。"
    echo -e "${BLUE}[信息]${PLAIN} 定时器将每 ${TIMER_INTERVAL} 秒运行一次限速脚本。"
}

# 创建卸载脚本 - (Identical to Version 1)
create_uninstall_script() {
    echo -e "${BLUE}[信息]${PLAIN} 创建卸载脚本..."
    mkdir -p /usr/local/scripts

    cat > /usr/local/scripts/uninstall-limiter.sh << EOF
#!/bin/bash
#
# 卸载 IP 带宽限速器
#

echo "正在卸载 IP 带宽限速器..."

# Stop and disable systemd units
echo "停止并禁用 systemd 定时器和相关服务..."
systemctl stop ip-bandwidth-limiter.timer 2>/dev/null
systemctl disable ip-bandwidth-limiter.timer 2>/dev/null
systemctl stop ip-bandwidth-limiter.service 2>/dev/null # Ensure service is stopped too
# Disable service just in case it was somehow enabled separately
systemctl disable ip-bandwidth-limiter.service 2>/dev/null

# Remove systemd unit files
echo "删除 systemd 单元文件..."
rm -f /etc/systemd/system/ip-bandwidth-limiter.service
rm -f /etc/systemd/system/ip-bandwidth-limiter.timer
systemctl daemon-reload

# Remove TC rules
IFACE_TO_CLEAR="$IFACE_DEFAULT" # Use the interface detected during installation
if [ -z "\$IFACE_TO_CLEAR" ]; then
    echo "警告：无法自动检测用于清除规则的接口。您可能需要手动运行 'tc qdisc del dev <your_interface> root'"
else
    echo "清除接口 \$IFACE_TO_CLEAR 上的 tc 规则..."
    tc qdisc del dev \$IFACE_TO_CLEAR root 2>/dev/null || echo "接口 \$IFACE_TO_CLEAR 上没有找到根 qdisc 或清除失败。"
fi

# Remove script files and log
echo "删除脚本文件和日志..."
rm -f /usr/local/scripts/ip-bandwidth-limiter.sh
rm -f /usr/local/scripts/monitor-bandwidth.sh
rm -f /usr/local/scripts/uninstall-limiter.sh
rm -f "$LOG_FILE"

# Attempt to remove directory if empty
rmdir /usr/local/scripts 2>/dev/null || echo "目录 /usr/local/scripts 非空，未删除。"

echo ""
echo -e "${GREEN}IP 带宽限速器已卸载！${PLAIN}"
echo "如果您不再需要 vnstat，可以手动卸载: apt remove vnstat"
EOF

    chmod +x /usr/local/scripts/uninstall-limiter.sh
    echo -e "${GREEN}[成功]${PLAIN} 卸载脚本已创建: /usr/local/scripts/uninstall-limiter.sh"
}

# 显示使用说明
show_usage() {
    echo -e "${CYAN}=====================================${PLAIN}"
    echo -e "${CYAN}    IP 带宽限速器 安装成功！       ${PLAIN}"
    echo -e "${CYAN}=====================================${PLAIN}"
    echo -e ""
    echo -e "${YELLOW}版本信息:${PLAIN}"
    echo -e " - 此版本 ${GREEN}限制所有${PLAIN} 检测到的公共 IP 进行限速"
    echo -e ""
    echo -e "${YELLOW}使用说明:${PLAIN}"
    echo -e " 1. 限速脚本通过 systemd 定时器每 ${GREEN}${TIMER_INTERVAL}${PLAIN} 秒自动运行"
    echo -e " 2. 为每个检测到的公共 IP 设置带宽限制为 ${GREEN}$RATE${PLAIN}"
    echo -e " 3. 未匹配的流量或私有 IP 流量 ${GREEN}不限速${PLAIN}"
    echo -e " 4. 使用的网卡: ${GREEN}$IFACE_DEFAULT${PLAIN}"
    echo -e ""
    echo -e "${YELLOW}可用命令:${PLAIN}"
    echo -e " - ${GREEN}监控带宽使用情况:${PLAIN}"
    echo -e "   ${CYAN}bash /usr/local/scripts/monitor-bandwidth.sh${PLAIN}"
    echo -e " - ${GREEN}手动立即运行一次限速脚本:${PLAIN}"
    echo -e "   ${CYAN}sudo bash /usr/local/scripts/ip-bandwidth-limiter.sh${PLAIN}"
    echo -e " - ${GREEN}查看限速日志:${PLAIN}"
    echo -e "   ${CYAN}tail -f /var/log/bandwidth-limit.log${PLAIN}"
    echo -e " - ${GREEN}查看定时器状态:${PLAIN}"
    echo -e "   ${CYAN}systemctl status ip-bandwidth-limiter.timer${PLAIN}"
    echo -e " - ${GREEN}查看服务日志:${PLAIN}"
    echo -e "   ${CYAN}journalctl -u ip-bandwidth-limiter.service -n 50 -f${PLAIN}"
    echo -e " - ${RED}卸载限速器:${PLAIN}"
    echo -e "   ${CYAN}sudo bash /usr/local/scripts/uninstall-limiter.sh${PLAIN}"
    echo -e ""
    echo -e "${CYAN}=====================================${PLAIN}"
}

# 主安装流程
main() {
    clear
    echo -e "${CYAN}=====================================${PLAIN}"
    echo -e "${CYAN}  IP 带宽限速器 安装程序 (限制所有IP版) ${PLAIN}"
    echo -e "${CYAN}=====================================${PLAIN}"
    echo -e ""

    check_root
    check_os
    check_interface # Check and potentially ask for interface early

    echo -e "${YELLOW}此脚本将为 ${RED}所有${PLAIN} 检测到的公共连接 IP 设置 ${GREEN}$RATE${PLAIN} 带宽限制"
    echo -e "${YELLOW}将在网卡 ${GREEN}$IFACE_DEFAULT${PLAIN} 上应用规则"
    echo -e ""

    read -p "是否继续安装？(y/n): " choice
    [[ ! "$choice" =~ ^[Yy]$ ]] && echo "安装已取消" && exit 0

    MONITOR_INSTALL="n" # Default to not installing monitor
    read -p "是否创建带宽监控脚本 (monitor-bandwidth.sh)? (y/n): " monitor_choice
    [[ "$monitor_choice" =~ ^[Yy]$ ]] && MONITOR_INSTALL="y"

    check_install # Pass monitor install choice to dependency check
    create_limiter_script
    if [[ "$MONITOR_INSTALL" = "y" ]]; then
        create_monitor_script
    fi
    setup_service
    create_uninstall_script

    echo -e ""
    echo -e "${BLUE}[信息]${PLAIN} 正在首次运行限速脚本以应用规则..."
    if bash /usr/local/scripts/ip-bandwidth-limiter.sh; then
        echo -e "${GREEN}[成功]${PLAIN} 首次运行完成。"
    else
        echo -e "${RED}[错误]${PLAIN} 首次运行限速脚本失败。请检查日志: $LOG_FILE"
    fi
    echo -e ""

    show_usage
}

# --- 执行主函数 ---
main
