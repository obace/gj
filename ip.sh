#!/bin/bash
#
# IP-Bandwidth-Limiter
# 一键为每个连接的 IP 设置带宽限制
# 适用于运行 X-UI 和 Hysteria 2 的 Debian/Ubuntu 服务器
#

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# 配置参数（可编辑）
# 自动检测网卡名称
IFACE_DEFAULT=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'dev \K\S+' || ip link | grep -E '^[0-9]+: ' | grep -v 'lo:' | head -n1 | awk '{print $2}' | cut -d: -f1)
[ -z "$IFACE_DEFAULT" ] && echo -e "${RED}错误：${PLAIN}无法自动检测网卡，请检查网络配置" && exit 1
# 可选：手动指定网卡（取消注释并替换为你的网卡名称）
# IFACE_DEFAULT="ens5"
RATE=${RATE:-"150mbit"}  # 每个 IP 和默认类的带宽限制
BURST=${BURST:-"15k"}    # 突发流量
LOG_FILE="/var/log/bandwidth-limit.log"

# 检查是否为 root 用户
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：${PLAIN}必须使用 root 用户运行此脚本！\n" && exit 1

# 检查系统类型
if [[ -f /etc/debian_version ]]; then
    release="debian"
elif [[ -f /etc/lsb-release || -f /etc/ubuntu-release ]]; then
    release="ubuntu"
else
    echo -e "${RED}错误：${PLAIN}不支持的操作系统！\n" && exit 1
fi

# 检查并安装必要的软件包
check_install() {
    echo -e "${BLUE}[信息]${PLAIN} 检查并安装必要的软件包..."
    
    if ! command -v tc &>/dev/null || ! command -v iptables &>/dev/null || ! command -v vnstat &>/dev/null || ! command -v ss &>/dev/null; then
        if command -v apt-get &>/dev/null; then
            apt-get update -y && apt-get install -y iproute2 iptables vnstat net-tools
        elif command -v apt &>/dev/null; then
            apt update -y && apt install -y iproute2 iptables vnstat net-tools
        else
            echo -e "${RED}[错误]${PLAIN} 未找到支持的包管理器" && exit 1
        fi
        
        if [ $? -ne 0 ]; then
            echo -e "${RED}[错误]${PLAIN} 安装软件包失败，请检查网络或手动安装 iproute2, iptables, vnstat 和 net-tools"
            exit 1
        fi
    fi
    
    systemctl enable vnstat &>/dev/null
    systemctl start vnstat &>/dev/null
    
    echo -e "${GREEN}[成功]${PLAIN} 所有必要的软件包已安装"
}

# 创建限速脚本
create_limiter_script() {
    echo -e "${BLUE}[信息]${PLAIN} 创建限速脚本..."
    
    mkdir -p /usr/local/scripts
    
    cat > /usr/local/scripts/ip-bandwidth-limiter.sh << EOF
#!/bin/bash
#
# IP-Bandwidth-Limiter
# 为每个连接的 IP 设置带宽限制
#

# 配置参数
IFACE=\${IFACE:-"$IFACE_DEFAULT"}
RATE="200mbit"
BURST="15k"
LOG_FILE="/var/log/bandwidth-limit.log"

# 记录日志函数
log() {
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - \$1" >> \$LOG_FILE
}

log "开始执行带宽限制，网卡: \$IFACE"

# 检查网卡是否有效
[ -z "\$IFACE" ] && log "错误：无法检测到网卡" && exit 1

# 清理旧规则并初始化 HTB qdisc
tc qdisc del dev \$IFACE root 2>/dev/null
tc qdisc add dev \$IFACE root handle 1: htb default 999 || {
    log "错误：创建 tc qdisc 失败"
    exit 1
}
tc class add dev \$IFACE parent 1: classid 1:999 htb rate \$RATE burst \$BURST  # 默认类也限制为 200mbit

# 获取当前所有已建立连接的唯一 IP 地址 (TCP 和 UDP)
CONNECTED_IPS=\$(ss -tn state established '( dport != :22 )' | awk 'NR>1 {print \$4}' | cut -d: -f1 | sort -u)
CONNECTED_IPS+=" \$(ss -un | awk 'NR>1 {print \$5}' | cut -d: -f1 | sort -u)"
CONNECTED_IPS=\$(echo "\$CONNECTED_IPS" | tr ' ' '\n' | sort -u)

log "检测到的 IP 列表: \$CONNECTED_IPS"

# 为所有 IP 创建限速类
IP_COUNT=1
for IP in \$CONNECTED_IPS; do
    # 跳过私有 IP 和无效 IP
    if [[ \$IP =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.|127\.|::1|fe80::|fc00::|fd00::|ff00::) ]] || \
       ! [[ \$IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\$ ]] && ! [[ \$IP =~ ^[0-9a-fA-F:]+\$ ]]; then
        continue
    fi
    
    CLASS_ID=\$((100 + \$IP_COUNT))
    
    tc class add dev \$IFACE parent 1: classid 1:\$CLASS_ID htb rate \$RATE burst \$BURST || continue
    tc qdisc add dev \$IFACE parent 1:\$CLASS_ID handle \$CLASS_ID: sfq perturb 10 || continue
    
    # TCP 和 UDP 过滤器
    tc filter add dev \$IFACE parent 1: protocol ip prio 1 u32 match ip dst \$IP/32 flowid 1:\$CLASS_ID
    tc filter add dev \$IFACE parent 1: protocol ip prio 1 u32 match ip src \$IP/32 flowid 1:\$CLASS_ID
    tc filter add dev \$IFACE parent 1: protocol ip prio 2 u32 match ip protocol 17 0xff match ip dst \$IP/32 flowid 1:\$CLASS_ID
    tc filter add dev \$IFACE parent 1: protocol ip prio 2 u32 match ip protocol 17 0xff match ip src \$IP/32 flowid 1:\$CLASS_ID
    
    IP_COUNT=\$((\$IP_COUNT + 1))
