#!/bin/bash

# Hysteria 2 完整安装和管理脚本
# 支持安装、证书管理、Let's Encrypt 修复等功能

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# 打印函数
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_step() { echo -e "${PURPLE}[STEP]${NC} $1"; }

# 全局变量
HYSTERIA_DIR="/etc/hysteria2"
CERT_DIR="$HYSTERIA_DIR/certs"
CONFIG_FILE="$HYSTERIA_DIR/config.yaml"
SERVICE_FILE="/etc/systemd/system/hysteria2.service"
HYSTERIA_BINARY="/usr/local/bin/hysteria2"

# 检查系统要求
check_system() {
    print_step "检查系统要求..."
    
    # 检查是否为 root
    if [[ $EUID -ne 0 ]]; then
        print_error "请使用 root 权限运行此脚本"
        exit 1
    fi
    
    # 检查系统架构
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l) ARCH="arm" ;;
        *) 
            print_error "不支持的架构: $ARCH"
            exit 1
            ;;
    esac
    
    # 检查系统版本
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$NAME
        VERSION=$VERSION_ID
        print_info "检测到系统: $OS $VERSION"
    else
        print_warning "无法检测系统版本"
    fi
    
    # 更新软件包
    print_info "更新软件包列表..."
    if command -v apt-get &> /dev/null; then
        apt-get update -q
        apt-get install -y curl wget tar socat openssl cron
    elif command -v yum &> /dev/null; then
        yum update -y -q
        yum install -y curl wget tar socat openssl crontabs
    else
        print_warning "未知的包管理器，请手动安装依赖"
    fi
    
    print_success "系统检查完成"
}

# 安装 Hysteria 2
install_hysteria2() {
    print_step "安装 Hysteria 2..."
    
    # 获取最新版本
    print_info "获取最新版本信息..."
    LATEST_VERSION=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | grep '"tag_name"' | cut -d'"' -f4)
    if [[ -z "$LATEST_VERSION" ]]; then
        print_error "无法获取最新版本"
        return 1
    fi
    
    print_info "最新版本: $LATEST_VERSION"
    
    # 下载二进制文件
    DOWNLOAD_URL="https://github.com/apernet/hysteria/releases/download/$LATEST_VERSION/hysteria-linux-$ARCH"
    print_info "下载 Hysteria 2..."
    
    if curl -L -o "$HYSTERIA_BINARY" "$DOWNLOAD_URL"; then
        chmod +x "$HYSTERIA_BINARY"
        print_success "Hysteria 2 安装完成"
    else
        print_error "下载失败"
        return 1
    fi
    
    # 验证安装
    if "$HYSTERIA_BINARY" version; then
        print_success "Hysteria 2 验证成功"
    else
        print_error "Hysteria 2 验证失败"
        return 1
    fi
}

# 安装和配置 acme.sh
install_acme() {
    print_step "安装和配置 acme.sh..."
    
    if [[ ! -f ~/.acme.sh/acme.sh ]]; then
        print_info "安装 acme.sh..."
        curl https://get.acme.sh | sh -s email=admin@example.com
        
        # 添加到 PATH
        if ! grep -q ".acme.sh" ~/.bashrc; then
            echo 'export PATH="$HOME/.acme.sh:$PATH"' >> ~/.bashrc
        fi
        
        source ~/.acme.sh/acme.sh.env
    else
        print_info "acme.sh 已安装"
    fi
    
    # 设置默认 CA 为 Let's Encrypt
    print_info "设置默认 CA 为 Let's Encrypt..."
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    
    # 确保配置文件中设置正确
    if [[ -f ~/.acme.sh/account.conf ]]; then
        if ! grep -q "DEFAULT_CA.*letsencrypt" ~/.acme.sh/account.conf; then
            sed -i 's/DEFAULT_CA=.*/DEFAULT_CA="https:\/\/acme-v02.api.letsencrypt.org\/directory"/' ~/.acme.sh/account.conf
            if ! grep -q "DEFAULT_CA" ~/.acme.sh/account.conf; then
                echo 'DEFAULT_CA="https://acme-v02.api.letsencrypt.org/directory"' >> ~/.acme.sh/account.conf
            fi
        fi
    fi
    
    print_success "acme.sh 配置完成"
}

