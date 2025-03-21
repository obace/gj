#!/bin/bash

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

# 检查是否为root用户
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}错误: 必须使用root用户运行此脚本!${PLAIN}"
    exit 1
fi

# 检查系统是否为Debian/Ubuntu
if ! [ -f /etc/debian_version ]; then
    echo -e "${RED}错误: 此脚本仅支持Debian/Ubuntu系统!${PLAIN}"
    exit 1
fi

echo -e "${GREEN}开始安装必要的软件包...${PLAIN}"
apt update
apt install -y iproute2 iptables ipset

# 创建限速脚本
cat > /usr/local/bin/limit-ip-speed.sh << 'EOF'
#!/bin/bash

# 网卡名称
IFACE="ens5"
# 限速值（kbps）
RATE="100000kbit" # 100Mbps
BURST="100000k"   # 突发流量限制

# 清除已有规则
tc qdisc del dev $IFACE root 2>/dev/null
tc qdisc del dev $IFACE ingress 2>/dev/null
iptables -t mangle -F

# 创建ipset if not exists
ipset create limited_ips hash:ip 2>/dev/null || ipset flush limited_ips

# 添加root qdisc
tc qdisc add dev $IFACE root handle 1: htb default 1
tc class add dev $IFACE parent 1: classid 1:1 htb rate $RATE ceil $RATE

# 添加ingress qdisc
tc qdisc add dev $IFACE handle ffff: ingress

# 获取所有已连接的IP
CONNECTED_IPS=$(netstat -nt | awk '{print $5}' | cut -d: -f1 | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' | sort -u)

for IP in $CONNECTED_IPS
do
    # 跳过内网IP
    if [[ $IP =~ ^(127\.|10\.|172\.16\.|172\.17\.|172\.18\.|172\.19\.|172\.20\.|172\.21\.|172\.22\.|172\.23\.|172\.24\.|172\.25\.|172\.26\.|172\.27\.|172\.28\.|172\.29\.|172\.30\.|172\.31\.|192\.168\.) ]]; then
        continue
    fi

    # 将IP添加到ipset
    ipset add limited_ips $IP 2>/dev/null

    # 为每个IP创建单独的类
    MARK=$(echo $IP | md5sum | cut -c1-4)
    MARK=$((16#$MARK))
    
    # 出站限速
    tc class add dev $IFACE parent 1:1 classid 1:$MARK htb rate $RATE ceil $RATE burst $BURST
    tc qdisc add dev $IFACE parent 1:$MARK handle $MARK: sfq perturb 10
    tc filter add dev $IFACE protocol ip parent 1:0 prio 1 handle $MARK fw flowid 1:$MARK

    # 入站限速
    tc filter add dev $IFACE parent ffff: protocol ip prio 1 u32 match ip src $IP police rate $RATE burst $BURST drop flowid :$MARK

    # iptables标记
    iptables -t mangle -A POSTROUTING -d $IP -j MARK --set-mark $MARK
done

# 添加iptables规则
iptables -t mangle -A POSTROUTING -m set --match-set limited_ips dst -j MARK --set-mark 100

echo "Current TC rules:"
tc -s qdisc ls dev $IFACE
echo -e "\nCurrent class rules:"
tc -s class ls dev $IFACE
echo -e "\nCurrent filter rules:"
tc -s filter ls dev $IFACE
echo -e "\nCurrent iptables rules:"
iptables -t mangle -L -n -v
echo -e "\nCurrent ipset entries:"
ipset list limited_ips
EOF

# 添加执行权限
chmod +x /usr/local/bin/limit-ip-speed.sh

# 创建systemd服务
cat > /etc/systemd/system/ip-speed-limit.service << 'EOF'
[Unit]
Description=IP Speed Limit Service
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/limit-ip-speed.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# 创建定时更新服务
cat > /etc/systemd/system/ip-speed-limit-update.timer << 'EOF'
[Unit]
Description=Update IP Speed Limits Every Minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
EOF

cat > /etc/systemd/system/ip-speed-limit-update.service << 'EOF'
[Unit]
Description=Update IP Speed Limits Service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/limit-ip-speed.sh

[Install]
WantedBy=multi-user.target
EOF

# 启用并启动服务
systemctl daemon-reload
systemctl enable ip-speed-limit
systemctl enable ip-speed-limit-update.timer
systemctl start ip-speed-limit
systemctl start ip-speed-limit-update.timer

echo -e "${GREEN}安装完成!${PLAIN}"
echo -e "${YELLOW}已经设置以下内容:${PLAIN}"
echo "1. 创建了限速脚本: /usr/local/bin/limit-ip-speed.sh"
echo "2. 创建了系统服务: ip-speed-limit"
echo "3. 添加了定时更新服务，每分钟更新一次规则"
echo -e "\n${YELLOW}当前限速规则:${PLAIN}"
tc -s qdisc ls dev ens5

echo -e "\n${YELLOW}使用以下命令可以管理服务:${PLAIN}"
echo "systemctl status ip-speed-limit           # 查看服务状态"
echo "systemctl status ip-speed-limit-update.timer  # 查看定时器状态"
echo "systemctl restart ip-speed-limit          # 重启服务"
