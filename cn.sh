#!/bin/bash

# GeoIP Filter Setup Script for nftables
# Author: AI Assistant based on user request
# Updated: 2025-04-01 (To handle inactive/disabled nftables service)

# --- 配置变量 ---
NFT_CONFIG_FILE="/etc/nftables.conf"
BACKUP_FILE="/etc/nftables.conf.bak.$(date +%Y%m%d%H%M%S)"
CHINA_IPV4_URL="https://raw.githubusercontent.com/misakaio/chnroutes2/master/chnroutes.txt"
CHINA_IPV6_URL="https://raw.githubusercontent.com/misakaio/chnroutes2/master/chnroutes.ipv6.txt"
TEMP_IPV4_LIST=$(mktemp)
TEMP_IPV6_LIST=$(mktemp)

# --- 清理函数 ---
cleanup() {
    echo "清理临时文件..."
    rm -f "$TEMP_IPV4_LIST" "$TEMP_IPV6_LIST"
}
trap cleanup EXIT

# --- 检查依赖 (已更新) ---
check_deps() {
    echo "检查依赖..."
    local missing_deps=()
    for cmd in curl nft; do
        if ! command -v $cmd &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done

    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo "错误：缺少以下依赖: ${missing_deps[*]}"
        echo "尝试自动安装..."
        # 先更新apt缓存，防止找不到包
        sudo apt update
        sudo apt install -y curl nftables
        # 安装后重新检查
        for cmd in curl nft; do
            if ! command -v $cmd &> /dev/null; then
                 echo "错误：安装依赖 $cmd 失败。请手动安装后重试。"
                 exit 1
            fi
        done
    fi
    echo "命令依赖检查通过 (curl, nft)。"

    echo "检查 nftables 服务状态..."
    # 优先使用 is-active 检查是否正在运行
    if systemctl is-active --quiet nftables.service; then
        echo "nftables 服务已在运行。"
        # 检查是否开机自启
        if ! systemctl is-enabled --quiet nftables.service; then
             echo "nftables 服务未设置为开机自启，尝试启用..."
             # 尝试启用，忽略错误，因为服务已在运行
             sudo systemctl enable nftables.service &> /dev/null || echo "警告：设置 nftables 开机自启失败，请手动检查。"
        fi
        return 0 # 服务正在运行，可以继续
    fi

    # 如果服务未运行，进一步判断状态
    echo "nftables 服务当前未运行。"

    # 检查服务是否存在 (loaded)
    if ! systemctl status nftables.service &> /dev/null; then
        echo "错误：nftables.service 单元文件不存在或 systemctl 无法查询。"
        echo "尝试重新安装 nftables..."
        sudo apt update && sudo apt --reinstall install nftables
        echo "请重新运行此脚本。"
        exit 1
    fi

    # 检查是否被屏蔽 (masked)
    if systemctl is-enabled nftables.service | grep -q 'masked'; then
        echo "nftables 服务被屏蔽 (masked)，尝试解除屏蔽..."
        sudo systemctl unmask nftables.service
        if systemctl is-enabled nftables.service | grep -q 'masked'; then
            echo "错误：解除屏蔽 nftables 服务失败。请手动检查。"
            exit 1
        else
            echo "解除屏蔽成功。"
        fi
    fi

    # 尝试启用服务 (设置为开机自启)
    # 即使已经是 enabled 状态，再次执行也无害
    echo "尝试启用 nftables 服务 (设置开机自启)..."
    sudo systemctl enable nftables.service
    # 检查是否启用成功 (除非是 masked)
     if ! systemctl is-enabled --quiet nftables.service && ! systemctl is-enabled nftables.service | grep -q 'masked'; then
         echo "警告：启用 nftables 服务失败，请手动检查。脚本将继续尝试启动..."
         # 可能只是警告，继续尝试启动
    else
         echo "启用服务设置成功或已启用。"
    fi

    # 尝试启动服务
    echo "尝试启动 nftables 服务..."
    sudo systemctl start nftables.service
    # 等待一小会儿，给服务启动时间
    sleep 2

    # 最终检查服务是否已运行
    if systemctl is-active --quiet nftables.service; then
        echo "nftables 服务启动成功。"
        return 0 # 服务现在正在运行
    else
        echo "错误：启动 nftables 服务失败。"
        echo "这通常是由于配置文件 (/etc/nftables.conf) 错误或系统问题导致的。"
        echo "请手动检查服务状态和日志获取详细错误信息："
        echo "  sudo systemctl status nftables.service"
        echo "  sudo journalctl -u nftables.service -n 50 --no-pager"
        echo "修复问题后，再重新运行此脚本。"
        exit 1
    fi
}