# 申请 Let's Encrypt 证书
request_certificate() {
    print_step "申请 Let's Encrypt 证书..."
    
    # 获取域名
    while true; do
        read -p "请输入您的域名: " DOMAIN
        if [[ -n "$DOMAIN" ]]; then
            break
        fi
        print_error "域名不能为空"
    done
    
    print_info "申请域名证书: $DOMAIN"
    
    # 创建证书目录
    mkdir -p "$CERT_DIR"
    
    # 停止可能冲突的服务
    print_info "停止可能冲突的服务..."
    systemctl stop hysteria2 2>/dev/null || true
    systemctl stop nginx 2>/dev/null || true
    systemctl stop apache2 2>/dev/null || true
    
    # 检查端口占用
    if netstat -tuln | grep -q ":80 "; then
        print_warning "端口 80 被占用，尝试释放..."
        pkill -f ":80" 2>/dev/null || true
        sleep 2
    fi
    
    # 申请证书
    print_info "使用 Let's Encrypt 申请证书..."
    if ~/.acme.sh/acme.sh --issue \
        -d "$DOMAIN" \
        --standalone \
        --server letsencrypt \
        --keylength 2048; then
        
        print_success "证书申请成功"
        
        # 安装证书
        ~/.acme.sh/acme.sh --installcert -d "$DOMAIN" \
            --key-file "$CERT_DIR/server.key" \
            --fullchain-file "$CERT_DIR/server.crt" \
            --reloadcmd "systemctl restart hysteria2" \
            --server letsencrypt
            
        print_success "证书安装完成"
        return 0
    else
        print_error "证书申请失败"
        return 1
    fi
}

