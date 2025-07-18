#!/bin/bash

# Hysteria2 一键安装脚本
# 支持 Linux 系统 (Ubuntu, Debian, CentOS, etc.)

set -e

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

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要root权限运行"
        exit 1
    fi
}

# 检测系统架构
detect_arch() {
    local arch=$(uname -m)
    case $arch in
        x86_64)
            echo "amd64"
            ;;
        aarch64)
            echo "arm64"
            ;;
        armv7l)
            echo "arm"
            ;;
        *)
            log_error "不支持的架构: $arch"
            exit 1
            ;;
    esac
}

# 检测操作系统
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo $ID
    elif [[ -f /etc/redhat-release ]]; then
        echo "centos"
    else
        log_error "无法检测操作系统"
        exit 1
    fi
}

# 安装依赖
install_dependencies() {
    local os=$(detect_os)
    log_info "安装依赖包..."
    
    case $os in
        ubuntu|debian)
            apt update
            apt install -y curl wget unzip systemd
            ;;
        centos|rhel|fedora)
            yum update -y
            yum install -y curl wget unzip systemd
            ;;
        *)
            log_warn "未知操作系统，尝试继续..."
            ;;
    esac
}

# 下载并安装Hysteria2
install_hysteria2() {
    local arch=$(detect_arch)
    local version="latest"
    local download_url="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${arch}"
    
    log_info "下载Hysteria2..."
    
    # 创建目录
    mkdir -p /etc/hysteria2
    mkdir -p /var/log/hysteria2
    
    # 下载二进制文件
    if ! curl -L -o /usr/local/bin/hysteria2 "$download_url"; then
        log_error "下载失败"
        exit 1
    fi
    
    # 设置权限
    chmod +x /usr/local/bin/hysteria2
    
    log_info "Hysteria2 安装完成"
}

# 安装 acme.sh 并申请证书
install_acme() {
    log_info "安装 acme.sh..."
    
    # 检查是否已安装
    if [[ -f ~/.acme.sh/acme.sh ]]; then
        log_info "acme.sh 已安装"
        return 0
    fi
    
    # 安装 acme.sh
    curl https://get.acme.sh | sh -s email=admin@example.com
    
    # 设置别名
    alias acme.sh=~/.acme.sh/acme.sh
    
    log_info "acme.sh 安装完成"
}

# 申请 Let's Encrypt 证书
get_letsencrypt_cert() {
    local domain=$1
    local email=${2:-admin@example.com}
    
    if [[ -z "$domain" ]]; then
        log_error "域名不能为空"
        return 1
    fi
    
    log_info "为域名 $domain 申请 Let's Encrypt 证书..."
    
    # 安装 acme.sh
    install_acme
    
    # 停止可能占用 80 端口的服务
    systemctl stop nginx 2>/dev/null || true
    systemctl stop apache2 2>/dev/null || true
    systemctl stop httpd 2>/dev/null || true
    
    # 申请证书（使用 standalone 模式）
    ~/.acme.sh/acme.sh --issue -d "$domain" --standalone --keylength ec-256
    
    if [[ $? -eq 0 ]]; then
        log_info "证书申请成功"
        
        # 安装证书到指定目录
        ~/.acme.sh/acme.sh --install-cert -d "$domain" --ecc \
            --cert-file /etc/hysteria2/server.crt \
            --key-file /etc/hysteria2/server.key \
            --fullchain-file /etc/hysteria2/fullchain.crt \
            --reloadcmd "systemctl reload hysteria2"
        
        # 设置权限
        chmod 600 /etc/hysteria2/server.key
        chmod 644 /etc/hysteria2/server.crt
        chmod 644 /etc/hysteria2/fullchain.crt
        
        log_info "证书安装完成"
        return 0
    else
        log_error "证书申请失败"
        return 1
    fi
}

