#!/bin/bash

# Hysteria 2 一键安装脚本 - 增强版
# 作者: 编程大师
# 版本: 2.1
# 功能: 安装、配置、管理 Hysteria 2 服务，支持端口跳跃和多种证书选项

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 全局变量
SCRIPT_VERSION="2.1"
HYSTERIA_VERSION="2.2.4"
WORK_DIR="/opt/hysteria2"
CONFIG_FILE="/etc/hysteria2/config.yaml"
SERVICE_FILE="/etc/systemd/system/hysteria2.service"
LOG_FILE="/var/log/hysteria2.log"
CERT_DIR="/etc/hysteria2/certs"

# 证书相关变量
CERT_TYPE=""
DOMAIN=""
CERT_PATH=""
KEY_PATH=""
EMAIL=""

# 打印彩色输出
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 显示欢迎界面
show_welcome() {
    clear
    echo -e "${PURPLE}================================${NC}"
    echo -e "${PURPLE}    Hysteria 2 一键安装脚本${NC}"
    echo -e "${PURPLE}         版本: $SCRIPT_VERSION${NC}"
    echo -e "${PURPLE}  支持多种证书配置 + 端口跳跃${NC}"
    echo -e "${PURPLE}================================${NC}"
    echo ""
}

# 检查系统
check_system() {
    print_info "检查系统环境..."
    
    # 检查是否为 root 用户
    if [[ $EUID -ne 0 ]]; then
        print_error "请使用 root 权限运行此脚本"
        exit 1
    fi
    
    # 检查系统类型
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
    else
        print_error "无法识别操作系统"
        exit 1
    fi
    
    print_success "系统检查完成: $OS $VERSION"
}

# 安装依赖
install_dependencies() {
    print_info "安装依赖包..."
    
    case $OS in
        "ubuntu"|"debian")
            apt update
            apt install -y curl wget unzip openssl ufw cron socat
            ;;
        "centos"|"rhel"|"fedora")
            if command -v dnf &> /dev/null; then
                dnf install -y curl wget unzip openssl firewalld cronie socat
            else
                yum install -y curl wget unzip openssl firewalld cronie socat
            fi
            ;;
        *)
            print_warning "未知系统，尝试通用安装..."
            ;;
    esac
    
    print_success "依赖包安装完成"
}

# 下载并安装 Hysteria 2
install_hysteria2() {
    print_info "下载 Hysteria 2..."
    
    # 创建工作目录
    mkdir -p $WORK_DIR
    mkdir -p /etc/hysteria2
    mkdir -p $CERT_DIR
    
    # 检测系统架构
    ARCH=$(uname -m)
    case $ARCH in
        "x86_64")
            ARCH_NAME="amd64"
            ;;
        "aarch64")
            ARCH_NAME="arm64"
            ;;
        "armv7l")
            ARCH_NAME="armv7"
            ;;
        *)
            print_error "不支持的架构: $ARCH"
            exit 1
            ;;
    esac
    
    # 下载 Hysteria 2
    DOWNLOAD_URL="https://github.com/apernet/hysteria/releases/download/app%2Fv${HYSTERIA_VERSION}/hysteria-linux-${ARCH_NAME}"
    
    cd $WORK_DIR
    wget -O hysteria2 $DOWNLOAD_URL || {
        print_error "下载失败，请检查网络连接"
        exit 1
    }
    
    chmod +x hysteria2
    ln -sf $WORK_DIR/hysteria2 /usr/local/bin/hysteria2
    
    print_success "Hysteria 2 安装完成"
}

# 安装 acme.sh
install_acme() {
    if command -v ~/.acme.sh/acme.sh &> /dev/null; then
        print_info "acme.sh 已安装"
        return
    fi
    
    print_info "安装 acme.sh..."
    curl https://get.acme.sh | sh -s email=$EMAIL
    
    # 添加到 PATH
    if ! grep -q ".acme.sh" ~/.bashrc; then
        echo 'export PATH="$HOME/.acme.sh:$PATH"' >> ~/.bashrc
    fi
    
    source ~/.bashrc
    print_success "acme.sh 安装完成"
}

