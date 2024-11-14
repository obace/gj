#!/bin/bash

# 禁用 IPv6 的 sysctl 配置
echo "禁用 IPv6...更新 sysctl 配置文件"
echo "net.ipv6.conf.all.disable_ipv6 = 1" | sudo tee -a /etc/sysctl.conf > /dev/null
echo "net.ipv6.conf.default.disable_ipv6 = 1" | sudo tee -a /etc/sysctl.conf > /dev/null
echo "net.ipv6.conf.lo.disable_ipv6 = 1" | sudo tee -a /etc/sysctl.conf > /dev/null

# 使 sysctl 配置生效
sudo sysctl -p

# 提示完成
echo "IPv6 已成功禁用！"
