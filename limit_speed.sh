#!/bin/bash

# 脚本描述：限制网卡 ens5 的每个连接和每个 IP 网速到 100Mbps

# 设置变量
INTERFACE="ens5"  # 你的网卡名称
RATE="100mbit"    # 限制速度为 100Mbps

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

# 添加根队列，使用 HTB（层次令牌桶）
echo "设置 $INTERFACE 的限速规则..."
tc qdisc add dev $INTERFACE root handle 1: htb default 10

# 设置总带宽限制为 100Mbps
tc class add dev $INTERFACE parent 1: classid 1:1 htb rate $RATE

# 添加默认过滤器，所有流量都走 1:1
tc filter add dev $INTERFACE protocol ip parent 1:0 prio 1 u32 match ip dst 0.0.0.0/0 flowid 1:1

# 显示当前规则
echo "限速设置完成！当前 tc 规则如下："
tc qdisc show dev $INTERFACE
tc class show dev $INTERFACE
tc filter show dev $INTERFACE

echo "网卡 $INTERFACE 已限制为每 IP 和每连接 100Mbps。"
echo "如需取消限速，请运行：tc qdisc del dev $INTERFACE root"