# 选择证书类型
choose_certificate_type() {
    clear
    echo -e "${CYAN}=== 证书配置选择 ===${NC}"
    echo ""
    echo "1) 自签名证书 (快速，但客户端需要跳过证书验证)"
    echo "2) Let's Encrypt 自动证书 (需要域名和80/443端口)"
    echo "3) Let's Encrypt DNS 证书 (需要域名和DNS API)"
    echo "4) 上传自有证书 (已有证书文件)"
    echo "5) 使用现有证书路径 (证书已在服务器上)"
    echo ""
    
    while true; do
        read -p "请选择证书类型 [1-5]: " cert_choice
        case $cert_choice in
            1)
                CERT_TYPE="self_signed"
                break
                ;;
            2)
                CERT_TYPE="letsencrypt_http"
                break
                ;;
            3)
                CERT_TYPE="letsencrypt_dns"
                break
                ;;
            4)
                CERT_TYPE="upload"
                break
                ;;
            5)
                CERT_TYPE="existing"
                break
                ;;
            *)
                print_error "无效选择，请重新输入"
                ;;
        esac
    done
}

# 配置证书
configure_certificate() {
    case $CERT_TYPE in
        "self_signed")
            generate_self_signed_certificate
            ;;
        "letsencrypt_http")
            generate_letsencrypt_http_certificate
            ;;
        "letsencrypt_dns")
            generate_letsencrypt_dns_certificate
            ;;
        "upload")
            upload_certificate
            ;;
        "existing")
            use_existing_certificate
            ;;
    esac
}

# 生成自签名证书
generate_self_signed_certificate() {
    print_info "生成自签名证书..."
    
    read -p "请输入证书域名/IP (默认: localhost): " DOMAIN
    DOMAIN=${DOMAIN:-localhost}
    
    openssl req -x509 -nodes -newkey rsa:4096 \
        -keyout $CERT_DIR/server.key \
        -out $CERT_DIR/server.crt \
        -days 3650 \
        -subj "/C=US/ST=State/L=City/O=Organization/OU=Unit/CN=$DOMAIN"
    
    chmod 600 $CERT_DIR/server.key
    chmod 644 $CERT_DIR/server.crt
    
    CERT_PATH="$CERT_DIR/server.crt"
    KEY_PATH="$CERT_DIR/server.key"
    
    print_success "自签名证书生成完成"
}

# Let's Encrypt HTTP 证书
generate_letsencrypt_http_certificate() {
    print_info "配置 Let's Encrypt HTTP 证书..."
    
    read -p "请输入域名: " DOMAIN
    if [[ -z "$DOMAIN" ]]; then
        print_error "域名不能为空"
        exit 1
    fi
    
    read -p "请输入邮箱地址: " EMAIL
    if [[ -z "$EMAIL" ]]; then
        print_error "邮箱不能为空"
        exit 1
    fi
    
    # 检查域名解析
    print_info "检查域名解析..."
    PUBLIC_IP=$(get_public_ip)
    DOMAIN_IP=$(nslookup $DOMAIN | grep "Address:" | tail -1 | awk '{print $2}')
    
    if [[ "$PUBLIC_IP" != "$DOMAIN_IP" ]]; then
        print_warning "域名 $DOMAIN 没有解析到当前服务器 IP: $PUBLIC_IP"
        print_warning "当前域名解析到: $DOMAIN_IP"
        read -p "是否继续? (y/n): " continue_anyway
        if [[ $continue_anyway != "y" ]]; then
            exit 1
        fi
    fi
    
    # 临时停止可能占用80端口的服务
    systemctl stop apache2 2>/dev/null || true
    systemctl stop nginx 2>/dev/null || true
    systemctl stop hysteria2 2>/dev/null || true
    
    # 安装 acme.sh
    install_acme
    
    # 申请证书
    print_info "申请 Let's Encrypt 证书..."
    ~/.acme.sh/acme.sh --issue -d $DOMAIN --standalone --keylength 2048
    
    if [[ $? -ne 0 ]]; then
        print_error "证书申请失败"
        exit 1
    fi
    
    # 安装证书
    ~/.acme.sh/acme.sh --installcert -d $DOMAIN \
        --key-file $CERT_DIR/server.key \
        --fullchain-file $CERT_DIR/server.crt \
        --reloadcmd "systemctl restart hysteria2"
    
    chmod 600 $CERT_DIR/server.key
    chmod 644 $CERT_DIR/server.crt
    
    CERT_PATH="$CERT_DIR/server.crt"
    KEY_PATH="$CERT_DIR/server.key"
    
    print_success "Let's Encrypt 证书配置完成"
}

