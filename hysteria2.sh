#!/bin/bash

# Hysteria2 自动安装脚本
# 支持 Ubuntu/Debian/CentOS 系统

set -e

# ==================== 配置区域 ====================
# 请在这里修改你的配置

# 基础配置
LISTEN_PORT="443"                    # 监听端口
DOMAIN="your-domain.com"             # 你的域名
EMAIL="your-email@example.com"       # 邮箱地址（用于申请证书）

# 认证配置
AUTH_TYPE="password"                 # 认证类型: password 或 userpass
AUTH_PASSWORD="your-password"        # 密码认证的密码
# 如果使用 userpass 认证，在下面添加用户
declare -A USERS=(
    ["user1"]="password1"
    ["user2"]="password2"
)

# 高级配置
MASQUERADE_TYPE="proxy"              # 伪装类型: file, proxy, string
MASQUERADE_PROXY="https://www.bing.com/"  # 代理伪装地址
MASQUERADE_STRING="Not Found"        # 字符串伪装内容
MASQUERADE_FILE="/var/www/html"      # 文件伪装目录

# 网络配置
BANDWIDTH_UP="1gbps"                 # 上行带宽限制
BANDWIDTH_DOWN="1gbps"               # 下行带宽限制
UDP_HOP_INTERVAL="30s"               # UDP 端口跳跃间隔

# TLS 配置
TLS_CERT_PATH="/etc/hysteria/server.crt"
TLS_KEY_PATH="/etc/hysteria/server.key"

# ==================== 脚本开始 ====================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查是否为 root 用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要 root 权限运行"
        exit 1
    fi
}

# 检测系统类型
detect_system() {
    if [[ -f /etc/redhat-release ]]; then
        OS="centos"
        PACKAGE_MANAGER="yum"
    elif [[ -f /etc/debian_version ]]; then
        OS="debian"
        PACKAGE_MANAGER="apt"
    else
        log_error "不支持的操作系统"
        exit 1
    fi
    log_info "检测到系统: $OS"
}

# 安装依赖
install_dependencies() {
    log_info "安装系统依赖..."
    
    if [[ $OS == "centos" ]]; then
        $PACKAGE_MANAGER update -y
        $PACKAGE_MANAGER install -y curl wget unzip socat cron
        # 安装 EPEL 仓库
        $PACKAGE_MANAGER install -y epel-release
    else
        $PACKAGE_MANAGER update -y
        $PACKAGE_MANAGER install -y curl wget unzip socat cron
    fi
}

# 安装 acme.sh
install_acme() {
    if [[ ! -f ~/.acme.sh/acme.sh ]]; then
        log_info "安装 acme.sh..."
        curl https://get.acme.sh | sh -s email=$EMAIL
        source ~/.bashrc
    else
        log_info "acme.sh 已安装"
    fi
}

# 申请 SSL 证书
issue_certificate() {
    log_info "申请 SSL 证书..."
    
    # 创建证书目录
    mkdir -p /etc/hysteria
    
    # 使用 standalone 模式申请证书
    ~/.acme.sh/acme.sh --issue -d $DOMAIN --standalone
    
    # 安装证书
    ~/.acme.sh/acme.sh --installcert -d $DOMAIN \
        --key-file $TLS_KEY_PATH \
        --fullchain-file $TLS_CERT_PATH \
        --reloadcmd "systemctl restart hysteria-server"
        
    # 设置证书权限
    chmod 600 $TLS_KEY_PATH
    chmod 644 $TLS_CERT_PATH
}

# 下载并安装 Hysteria2
install_hysteria2() {
    log_info "下载并安装 Hysteria2..."
    
    # 创建临时目录
    TMP_DIR=$(mktemp -d)
    cd $TMP_DIR
    
    # 检测架构
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)
            ARCH="amd64"
            ;;
        aarch64)
            ARCH="arm64"
            ;;
        armv7l)
            ARCH="armv7"
            ;;
        *)
            log_error "不支持的架构: $ARCH"
            exit 1
            ;;
    esac
    
    # 获取最新版本
    LATEST_VERSION=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | grep '"tag_name"' | cut -d'"' -f4)
    
    # 下载文件
    DOWNLOAD_URL="https://github.com/apernet/hysteria/releases/download/${LATEST_VERSION}/hysteria-linux-${ARCH}"
    
    log_info "下载 Hysteria2 ${LATEST_VERSION}..."
    wget -O hysteria $DOWNLOAD_URL
    
    # 安装到系统目录
    chmod +x hysteria
    mv hysteria /usr/local/bin/
    
    # 创建用户
    useradd -r -s /bin/false hysteria || true
    
    # 清理临时文件
    cd /
    rm -rf $TMP_DIR
}

# 生成配置文件
generate_config() {
    log_info "生成配置文件..."
    
    cat > /etc/hysteria/config.yaml << EOF
listen: :$LISTEN_PORT

tls:
  cert: $TLS_CERT_PATH
  key: $TLS_KEY_PATH

EOF

    # 添加认证配置
    if [[ $AUTH_TYPE == "password" ]]; then
        cat >> /etc/hysteria/config.yaml << EOF
auth:
  type: password
  password: $AUTH_PASSWORD

EOF
    else
        cat >> /etc/hysteria/config.yaml << EOF
auth:
  type: userpass
  userpass:
EOF
        for user in "${!USERS[@]}"; do
            echo "    $user: ${USERS[$user]}" >> /etc/hysteria/config.yaml
        done
        echo "" >> /etc/hysteria/config.yaml
    fi

    # 添加伪装配置
    case $MASQUERADE_TYPE in
        "proxy")
            cat >> /etc/hysteria/config.yaml << EOF
masquerade:
  type: proxy
  proxy:
    url: $MASQUERADE_PROXY
    rewriteHost: true