# 生成配置文件
generate_config() {
    print_step "生成 Hysteria 2 配置..."
    
    # 获取配置参数
    read -p "请输入监听端口 (默认 443): " PORT
    PORT=${PORT:-443}
    
    read -p "请输入密码: " PASSWORD
    while [[ -z "$PASSWORD" ]]; do
        print_error "密码不能为空"
        read -p "请输入密码: " PASSWORD
    done
    
    read -p "请输入伪装网站 (默认 https://www.bing.com): " MASQUERADE
    MASQUERADE=${MASQUERADE:-https://www.bing.com}
    
    # 创建配置目录
    mkdir -p "$HYSTERIA_DIR"
    
    # 生成配置文件
    cat > "$CONFIG_FILE" << EOF
listen: :$PORT

tls:
  cert: $CERT_DIR/server.crt
  key: $CERT_DIR/server.key

auth:
  type: password
  password: $PASSWORD

masquerade:
  type: proxy
  proxy:
    url: $MASQUERADE
    rewriteHost: true

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  maxIncomingStreams: 1024
  disablePathMTUDiscovery: false

ignoreClientBandwidth: false
disableUDP: false
udpIdleTimeout: 60s

resolver:
  type: https
  https:
    addr: 1.1.1.1:443
    timeout: 10s
EOF

    print_success "配置文件生成完成"
    
    # 显示配置信息
    echo -e "${CYAN}配置信息:${NC}"
    echo "监听端口: $PORT"
    echo "密码: $PASSWORD"
    echo "伪装网站: $MASQUERADE"
    echo "域名: $DOMAIN"
}

# 创建系统服务
create_service() {
    print_step "创建系统服务..."
    
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Hysteria 2 Server
Documentation=https://hysteria.network/
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
User=root
Group=root
ExecStart=$HYSTERIA_BINARY server -c $CONFIG_FILE
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

    # 重载和启用服务
    systemctl daemon-reload
    systemctl enable hysteria2
    
    print_success "系统服务创建完成"
}

# 启动服务
start_service() {
    print_step "启动 Hysteria 2 服务..."
    
    # 验证配置文件
    if "$HYSTERIA_BINARY" server -c "$CONFIG_FILE" --check; then
        print_success "配置文件验证通过"
    else
        print_error "配置文件验证失败"
        return 1
    fi
    
    # 启动服务
    systemctl start hysteria2
    
    # 检查服务状态
    sleep 3
    if systemctl is-active --quiet hysteria2; then
        print_success "Hysteria 2 服务启动成功"
        return 0
    else
        print_error "服务启动失败"
        systemctl status hysteria2 --no-pager -l
        return 1
    fi
}

# 生成客户端配置
generate_client_config() {
    print_step "生成客户端配置..."
    
    if [[ -z "$DOMAIN" ]]; then
        DOMAIN=$(openssl x509 -in "$CERT_DIR/server.crt" -noout -subject | grep -o 'CN=[^,]*' | cut -d'=' -f2 2>/dev/null || echo "your-domain.com")
    fi
    
    if [[ -z "$PASSWORD" ]]; then
        PASSWORD=$(grep "password:" "$CONFIG_FILE" | awk '{print $2}' 2>/dev/null || echo "your-password")
    fi
    
    if [[ -z "$PORT" ]]; then
        PORT=$(grep "listen:" "$CONFIG_FILE" | awk -F: '{print $NF}' 2>/dev/null || echo "443")
    fi
    
    # 获取服务器IP
    SERVER_IP=$(curl -s ipv4.icanhazip.com 2>/dev/null || curl -s ifconfig.me 2>/dev/null || echo "YOUR_SERVER_IP")
    
    cat > "/root/hysteria2-client.yaml" << EOF
server: $DOMAIN:$PORT

auth: $PASSWORD

tls:
  sni: $DOMAIN
  insecure: false

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  keepAlivePeriod: 10s
  disablePathMTUDiscovery: false

bandwidth:
  up: 20 mbps
  down: 100 mbps

socks5:
  listen: 127.0.0.1:1080

http:
  listen: 127.0.0.1:8080
EOF

    print_success "客户端配置已保存到: /root/hysteria2-client.yaml"
    
    echo -e "${CYAN}客户端连接信息:${NC}"
    echo "服务器: $DOMAIN:$PORT"
    echo "密码: $PASSWORD"
    echo "SOCKS5 代理: 127.0.0.1:1080"
    echo "HTTP 代理: 127.0.0.1:8080"
}

# 修复 Let's Encrypt 设置
fix_letsencrypt() {
    print_step "修复 Let's Encrypt 设置..."
    
    # 检查当前证书提供商
    if [[ -f "$CERT_DIR/server.crt" ]]; then
        CURRENT_ISSUER=$(openssl x509 -in "$CERT_DIR/server.crt" -noout -issuer 2>/dev/null)
        echo -e "${BLUE}当前证书颁发者:${NC} $CURRENT_ISSUER"
        
        if echo "$CURRENT_ISSUER" | grep -qi "zerossl"; then
            print_warning "检测到 ZeroSSL 证书，将切换到 Let's Encrypt"
            NEED_REISSUE=true
        elif echo "$CURRENT_ISSUER" | grep -qi "let's encrypt"; then
            print_success "已在使用 Let's Encrypt 证书"
            NEED_REISSUE=false
        else
            print_info "未知证书颁发者，建议重新申请"
            NEED_REISSUE=true
        fi
    else
        print_warning "未找到证书文件"
        NEED_REISSUE=true
    fi
    
    # 设置默认 CA 为 Let's Encrypt
    print_info "设置默认 CA 为 Let's Encrypt..."
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    
    # 修复配置文件
    if [[ -f ~/.acme.sh/account.conf ]]; then
        sed -i 's/DEFAULT_CA=.*/DEFAULT_CA="https:\/\/acme-v02.api.letsencrypt.org\/directory"/' ~/.acme.sh/account.conf
        if ! grep -q "DEFAULT_CA" ~/.acme.sh/account.conf; then
            echo 'DEFAULT_CA="https://acme-v02.api.letsencrypt.org/directory"' >> ~/.acme.sh/account.conf
        fi
    fi
    
    if [[ "$NEED_REISSUE" == "true" ]]; then
        echo ""
        read -p "是否重新申请 Let's Encrypt 证书？(y/n): " CONFIRM
        if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
            reissue_certificate
        fi
    fi
    
    # 更新续期设置
    DOMAIN_LIST=$(~/.acme.sh/acme.sh --list 2>/dev/null | grep -v "Main_Domain" | awk '{print $1}' | grep -v "^$")
    for domain in $DOMAIN_LIST; do
        if [[ -n "$domain" ]]; then
            print_info "更新域名 $domain 的续期设置..."
            ~/.acme.sh/acme.sh --installcert -d "$domain" \
                --key-file "$CERT_DIR/server.key" \
                --fullchain-file "$CERT_DIR/server.crt" \
                --reloadcmd "systemctl restart hysteria2" \
                --server letsencrypt
        fi
    done
    
    print_success "Let's Encrypt 设置修复完成"
}

# 重新申请证书
reissue_certificate() {
    print_info "重新申请 Let's Encrypt 证书..."
    
    # 获取域名
    DOMAIN_LIST=$(~/.acme.sh/acme.sh --list 2>/dev/null | grep -v "Main_Domain" | awk '{print $1}' | grep -v "^$")
    
    if [[ -z "$DOMAIN_LIST" ]]; then
        read -p "请输入域名: " DOMAIN
    else
        echo -e "${BLUE}已配置的域名:${NC}"
        echo "$DOMAIN_LIST"
        read -p "请输入要重新申请的域名（回车选择第一个）: " DOMAIN
        if [[ -z "$DOMAIN" ]]; then
            DOMAIN=$(echo "$DOMAIN_LIST" | head -n1)
        fi
    fi
    
    if [[ -z "$DOMAIN" ]]; then
        print_error "域名不能为空"
        return 1
    fi
    
    print_info "重新申请域名: $DOMAIN"
    
    # 停止服务
    systemctl stop hysteria2 2>/dev/null || true
    systemctl stop nginx 2>/dev/null || true
    systemctl stop apache2 2>/dev/null || true
    
    # 删除旧证书记录
    ~/.acme.sh/acme.sh --remove -d "$DOMAIN" 2>/dev/null || true
    
    # 申请新证书
    if ~/.acme.sh/acme.sh --issue \
        -d "$DOMAIN" \
        --standalone \
        --server letsencrypt \
        --keylength 2048 \
        --force; then
        
        # 安装证书
        ~/.acme.sh/acme.sh --installcert -d "$DOMAIN" \
            --key-file "$CERT_DIR/server.key" \
            --fullchain-file "$CERT_DIR/server.crt" \
            --reloadcmd "systemctl restart hysteria2" \
            --server letsencrypt
            
        print_success "Let's Encrypt 证书申请成功"
        
        # 重启服务
        systemctl start hysteria2
        
        return 0
    else
        print_error "证书申请失败"
        return 1
    fi
}

# 查看证书信息
show_certificate_info() {
    print_step "证书信息..."
    
    if [[ -f "$CERT_DIR/server.crt" ]]; then
        echo -e "${BLUE}证书文件信息:${NC}"
        echo "证书文件: $CERT_DIR/server.crt"
        echo "密钥文件: $CERT_DIR/server.key"
        
        echo -e "\n${BLUE}证书详情:${NC}"
        openssl x509 -in "$CERT_DIR/server.crt" -text -noout | grep -E "(Subject:|Issuer:|Not Before:|Not After:|DNS:)"
        
        echo -e "\n${BLUE}证书有效期:${NC}"
        openssl x509 -in "$CERT_DIR/server.crt" -noout -dates
        
        # 计算剩余天数
        end_date=$(openssl x509 -in "$CERT_DIR/server.crt" -noout -enddate | cut -d= -f2)
        end_timestamp=$(date -d "$end_date" +%s 2>/dev/null || echo "0")
        current_timestamp=$(date +%s)
        
        if [[ "$end_timestamp" -gt 0 ]]; then
            days_left=$(( (end_timestamp - current_timestamp) / 86400 ))
            echo -e "${BLUE}距离到期:${NC} $days_left 天"
            
            if [[ $days_left -lt 30 ]]; then
                print_warning "证书将在 $days_left 天后到期，建议续期"
            fi
        fi
    else
        print_error "未找到证书文件"
    fi
    
    echo -e "\n${BLUE}acme.sh 证书列表:${NC}"
    ~/.acme.sh/acme.sh --list 2>/dev/null || print_warning "获取证书列表失败"
}

# 查看服务状态
show_status() {
    print_step "服务状态..."
    
    echo -e "${BLUE}Hysteria 2 服务状态:${NC}"
    if systemctl is-active --quiet hysteria2; then
        print_success "服务运行中"
        systemctl status hysteria2 --no-pager -l
    else
        print_error "服务未运行"
        systemctl status hysteria2 --no-pager -l
    fi
    
    echo -e "\n${BLUE}端口监听状态:${NC}"
    if [[ -f "$CONFIG_FILE" ]]; then
        PORT=$(grep "listen:" "$CONFIG_FILE" | awk -F: '{print $NF}' | tr -d ' ')
        if netstat -tuln | grep -q ":$PORT "; then
            print_success "端口 $PORT 正在监听"
        else
            print_warning "端口 $PORT 未在监听"
        fi
    fi
    
    echo -e "\n${BLUE}配置文件:${NC}"
    if [[ -f "$CONFIG_FILE" ]]; then
        print_success "配置文件存在: $CONFIG_FILE"
    else
        print_error "配置文件不存在"
    fi
    
    echo -e "\n${BLUE}证书文件:${NC}"
    if [[ -f "$CERT_DIR/server.crt" && -f "$CERT_DIR/server.key" ]]; then
        print_success "证书文件存在"
    else
        print_error "证书文件缺失"
    fi
}

# 卸载 Hysteria 2
uninstall_hysteria2() {
    print_step "卸载 Hysteria 2..."
    
    read -p "确认要完全卸载 Hysteria 2？(y/n): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        print_info "取消卸载"
        return
    fi
    
    # 停止并禁用服务
    print_info "停止服务..."
    systemctl stop hysteria2 2>/dev/null || true
    systemctl disable hysteria2 2>/dev/null || true
    
    # 删除服务文件
    print_info "删除服务文件..."
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    
    # 删除二进制文件
    print_info "删除程序文件..."
    rm -f "$HYSTERIA_BINARY"
    
    # 删除配置文件
    read -p "是否删除配置和证书文件？(y/n): " DELETE_CONFIG
    if [[ "$DELETE_CONFIG" =~ ^[Yy]$ ]]; then
        rm -rf "$HYSTERIA_DIR"
        print_info "配置和证书文件已删除"
    fi
    
    print_success "Hysteria 2 卸载完成"
}

# 完整安装流程
full_install() {
    print_step "开始 Hysteria 2 完整安装..."
    
    check_system || exit 1
    install_hysteria2 || exit 1
    install_acme || exit 1
    request_certificate || exit 1
    generate_config || exit 1
    create_service || exit 1
    start_service || exit 1
    generate_client_config
    
    print_success "Hysteria 2 安装完成！"
    show_status
}

# 主菜单
show_menu() {
    while true; do
        clear
        echo -e "${CYAN}========================================${NC}"
        echo -e "${CYAN}        Hysteria 2 管理脚本${NC}"
        echo -e "${CYAN}========================================${NC}"
        echo ""
        echo "  安装管理:"
        echo "  1) 完整安装 Hysteria 2"
        echo "  2) 仅安装 Hysteria 2 程序"
        echo "  3) 申请/更新证书"
        echo "  4) 生成配置文件"
        echo ""
        echo "  证书管理:"
        echo "  5) 修复 Let's Encrypt 设置"
        echo "  6) 重新申请证书"
        echo "  7) 查看证书信息"
        echo ""
        echo "  服务管理:"
        echo "  8) 启动/重启服务"
        echo "  9) 停止服务"
        echo " 10) 查看服务状态"
        echo " 11) 生成客户端配置"
        echo ""
        echo " 12) 卸载 Hysteria 2"
        echo "  0) 退出"
        echo ""
        
        read -p "请选择操作 [0-12]: " choice
        
        case $choice in
            1) full_install; read -p "按回车继续..." ;;
            2) check_system && install_hysteria2; read -p "按回车继续..." ;;
            3) install_acme && request_certificate; read -p "按回车继续..." ;;
            4) generate_config; read -p "按回车继续..." ;;
            5) fix_letsencrypt; read -p "按回车继续..." ;;
            6) reissue_certificate; read -p "按回车继续..." ;;
            7) show_certificate_info; read -p "按回车继续..." ;;
            8) systemctl restart hysteria2; show_status; read -p "按回车继续..." ;;
            9) systemctl stop hysteria2; print_info "服务已停止"; read -p "按回车继续..." ;;
            10) show_status; read -p "按回车继续..." ;;
            11) generate_client_config; read -p "按回车继续..." ;;
            12) uninstall_hysteria2; read -p "按回车继续..." ;;
            0) print_info "退出"; exit 0 ;;
            *) print_error "无效选项"; read -p "按回车继续..." ;;
        esac
    done
}

# 脚本入口
main() {
    case "${1:-menu}" in
        "install") full_install ;;
        "fix") fix_letsencrypt ;;
        "cert") show_certificate_info ;;
        "status") show_status ;;
        "reissue") reissue_certificate ;;
        *) show_menu ;;
    esac
}

main "$@"