# Let's Encrypt DNS 证书
generate_letsencrypt_dns_certificate() {
    print_info "配置 Let's Encrypt DNS 证书..."
    
    read -p "请输入域名: " DOMAIN
    if [[ -z "$DOMAIN" ]]; then
        print_error "域名不能为空"
        exit 1
    fi
    
    read -p "请输入邮箱地址: " EMAIL
    if [[ -z "$EMAIL" ]]; then
        print_error "邮箱不能为空"
        exit 1
    fi
    
    echo ""
    echo -e "${YELLOW}支持的 DNS 提供商:${NC}"
    echo "1) Cloudflare"
    echo "2) Aliyun (阿里云)"
    echo "3) DNSPod (腾讯云)"
    echo "4) GoDaddy"
    echo "5) 其他 (需要手动配置)"
    echo ""
    
    read -p "请选择 DNS 提供商 [1-5]: " dns_provider
    
    case $dns_provider in
        1)
            configure_cloudflare_dns
            ;;
        2)
            configure_aliyun_dns
            ;;
        3)
            configure_dnspod_dns
            ;;
        4)
            configure_godaddy_dns
            ;;
        5)
            configure_manual_dns
            ;;
        *)
            print_error "无效选择"
            exit 1
            ;;
    esac
}

# Cloudflare DNS 配置
configure_cloudflare_dns() {
    read -p "请输入 Cloudflare Email: " CF_EMAIL
    read -p "请输入 Cloudflare Global API Key: " CF_KEY
    
    export CF_Email="$CF_EMAIL"
    export CF_Key="$CF_KEY"
    
    install_acme
    
    ~/.acme.sh/acme.sh --issue --dns dns_cf -d $DOMAIN --keylength 2048
    
    if [[ $? -eq 0 ]]; then
        install_certificate_from_acme
    else
        print_error "Cloudflare DNS 证书申请失败"
        exit 1
    fi
}

# 阿里云 DNS 配置
configure_aliyun_dns() {
    read -p "请输入阿里云 Access Key ID: " ALI_KEY
    read -p "请输入阿里云 Access Key Secret: " ALI_SECRET
    
    export Ali_Key="$ALI_KEY"
    export Ali_Secret="$ALI_SECRET"
    
    install_acme
    
    ~/.acme.sh/acme.sh --issue --dns dns_ali -d $DOMAIN --keylength 2048
    
    if [[ $? -eq 0 ]]; then
        install_certificate_from_acme
    else
        print_error "阿里云 DNS 证书申请失败"
        exit 1
    fi
}

# DNSPod DNS 配置
configure_dnspod_dns() {
    read -p "请输入 DNSPod API ID: " DP_ID
    read -p "请输入 DNSPod API Key: " DP_KEY
    
    export DP_Id="$DP_ID"
    export DP_Key="$DP_KEY"
    
    install_acme
    
    ~/.acme.sh/acme.sh --issue --dns dns_dp -d $DOMAIN --keylength 2048
    
    if [[ $? -eq 0 ]]; then
        install_certificate_from_acme
    else
        print_error "DNSPod DNS 证书申请失败"
        exit 1
    fi
}

# GoDaddy DNS 配置
configure_godaddy_dns() {
    read -p "请输入 GoDaddy API Key: " GD_KEY
    read -p "请输入 GoDaddy API Secret: " GD_SECRET
    
    export GD_Key="$GD_KEY"
    export GD_Secret="$GD_SECRET"
    
    install_acme
    
    ~/.acme.sh/acme.sh --issue --dns dns_gd -d $DOMAIN --keylength 2048
    
    if [[ $? -eq 0 ]]; then
        install_certificate_from_acme
    else
        print_error "GoDaddy DNS 证书申请失败"
        exit 1
    fi
}

