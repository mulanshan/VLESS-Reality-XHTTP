#!/bin/bash

# ==========================================
# VLESS-TCP-REALITY-VISION 

# 检查root权限并更新系统
root() {
    if [[ ${EUID} -ne 0 ]]; then
        echo "Error: This script must be run as root!" 1>&2
        exit 1
    fi
    
    echo "正在更新系统和安装依赖..."
    if [ -f "/usr/bin/apt-get" ]; then
        apt-get update -y && apt-get upgrade -y
        apt-get install -y gawk curl net-tools
    else
        yum update -y && yum upgrade -y
        yum install -y epel-release gawk curl net-tools
    fi
}

# 设置端口为 443 (抗封锁最佳实践)
port() {    
    # 检查 443 是否被占用
    if ss -ltn | grep -q ":443 "; then
        echo "======================================================"
        echo -e "\033[31m错误: 端口 443 已经被占用！\033[0m"
        echo "请先停止占用 443 的服务 (如 Nginx/Apache) 再运行此脚本。"
        echo "命令参考: systemctl stop nginx"
        echo "======================================================"
        exit 1
    fi
    
    PORT=443
    echo "端口检查通过，将使用端口: $PORT"
}

# 配置和启动Xray
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

    # 配置 config.json
    # 修正: sniffing 模块已放置在正确位置
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
          "target": "www.ucla.edu:443",
          "serverNames": [
            "www.ucla.edu"
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
    if ! systemctl is-active --quiet xray.service; then
      echo "Xray 启动失败，请检查配置文件格式。"
      exit 1
    fi
    
    # 获取IP
    HOST_IP=$(curl -s -4 http://www.cloudflare.com/cdn-cgi/trace | grep "ip" | awk -F "[=]" '{print $2}')
    if [[ -z "${HOST_IP}" ]]; then
        HOST_IP=$(curl -s -6 http://www.cloudflare.com/cdn-cgi/trace | grep "ip" | awk -F "[=]" '{print $2}')
    fi
    
    # 获取IP所在国家
    IP_COUNTRY=$(curl -s http://ipinfo.io/${HOST_IP}/country)
    
    # 生成链接 (确保 sni=www.ucla.edu)
    LINK="vless://${uuid}@${HOST_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.ucla.edu&fp=chrome&pbk=${PublicKey}&sid=${shid}&type=tcp&headerType=none#${IP_COUNTRY}_UCLA_Vision"

    # 输出结果
    echo "$LINK" > /usr/local/etc/xray/config.txt

    echo ""
    echo "======================================================"
    echo "      Xray 安装完成 (UCLA.edu + Vision)"
    echo "======================================================"
    echo "地址 (IP):      ${HOST_IP}"
    echo "端口 (Port):    ${PORT}"
    echo "用户ID (UUID):  ${uuid}"
    echo "流控 (Flow):    xtls-rprx-vision"
    echo "伪装域名 (SNI): www.ucla.edu"
    echo "ShortId:        ${shid}"
    echo "======================================================"
    echo "🚀 客户端连接链接 (复制下方内容):"
    echo ""
    echo "${LINK}"
    echo ""
    echo "======================================================"
}

# 主函数
main() {
    root
    port
    xray
}

# 执行脚本
main
