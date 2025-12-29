#!/bin/bash

# ==========================================
# VLESS-TCP-REALITY-VISION (Loon/Surge/Shadowrocket 全兼容版)
# ==========================================

# --- 1. 环境检查与依赖安装 ---
root() {
    if [[ ${EUID} -ne 0 ]]; then
        echo -e "\033[31m错误: 必须使用 root 权限运行此脚本！\033[0m" 1>&2
        exit 1
    fi
    
    echo "正在检查并更新系统依赖..."
    if [ -f "/usr/bin/apt-get" ]; then
        apt-get update -y
        apt-get install -y gawk curl net-tools openssl
    else
        yum update -y
        yum install -y epel-release gawk curl net-tools openssl
    fi
}

# --- 2. 端口设置 (自动/手动) ---
port() {    
    while true; do
        echo -e "======================================================"
        echo -e "请输入端口号 (1-65535)"
        echo -e "\033[32m直接回车 (Enter) 将生成随机高位端口 [推荐]\033[0m"
        read -p "请输入: " input_port

        if [[ -z "$input_port" ]]; then
            # 生成 10000-55000 之间的随机端口
            PORT=$((RANDOM % 45000 + 10000))
            echo -e "已选择随机端口: \033[36m$PORT\033[0m"
        else
            if ! [[ "$input_port" =~ ^[0-9]+$ ]]; then
                echo -e "\033[31m错误: 请输入有效的数字！\033[0m"
                continue
            fi
            if [[ "$input_port" -lt 1 || "$input_port" -gt 65535 ]]; then
                echo -e "\033[31m错误: 端口范围必须在 1-65535 之间！\033[0m"
                continue
            fi
            PORT=$input_port
            echo -e "已选择自定义端口: \033[36m$PORT\033[0m"
        fi

        # 检查端口占用
        if ss -ltn | grep -q ":$PORT "; then
            echo -e "\033[31m错误: 端口 $PORT 已被占用，请重新选择！\033[0m"
        else
            echo -e "\033[32m端口 $PORT 可用，验证通过。\033[0m"
            break
        fi
    done
}

# --- 3. BBR 加速 ---
enable_bbr() {
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "正在开启 BBR 加速..."
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p > /dev/null 2>&1
        echo -e "\033[32mBBR 已开启。\033[0m"
    fi
}

# --- 4. 防火墙自动放行 (关键步骤) ---
open_firewall() {
    echo "正在尝试自动放行防火墙端口: $PORT ..."
    # 检测 UFW (Debian/Ubuntu 常用)
    if command -v ufw >/dev/null 2>&1; then
        ufw allow $PORT/tcp >/dev/null 2>&1
        ufw reload >/dev/null 2>&1
        echo -e "\033[32mUFW 防火墙规则已添加。\033[0m"
    # 检测 Firewalld (CentOS 常用)
    elif command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --zone=public --add-port=$PORT/tcp --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        echo -e "\033[32mFirewalld 防火墙规则已添加。\033[0m"
    # 检测 iptables
    elif command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT -p tcp --dport $PORT -j ACCEPT
        echo -e "\033[32mIptables 规则已添加。\033[0m"
    fi
}