# 自动检测证书路径
auto_detect_cert() {
    local domain=$1
    
    # 常见的证书路径
    local cert_paths=(
        "/etc/letsencrypt/live/${domain}/fullchain.pem"
        "/etc/letsencrypt/live/${domain}/cert.pem"
        "/etc/ssl/certs/${domain}.crt"
        "/etc/ssl/certs/${domain}.pem"
        "/etc/nginx/ssl/${domain}.crt"
        "/etc/nginx/ssl/${domain}.pem"
        "/etc/apache2/ssl/${domain}.crt"
        "/etc/apache2/ssl/${domain}.pem"
        "/opt/ssl/${domain}.crt"
        "/opt/ssl/${domain}.pem"
        "/usr/local/nginx/conf/ssl/${domain}.crt"
        "/usr/local/nginx/conf/ssl/${domain}.pem"
        "/www/server/panel/vhost/cert/${domain}/fullchain.pem"
        "/www/server/panel/vhost/cert/${domain}/cert.pem"
        "~/.acme.sh/${domain}_ecc/fullchain.cer"
        "~/.acme.sh/${domain}/fullchain.cer"
        "/root/.acme.sh/${domain}_ecc/fullchain.cer"
        "/root/.acme.sh/${domain}/fullchain.cer"
    )
    
    local key_paths=(
        "/etc/letsencrypt/live/${domain}/privkey.pem"
        "/etc/ssl/private/${domain}.key"
        "/etc/nginx/ssl/${domain}.key"
        "/etc/apache2/ssl/${domain}.key"
        "/opt/ssl/${domain}.key"
        "/usr/local/nginx/conf/ssl/${domain}.key"
        "/www/server/panel/vhost/cert/${domain}/privkey.pem"
        "~/.acme.sh/${domain}_ecc/${domain}.key"
        "~/.acme.sh/${domain}/${domain}.key"
        "/root/.acme.sh/${domain}_ecc/${domain}.key"
        "/root/.acme.sh/${domain}/${domain}.key"
    )
    
    log_info "自动检测域名 ${domain} 的证书路径..."
    
    local found_cert=""
    local found_key=""
    
    # 检测证书文件
    for cert_path in "${cert_paths[@]}"; do
        # 展开 ~ 路径
        cert_path=$(eval echo "$cert_path")
        if [[ -f "$cert_path" ]]; then
            found_cert="$cert_path"
            log_info "找到证书文件: $cert_path"
            break
        fi
    done
    
    # 检测密钥文件
    for key_path in "${key_paths[@]}"; do
        # 展开 ~ 路径
        key_path=$(eval echo "$key_path")
        if [[ -f "$key_path" ]]; then
            found_key="$key_path"
            log_info "找到密钥文件: $key_path"
            break
        fi
    done
    
    # 检查是否找到了证书和密钥
    if [[ -n "$found_cert" ]] && [[ -n "$found_key" ]]; then
        log_info "自动检测到证书，使用现有证书文件"
        use_custom_cert "$found_cert" "$found_key"
        return 0
    else
        log_warn "未找到现有证书文件"
        return 1
    fi
}

# 自动检测所有可能的证书
auto_detect_any_cert() {
    log_info "自动检测系统中的证书文件..."
    
    # 通用证书路径（不依赖域名）
    local common_cert_paths=(
        "/etc/letsencrypt/live/*/fullchain.pem"
        "/etc/letsencrypt/live/*/cert.pem"
        "/etc/ssl/certs/*.crt"
        "/etc/ssl/certs/*.pem"
        "/etc/nginx/ssl/*.crt"
        "/etc/nginx/ssl/*.pem"
        "/etc/apache2/ssl/*.crt"
        "/etc/apache2/ssl/*.pem"
        "/opt/ssl/*.crt"
        "/opt/ssl/*.pem"
        "/www/server/panel/vhost/cert/*/fullchain.pem"
        "/root/.acme.sh/*/fullchain.cer"
        "/root/.acme.sh/*_ecc/fullchain.cer"
    )
    
    local found_cert=""
    local found_key=""
    
    # 搜索证书文件
    for pattern in "${common_cert_paths[@]}"; do
        for cert_file in $pattern; do
            if [[ -f "$cert_file" ]]; then
                # 尝试找到对应的密钥文件
                local dir=$(dirname "$cert_file")
                local basename=$(basename "$cert_file")
                
                # 可能的密钥文件名
                local key_patterns=(
                    "${dir}/privkey.pem"
                    "${dir}/private.key"
                    "${dir}/*.key"
                    "${dir}/${basename%.*}.key"
                )
                
                for key_pattern in "${key_patterns[@]}"; do
                    for key_file in $key_pattern; do
                        if [[ -f "$key_file" ]]; then
                            found_cert="$cert_file"
                            found_key="$key_file"
                            log_info "找到证书对: $cert_file, $key_file"
                            break 3
                        fi
                    done
                done
            fi
        done
    done
    
    if [[ -n "$found_cert" ]] && [[ -n "$found_key" ]]; then
        log_info "自动检测到证书，使用现有证书文件"
        use_custom_cert "$found_cert" "$found_key"
        return 0
    else
        log_warn "未找到任何可用的证书文件"
        return 1
    fi
}

# 使用用户提供的证书
use_custom_cert() {
    local cert_path=$1
    local key_path=$2
    
    if [[ ! -f "$cert_path" ]] || [[ ! -f "$key_path" ]]; then
        log_error "证书文件不存在"
        return 1
    fi
    
    log_info "使用自定义证书..."
    
    # 复制证书文件
    cp "$cert_path" /etc/hysteria2/server.crt
    cp "$key_path" /etc/hysteria2/server.key
    
    # 设置权限
    chmod 600 /etc/hysteria2/server.key
    chmod 644 /etc/hysteria2/server.crt
    
    log_info "自定义证书配置完成"
    return 0
}

