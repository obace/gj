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
apt install -y iproute2 iptables

# 创建限速脚本
cat > /usr/local/bin/limit-ip-speed.sh << 'EOF'
#!/bin/bash

# 网卡名称
IFACE="ens5"

# 清除已有规则
tc qdisc del dev $IFACE root 2>/dev/null
iptables -t mangle -F

# 创建根队列规则
tc qdisc add dev $IFACE root handle 1: htb default 10

# 创建主类
tc class add dev $IFACE parent 1: classid 1:1 htb rate 100Gbit

# 获取所有已连接的IP
CONNECTED_IPS=$(netstat -ntu | awk '{print $5}' | cut -d: -f1 | grep -v '^[[:space:]]*$' | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' | sort -u)

# 为每个IP创建限速规则
for IP in $CONNECTED_IPS
do
    # 获取标记号(使用IP的哈希值作为标记，避免冲突)
    MARK=$(echo $IP | md5sum | cut -c1-4)
    MARK=$((16#$MARK)) # 转换为十进制
    
    # 创建100Mbps的子类
    tc class add dev $IFACE parent 1:1 classid 1:$MARK htb rate 100Mbit ceil 100Mbit
    
    # 创建过滤器
    tc filter add dev $IFACE protocol ip parent 1:0 prio 1 handle $MARK fw flowid 1:$MARK
    
    # 添加iptables标记
    iptables -t mangle -A POSTROUTING -d $IP -j MARK --set-mark $MARK
done

# 显示当前规则
echo "Current TC rules:"
tc -s qdisc ls dev $IFACE
echo -e "\nCurrent IP marks:"
iptables -t mangle -L POSTROUTING -n -v
EOF

# 添加执行权限
chmod +x /usr/local/bin/limit-ip-speed.sh

# 创建systemd服务
cat > /etc/systemd/system/ip-speed-limit.service << 'EOF'
[Unit]
Description=IP Speed Limit Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/limit-ip-speed.sh
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

# 创建定时任务以定期更新规则
cat > /etc/cron.d/ip-speed-limit << 'EOF'
*/5 * * * * root /usr/local/bin/limit-ip-speed.sh
EOF

# 启用并启动服务
systemctl daemon-reload
systemctl enable ip-speed-limit
systemctl start ip-speed-limit

echo -e "${GREEN}安装完成!${PLAIN}"
echo -e "${YELLOW}已经设置以下内容:${PLAIN}"
echo "1. 创建了限速脚本: /usr/local/bin/limit-ip-speed.sh"
echo "2. 创建了系统服务: ip-speed-limit"
echo "3. 添加了定时任务每5分钟更新一次规则"
echo -e "\n${YELLOW}当前限速规则:${PLAIN}"
tc -s qdisc ls dev ens5

echo -e "\n${YELLOW}使用以下命令可以管理服务:${PLAIN}"
echo "systemctl status ip-speed-limit  # 查看服务状态"
echo "systemctl stop ip-speed-limit    # 停止服务"
echo "systemctl start ip-speed-limit   # 启动服务"
echo "systemctl restart ip-speed-limit # 重启服务"