# 手动 DNS 配置
configure_manual_dns() {
    install_acme
    
    print_warning "将使用手动 DNS 验证模式"
    print_info "请按照提示添加 TXT 记录到您的 DNS 服务商"
    
    ~/.acme.sh/acme.sh --issue --dns -d $DOMAIN --yes-I-know-dns-manual-mode-enough-go-ahead-please --keylength 2048
    
    if [[ $? -eq 0 ]]; then
        install_certificate_from_acme
    else
        print_error "手动 DNS 证书申请失败"
        exit 1
    fi
}

# 从 acme.sh 安装证书
install_certificate_from_acme() {
    ~/.acme.sh/acme.sh --installcert -d $DOMAIN \
        --key-file $CERT_DIR/server.key \
        --fullchain-file $CERT_DIR/server.crt \
        --reloadcmd "systemctl restart hysteria2"
    
    chmod 600 $CERT_DIR/server.key
    chmod 644 $CERT_DIR/server.crt
    
    CERT_PATH="$CERT_DIR/server.crt"
    KEY_PATH="$CERT_DIR/server.key"
    
    print_success "Let's Encrypt DNS 证书配置完成"
}

# 上传证书文件
upload_certificate() {
    print_info "上传证书文件..."
    
    echo "请将您的证书文件传输到服务器，然后输入路径："
    echo ""
    
    while true; do
        read -p "请输入证书文件路径 (.crt/.pem): " upload_cert_path
        if [[ -f "$upload_cert_path" ]]; then
            break
        else
            print_error "文件不存在，请重新输入"
        fi
    done
    
    while true; do
        read -p "请输入私钥文件路径 (.key): " upload_key_path
        if [[ -f "$upload_key_path" ]]; then
            break
        else
            print_error "文件不存在，请重新输入"
        fi
    done
    
    # 复制文件
    cp "$upload_cert_path" $CERT_DIR/server.crt
    cp "$upload_key_path" $CERT_DIR/server.key
    
    chmod 600 $CERT_DIR/server.key
    chmod 644 $CERT_DIR/server.crt
    
    CERT_PATH="$CERT_DIR/server.crt"
    KEY_PATH="$CERT_DIR/server.key"
    
    read -p "请输入证书对应的域名: " DOMAIN
    
    print_success "证书文件上传完成"
}

# 使用现有证书路径
use_existing_certificate() {
    print_info "使用现有证书..."
    
    while true; do
        read -p "请输入证书文件路径: " existing_cert_path
        if [[ -f "$existing_cert_path" ]]; then
            CERT_PATH="$existing_cert_path"
            break
        else
            print_error "文件不存在，请重新输入"
        fi
    done
    
    while true; do
        read -p "请输入私钥文件路径: " existing_key_path
        if [[ -f "$existing_key_path" ]]; then
            KEY_PATH="$existing_key_path"
            break
        else
            print_error "文件不存在，请重新输入"
        fi
    done
    
    read -p "请输入证书对应的域名: " DOMAIN
    
    print_success "现有证书配置完成"
}

# 获取公网IP
get_public_ip() {
    local ip
    ip=$(curl -s4 ifconfig.me) || ip=$(curl -s4 icanhazip.com) || ip=$(curl -s4 ipinfo.io/ip)
    echo $ip
}