# --- 5. 安装与配置 Xray ---
xray() {
    echo "正在下载并安装 Xray 内核..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    
    # 生成 Reality 所需参数
    uuid=$(/usr/local/bin/xray uuid)
    X25519Key=$(/usr/local/bin/xray x25519)
    PrivateKey=$(echo "$X25519Key" | grep -i '^PrivateKey:' | awk '{print $2}')
    PublicKey=$(echo "$X25519Key" | grep -E '^(PublicKey|Password):' | awk '{print $2}')
    # 生成 4字节(8字符)的 ShortId
    shid=$(openssl rand -hex 4)

    # 伪装域名 (可修改为 learn.microsoft.com 或 www.apple.com)
    DEST_SITE="www.ucla.edu"

    # 写入配置文件
    cat >/usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": ${PORT},
      "tag": "vless-tcp",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "target": "${DEST_SITE}:443",
          "serverNames": [
            "${DEST_SITE}"
          ],
          "privateKey": "${PrivateKey}",
          "shortIds": [
            "${shid}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF

    # 重启服务
    systemctl enable xray.service && systemctl restart xray.service
    sleep 2
    if ! systemctl is-active --quiet xray.service; then
        echo -e "\033[31m错误：Xray 启动失败！请检查配置文件。\033[0m"
        exit 1
    fi
    
    # 执行防火墙放行
    open_firewall

    # 获取本机外网IP
    HOST_IP=$(curl -s -4 http://www.cloudflare.com/cdn-cgi/trace | grep "ip" | awk -F "[=]" '{print $2}')
    if [[ -z "${HOST_IP}" ]]; then
        HOST_IP=$(curl -s -6 http://www.cloudflare.com/cdn-cgi/trace | grep "ip" | awk -F "[=]" '{print $2}')
    fi
    
    # 获取IP地理位置
    IP_COUNTRY=$(curl -s http://ipinfo.io/${HOST_IP}/country)
    
    # ----------------------------------------------------------------------
    # 生成链接：Shadowrocket / v2rayN 格式
    # ----------------------------------------------------------------------
    LINK="vless://${uuid}@${HOST_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST_SITE}&fp=chrome&pbk=${PublicKey}&sid=${shid}&type=tcp&headerType=none#${IP_COUNTRY}_Vision"

    # ----------------------------------------------------------------------
    # 生成链接：Loon 专用配置格式
    # ----------------------------------------------------------------------
    LOON_TAG="${IP_COUNTRY}_Vision"
    # Loon 格式说明: 别名 = vless, IP, 端口, UUID, transport=tcp, flow=vision, security=reality, ...
    LOON_LINK="${LOON_TAG} = vless, ${HOST_IP}, ${PORT}, ${uuid}, transport=tcp, flow=xtls-rprx-vision, security=reality, public-key=${PublicKey}, short-id=${shid}, server-name=${DEST_SITE}, fingerprint=chrome"

    # 保存信息到文件备查
    echo -e "--- Shadowrocket ---\n$LINK\n\n--- Loon ---\n$LOON_LINK" > /usr/local/etc/xray/result.txt

    # --- 最终输出 ---
    echo ""
    echo "======================================================"
    echo -e "\033[32m       Xray 安装完成 (Reality + Vision)\033[0m"
    echo "======================================================"
    echo " 地址 (IP):      ${HOST_IP}"
    echo " 端口 (Port):    ${PORT}"
    echo " UUID:           ${uuid}"
    echo " 伪装域名 (SNI): ${DEST_SITE}"
    echo " Public Key:     ${PublicKey}"
    echo " ShortId:        ${shid}"
    echo "======================================================"
    echo ""
    echo -e "🚀 \033[33m[方案 A] Shadowrocket (小火箭) / v2rayN 专用:\033[0m"
    echo "------------------------------------------------------"
    echo -e "\033[36m${LINK}\033[0m"
    echo "------------------------------------------------------"
    echo "(直接复制上方链接，小火箭会自动识别)"
    echo ""
    echo -e "🎈 \033[33m[方案 B] Loon 专用配置行 (推荐):\033[0m"
    echo "------------------------------------------------------"
    echo -e "\033[35m${LOON_LINK}\033[0m"
    echo "------------------------------------------------------"
    echo "(复制上方紫色的整行 -> Loon -> 配置 -> 节点 -> 添加 -> 手动输入)"
    echo ""
    echo "======================================================"
    echo -e "\033[31m注意：如果连不上，请务必去云服务商网页控制台(安全组)放行端口: ${PORT}\033[0m"
}

# 运行主程序
main() {
    root
    port
    enable_bbr
    xray
}

main