done

log "已为 \$((\$IP_COUNT - 1)) 个 IP 设置 \$RATE 限速"
EOF
    
    chmod +x /usr/local/scripts/ip-bandwidth-limiter.sh
    echo -e "${GREEN}[成功]${PLAIN} 限速脚本已创建: /usr/local/scripts/ip-bandwidth-limiter.sh"
}

# 创建监控脚本
create_monitor_script() {
    echo -e "${BLUE}[信息]${PLAIN} 创建监控脚本..."
    
    cat > /usr/local/scripts/monitor-bandwidth.sh << EOF
#!/bin/bash
#
# 带宽监控脚本
#

IFACE=\${IFACE:-"$IFACE_DEFAULT"}

clear
echo "===================================="
echo "      实时带宽使用情况监控"
echo "===================================="
echo "网卡: \$IFACE"
echo "按 Ctrl+C 退出监控"
echo "===================================="
echo ""

echo "当前限速规则:"
tc -s class show dev \$IFACE | grep -E "class htb 1:[0-9]+ " | while read line; do
    echo "\$line"
done
echo ""

if command -v vnstat &>/dev/null; then
    vnstat -l -i \$IFACE
else
    echo "未安装 vnstat，使用 iftop 替代..."
    if command -v iftop &>/dev/null; then
        iftop -i \$IFACE -N
    else
        echo "未安装 iftop，请使用: apt-get install iftop"
    fi
fi
EOF
    
    chmod +x /usr/local/scripts/monitor-bandwidth.sh
    echo -e "${GREEN}[成功]${PLAIN} 监控脚本已创建: /usr/local/scripts/monitor-bandwidth.sh"
}

# 设置 systemd 服务和定时器
setup_service() {
    echo -e "${BLUE}[信息]${PLAIN} 设置系统服务和定时器..."
    
    touch $LOG_FILE
    chmod 644 $LOG_FILE
    
    cat > /etc/systemd/system/ip-bandwidth-limiter@.service << EOF
[Unit]
Description=IP Bandwidth Limiter Service for %i
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/scripts/ip-bandwidth-limiter.sh
Restart=on-failure
RestartSec=5s
Environment="IFACE=%i"

[Install]
WantedBy=multi-user.target
EOF
    
    cat > /etc/systemd/system/ip-bandwidth-limiter.timer << 'EOF'
[Unit]
Description=Run IP Bandwidth Limiter every 5 seconds

[Timer]
OnCalendar=*:*:0/5
Persistent=true
Unit=ip-bandwidth-limiter@%i.service

[Install]
WantedBy=timers.target
EOF
    
    systemctl daemon-reload
    
    systemctl enable ip-bandwidth-limiter@"$IFACE_DEFAULT".service || {
        echo -e "${RED}[错误]${PLAIN} 无法启用服务 ip-bandwidth-limiter@$IFACE_DEFAULT.service"
        exit 1
    }
    systemctl start ip-bandwidth-limiter@"$IFACE_DEFAULT".service || {
        echo -e "${RED}[错误]${PLAIN} 无法启动服务 ip-bandwidth-limiter@$IFACE_DEFAULT.service"
        exit 1
    }
    systemctl enable ip-bandwidth-limiter.timer || {
        echo -e "${RED}[错误]${PLAIN} 无法启用定时器 ip-bandwidth-limiter.timer"
        exit 1
    }
    systemctl start ip-bandwidth-limiter.timer || {
        echo -e "${RED}[错误]${PLAIN} 无法启动定时器 ip-bandwidth-limiter.timer"
        exit 1
    }
    
    echo -e "${GREEN}[成功]${PLAIN} 系统服务和定时器已设置"
}