# 生成配置文件
generate_config() {
    print_info "生成配置文件..."
    
    # 获取用户输入
    read -p "请输入监听端口 (默认: 8443): " LISTEN_PORT
    LISTEN_PORT=${LISTEN_PORT:-8443}
    
    echo -e "\n${YELLOW}端口跳跃配置:${NC}"
    read -p "是否启用端口跳跃? (y/n, 默认: y): " ENABLE_PORT_HOPPING
    ENABLE_PORT_HOPPING=${ENABLE_PORT_HOPPING:-y}
    
    if [[ $ENABLE_PORT_HOPPING == "y" || $ENABLE_PORT_HOPPING == "Y" ]]; then
        read -p "请输入端口跳跃范围起始端口 (默认: 10000): " PORT_HOP_START
        PORT_HOP_START=${PORT_HOP_START:-10000}
        
        read -p "请输入端口跳跃范围结束端口 (默认: 15000): " PORT_HOP_END
        PORT_HOP_END=${PORT_HOP_END:-15000}
        
        PORT_HOP_CONFIG="portHopping: ${PORT_HOP_START}-${PORT_HOP_END}"
        
        # 配置防火墙规则
        configure_firewall_port_hopping
    else
        PORT_HOP_CONFIG=""
        # 配置单端口防火墙
        configure_firewall_single_port
    fi
    
    read -p "请输入认证密码 (默认: 随机生成): " AUTH_PASSWORD
    if [[ -z $AUTH_PASSWORD ]]; then
        AUTH_PASSWORD=$(openssl rand -base64 32)
    fi
    
    read -p "请输入带宽限制 (Mbps, 默认: 100): " BANDWIDTH
    BANDWIDTH=${BANDWIDTH:-100}
    
    read -p "请输入忽略客户端带宽设置? (y/n, 默认: n): " IGNORE_CLIENT_BANDWIDTH
    IGNORE_CLIENT_BANDWIDTH=${IGNORE_CLIENT_BANDWIDTH:-n}
    
    # 获取公网IP
    PUBLIC_IP=$(get_public_ip)
    
    # 确定服务器地址
    if [[ -n "$DOMAIN" ]]; then
        SERVER_ADDR="$DOMAIN"
    else
        SERVER_ADDR="$PUBLIC_IP"
    fi
    
    # 生成配置文件
    cat > $CONFIG_FILE << EOF
listen: :${LISTEN_PORT}
${PORT_HOP_CONFIG}

tls:
  cert: ${CERT_PATH}
  key: ${KEY_PATH}

auth:
  type: password
  password: ${AUTH_PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true

bandwidth:
  up: ${BANDWIDTH} mbps
  down: ${BANDWIDTH} mbps

ignoreClientBandwidth: $([ "$IGNORE_CLIENT_BANDWIDTH" == "y" ] && echo "true" || echo "false")

resolver:
  type: https
  https:
    addr: 1.1.1.1:443
    timeout: 10s

outbounds:
  - name: direct
    type: direct

acl:
  inline:
    - reject(geoip:private)

EOF

    print_success "配置文件生成完成"
    
    # 生成客户端配置信息
    generate_client_config
}

# 生成客户端配置信息
generate_client_config() {
    local client_sni=""
    local client_insecure=""
    
    if [[ "$CERT_TYPE" == "self_signed" ]]; then
        client_sni="$SERVER_ADDR"
        client_insecure="insecure: true"
    else
        client_sni="$DOMAIN"
        client_insecure="# insecure: false  # 使用有效证书，无需跳过验证"
    fi
    
    # 保存配置信息
    cat > /etc/hysteria2/client_info.txt << EOF
=== Hysteria 2 客户端配置信息 ===

证书类型: $CERT_TYPE
服务器地址: ${SERVER_ADDR}
服务器 IP: $(get_public_ip)
端口: ${LISTEN_PORT}
$([ "$ENABLE_PORT_HOPPING" == "y" ] && echo "端口跳跃: ${PORT_HOP_START}-${PORT_HOP_END}")
认证密码: ${AUTH_PASSWORD}
带宽: ${BANDWIDTH} Mbps
传输协议: hysteria2

=== 客户端配置文件参考 ===
server: ${SERVER_ADDR}:${LISTEN_PORT}
$([ "$ENABLE_PORT_HOPPING" == "y" ] && echo "portHopping: ${PORT_HOP_START}-${PORT_HOP_END}")
auth: ${AUTH_PASSWORD}
tls:
  sni: ${client_sni}
  ${client_insecure}
bandwidth:
  up: ${BANDWIDTH} mbps
  down: ${BANDWIDTH} mbps
socks5:
  listen: 127.0.0.1:1080
http:
  listen: 127.0.0.1:8080

=== v2rayN 配置参考 ===
服务器地址: ${SERVER_ADDR}
端口: ${LISTEN_PORT}
$([ "$ENABLE_PORT_HOPPING" == "y" ] && echo "端口跳跃: ${PORT_HOP_START}-${PORT_HOP_END}")
密码: ${AUTH_PASSWORD}
SNI: ${client_sni}
$([ "$CERT_TYPE" == "self_signed" ] && echo "跳过证书验证: 是" || echo "跳过证书验证: 否")

EOF
}

# 配置防火墙 - 端口跳跃
configure_firewall_port_hopping() {
    print_info "配置防火墙规则 (端口跳跃)..."
    
    case $OS in
        "ubuntu"|"debian")
            # UFW
            ufw --force enable
            ufw allow $LISTEN_PORT/udp
            ufw allow ${PORT_HOP_START}:${PORT_HOP_END}/udp
            ufw allow ssh
            # Let's Encrypt 需要的端口
            if [[ "$CERT_TYPE" == "letsencrypt_http" ]]; then
                ufw allow 80/tcp
                ufw allow 443/tcp
            fi
            ;;
        "centos"|"rhel"|"fedora")
            # FirewallD
            systemctl enable firewalld
            systemctl start firewalld
            firewall-cmd --permanent --add-port=${LISTEN_PORT}/udp
            firewall-cmd --permanent --add-port=${PORT_HOP_START}-${PORT_HOP_END}/udp
            firewall-cmd --permanent --add-service=ssh
            # Let's Encrypt 需要的端口
            if [[ "$CERT_TYPE" == "letsencrypt_http" ]]; then
                firewall-cmd --permanent --add-port=80/tcp
                firewall-cmd --permanent --add-port=443/tcp
            fi
            firewall-cmd --reload
            ;;
    esac
    
    print_success "防火墙规则配置完成"
}