# 证书配置主函数
setup_certificate() {
    local cert_type=$1
    local domain=$2
    local cert_path=$3
    local key_path=$4
    
    case $cert_type in
        "letsencrypt")
            if [[ -z "$domain" ]]; then
                log_error "使用 Let's Encrypt 需要提供域名"
                exit 1
            fi
            get_letsencrypt_cert "$domain"
            ;;
        "custom")
            if [[ -z "$cert_path" ]] || [[ -z "$key_path" ]]; then
                log_error "使用自定义证书需要提供证书路径和密钥路径"
                exit 1
            fi
            use_custom_cert "$cert_path" "$key_path"
            ;;
        "auto")
            # 自动检测模式
            if [[ -n "$domain" ]]; then
                # 如果提供了域名，先尝试检测该域名的证书
                if ! auto_detect_cert "$domain"; then
                    log_info "未找到域名 $domain 的证书，尝试申请 Let's Encrypt 证书..."
                    get_letsencrypt_cert "$domain"
                fi
            else
                # 没有提供域名，尝试检测任何可用的证书
                if ! auto_detect_any_cert; then
                    log_error "未找到任何可用的证书，请指定域名以申请 Let's Encrypt 证书，或手动指定证书路径"
                    exit 1
                fi
            fi
            ;;
        *)
            log_error "不支持的证书类型: $cert_type"
            log_info "支持的类型: letsencrypt, custom, auto"
            exit 1
            ;;
    esac
}

# 生成配置文件
generate_config() {
    local password=$(openssl rand -base64 32)
    local port=${1:-8443}
    
    log_info "生成配置文件..."
    
    cat > /etc/hysteria2/config.yaml << EOF
listen: :${port}

tls:
  cert: /etc/hysteria2/server.crt
  key: /etc/hysteria2/server.key

auth:
  type: password
  password: ${password}

masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520

bandwidth:
  up: 1 gbps
  down: 1 gbps

ignoreClientBandwidth: false
disableUDP: false
udpIdleTimeout: 60s

resolver:
  type: udp
  tcp:
    addr: 8.8.8.8:53
    timeout: 4s
  udp:
    addr: 8.8.8.8:53
    timeout: 4s
  tls:
    addr: 1.1.1.1:853
    timeout: 10s
    sni: cloudflare-dns.com
    insecure: false
  https:
    addr: 1.1.1.1:443
    timeout: 10s
    sni: cloudflare-dns.com
    insecure: false

sniff:
  enable: true
  timeout: 2s
  rewriteDomain: false
  tcpPorts: 80,443,8000-8080
  udpPorts: 443,53

tcpRedirect:
  listen: :8080
  sniff: true
  timeout: 3s

udpRedirect:
  listen: :5353
  timeout: 3s
EOF

    log_info "配置文件已生成"
    log_info "连接密码: ${password}"
    log_info "端口: ${port}"
}

# 创建systemd服务
create_service() {
    log_info "创建systemd服务..."
    
    cat > /etc/systemd/system/hysteria2.service << EOF
[Unit]
Description=Hysteria2 Server
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/hysteria2 server -c /etc/hysteria2/config.yaml
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable hysteria2
}

# 配置防火墙
configure_firewall() {
    local port=${1:-8443}
    
    log_info "配置防火墙..."
    
    # 尝试配置 ufw
    if command -v ufw &> /dev/null; then
        ufw allow $port/tcp
        ufw allow $port/udp
    fi
    
    # 尝试配置 firewalld
    if command -v firewall-cmd &> /dev/null; then
        firewall-cmd --permanent --add-port=$port/tcp
        firewall-cmd --permanent --add-port=$port/udp
        firewall-cmd --reload
    fi
    
    # 尝试配置 iptables
    if command -v iptables &> /dev/null; then
        iptables -A INPUT -p tcp --dport $port -j ACCEPT
        iptables -A INPUT -p udp --dport $port -j ACCEPT
        # 保存规则（不同系统可能不同）
        if command -v iptables-save &> /dev/null; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        fi
    fi
}

# 启动服务
start_service() {
    log_info "启动Hysteria2服务..."
    
    systemctl start hysteria2
    
    if systemctl is-active --quiet hysteria2; then
        log_info "服务启动成功"
    else
        log_error "服务启动失败"
        exit 1
    fi
}