# --- 获取用户输入 ---
get_user_input() {
    echo "--- 用户输入 ---"
    read -p "请输入 VLESS 使用的 TCP 端口 (多个端口用逗号分隔, e.g., 443,8443): " VLESS_TCP_PORTS
    read -p "请输入 Hysteria2 使用的 UDP 端口 (多个端口用逗号分隔, e.g., 12345,23456): " HY2_UDP_PORTS
    read -p "请输入你的 SSH 端口 (默认 22): " SSH_PORT
    SSH_PORT=${SSH_PORT:-22} # Default to 22 if empty
    read -p "是否需要启用 IPv6 限制? (y/N): " ENABLE_IPV6

    # 验证端口输入 (简单验证)
    if [[ -z "$VLESS_TCP_PORTS" && -z "$HY2_UDP_PORTS" ]]; then
        echo "错误：至少需要输入 VLESS 或 Hysteria2 的端口。"
        exit 1
    fi
    if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]]; then
        echo "错误：SSH 端口必须是数字。"
        exit 1
    fi
    # 将逗号分隔的端口转换为 nftables set 格式 { port1, port2 }
    VLESS_TCP_PORTS_SET=$(echo "$VLESS_TCP_PORTS" | tr ',' '\n' | awk 'NF' | paste -sd,)
    HY2_UDP_PORTS_SET=$(echo "$HY2_UDP_PORTS" | tr ',' '\n' | awk 'NF' | paste -sd,)

    echo "--- 配置确认 ---"
    echo "VLESS TCP 端口: ${VLESS_TCP_PORTS_SET:-无}"
    echo "Hysteria2 UDP 端口: ${HY2_UDP_PORTS_SET:-无}"
    echo "SSH 端口: $SSH_PORT"
    echo "启用 IPv6: ${ENABLE_IPV6,,}" # Show lowercase y/n
    read -p "确认以上信息并继续? (y/N): " CONFIRM
    if [[ "${CONFIRM,,}" != "y" ]]; then
        echo "操作已取消。"
        exit 0
    fi
}

# --- 下载 GeoIP 列表 ---
download_ip_lists() {
    echo "--- 下载中国 IP 地址列表 ---"
    echo "下载 IPv4 列表..."
    if ! curl -sfL "$CHINA_IPV4_URL" -o "$TEMP_IPV4_LIST"; then
        echo "错误：下载 IPv4 列表失败。请检查网络连接或 URL ($CHINA_IPV4_URL)"
        exit 1
    fi
    # 检查下载的文件是否为空
    if [ ! -s "$TEMP_IPV4_LIST" ]; then
        echo "错误：下载的 IPv4 列表文件为空。请检查源 URL。"
        exit 1
    fi
    echo "IPv4 列表下载完成。"

    if [[ "${ENABLE_IPV6,,}" == "y" ]]; then
        echo "下载 IPv6 列表..."
        if ! curl -sfL "$CHINA_IPV6_URL" -o "$TEMP_IPV6_LIST"; then
            echo "错误：下载 IPv6 列表失败。请检查网络连接或 URL ($CHINA_IPV6_URL)"
            # 不强制退出，可能用户只需要IPv4
            ENABLE_IPV6="n"
            echo "警告：将禁用 IPv6 限制。"
        elif [ ! -s "$TEMP_IPV6_LIST" ]; then
            echo "错误：下载的 IPv6 列表文件为空。请检查源 URL。"
            ENABLE_IPV6="n"
            echo "警告：将禁用 IPv6 限制。"
        else
            echo "IPv6 列表下载完成。"
        fi
    fi
}

