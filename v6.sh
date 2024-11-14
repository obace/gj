#!/bin/bash

# 禁用 IPv6 的 sysctl 配置
echo "禁用 IPv6...更新 sysctl 配置文件"
echo "net.ipv6.conf.all.disable_ipv6 = 1" | sudo tee -a /etc/sysctl.conf > /dev/null
echo "net.ipv6.conf.default.disable_ipv6 = 1" | sudo tee -a /etc/sysctl.conf > /dev/null
echo "net.ipv6.conf.lo.disable_ipv6 = 1" | sudo tee -a /etc/sysctl.conf > /dev/null

# 使 sysctl 配置生效
sudo sysctl -p

# 禁用 IPv6 模块
echo "禁用 IPv6 模块..."
echo "blacklist ipv6" | sudo tee -a /etc/modprobe.d/blacklist.conf > /dev/null

# 重启网络服务（如果适用）
echo "重启网络服务..."
if systemctl is-active --quiet NetworkManager; then
    sudo systemctl restart NetworkManager
elif systemctl is-active --quiet systemd-networkd; then
    sudo systemctl restart systemd-networkd
else
    echo "未找到合适的网络服务。IPv6 配置已禁用，不需要重启。"
fi

# 提示完成
echo "IPv6 已成功禁用！"
