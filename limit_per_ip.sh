#!/bin/bash

# 脚本描述：限制网卡 ens5 上每个 IP 的下载速度到 100Mbps

# 设置变量
INTERFACE="ens5"  # 你的网卡名称
RATE="100mbit"    # 每个 IP 的限速为 100Mbps
IP_RANGE=${1:-"none"}  # 可选参数指定 IP 范围，例如 192.168.1.0/24

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
  echo "请以 root 权限运行：sudo $0 [IP_RANGE]"
  exit 1
fi

# 检查 tc
if ! command -v tc &> /dev/null; then
  echo "安装 iproute2..."
  apt update && apt install -y iproute2 || { echo "安装失败"; exit 1; }
fi

# 清除旧规则
echo "清除 $INTERFACE 旧规则..."
tc qdisc del dev $INTERFACE root 2>/dev/null

# 添加 HTB 队列
echo "设置 HTB 队列..."
tc qdisc add dev $INTERFACE root handle 1: htb default 9999 || { echo "队列设置失败"; exit 1; }

# 获取 IP 列表
if [ "$IP_RANGE" == "none" ]; then
  echo "检测活动 IP（使用 netstat）..."
  IPS=$(netstat -tn | grep ESTABLISHED | awk '{print $5}' | cut -d: -f1 | sort -u)
  if [ -z "$IPS" ]; then
    echo "未检测到活动连接，可能需要指定 IP 范围（例如 192.168.1.0/24）。"
    echo "当前 ARP 表："
    arp -i $INTERFACE
    exit 1
  fi
else
  if ! command -v ipcalc &> /dev/null; then
    echo "安装 ipcalc..."
    apt install -y ipcalc || { echo "安装失败"; exit 1; }
  fi
  IPS=$(ipcalc $IP_RANGE | grep Host | awk '{print $2}')
fi

# 调试：显示检测到的 IP
echo "检测到的 IP 列表：$IPS"

# 设置限速
CLASS_ID=10
for IP in $IPS; do
  if [[ $IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "限制 IP $IP 到 $RATE..."
    tc class add dev $INTERFACE parent 1: classid 1:$CLASS_ID htb rate $RATE || echo "添加 class 失败: $IP"
    tc filter add dev $INTERFACE protocol ip parent 1: prio 1 u32 match ip src $IP flowid 1:$CLASS_ID || echo "添加 filter 失败: $IP"
    CLASS_ID=$((CLASS_ID + 1))
  else
    echo "跳过无效 IP: $IP"
  fi
done

# 显示规则
echo "当前 tc 规则："
tc qdisc show dev $INTERFACE
tc class show dev $INTERFACE
tc filter show dev $INTERFACE

echo "完成！每个 IP 下载速度应限制为 100Mbps。"
echo "取消限速：tc qdisc del dev $INTERFACE root"