EOF
            ;;
        "file")
            cat >> /etc/hysteria/config.yaml << EOF
masquerade:
  type: file
  file:
    dir: $MASQUERADE_FILE

EOF
            ;;
        "string")
            cat >> /etc/hysteria/config.yaml << EOF
masquerade:
  type: string
  string:
    content: $MASQUERADE_STRING
    headers:
      content-type: text/plain
      custom-stuff: ice-cream-so-good

EOF
            ;;
    esac

    # 添加其他配置
    cat >> /etc/hysteria/config.yaml << EOF
bandwidth:
  up: $BANDWIDTH_UP
  down: $BANDWIDTH_DOWN

udpIdleTimeout: 60s
udpHopInterval: $UDP_HOP_INTERVAL

ignoreClientBandwidth: false
disableUDP: false
EOF

    # 设置配置文件权限
    chmod 644 /etc/hysteria/config.yaml
    chown hysteria:hysteria /etc/hysteria/config.yaml
}

# 创建 systemd 服务
create_systemd_service() {
    log_info "创建 systemd 服务..."
    
    cat > /etc/systemd/system/hysteria-server.service << EOF
[Unit]
Description=Hysteria Server
Documentation=https://hysteria.network
After=network.target nss-lookup.target

[Service]
Type=simple
User=hysteria
Group=hysteria
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
WorkingDirectory=/etc/hysteria
Environment=HYSTERIA_LOG_LEVEL=info
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
Restart=on-failure
RestartSec=10
RestartPreventExitStatus=23

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable hysteria-server
}

# 配置防火墙
configure_firewall() {
    log_info "配置防火墙..."
    
    if command -v firewall-cmd &> /dev/null; then
        # CentOS/RHEL with firewalld
        firewall-cmd --permanent --add-port=$LISTEN_PORT/tcp
        firewall-cmd --permanent --add-port=$LISTEN_PORT/udp
        firewall-cmd --reload
    elif command -v ufw &> /dev/null; then
        # Ubuntu with ufw
        ufw allow $LISTEN_PORT/tcp
        ufw allow $LISTEN_PORT/udp
    elif command -v iptables &> /dev/null; then
        # Generic iptables
        iptables -A INPUT -p tcp --dport $LISTEN_PORT -j ACCEPT
        iptables -A INPUT -p udp --dport $LISTEN_PORT -j ACCEPT
        
        # 保存 iptables 规则
        if [[ $OS == "centos" ]]; then
            service iptables save
        else
            iptables-save > /etc/iptables/rules.v4
        fi
    fi
}

# 生成客户端配置
generate_client_config() {
    log_info "生成客户端配置..."
    
    cat > /etc/hysteria/client.yaml << EOF
server: $DOMAIN:$LISTEN_PORT

EOF

    if [[ $AUTH_TYPE == "password" ]]; then
        cat >> /etc/hysteria/client.yaml << EOF
auth: $AUTH_PASSWORD

EOF
    else
        # 使用第一个用户作为示例
        FIRST_USER=$(echo "${!USERS[@]}" | cut -d' ' -f1)
        FIRST_PASS=${USERS[$FIRST_USER]}
        cat >> /etc/hysteria/client.yaml << EOF
auth: $FIRST_USER:$FIRST_PASS

EOF
    fi

    cat >> /etc/hysteria/client.yaml << EOF
bandwidth:
  up: 20 mbps
  down: 100 mbps

socks5:
  listen: 127.0.0.1:1080

http:
  listen: 127.0.0.1:8080

tls:
  sni: $DOMAIN
  insecure: false
EOF

    log_info "客户端配置已保存到: /etc/hysteria/client.yaml"
}

# 显示连接信息
show_connection_info() {
    echo ""
    echo "=========================================="
    echo -e "${GREEN}Hysteria2 安装完成！${NC}"
    echo "=========================================="
    echo "服务器地址: $DOMAIN"
    echo "端口: $LISTEN_PORT"
    if [[ $AUTH_TYPE == "password" ]]; then
        echo "密码: $AUTH_PASSWORD"
    else
        echo "用户列表:"
        for user in "${!USERS[@]}"; do
            echo "  用户名: $user, 密码: ${USERS[$user]}"
        done
    fi
    echo ""
    echo "客户端配置文件: /etc/hysteria/client.yaml"
    echo "服务状态: systemctl status hysteria-server"
    echo "查看日志: journalctl -u hysteria-server -f"
    echo ""
    echo "连接URL (可直接导入客户端):"
    if [[ $AUTH_TYPE == "password" ]]; then
        echo "hysteria2://$AUTH_PASSWORD@$DOMAIN:$LISTEN_PORT"
    else
        FIRST_USER=$(echo "${!USERS[@]}" | cut -d' ' -f1)
        FIRST_PASS=${USERS[$FIRST_USER]}
        echo "hysteria2://$FIRST_USER:$FIRST_PASS@$DOMAIN:$LISTEN_PORT"
    fi
    echo "=========================================="
}

# 主函数
main() {
    echo -e "${BLUE}"
    echo "========================================"
    echo "    Hysteria2 自动安装脚本"
    echo "========================================"
    echo -e "${NC}"
    
    check_root
    detect_system
    install_dependencies
    install_acme
    issue_certificate
    install_hysteria2
    generate_config
    create_systemd_service
    configure_firewall
    
    # 启动服务
    log_info "启动 Hysteria2 服务..."
    systemctl start hysteria-server
    
    # 检查服务状态
    if systemctl is-active --quiet hysteria-server; then
        log_info "Hysteria2 服务启动成功"
        generate_client_config
        show_connection_info
    else
        log_error "Hysteria2 服务启动失败，请检查日志: journalctl -u hysteria-server"
        exit 1
    fi
}

# 运行主函数
main