# 配置防火墙 - 单端口
configure_firewall_single_port() {
    print_info "配置防火墙规则..."
    
    case $OS in
        "ubuntu"|"debian")
            # UFW
            ufw --force enable
            ufw allow $LISTEN_PORT/udp
            ufw allow ssh
            # Let's Encrypt 需要的端口
            if [[ "$CERT_TYPE" == "letsencrypt_http" ]]; then
                ufw allow 80/tcp
                ufw allow 443/tcp
            fi
            ;;
        "centos"|"rhel"|"fedora")
            # FirewallD
            systemctl enable firewalld
            systemctl start firewalld
            firewall-cmd --permanent --add-port=${LISTEN_PORT}/udp
            firewall-cmd --permanent --add-service=ssh
            # Let's Encrypt 需要的端口
            if [[ "$CERT_TYPE" == "letsencrypt_http" ]]; then
                firewall-cmd --permanent --add-port=80/tcp
                firewall-cmd --permanent --add-port=443/tcp
            fi
            firewall-cmd --reload
            ;;
    esac
    
    print_success "防火墙规则配置完成"
}

# 创建系统服务
create_service() {
    print_info "创建系统服务..."
    
    cat > $SERVICE_FILE << EOF
[Unit]
Description=Hysteria 2 Server
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/hysteria2 server -c /etc/hysteria2/config.yaml
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable hysteria2
    
    print_success "系统服务创建完成"
}

# 启动服务
start_service() {
    print_info "启动 Hysteria 2 服务..."
    
    systemctl start hysteria2
    
    if systemctl is-active --quiet hysteria2; then
        print_success "Hysteria 2 服务启动成功"
    else
        print_error "Hysteria 2 服务启动失败"
        print_info "查看日志: journalctl -u hysteria2 -f"
        exit 1
    fi
}

# 显示安装结果
show_result() {
    clear
    echo -e "${GREEN}================================${NC}"
    echo -e "${GREEN}    Hysteria 2 安装完成！${NC}"
    echo -e "${GREEN}================================${NC}"
    echo ""
    
    cat /etc/hysteria2/client_info.txt
    
    echo ""
    echo -e "${YELLOW}管理命令:${NC}"
    echo "启动服务: systemctl start hysteria2"
    echo "停止服务: systemctl stop hysteria2"
    echo "重启服务: systemctl restart hysteria2"
    echo "查看状态: systemctl status hysteria2"
    echo "查看日志: journalctl -u hysteria2 -f"
    echo "配置文件: $CONFIG_FILE"
    echo "客户端信息: /etc/hysteria2/client_info.txt"
    echo ""
    echo -e "${YELLOW}脚本管理: bash $0${NC}"
    
    if [[ "$CERT_TYPE" == "letsencrypt_http" || "$CERT_TYPE" == "letsencrypt_dns" ]]; then
        echo ""
        echo -e "${CYAN}证书自动续期已配置${NC}"
        echo "续期命令: ~/.acme.sh/acme.sh --cron"
        echo "查看定时任务: crontab -l"
    fi
}

