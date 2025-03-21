#!/bin/bash

# 脚本描述：限制网卡 ens5 上每个 IP 的下载速度到 100Mbps，不限制总带宽

# 设置变量
INTERFACE="ens5"  # 你的网卡名称
RATE="100mbit"    # 每个 IP 的限速为 100Mbps

# 检查是否以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo "请以 root 权限运行此脚本：sudo $0"
  exit 1
fi

# 检查 tc 是否可用
if ! command -v tc &> /dev/null; then
  echo "tc 未安装，正在尝试安装 iproute2..."
  apt update && apt install -y iproute2
  if [ $? -ne 0 ]; then
    echo "安装 iproute2 失败，请手动安装后重试。"
    exit 1
  fi
fi

# 清除现有 tc 规则
echo "清除 $INTERFACE 上的现有 tc 规则..."
tc qdisc del dev $INTERFACE root 2>/dev/null

# 添加根队列，使用 HTB
echo "设置 $INTERFACE 的限速规则..."
tc qdisc add dev $INTERFACE root handle 1: htb

# 为每个 IP 创建独立的限速类
# 这里我们不设置总上限，只为每个 IP 添加过滤器
echo "正在为每个 IP 配置 100Mbps 限速..."

# 示例：动态检测当前连接的 IP 并限速
# 获取当前连接的 IP 列表（假设这些 IP 是客户端来源 IP）
# 这里需要结合实际情况动态更新，或者手动指定 IP 范围
IPS=$(ip -o addr show $INTERFACE | grep inet | awk '{print $4}' | cut -d'/' -f1)
if [ -z "$IPS" ]; then
  echo "未检测到 $INTERFACE 的 IP，可能需要手动指定 IP 范围。"
  echo "示例：sudo $0 192.168.1.0/24"
  exit 1
fi

# 计数器，用于分配 classid
CLASS_ID=10

# 为每个 IP 设置限速
for IP in $(arp -i $INTERFACE | grep -v "Address" | awk '{print $1}'); do
  echo "限制 IP $IP 到 $RATE..."
  tc class add dev $INTERFACE parent 1: classid 1:$CLASS_ID htb rate $RATE
  tc filter add dev $INTERFACE protocol ip parent 1: prio 1 u32 match ip src $IP flowid 1:$CLASS_ID
  CLASS_ID=$((CLASS_ID + 1))
done

# 显示当前规则
echo "限速设置完成！当前 tc 规则如下："
tc qdisc show dev $INTERFACE
tc class show dev $INTERFACE
tc filter show dev $INTERFACE

echo "网卡 $INTERFACE 上每个 IP 的下载速度已限制为 100Mbps。"
echo "如需取消限速，请运行：tc qdisc del dev $INTERFACE root"
