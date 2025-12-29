#!/bin/bash

# ==========================================
# VLESS-TCP-REALITY-VISION (含终端二维码输出)
# ==========================================

# --- 1. 环境检查与依赖安装 ---
root() {
    if [[ ${EUID} -ne 0 ]]; then
        echo -e "\033[31m错误: 必须使用 root 权限运行此脚本！\033[0m" 1>&2
        exit 1
    fi
    
    echo "正在检查并更新系统依赖 (含二维码工具)..."
    if [ -f "/usr/bin/apt-get" ]; then
        apt-get update -y
        # 新增 qrencode 依赖
        apt-get install -y gawk curl net-tools openssl qrencode
    else
        yum update -y
        yum install -y epel-release gawk curl net-tools openssl qrencode
    fi
}

# --- 2. 端口设置 ---
port() {    
    while true; do
        echo -e "======================================================"
        echo -e "请输入端口号 (1-65535)"
        echo -e "\033[32m直接回车 (Enter) 将生成随机高位端口 [推荐]\033[0m"
        read -p "请输入: " input_port

        if [[ -z "$input_port" ]]; then
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
    fi
}

# --- 4. 防火墙自动放行 ---
open_firewall() {
    echo "正在尝试自动放行防火墙端口: $PORT ..."
    if command -v ufw >/dev/null 2>&1; then
        ufw allow $PORT/tcp >/dev/null 2>&1
        ufw reload >/dev/null 2>&1
    elif command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --zone=public --add-port=$PORT/tcp --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    elif command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT -p tcp --dport $PORT -j ACCEPT
    fi
}

# --- 5. 安装与配置 Xray ---
xray() {
    # 如果已经安装过，跳过下载，仅覆盖配置
    if [ ! -f "/usr/local/bin/xray" ]; then
        echo "正在下载并安装 Xray 内核..."
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    fi
    
    uuid=$(/usr/local/bin/xray uuid)
    X25519Key=$(/usr/local/bin/xray x25519)
    PrivateKey=$(echo "$X25519Key" | grep -i '^PrivateKey:' | awk '{print $2}')
    PublicKey=$(echo "$X25519Key" | grep -E '^(PublicKey|Password):' | awk '{print $2}')
    shid=$(openssl rand -hex 4)
    DEST_SITE="www.ucla.edu"

    cat >/usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": ${PORT},
      "tag": "vless-tcp",
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${uuid}", "flow": "xtls-rprx-vision" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "target": "${DEST_SITE}:443",
          "serverNames": [ "${DEST_SITE}" ],
          "privateKey": "${PrivateKey}",
          "shortIds": [ "${shid}" ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [ "http", "tls", "quic" ]
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF

    systemctl enable xray.service && systemctl restart xray.service
    sleep 2
    open_firewall

    HOST_IP=$(curl -s -4 http://www.cloudflare.com/cdn-cgi/trace | grep "ip" | awk -F "[=]" '{print $2}')
    if [[ -z "${HOST_IP}" ]]; then
        HOST_IP=$(curl -s -6 http://www.cloudflare.com/cdn-cgi/trace | grep "ip" | awk -F "[=]" '{print $2}')
    fi
    IP_COUNTRY=$(curl -s http://ipinfo.io/${HOST_IP}/country)
    
    # 生成标准链接
    LINK="vless://${uuid}@${HOST_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST_SITE}&fp=chrome&pbk=${PublicKey}&sid=${shid}&type=tcp&headerType=none#${IP_COUNTRY}_Vision"
    
    # 生成 Loon 链接
    LOON_TAG="${IP_COUNTRY}_Vision"
    LOON_LINK="${LOON_TAG} = vless, ${HOST_IP}, ${PORT}, ${uuid}, transport=tcp, flow=xtls-rprx-vision, security=reality, public-key=${PublicKey}, short-id=${shid}, server-name=${DEST_SITE}, fingerprint=chrome"

    # --- 输出信息 ---
    echo ""
    echo "======================================================"
    echo -e "\033[32m       Xray 安装完成 \033[0m"
    echo "======================================================"
    echo -e "🚀 \033[33mShadowrocket / v2rayN 链接:\033[0m"
    echo -e "\033[36m${LINK}\033[0m"
    echo ""
    echo -e "🎈 \033[33mLoon 专用配置行:\033[0m"
    echo -e "\033[35m${LOON_LINK}\033[0m"
    echo ""
    echo "======================================================"
    echo -e "\033[32m👇 下面是生成的二维码 (请直接扫码) 👇\033[0m"
    echo "======================================================"
    
    # 核心：使用 qrencode 在终端输出二维码
    qrencode -t ANSIUTF8 "${LINK}"
    
    echo "======================================================"
    echo ""
}

main() {
    root
    port
    enable_bbr
    xray
}

main
