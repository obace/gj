#!/bin/bash

# 检测是否存在虚拟内存
if grep -q '/swapfile' /etc/fstab; then
    echo "虚拟内存已存在，脚本终止运行。"
    exit 0
fi

# 创建交换文件
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile

# 设置开机自动加载交换文件
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

# 显示内存信息
free -h
