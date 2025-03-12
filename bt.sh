#!/bin/bash

# 检查是否有root权限
if [ "$(id -u)" != "0" ]; then
   echo "此脚本需要root权限才能运行" 
   exit 1
fi

echo "开始设置BitTorrent流量拦截规则..."

# 清除现有的相关规则
iptables -F OUTPUT
iptables -F INPUT

# TCP字符串匹配规则
echo "添加TCP字符串匹配规则..."
keywords=("torrent" ".torrent" "peer_id=" "announce" "info_hash" "get_peers" "find_node" "BitTorrent" "announce_peer" "BitTorrent protocol" "announce.php?passkey=" "magnet:" "xunlei" "sandai" "Thunder" "XLLiveUD")

for keyword in "${keywords[@]}"; do
    iptables -A OUTPUT -p tcp -m string --string "$keyword" --algo bm -j DROP
    echo "已添加规则: 拦截包含 '$keyword' 的TCP出站流量"
done

# 添加UDP端口拦截
echo "添加UDP端口拦截规则..."
# BitTorrent常用UDP端口
iptables -A OUTPUT -p udp --dport 6881:6889 -j DROP
iptables -A OUTPUT -p udp --dport 2710 -j DROP
iptables -A OUTPUT -p udp --dport 51413 -j DROP
iptables -A OUTPUT -p udp --dport 16881:16889 -j DROP
iptables -A OUTPUT -p udp --dport 8881:8889 -j DROP
iptables -A OUTPUT -p udp --dport 1337 -j DROP

# 拦截入站BitTorrent流量
echo "添加入站流量拦截规则..."
# 常用BitTorrent入站端口
iptables -A INPUT -p tcp --dport 6881:6889 -j DROP
iptables -A INPUT -p udp --dport 6881:6889 -j DROP
iptables -A INPUT -p tcp --dport 51413 -j DROP
iptables -A INPUT -p udp --dport 51413 -j DROP

# 保存规则以便在重启后仍然生效
if command -v iptables-save > /dev/null; then
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || iptables-save > /etc/iptables.rules 2>/dev/null
    echo "规则已保存"
else
    echo "警告: iptables-save命令不可用，规则在重启后可能不会保留"
    echo "您可以手动运行: 'iptables-save > /etc/iptables.rules'"
fi

echo "BitTorrent拦截规则设置完成！"
