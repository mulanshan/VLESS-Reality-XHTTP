#!/bin/bash

# ==========================================
# VLESS-TCP-REALITY-VISION (随机端口/自定义端口版)

# 1. 检查root权限并更新系统
root() {
    if [[ ${EUID} -ne 0 ]]; then
        echo -e "\033[31m错误: 必须使用 root 权限运行此脚本！\033[0m" 1>&2
        exit 1
    fi
    
    echo "正在更新系统和安装依赖..."
    if [ -f "/usr/bin/apt-get" ]; then
        apt-get update -y
        apt-get install -y gawk curl net-tools
    else
        yum update -y
        yum install -y epel-release gawk curl net-tools
    fi
}

# 2. 设置端口 (修改重点：支持随机或自定义)
port() {    
    while true; do
        echo -e "======================================================"
        echo -e "请输入端口号 (1-65535)"
        echo -e "\033[32m直接回车 (Enter) 将生成随机高位端口 [推荐]\033[0m"
        read -p "请输入: " input_port

        if [[ -z "$input_port" ]]; then
            # 生成 10000-65000 之间的随机端口
            PORT=$((RANDOM % 55000 + 10000))
            echo -e "已选择随机端口: \033[36m$PORT\033[0m"
        else
            # 检查是否为数字
            if ! [[ "$input_port" =~ ^[0-9]+$ ]]; then
                echo -e "\033[31m错误: 请输入有效的数字！\033[0m"
                continue
            fi
            
            # 检查范围
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

# 3. 开启 BBR (新增优化：防止断流)
enable_bbr() {
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "正在开启 BBR 加速..."
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p > /dev/null 2>&1
        echo -e "\033[32mBBR 已开启。\033[0m"
    fi
}

# 4. 配置和启动Xray
xray() {
    # 安装Xray内核
    echo "正在安装 Xray 内核..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    
    # 生成所需参数
    uuid=$(/usr/local/bin/xray uuid)
    X25519Key=$(/usr/local/bin/xray x25519)
    PrivateKey=$(echo "$X25519Key" | grep -i '^PrivateKey:' | awk '{print $2}')
    PublicKey=$(echo "$X25519Key" | grep -E '^(PublicKey|Password):' | awk '{print $2}')
    shid=$(openssl rand -hex 8)

    # 定义目标网站 (防止单一目标被针对)
    DEST_SITE="www.ucla.edu"

    # 配置 config.json
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

    # 启动Xray服务
    systemctl enable xray.service && systemctl restart xray.service
    sleep 3
    if ! systemctl is-active --quiet xray.service; then
        echo -e "\033[31mXray 启动失败，请检查配置文件格式。\033[0m"
        exit 1
    fi
    
    # 获取IP
    HOST_IP=$(curl -s -4 http://www.cloudflare.com/cdn-cgi/trace | grep "ip" | awk -F "[=]" '{print $2}')
    if [[ -z "${HOST_IP}" ]]; then
        HOST_IP=$(curl -s -6 http://www.cloudflare.com/cdn-cgi/trace | grep "ip" | awk -F "[=]" '{print $2}')
    fi
    
    # 获取IP所在国家
    IP_COUNTRY=$(curl -s http://ipinfo.io/${HOST_IP}/country)
    
    # 生成链接
    # 注意：Reality 的 SNI 依然是 www.ucla.edu，但连接端口变成了你的自定义端口
    LINK="vless://${uuid}@${HOST_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST_SITE}&fp=chrome&pbk=${PublicKey}&sid=${shid}&type=tcp&headerType=none#${IP_COUNTRY}_Vision_Port${PORT}"

    # 输出结果
    echo "$LINK" > /usr/local/etc/xray/config.txt

    echo ""
    echo "======================================================"
    echo -e "\033[32m      Xray 安装完成 (Reality + Vision)\033[0m"
    echo "======================================================"
    echo "地址 (IP):      ${HOST_IP}"
    echo "端口 (Port):    ${PORT}"
    echo "用户ID (UUID):  ${uuid}"
    echo "流控 (Flow):    xtls-rprx-vision"
    echo "伪装域名 (SNI): ${DEST_SITE}"
    echo "ShortId:        ${shid}"
    echo "======================================================"
    echo "🚀 客户端连接链接 (复制下方内容):"
    echo ""
    echo -e "\033[33m${LINK}\033[0m"
    echo ""
    echo "======================================================"
}

# 主函数
main() {
    root
    port
    enable_bbr
    xray
}

# 执行脚本
main
