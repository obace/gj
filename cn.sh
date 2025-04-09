#!/bin/bash

# GeoIP Filter Setup Script for nftables (IPv4 Only)
# Author: AI Assistant based on user request
# Updated: 2025-04-10 (Fixed IP list parsing by filtering comments/blanks)
# Previous Update: 2025-04-05 (Added Hy2 port auto-detection, Improved service check, Removed IPv6)

# --- 配置变量 ---
NFT_CONFIG_FILE="/etc/nftables.conf"
BACKUP_FILE="/etc/nftables.conf.bak.$(date +%Y%m%d%H%M%S)"
CHINA_IPV4_URL="https://raw.githubusercontent.com/misakaio/chnroutes2/master/chnroutes.txt"
TEMP_IPV4_LIST=$(mktemp)

# --- 清理函数 ---
cleanup() {
    echo "清理临时文件..."
    rm -f "$TEMP_IPV4_LIST"
}
trap cleanup EXIT

# --- 检查依赖 (包含 nftables 服务检查与启动逻辑) ---
check_deps() {
    echo "检查依赖..."
    local missing_deps=()
    for cmd in curl nft grep awk sed head; do # Added tools used for parsing
        if ! command -v $cmd &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done

    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo "错误：缺少以下依赖: ${missing_deps[*]}"
        echo "尝试自动安装..."
        # Might need to install specific packages like gawk depending on minimal install
        # Assuming Debian/Ubuntu based system for apt
        sudo apt update
        sudo apt install -y curl nftables grep gawk sed # Ensure gawk is installed for robust awk
        for cmd in curl nft grep awk sed head; do
            if ! command -v $cmd &> /dev/null; then
                echo "错误：安装依赖 $cmd 失败。请手动安装后重试。"
                exit 1
            fi
        done
    fi
    echo "命令依赖检查通过 (curl, nft, grep, awk, sed, head)。" # Updated message

    echo "检查 nftables 服务状态..."
    if systemctl is-active --quiet nftables.service; then
        echo "nftables 服务已在运行。"
        if ! systemctl is-enabled --quiet nftables.service; then
            echo "nftables 服务未设置为开机自启，尝试启用..."
            sudo systemctl enable nftables.service &> /dev/null || echo "警告：设置 nftables 开机自启失败，请手动检查。"
        fi
        return 0 # 服务正在运行
    fi

    # 如果服务未运行，检查单元文件是否存在
    echo "nftables 服务当前未运行。"
    if ! systemctl cat nftables.service &> /dev/null; then
        echo "错误：无法找到 nftables.service 单元文件。服务可能未正确安装。"
        echo "尝试重新安装 nftables..."
        sudo apt update
        sudo apt --reinstall install -y nftables
        if ! systemctl cat nftables.service &> /dev/null; then
             echo "错误：重新安装后仍然找不到 nftables.service 单元文件。请手动检查安装。"
             exit 1
        else
             echo "重新安装似乎已添加服务文件，继续尝试启动..."
        fi
    fi

    # --- 现在处理服务存在但未运行的情况 (或刚重装成功) ---
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

    echo "尝试启用 nftables 服务 (设置开机自启)..."
    sudo systemctl enable nftables.service
    if ! systemctl is-enabled --quiet nftables.service && ! systemctl is-enabled nftables.service | grep -q 'masked'; then
        echo "警告：启用 nftables 服务失败，请手动检查。脚本将继续尝试启动..."
    else
        echo "启用服务设置成功或已启用。"
    fi

    echo "尝试启动 nftables 服务..."
    sudo systemctl start nftables.service
    sleep 2

    if systemctl is-active --quiet nftables.service; then
        echo "nftables 服务启动成功。"
        return 0
    else
        echo "错误：启动 nftables 服务失败。"
        echo "请手动检查服务状态和日志："
        echo "  sudo systemctl status nftables.service"
        echo "  sudo journalctl -u nftables.service -n 50 --no-pager"
        exit 1
    fi
}