# 显示连接信息
show_connection_info() {
    local port=${1:-8443}
    local server_ip=$(curl -s ifconfig.me || curl -s ipinfo.io/ip || echo "YOUR_SERVER_IP")
    
    echo
    echo "=================================="
    echo "Hysteria2 安装完成！"
    echo "=================================="
    echo "服务器地址: $server_ip"
    echo "端口: $port"
    echo "协议: hysteria2"
    echo "认证: password"
    echo "TLS: 启用 (自签名证书)"
    echo
    echo "配置文件位置: /etc/hysteria2/config.yaml"
    echo "日志查看: journalctl -u hysteria2 -f"
    echo "服务管理:"
    echo "  启动: systemctl start hysteria2"
    echo "  停止: systemctl stop hysteria2"
    echo "  重启: systemctl restart hysteria2"
    echo "  状态: systemctl status hysteria2"
    echo "=================================="
}

# 显示使用说明
show_usage() {
    echo "Hysteria2 一键安装脚本"
    echo
    echo "使用方法:"
    echo "  $0 [选项] [端口]"
    echo
    echo "选项:"
    echo "  -t, --cert-type TYPE     证书类型 (letsencrypt|custom|auto)"
    echo "  -d, --domain DOMAIN      域名 (用于 Let's Encrypt 或自动检测)"
    echo "  -c, --cert-file FILE     证书文件路径 (用于自定义证书)"
    echo "  -k, --key-file FILE      密钥文件路径 (用于自定义证书)"
    echo "  -p, --port PORT          端口号 (默认: 8443)"
    echo "  -h, --help               显示帮助信息"
    echo
    echo "证书类型说明:"
    echo "  letsencrypt             申请 Let's Encrypt 免费证书"
    echo "  custom                  使用指定的证书文件"
    echo "  auto                    自动检测现有证书或申请新证书"
    echo
    echo "示例:"
    echo "  # 自动检测证书（推荐）"
    echo "  $0 -t auto -d example.com"
    echo
    echo "  # 使用 Let's Encrypt 证书"
    echo "  $0 -t letsencrypt -d example.com -p 8443"
    echo
    echo "  # 使用自定义证书"
    echo "  $0 -t custom -c /path/to/cert.pem -k /path/to/key.pem -p 8443"
    echo
    echo "  # 自动检测任何可用证书（无域名）"
    echo "  $0 -t auto"
    echo
    echo "一键安装命令:"
    echo "  # 自动模式（推荐）"
    echo "  bash <(curl -fsSL https://raw.githubusercontent.com/username/repo/main/install.sh) -t auto -d your-domain.com"
    echo
    echo "  # Let's Encrypt 证书"
    echo "  bash <(curl -fsSL https://raw.githubusercontent.com/username/repo/main/install.sh) -t letsencrypt -d your-domain.com"
    echo
    echo "  # 自定义证书"
    echo "  bash <(curl -fsSL https://raw.githubusercontent.com/username/repo/main/install.sh) -t custom -c /path/to/cert.pem -k /path/to/key.pem"
}

# 解析命令行参数
parse_args() {
    CERT_TYPE="auto"  # 默认使用自动检测
    DOMAIN=""
    CERT_FILE=""
    KEY_FILE=""
    PORT=8443
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -t|--cert-type)
                CERT_TYPE="$2"
                shift 2
                ;;
            -d|--domain)
                DOMAIN="$2"
                shift 2
                ;;
            -c|--cert-file)
                CERT_FILE="$2"
                shift 2
                ;;
            -k|--key-file)
                KEY_FILE="$2"
                shift 2
                ;;
            -p|--port)
                PORT="$2"
                shift 2
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            -*)
                log_error "未知参数: $1"
                show_usage
                exit 1
                ;;
            *)
                # 如果是数字，当作端口处理
                if [[ "$1" =~ ^[0-9]+$ ]]; then
                    PORT="$1"
                else
                    log_error "未知参数: $1"
                    show_usage
                    exit 1
                fi
                shift
                ;;
        esac
    done
    
    # 验证参数
    if [[ "$CERT_TYPE" == "letsencrypt" ]] && [[ -z "$DOMAIN" ]]; then
        log_error "使用 Let's Encrypt 需要指定域名 (-d domain.com)"
        show_usage
        exit 1
    fi
    
    if [[ "$CERT_TYPE" == "custom" ]] && ([[ -z "$CERT_FILE" ]] || [[ -z "$KEY_FILE" ]]); then
        log_error "使用自定义证书需要指定证书文件路径 (-c cert.pem -k key.pem)"
        show_usage
        exit 1
    fi
}

# 主函数
main() {
    log_info "开始安装Hysteria2..."
    
    # 检查root权限
    check_root
    
    # 解析命令行参数
    parse_args "$@"
    
    # 安装步骤
    install_dependencies
    install_hysteria2
    setup_certificate "$CERT_TYPE" "$DOMAIN" "$CERT_FILE" "$KEY_FILE"
    generate_config $PORT
    create_service
    configure_firewall $PORT
    start_service
    show_connection_info $PORT
    
    log_info "安装完成！"
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