# 证书管理菜单
certificate_management() {
    while true; do
        clear
        echo -e "${CYAN}=== 证书管理 ===${NC}"
        echo ""
        echo "1) 查看证书信息"
        echo "2) 更新证书"
        echo "3) 强制续期 Let's Encrypt 证书"
        echo "4) 切换证书类型"
        echo "0) 返回主菜单"
        echo ""
        
        read -p "请选择操作 [0-4]: " cert_choice
        
        case $cert_choice in
            1)
                show_certificate_info
                read -p "按回车键继续..."
                ;;
            2)
                update_certificate
                read -p "按回车键继续..."
                ;;
            3)
                force_renew_certificate
                read -p "按回车键继续..."
                ;;
            4)
                change_certificate_type
                read -p "按回车键继续..."
                ;;
            0)
                break
                ;;
            *)
                print_error "无效选项"
                read -p "按回车键继续..."
                ;;
        esac
    done
}

# 查看证书信息
show_certificate_info() {
    print_info "证书信息:"
    
    if [[ -f "$CERT_PATH" ]]; then
        openssl x509 -in "$CERT_PATH" -text -noout | grep -E "(Subject:|Issuer:|Not Before:|Not After:)"
    else
        print_error "证书文件不存在"
    fi
}

# 更新证书
update_certificate() {
    print_info "更新证书..."
    
    if command -v ~/.acme.sh/acme.sh &> /dev/null; then
        ~/.acme.sh/acme.sh --cron --force
        print_success "证书更新完成"
        systemctl restart hysteria2
    else
        print_warning "未找到 acme.sh，请手动更新证书"
    fi
}

# 强制续期证书
force_renew_certificate() {
    if [[ -z "$DOMAIN" ]]; then
        print_error "未配置域名，无法续期"
        return
    fi
    
    print_info "强制续期证书..."
    ~/.acme.sh/acme.sh --renew -d "$DOMAIN" --force
    systemctl restart hysteria2
    print_success "证书续期完成"
}

# 切换证书类型
change_certificate_type() {
    print_warning "切换证书类型将重新配置证书"
    read -p "确认继续? (y/n): " confirm
    
    if [[ $confirm == "y" || $confirm == "Y" ]]; then
        systemctl stop hysteria2
        choose_certificate_type
        configure_certificate
        
        # 更新配置文件中的证书路径
        sed -i "s|cert:.*|cert: ${CERT_PATH}|" $CONFIG_FILE
        sed -i "s|key:.*|key: ${KEY_PATH}|" $CONFIG_FILE
        
        generate_client_config
        systemctl start hysteria2
        print_success "证书类型切换完成"
    fi
}

# 卸载 Hysteria 2
uninstall_hysteria2() {
    print_warning "准备卸载 Hysteria 2..."
    read -p "确认卸载? (y/n): " CONFIRM
    
    if [[ $CONFIRM != "y" && $CONFIRM != "Y" ]]; then
        print_info "取消卸载"
        return
    fi
    
    print_info "停止服务..."
    systemctl stop hysteria2 2>/dev/null || true
    systemctl disable hysteria2 2>/dev/null || true
    
    print_info "删除文件..."
    rm -f $SERVICE_FILE
    rm -f /usr/local/bin/hysteria2
    rm -rf $WORK_DIR
    rm -rf /etc/hysteria2
    
    print_info "重新加载系统服务..."
    systemctl daemon-reload
    
    print_success "Hysteria 2 卸载完成"
}