# --- 获取用户输入 ---
get_user_input() {
    echo "--- 用户输入 ---"
    read -p "请输入 VLESS 使用的 TCP 端口 (多个端口用逗号分隔, e.g., 443,8443): " VLESS_TCP_PORTS

    # --- Hysteria2 端口自动检测 ---
    HY2_CONFIG_FILE="/etc/hysteria/config.yaml"
    DETECTED_HY2_PORT=""
    HY2_UDP_PORTS="" # 初始化变量

    if [ -f "$HY2_CONFIG_FILE" ]; then
        echo "检测到 Hysteria2 配置文件: $HY2_CONFIG_FILE"
        # 尝试从 'listen:' 行提取端口号 (取最后一个冒号后的数字)
        DETECTED_HY2_PORT=$(grep -E '^\s*listen:' "$HY2_CONFIG_FILE" | awk -F: '{print $NF}' | grep -o '[0-9]\+' | head -n 1)

        if [[ "$DETECTED_HY2_PORT" =~ ^[0-9]+$ ]]; then
            echo "成功自动检测到 Hysteria2 UDP 端口: $DETECTED_HY2_PORT"
            HY2_UDP_PORTS=$DETECTED_HY2_PORT # 使用检测到的端口
        else
            echo "未能从配置文件中自动检测到有效的 Hysteria2 端口。"
            DETECTED_HY2_PORT="" # 清空检测变量，以便后续提示用户输入
        fi
    else
        echo "未找到 Hysteria2 配置文件: $HY2_CONFIG_FILE"
    fi

    # 如果自动检测失败或未找到配置文件，则要求用户输入
    if [ -z "$DETECTED_HY2_PORT" ]; then
        read -p "请输入 Hysteria2 使用的 UDP 端口 (多个端口用逗号分隔, e.g., 12345): " HY2_UDP_PORTS
    fi
    # --- Hysteria2 端口处理结束 ---

    read -p "请输入你的 SSH 端口 (默认 22): " SSH_PORT
    SSH_PORT=${SSH_PORT:-22} # Default to 22 if empty

    # 验证端口输入 (简单验证)
    if [[ -z "$VLESS_TCP_PORTS" && -z "$HY2_UDP_PORTS" ]]; then
        echo "错误：至少需要输入 VLESS TCP 端口或 Hysteria2 UDP 端口。"
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
    echo "防火墙将只限制 IPv4 流量。"
    read -p "确认以上信息并继续? (y/N): " CONFIRM
    if [[ "${CONFIRM,,}" != "y" ]]; then
        echo "操作已取消。"
        exit 0
    fi
}

# --- 下载 GeoIP 列表 ---
download_ip_lists() {
    echo "--- 下载中国 IPv4 地址列表 ---"
    if ! curl -sfL "$CHINA_IPV4_URL" -o "$TEMP_IPV4_LIST"; then
        echo "错误：下载 IPv4 列表失败。请检查网络连接或 URL ($CHINA_IPV4_URL)"
        exit 1
    fi
    if [ ! -s "$TEMP_IPV4_LIST" ]; then
        echo "错误：下载的 IPv4 列表文件为空。请检查源 URL。"
        exit 1
    fi
    echo "IPv4 列表下载完成。"
}