# 创建卸载脚本
create_uninstall_script() {
    echo -e "${BLUE}[信息]${PLAIN} 创建卸载脚本..."
    
    cat > /usr/local/scripts/uninstall-limiter.sh << EOF
#!/bin/bash
#
# 卸载 IP 带宽限速器
#

echo "正在卸载 IP 带宽限速器..."

systemctl stop ip-bandwidth-limiter@*.service 2>/dev/null
systemctl disable ip-bandwidth-limiter@*.service 2>/dev/null
systemctl stop ip-bandwidth-limiter.timer 2>/dev/null
systemctl disable ip-bandwidth-limiter.timer 2>/dev/null

rm -f /etc/systemd/system/ip-bandwidth-limiter@.service
rm -f /etc/systemd/system/ip-bandwidth-limiter.timer
systemctl daemon-reload

IFACE="$IFACE_DEFAULT"
tc qdisc del dev \$IFACE root 2>/dev/null

rm -f /usr/local/scripts/ip-bandwidth-limiter.sh
rm -f /usr/local/scripts/monitor-bandwidth.sh
rm -f /usr/local/scripts/uninstall-limiter.sh
rm -f /var/log/bandwidth-limit.log
rmdir /usr/local/scripts 2>/dev/null || echo "目录非空，未删除 /usr/local/scripts"

echo "IP 带宽限速器已完全卸载！"
EOF
    
    chmod +x /usr/local/scripts/uninstall-limiter.sh
    echo -e "${GREEN}[成功]${PLAIN} 卸载脚本已创建: /usr/local/scripts/uninstall-limiter.sh"
}

# 显示使用说明
show_usage() {
    echo -e "${CYAN}=====================================${PLAIN}"
    echo -e "${CYAN}    IP 带宽限速器 安装成功！    ${PLAIN}"
    echo -e "${CYAN}=====================================${PLAIN}"
    echo -e ""
    echo -e "${YELLOW}使用说明:${PLAIN}"
    echo -e " 1. 限速脚本每5秒自动运行"
    echo -e " 2. 每个 IP 的带宽限制为 ${GREEN}$RATE${PLAIN}"
    echo -e " 3. 未匹配的流量也限制为 ${GREEN}$RATE${PLAIN}"
    echo -e ""
    echo -e "${YELLOW}可用命令:${PLAIN}"
    echo -e " - ${GREEN}监控带宽使用情况:${PLAIN}"
    echo -e "   ${CYAN}bash /usr/local/scripts/monitor-bandwidth.sh${PLAIN}"
    echo -e " - ${GREEN}手动运行限速脚本:${PLAIN}"
    echo -e "   ${CYAN}bash /usr/local/scripts/ip-bandwidth-limiter.sh${PLAIN}"
    echo -e " - ${GREEN}查看限速日志:${PLAIN}"
    echo -e "   ${CYAN}cat /var/log/bandwidth-limit.log${PLAIN}"
    echo -e " - ${RED}卸载限速器:${PLAIN}"
    echo -e "   ${CYAN}bash /usr/local/scripts/uninstall-limiter.sh${PLAIN}"
    echo -e ""
    echo -e "${CYAN}=====================================${PLAIN}"
}

# 主安装流程
main() {
    echo -e "${CYAN}=====================================${PLAIN}"
    echo -e "${CYAN}    IP 带宽限速器 安装程序    ${PLAIN}"
    echo -e "${CYAN}=====================================${PLAIN}"
    echo -e ""
    echo -e "${YELLOW}此脚本将为每个连接的 IP 设置 $RATE 带宽限制${PLAIN}"
    echo -e "${YELLOW}自动检测到的网卡: $IFACE_DEFAULT${PLAIN}"
    echo -e ""
    
    read -p "是否继续安装？(y/n): " choice
    [[ ! "$choice" =~ ^[Yy]$ ]] && echo "安装已取消" && exit 0
    
    check_install
    create_limiter_script
    
    read -p "是否安装带宽监控脚本？(y/n): " monitor_choice
    [[ "$monitor_choice" =~ ^[Yy]$ ]] && create_monitor_script
    
    setup_service
    create_uninstall_script
    
    echo -e "${BLUE}[信息]${PLAIN} 首次运行限速脚本..."
    bash /usr/local/scripts/ip-bandwidth-limiter.sh
    
    show_usage
}

# 执行主函数
main
