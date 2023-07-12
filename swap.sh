#!/bin/bash

# 创建交换文件
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile

# 设置开机自动加载交换文件
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

# 显示内存信息
free -h