# --- 生成并应用 nftables 规则 ---
apply_nft_rules() {
    echo "--- 生成并应用 nftables 规则 ---"

    # 备份现有配置
    if [ -f "$NFT_CONFIG_FILE" ]; then
        echo "备份当前 nftables 配置到 $BACKUP_FILE ..."
        sudo cp "$NFT_CONFIG_FILE" "$BACKUP_FILE" || { echo "错误：备份失败！"; exit 1; }
    else
        echo "注意：未找到现有的 $NFT_CONFIG_FILE 文件。将创建新文件。"
    fi

    echo "正在生成新的 nftables 配置文件..."

    # --- 开始生成 nftables 配置 ---
    # 使用 cat 和 EOF 来创建整个文件内容
    # Important: Ensure the final EOF is at the beginning of the line with no leading spaces.
    sudo bash -c "cat > $NFT_CONFIG_FILE" << EOF
#!/usr/sbin/nft -f

# Generated by setup_geoip_filter.sh script

flush ruleset

table inet filter {
    # Define China IP sets
    set china_ipv4 {
        type ipv4_addr
        flags interval
        # Auto-add elements from the downloaded list
        elements = {
$(cat "$TEMP_IPV4_LIST" | sed 's/$/,/')
        }
    }
EOF

    # Add IPv6 set definition if enabled
    if [[ "${ENABLE_IPV6,,}" == "y" ]]; then
    sudo bash -c "cat >> $NFT_CONFIG_FILE" << EOF
    set china_ipv6 {
        type ipv6_addr
        flags interval
        elements = {
$(cat "$TEMP_IPV6_LIST" | sed 's/$/,/')
        }
    }
EOF
    fi

    # Add input chain definition
    sudo bash -c "cat >> $NFT_CONFIG_FILE" << EOF
    # Define main input chain
    chain input {
        type filter hook input priority 0; policy drop; # Default policy: drop for security

        # Basic stateful filtering and loopback
        iifname lo accept comment "Allow loopback traffic"
        ct state related,established accept comment "Allow established/related connections"
        ct state invalid drop comment "Drop invalid packets"

        # Allow ICMP (Ping, etc.) - adjust if needed
        ip protocol icmp accept comment "Allow IPv4 ICMP"
        ip6 nexthdr ipv6-icmp accept comment "Allow IPv6 ICMPv6"

        # --- IMPORTANT: Allow SSH access ---
        tcp dport $SSH_PORT accept comment "Allow SSH access"

EOF

    # Add VLESS TCP rules if ports were provided
    if [ -n "$VLESS_TCP_PORTS_SET" ]; then
        sudo bash -c "cat >> $NFT_CONFIG_FILE" << EOF
        # Allow VLESS TCP from China IPs
        ip saddr @china_ipv4 tcp dport { $VLESS_TCP_PORTS_SET } accept comment "Allow VLESS TCP from China IPv4"
EOF
        if [[ "${ENABLE_IPV6,,}" == "y" ]]; then
            sudo bash -c "cat >> $NFT_CONFIG_FILE" << EOF
        ip6 saddr @china_ipv6 tcp dport { $VLESS_TCP_PORTS_SET } accept comment "Allow VLESS TCP from China IPv6"
EOF
        fi
    fi

    # Add Hysteria2 UDP rules if ports were provided
    if [ -n "$HY2_UDP_PORTS_SET" ]; then
        sudo bash -c "cat >> $NFT_CONFIG_FILE" << EOF
        # Allow Hysteria2 UDP from China IPs
        ip saddr @china_ipv4 udp dport { $HY2_UDP_PORTS_SET } accept comment "Allow Hy2 UDP from China IPv4"
EOF
        if [[ "${ENABLE_IPV6,,}" == "y" ]]; then
            sudo bash -c "cat >> $NFT_CONFIG_FILE" << EOF
        ip6 saddr @china_ipv6 udp dport { $HY2_UDP_PORTS_SET } accept comment "Allow Hy2 UDP from China IPv6"
EOF
        fi
    fi

    # End input chain and filter table
    sudo bash -c "cat >> $NFT_CONFIG_FILE" << EOF
        # --- End of specific rules ---
        # Packets not matching any rule above will be dropped by the default policy
    }

    # Define basic forward and output chains (adjust policies if needed)
    # chain forward {
    #     type filter hook forward priority 0; policy drop;
    # }
    #
    # chain output {
    #     type filter hook output priority 0; policy accept; # Allow all outgoing traffic by default
    # }
} # End of table inet filter
EOF
    # --- nftables 配置生成结束 ---

    echo "配置文件 $NFT_CONFIG_FILE 已生成。"
    echo "内容预览 (前 20 行和后 10 行):"
    sudo head -n 20 "$NFT_CONFIG_FILE"
    echo "..."
    sudo tail -n 10 "$NFT_CONFIG_FILE"
    echo "---"


    # 检查配置文件语法
    echo "检查 nftables 配置语法..."
    if ! sudo nft -c -f "$NFT_CONFIG_FILE"; then
        echo "错误：新的 nftables 配置文件语法检查失败！"
        echo "规则未应用。请检查 $NFT_CONFIG_FILE 文件。"
        echo "你可以尝试使用 'sudo nft -c -f $NFT_CONFIG_FILE' 手动检查。"
        # 尝试恢复备份
        if [ -f "$BACKUP_FILE" ]; then
            echo "尝试恢复备份 $BACKUP_FILE ..."
            sudo cp "$BACKUP_FILE" "$NFT_CONFIG_FILE" && echo "备份已恢复。" || echo "错误：恢复备份失败！"
        fi
        exit 1
    fi
    echo "语法检查通过。"

    # 应用规则并重启服务
    echo "应用新的 nftables 规则..."
    if ! sudo systemctl restart nftables; then
        echo "错误：重启 nftables 服务失败！规则可能未完全应用。"
        echo "请检查服务状态：'sudo systemctl status nftables' 和日志 'sudo journalctl -u nftables'"
        # 再次尝试恢复备份
        if [ -f "$BACKUP_FILE" ]; then
             echo "尝试恢复备份 $BACKUP_FILE ..."
             sudo cp "$BACKUP_FILE" "$NFT_CONFIG_FILE"
             sudo systemctl restart nftables && echo "备份已恢复并加载。" || echo "错误：恢复备份失败！请手动干预！"
        fi
        exit 1
    fi

    echo "nftables 规则已成功应用。"
    echo "旧配置备份在: $BACKUP_FILE"
}

# --- 主逻辑 ---
main() {
    echo "--- GeoIP 防火墙配置脚本 ---"
    check_deps
    get_user_input
    download_ip_lists
    apply_nft_rules

    echo ""
    echo "--- 完成 ---"
    echo "GeoIP 防火墙规则已配置完成。"
    echo "重要提示:"
    echo "1. 如果遇到连接问题 (包括 SSH)，请先尝试恢复备份: "
    echo "   sudo cp $BACKUP_FILE $NFT_CONFIG_FILE && sudo systemctl restart nftables"
    echo "   如果无法 SSH，请使用服务器提供商的控制台/VNC 操作。"
    echo "2. IP 地址列表会变化，你需要定期更新。建议设置 Cron 任务每月重新运行此脚本来更新列表和规则。"
    echo "3. 当前配置的默认入站策略是 DROP，仅明确允许的流量 (SSH, 相关连接, ICMP, 以及来自中国的 VLESS/Hy2 流量) 可通过。"
}

# --- 运行主函数 ---
main

exit 0
