#!/bin/bash

# Hysteria 2 安装脚本 - 适用于 Linux 服务器，支持自动 ACME 证书
# 作者：基于官方文档自定义
# 运行：sudo bash install_hy2.sh

# 检查是否 root 用户
if [ "$(id -u)" != "0" ]; then
   echo "错误：请用 root 或 sudo 运行此脚本。"
   exit 1
fi

# 安装必要工具
echo "步骤1: 安装必要工具（curl, wget, unzip）..."
apt update && apt install -y curl wget unzip || yum install -y curl wget unzip || echo "警告：无法自动安装工具，请手动安装 curl/wget/unzip。"

# 检测系统架构
ARCH=$(uname -m)
case $ARCH in
    x86_64) BINARY="hysteria-linux-amd64" ;;
    aarch64) BINARY="hysteria-linux-arm64" ;;
    armv7l) BINARY="hysteria-linux-arm" ;;
    *) echo "错误：不支持的架构 $ARCH。请手动下载二进制。" ; exit 1 ;;
esac

# 下载 Hysteria 2 二进制
echo "步骤2: 下载 Hysteria 2（架构: $ARCH）..."
wget "https://download.hysteria.network/app/latest/$BINARY" -O /usr/local/bin/hysteria
chmod +x /usr/local/bin/hysteria

if [ ! -f /usr/local/bin/hysteria ]; then
    echo "错误：下载失败。请检查网络或手动下载。"
    exit 1
fi

# 创建配置目录
mkdir -p /etc/hysteria

# 交互式生成配置文件
echo "步骤3: 生成配置文件。请回答以下问题（按回车使用默认值）..."

read -p "输入监听端口 (默认 443): " PORT
PORT=${PORT:-443}

read -p "输入认证密码 (默认 random 生成): " PASS
if [ -z "$PASS" ]; then
    PASS=$(openssl rand -hex 8)
    echo "生成的密码: $PASS"
fi

read -p "是否启用 TLS? (y/n, 默认 n): " TLS_ENABLE
if [ "$TLS_ENABLE" = "y" ]; then
    read -p "是否使用自动证书 (ACME, 如 Let's Encrypt, y/n): " ACME_ENABLE
    if [ "$ACME_ENABLE" = "y" ]; then
        read -p "输入域名 (用于证书, 如 yourdomain.com, 多域名用逗号分隔): " DOMAINS
        DOMAINS=$(echo $DOMAINS | sed 's/,/ /g')  # 转换为空格分隔
        read -p "输入邮箱 (用于通知, 如 your@email.com): " EMAIL
        read -p "选择 CA (letsencrypt 或 zerossl, 默认 letsencrypt): " CA
        CA=${CA:-letsencrypt}
        read -p "选择挑战类型 (http/tls/dns, 默认 http): " CHALLENGE_TYPE
        CHALLENGE_TYPE=${CHALLENGE_TYPE:-http}

        # ACME 配置
        ACME_CONFIG="acme:
  domains:
    - $(echo $DOMAINS | sed 's/ /\
    - /g')
  email: $EMAIL
  ca: $CA
  type: $CHALLENGE_TYPE"

        # 根据类型添加额外配置（简单默认）
        if [ "$CHALLENGE_TYPE" = "http" ]; then
            ACME_CONFIG="$ACME_CONFIG
  http:
    altPort: 80"
            EXTRA_PORT=80
        elif [ "$CHALLENGE_TYPE" = "tls" ]; then
            ACME_CONFIG="$ACME_CONFIG
  tls:
    altPort: 443"
            EXTRA_PORT=443
        elif [ "$CHALLENGE_TYPE" = "dns" ]; then
            echo "警告：DNS 挑战需要提供商配置。请后期手动编辑 config.yaml 的 dns 部分（参考官方文档）。"
            ACME_CONFIG="$ACME_CONFIG
  dns:
    name: your_dns_provider  # 如 cloudflare, 替换
    config:
      # key: value  # 添加 API key 等"
        fi

        TLS_CONFIG="$ACME_CONFIG"
    else
        # 手动 TLS
        read -p "证书路径 (如 /etc/hysteria/cert.pem): " CERT_PATH
        read -p "私钥路径 (如 /etc/hysteria/key.pem): " KEY_PATH
        TLS_CONFIG="tls:
  cert: $CERT_PATH
  key: $KEY_PATH"
    fi
else
    TLS_CONFIG=""
fi

# 写入基本 server 配置（YAML 格式）
cat << EOF > /etc/hysteria/config.yaml
listen: :$PORT

auth:
  type: password
  password: $PASS

$TLS_CONFIG

masquerade:
  type: proxy
  proxy:
    url: https://www.example.com  # 伪装网站，可自定义
    rewriteHost: true
EOF

echo "配置文件生成在 /etc/hysteria/config.yaml。你可以后期编辑它（尤其是 DNS 挑战配置）。"

# 设置 systemd 服务
echo "步骤4: 设置 systemd 服务..."
cat << EOF > /etc/systemd/system/hysteria.service
[Unit]
Description=Hysteria 2 Server
After=network.target

[Service]
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hysteria
systemctl start hysteria

# 检查状态
if systemctl status hysteria | grep -q "active (running)"; then
    echo "步骤5: Hysteria 2 安装成功！服务已启动。"
    echo "如果使用 ACME，首次启动会自动申请证书。请检查日志以确认。"
    echo "客户端连接示例: hysteria client -c client.yaml （匹配密码/端口 + 域名）"
else
    echo "警告：服务启动失败。请检查 journalctl -u hysteria -e（如果 ACME 失败，可能是域名未解析或端口问题）。"
fi

# 防火墙提示
echo "提示：请开启端口 $PORT (UDP)。"
if [ -n EXTRA_PORT" ]; then
    echo "额外：为 ACME 开启端口 $EXTRA_PORT。"
fi
if command -v ufw &> /dev/null; then
    ufw allow $PORT/udp
    [ -n "$EXTRA_PORT" ] && ufw allow $EXTRA_PORT
    ufw reload
elif command -v firewall-cmd &> /dev/null; then
    firewall-cmd --add-port=$PORT/udp --permanent
    [ -n "$EXTRA_PORT" ] && firewall-cmd --add-port=$EXTRA_PORT/tcp --permanent  # HTTP/TLS 是 TCP
    firewall-cmd --reload
fi

# 卸载提示
echo "卸载命令：systemctl stop hysteria; systemctl disable hysteria; rm /etc/systemd/systemd/system/hysteria.service; rm /usr/local/bin/hysteria; rm -rf /etc/hysteria; systemctl daemon-reload"