# --- 生成并应用 nftables 规则 ---
apply_nft_rules() {
    echo "--- 生成并应用 nftables 规则 ---"

    if [ -f "$NFT_CONFIG_FILE" ]; then
        echo "备份当前 nftables 配置到 $BACKUP_FILE ..."
        sudo cp "$NFT_CONFIG_FILE" "$BACKUP_FILE" || { echo "错误：备份失败！"; exit 1; }
    else
        echo "注意：未找到现有的 $NFT_CONFIG_FILE 文件。将创建新文件。"
    fi

    echo "正在生成新的 nftables 配置文件..."

    # --- 开始生成 nftables 配置 ---
    sudo bash -c "cat > $NFT_CONFIG_FILE" << EOF
#!/usr/sbin/nft -f

# Generated by setup_geoip_filter.sh script (IPv4 Only)

flush ruleset

table inet filter {
    set china_ipv4 {
        type ipv4_addr
        flags interval
        elements = {
# ***** 修改处 ***** : 使用 grep 过滤掉注释行和空行
$(grep -Ev '^#|^$' "$TEMP_IPV4_LIST" | sed 's/$/,/')
# ***** 修改结束 *****
        }
    }

    chain input {
        type filter hook input priority 0; policy drop;

        iifname lo accept comment "Allow loopback traffic"
        ct state related,established accept comment "Allow established/related connections"
        ct state invalid drop comment "Drop invalid packets"
        ip protocol icmp accept comment "Allow IPv4 ICMP"
        tcp dport $SSH_PORT accept comment "Allow SSH access"

EOF

    # Add VLESS TCP rules if ports were provided
    if [ -n "$VLESS_TCP_PORTS_SET" ]; then
        sudo bash -c "cat >> $NFT_CONFIG_FILE" << EOF
        # Allow VLESS TCP from China IPv4 IPs
        ip saddr @china_ipv4 tcp dport { $VLESS_TCP_PORTS_SET } accept comment "Allow VLESS TCP from China IPv4"
EOF
    fi

    # Add Hysteria2 UDP rules if ports were provided
    if [ -n "$HY2_UDP_PORTS_SET" ]; then
        sudo bash -c "cat >> $NFT_CONFIG_FILE" << EOF
        # Allow Hysteria2 UDP from China IPv4 IPs
        ip saddr @china_ipv4 udp dport { $HY2_UDP_PORTS_SET } accept comment "Allow Hy2 UDP from China IPv4"
EOF
    fi

    # End input chain and filter table
    sudo bash -c "cat >> $NFT_CONFIG_FILE" << EOF
    } # End chain input
} # End table inet filter
EOF
    # --- nftables 配置生成结束 ---

    echo "配置文件 $NFT_CONFIG_FILE 已生成。"
    echo "内容预览 (前 20 行和后 10 行):"
    sudo head -n 20 "$NFT_CONFIG_FILE"
    echo "..."
    sudo tail -n 10 "$NFT_CONFIG_FILE"
    echo "---"

    echo "检查 nftables 配置语法..."
    if ! sudo nft -c -f "$NFT_CONFIG_FILE"; then
        echo "错误：新的 nftables 配置文件语法检查失败！"
        echo "规则未应用。请检查 $NFT_CONFIG_FILE 文件。"
        if [ -f "$BACKUP_FILE" ]; then
            echo "尝试恢复备份 $BACKUP_FILE ..."
            sudo cp "$BACKUP_FILE" "$NFT_CONFIG_FILE" && echo "备份已恢复。" || echo "错误：恢复备份失败！"
        fi
        exit 1
    fi
    echo "语法检查通过。"

    echo "应用新的 nftables 规则..."
    if ! sudo systemctl restart nftables; then
        echo "错误：重启 nftables 服务失败！规则可能未完全应用。"
        echo "请检查服务状态：'sudo systemctl status nftables' 和日志 'sudo journalctl -u nftables'"
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
    echo "--- GeoIP 防火墙配置脚本 (仅 IPv4) ---"
    check_deps
    get_user_input
    download_ip_lists
    apply_nft_rules

    echo ""
    echo "--- 完成 ---"
    echo "GeoIP 防火墙规则已配置完成 (仅 IPv4)。"
    echo "重要提示:"
    echo "1. 如果遇到连接问题 (包括 SSH)，请先尝试恢复备份: "
    echo "       sudo cp $BACKUP_FILE $NFT_CONFIG_FILE && sudo systemctl restart nftables"
    echo "    如果无法 SSH，请使用服务器提供商的控制台/VNC 操作。"
    echo "2. IP 地址列表会变化，你需要定期更新。建议设置 Cron 任务每月重新运行此脚本来更新列表和规则。"
    echo "3. 当前配置的默认入站策略是 DROP，仅明确允许的流量 (SSH, 相关连接, ICMPv4, 以及来自中国IPv4的 VLESS/Hy2 流量) 可通过。"
}

# --- 运行主函数 ---
main

exit 0