# 查看服务状态
show_status() {
    echo -e "${BLUE}=== Hysteria 2 服务状态 ===${NC}"
    if systemctl is-active --quiet hysteria2; then
        echo -e "状态: ${GREEN}运行中${NC}"
    else
        echo -e "状态: ${RED}已停止${NC}"
    fi
    
    echo ""
    systemctl status hysteria2 --no-pager
    
    echo ""
    echo -e "${BLUE}=== 连接信息 ===${NC}"
    if [[ -f /etc/hysteria2/client_info.txt ]]; then
        cat /etc/hysteria2/client_info.txt
    else
        print_warning "配置文件不存在"
    fi
}

# 查看日志
show_logs() {
    print_info "显示 Hysteria 2 日志 (Ctrl+C 退出)..."
    journalctl -u hysteria2 -f --no-pager
}

# 重新配置
reconfigure() {
    print_warning "重新配置将覆盖当前配置"
    read -p "确认继续? (y/n): " CONFIRM
    
    if [[ $CONFIRM != "y" && $CONFIRM != "Y" ]]; then
        print_info "取消重新配置"
        return
    fi
    
    systemctl stop hysteria2
    choose_certificate_type
    configure_certificate
    generate_config
    systemctl start hysteria2
    print_success "重新配置完成"
}

# 更新 Hysteria 2
update_hysteria2() {
    print_info "更新 Hysteria 2..."
    
    systemctl stop hysteria2
    
    # 备份配置文件
    cp $CONFIG_FILE /tmp/hysteria2_config_backup.yaml
    
    # 重新安装
    install_hysteria2
    
    # 恢复配置文件
    mv /tmp/hysteria2_config_backup.yaml $CONFIG_FILE
    
    systemctl start hysteria2
    print_success "Hysteria 2 更新完成"
}

# 主菜单
show_menu() {
    while true; do
        clear
        show_welcome
        
        echo -e "${CYAN}请选择操作:${NC}"
        echo "1) 安装 Hysteria 2"
        echo "2) 卸载 Hysteria 2"
        echo "3) 查看服务状态"
        echo "4) 启动服务"
        echo "5) 停止服务"
        echo "6) 重启服务"
        echo "7) 查看日志"
        echo "8) 重新配置"
        echo "9) 更新 Hysteria 2"
        echo "10) 证书管理"
        echo "0) 退出"
        echo ""
        
        read -p "请输入选项 [0-10]: " choice
        
        case $choice in
            1)
                check_system
                install_dependencies
                install_hysteria2
                choose_certificate_type
                configure_certificate
                generate_config
                create_service
                start_service
                show_result
                read -p "按回车键继续..."
                ;;
            2)
                uninstall_hysteria2
                read -p "按回车键继续..."
                ;;
            3)
                show_status
                read -p "按回车键继续..."
                ;;
            4)
                systemctl start hysteria2
                print_success "服务已启动"
                read -p "按回车键继续..."
                ;;
            5)
                systemctl stop hysteria2
                print_success "服务已停止"
                read -p "按回车键继续..."
                ;;
            6)
                systemctl restart hysteria2
                print_success "服务已重启"
                read -p "按回车键继续..."
                ;;
            7)
                show_logs
                ;;
            8)
                reconfigure
                read -p "按回车键继续..."
                ;;
            9)
                update_hysteria2
                read -p "按回车键继续..."
                ;;
            10)
                certificate_management
                ;;
            0)
                print_info "退出脚本"
                exit 0
                ;;
            *)
                print_error "无效选项，请重新选择"
                read -p "按回车键继续..."
                ;;
        esac
    done
}

# 脚本入口
main() {
    # 检查参数
    if [[ $# -eq 0 ]]; then
        show_menu
    else
        case $1 in
            "install")
                check_system
                install_dependencies
                install_hysteria2
                choose_certificate_type
                configure_certificate
                generate_config
                create_service
                start_service
                show_result
                ;;
            "uninstall")
                uninstall_hysteria2
                ;;
            "status")
                show_status
                ;;
            "logs")
                show_logs
                ;;
            *)
                echo "用法: $0 [install|uninstall|status|logs]"
                echo "或直接运行 $0 进入交互菜单"
                ;;
        esac
    fi
}

# 执行主函数
main "$@"
