#!/bin/bash

# Hysteria 2 完整安装脚本 - 修复版本
# 修复端口跳跃配置文件格式问题和其他优化

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
IPTABLES_RULES_FILE="/etc/hysteria2/iptables-rules.sh"

# 检查系统
check_system() {
    print_step "检查系统环境..."
    
    if [[ $EUID -ne 0 ]]; then
        print_error "请使用 root 权限运行"
        exit 1
    fi
    
    # 检查架构
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        armv7l) ARCH="arm" ;;
        armv8*) ARCH="arm64" ;;
        *) print_error "不支持的架构: $ARCH"; exit 1 ;;
    esac
    
    print_info "系统架构: $ARCH"
    
    # 安装依赖
    print_info "安装必要工具..."
    if command -v apt-get &> /dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget tar socat openssl cron net-tools dnsutils lsof iptables iptables-persistent
    elif command -v yum &> /dev/null; then
        yum update -y -q
        yum install -y curl wget tar socat openssl crontabs net-tools bind-utils lsof iptables-services
    elif command -v dnf &> /dev/null; then
        dnf update -y -q
        dnf install -y curl wget tar socat openssl cronie net-tools bind-utils lsof iptables-services
    fi
    
    print_success "系统检查完成 ($ARCH)"
}

# 改进的安装 Hysteria 2 函数
install_hysteria2() {
    print_step "安装 Hysteria 2..."
    
    # 先清理可能存在的旧文件
    rm -f "$HYSTERIA_BINARY" 2>/dev/null || true
    
    # 获取最新版本
    print_info "获取最新版本信息..."
    LATEST_VERSION=""
    
    # 尝试多种方式获取版本
    for i in {1..3}; do
        LATEST_VERSION=$(curl -s --connect-timeout 10 --max-time 30 \
            "https://api.github.com/repos/apernet/hysteria/releases/latest" | \
            grep '"tag_name"' | cut -d'"' -f4 2>/dev/null)
        
        if [[ -n "$LATEST_VERSION" ]]; then
            break
        fi
        
        print_warning "第 $i 次获取版本失败，重试中..."
        sleep 2
    done
    
    # 如果仍然失败，使用备用版本
    if [[ -z "$LATEST_VERSION" ]]; then
        LATEST_VERSION="v2.6.0"
        print_warning "无法获取最新版本，使用默认版本: $LATEST_VERSION"
    else
        print_info "最新版本: $LATEST_VERSION"
    fi
    
    # 构造下载链接
    DOWNLOAD_URL="https://github.com/apernet/hysteria/releases/download/$LATEST_VERSION/hysteria-linux-$ARCH"
    
    print_info "下载地址: $DOWNLOAD_URL"
    
    # 尝试下载
    print_info "正在下载 Hysteria 2..."
    local download_success=false
    
    # 尝试多次下载
    for i in {1..3}; do
        if curl -L --progress-bar \
            --connect-timeout 30 \
            --max-time 300 \
            --retry 3 \
            --retry-delay 2 \
            -o "$HYSTERIA_BINARY" \
            "$DOWNLOAD_URL"; then
            download_success=true
            break
        fi
        
        print_warning "第 $i 次下载失败，重试中..."
        rm -f "$HYSTERIA_BINARY" 2>/dev/null || true
        sleep 3
    done
    
    if [[ "$download_success" = false ]]; then
        print_error "下载失败，请检查网络连接"
        return 1
    fi
    
    # 检查文件是否成功下载
    if [[ ! -f "$HYSTERIA_BINARY" ]] || [[ ! -s "$HYSTERIA_BINARY" ]]; then
        print_error "下载的文件无效"
        rm -f "$HYSTERIA_BINARY" 2>/dev/null || true
        return 1
    fi
    
    # 设置执行权限
    chmod +x "$HYSTERIA_BINARY"
    
    # 验证二进制文件
    print_info "验证程序..."
    if "$HYSTERIA_BINARY" version >/dev/null 2>&1; then
        local version_info=$("$HYSTERIA_BINARY" version 2>/dev/null | head -1)
        print_success "Hysteria 2 安装成功"
        print_info "版本信息: $version_info"
        return 0
    else
        print_error "程序验证失败"
        rm -f "$HYSTERIA_BINARY" 2>/dev/null || true
        return 1
    fi
}

# 重新安装 acme.sh
install_acme_clean() {
    print_step "重新安装 acme.sh..."
    
    # 完全清理
    print_info "清理旧安装..."
    pkill -f acme.sh 2>/dev/null || true
    rm -rf ~/.acme.sh 2>/dev/null || true
    
    # 清理环境变量
    if [[ -f ~/.bashrc ]]; then
        sed -i '/acme\.sh/d' ~/.bashrc 2>/dev/null || true
    fi
    
    # 清理 crontab
    (crontab -l 2>/dev/null | grep -v acme.sh) | crontab - 2>/dev/null || true
    
    # 获取邮箱
    local email=""
    while true; do
        read -p "请输入邮箱地址（用于证书通知）: " email
        if [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] && \
           [[ ! "$email" =~ @(example\.(com|org|net)|test\.com|localhost)$ ]]; then
            break
        fi
        print_error "请输入有效的邮箱地址"
    done
    
    print_success "使用邮箱: $email"
    
    # 下载并安装
    print_info "下载 acme.sh..."
    cd /tmp
    rm -rf acme.sh-master
    
    if curl -sL https://github.com/acmesh-official/acme.sh/archive/master.tar.gz | tar xz; then
        cd acme.sh-master
        print_info "安装 acme.sh..."
        
        # 直接安装
        ./acme.sh --install \
            --home ~/.acme.sh \
            --config-home ~/.acme.sh \
            --cert-home ~/.acme.sh \
            --accountemail "$email"
        
        # 加载环境
        source ~/.acme.sh/acme.sh.env 2>/dev/null || true
        
        # 手动创建正确的配置
        print_info "配置 acme.sh..."
        cat > ~/.acme.sh/account.conf << EOF
ACCOUNT_EMAIL='$email'
DEFAULT_CA='https://acme-v02.api.letsencrypt.org/directory'
AUTO_UPGRADE='1'
EOF
        
        # 设置默认 CA
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        
        print_success "acme.sh 安装完成"
        return 0
    else
        print_error "下载失败"
        return 1
    fi
}

# 选择证书颁发机构
choose_ca_provider() {
    echo ""
    echo -e "${CYAN}选择证书颁发机构 (CA):${NC}"
    echo "1) Let's Encrypt (默认，推荐)"
    echo "2) ZeroSSL (支持更多域名类型)" 
    echo ""
    
    local ca_choice
    read -p "请选择 CA [1-2]: " ca_choice
    
    case $ca_choice in
        1|"")
            CA_SERVER="letsencrypt"
            CA_NAME="Let's Encrypt"
            print_info "选择 CA: $CA_NAME"
            ;;
        2)
            CA_SERVER="zerossl"
            CA_NAME="ZeroSSL"
            print_info "选择 CA: $CA_NAME"
            
            # ZeroSSL 需要 EAB (External Account Binding)
            setup_zerossl_eab
            ;;
        *)
            print_warning "无效选择，使用默认: Let's Encrypt"
            CA_SERVER="letsencrypt"
            CA_NAME="Let's Encrypt"
            ;;
    esac
    
    # 设置默认 CA
    ~/.acme.sh/acme.sh --set-default-ca --server "$CA_SERVER"
    
    return 0
}

# 配置 ZeroSSL EAB
setup_zerossl_eab() {
    print_info "ZeroSSL 需要 EAB 密钥..."
    echo ""
    echo -e "${YELLOW}获取 ZeroSSL EAB 密钥步骤:${NC}"
    echo "1. 访问 https://app.zerossl.com/developer"
    echo "2. 注册/登录账号"
    echo "3. 在 Developer 页面获取 EAB Kid 和 EAB HMAC Key"
    echo ""
    
    read -p "是否已获取 EAB 密钥？(y/n): " has_eab
    if [[ ! "$has_eab" =~ ^[Yy]$ ]]; then
        print_info "请先获取 EAB 密钥，然后重新运行"
        return 1
    fi
    
    local eab_kid
    local eab_hmac_key
    
    read -p "请输入 EAB Kid: " eab_kid
    read -p "请输入 EAB HMAC Key: " eab_hmac_key
    
    if [[ -n "$eab_kid" && -n "$eab_hmac_key" ]]; then
        # 注册 ZeroSSL EAB
        if ~/.acme.sh/acme.sh --register-account \
            --server zerossl \
            --eab-kid "$eab_kid" \
            --eab-hmac-key "$eab_hmac_key"; then
            print_success "ZeroSSL EAB 配置成功"
            return 0
        else
            print_error "ZeroSSL EAB 配置失败"
            return 1
        fi
    else
        print_error "EAB 信息不能为空"
        return 1
    fi
}

# 检查现有证书
check_existing_certificate() {
    local domain="$1"
    
    print_info "检查现有证书..."
    
    # 检查 acme.sh 记录
    if [[ -d ~/.acme.sh/"$domain" ]]; then
        print_warning "发现现有证书记录: $domain"
        
        local cert_file="$CERT_DIR/server.crt"
        if [[ -f "$cert_file" ]]; then
            # 获取证书信息
            local issuer=$(openssl x509 -in "$cert_file" -noout -issuer 2>/dev/null | sed 's/.*CN=//' | cut -d',' -f1)
            local expires=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | cut -d'=' -f2)
            local subject=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null | grep -o 'CN=[^,]*' | cut -d'=' -f2)
            
            echo -e "${BLUE}当前证书信息:${NC}"
            echo "  域名: $subject"
            echo "  颁发者: $issuer"
            echo "  过期时间: $expires"
            
            # 计算剩余天数
            if command -v date >/dev/null 2>&1; then
                local expire_date=$(date -d "$expires" +%s 2>/dev/null || echo "0")
                local current_date=$(date +%s)
                if [[ "$expire_date" -gt 0 ]]; then
                    local days_left=$(( (expire_date - current_date) / 86400 ))
                    echo "  剩余天数: $days_left 天"
                    
                    # 如果证书还有30天以上有效期，询问是否继续
                    if [[ $days_left -gt 30 ]]; then
                        echo ""
                        echo -e "${YELLOW}当前证书仍然有效（剩余 $days_left 天），是否：${NC}"
                        echo "1) 继续使用现有证书"
                        echo "2) 强制重新申请"
                        echo "3) 删除现有证书后申请"
                        echo ""
                        
                        local choice
                        read -p "请选择 [1-3]: " choice
                        
                        case $choice in
                            1)
                                print_info "使用现有证书"
                                return 2  # 表示使用现有证书
                                ;;
                            2)
                                print_info "强制重新申请"
                                return 1  # 表示强制申请
                                ;;
                            3)
                                print_info "删除现有证书"
                                delete_certificate "$domain"
                                return 0  # 表示正常申请
                                ;;
                            *)
                                print_info "使用现有证书"
                                return 2
                                ;;
                        esac
                    fi
                fi
            fi
        fi
        
        echo ""
        echo -e "${YELLOW}发现现有证书配置，是否：${NC}"  
        echo "1) 更新现有证书"
        echo "2) 删除后重新申请"
        echo "3) 取消操作"
        echo ""
        
        local choice
        read -p "请选择 [1-3]: " choice
        
        case $choice in
            1)
                print_info "更新现有证书"
                return 1  # 表示更新证书
                ;;
            2)
                print_info "删除现有证书"
                delete_certificate "$domain"
                return 0  # 表示重新申请
                ;;
            3)
                print_info "取消操作"
                return 3  # 表示取消
                ;;
            *)
                return 1  # 默认更新
                ;;
        esac
    fi
    
    return 0  # 没有现有证书
}

# 删除证书
delete_certificate() {
    local domain="$1"
    
    print_info "删除域名 $domain 的证书..."
    
    # 删除 acme.sh 记录
    ~/.acme.sh/acme.sh --remove -d "$domain" 2>/dev/null || true
    
    # 删除证书文件目录
    rm -rf ~/.acme.sh/"$domain" 2>/dev/null || true
    rm -rf ~/.acme.sh/"$domain"_ecc 2>/dev/null || true
    
    # 删除安装的证书文件
    rm -f "$CERT_DIR/server.crt" "$CERT_DIR/server.key" 2>/dev/null || true
    
    print_success "证书删除完成"
}

# 修改后的申请证书函数
request_certificate() {
    print_step "申请 SSL 证书..."
    
    # 获取域名
    local domain=""
    while true; do
        read -p "请输入域名: " domain
        if [[ -n "$domain" && "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?)*$ ]]; then
            break
        fi
        print_error "域名格式不正确"
    done
    
    # 设置全局变量
    DOMAIN="$domain"
    export DOMAIN
    
    print_info "准备申请域名: $DOMAIN"
    
    # 检查现有证书
    check_existing_certificate "$DOMAIN"
    local cert_status=$?
    
    case $cert_status in
        2)
            print_success "使用现有有效证书"
            return 0
            ;;
        3)
            print_info "操作已取消"
            return 1
            ;;
    esac
    
    # 确保环境
    export PATH="$HOME/.acme.sh:$PATH"
    source ~/.acme.sh/acme.sh.env 2>/dev/null || true
    
    # 选择 CA
    choose_ca_provider || return 1
    
    # 检查域名解析
    print_info "检查域名解析..."
    local server_ip=$(curl -s --connect-timeout 10 ipv4.icanhazip.com || curl -s --connect-timeout 10 ifconfig.me)
    local domain_ip=$(dig +short "$DOMAIN" @8.8.8.8 | head -1)
    
    if [[ -n "$server_ip" && -n "$domain_ip" ]]; then
        if [[ "$server_ip" == "$domain_ip" ]]; then
            print_success "域名解析正确: $DOMAIN -> $server_ip"
        else
            print_warning "域名解析不匹配！"
            print_warning "服务器IP: $server_ip"
            print_warning "域名解析: $domain_ip"
            read -p "继续申请？(y/n): " continue_cert
            [[ ! "$continue_cert" =~ ^[Yy]$ ]] && return 1
        fi
    fi
    
    # 创建证书目录
    mkdir -p "$CERT_DIR"
    
    # 停止冲突服务
    print_info "停止冲突服务..."
    local services=(nginx apache2 httpd lighttpd caddy hysteria2)
    for svc in "${services[@]}"; do
        systemctl stop "$svc" 2>/dev/null || true
    done
    
    # 强制清理 80 端口
    print_info "清理端口 80..."
    local pids=$(lsof -ti:80 2>/dev/null)
    for pid in $pids; do
        [[ "$pid" =~ ^[0-9]+$ ]] && kill -9 "$pid" 2>/dev/null || true
    done
    
    sleep 3
    
    # 验证端口释放
    if lsof -i:80 >/dev/null 2>&1; then
        print_error "端口 80 仍被占用"
        lsof -i:80
        return 1
    fi
    
    print_success "端口 80 已释放"
    
    # 申请证书参数
    local issue_params=(
        "--issue"
        "-d" "$DOMAIN"
        "--standalone"
        "--httpport" "80"
        "--server" "$CA_SERVER"
    )
    
    # 如果是更新现有证书，添加 force 参数
    if [[ $cert_status -eq 1 ]]; then
        issue_params+=("--force")
        print_info "强制更新证书..."
    else
        print_info "申请新证书..."
    fi
    
    # 申请证书
    print_info "正在申请 $CA_NAME 证书..."
    if ~/.acme.sh/acme.sh "${issue_params[@]}"; then
        print_success "证书申请成功！"
        
        # 安装证书
        print_info "安装证书..."
        ~/.acme.sh/acme.sh --install-cert \
            -d "$DOMAIN" \
            --key-file "$CERT_DIR/server.key" \
            --fullchain-file "$CERT_DIR/server.crt" \
            --reloadcmd "systemctl reload hysteria2 2>/dev/null || true"
        
        # 设置权限
        chmod 600 "$CERT_DIR/server.key"
        chmod 644 "$CERT_DIR/server.crt"
        
        # 修复私钥格式（如果需要）
        print_info "验证和修复证书格式..."
        fix_certificate_format
        
        # 验证证书
        if openssl x509 -in "$CERT_DIR/server.crt" -noout -text >/dev/null 2>&1; then
            local cert_info=$(openssl x509 -in "$CERT_DIR/server.crt" -noout -subject -issuer -dates)
            print_success "证书验证成功"
            echo -e "${GREEN}证书信息:${NC}"
            echo "$cert_info"
            return 0
        else
            print_error "证书验证失败"
            return 1
        fi
    else
        print_error "证书申请失败"
        
        # 显示详细错误
        print_info "错误详情："
        if [[ -f ~/.acme.sh/acme.sh.log ]]; then
            tail -20 ~/.acme.sh/acme.sh.log | grep -E "(error|Error|ERROR|failed|Failed)"
        fi
        
        return 1
    fi
}

# 修复证书格式函数
fix_certificate_format() {
    print_info "修复证书格式..."
    
    # 备份原始文件
    cp "$CERT_DIR/server.key" "$CERT_DIR/server.key.backup" 2>/dev/null || true
    cp "$CERT_DIR/server.crt" "$CERT_DIR/server.crt.backup" 2>/dev/null || true
    
    # 检查私钥格式
    if [[ -f "$CERT_DIR/server.key" ]]; then
        # 尝试转换私钥格式
        if openssl rsa -in "$CERT_DIR/server.key" -out "$CERT_DIR/server.key.tmp" 2>/dev/null; then
            mv "$CERT_DIR/server.key.tmp" "$CERT_DIR/server.key"
            print_success "私钥格式已转换"
        elif openssl ec -in "$CERT_DIR/server.key" -out "$CERT_DIR/server.key.tmp" 2>/dev/null; then
            mv "$CERT_DIR/server.key.tmp" "$CERT_DIR/server.key"
            print_success "EC 私钥格式已转换"
        else
            print_warning "私钥格式转换失败，使用原始格式"
        fi
    fi
    
    # 设置正确的权限
    chmod 600 "$CERT_DIR/server.key"
    chmod 644 "$CERT_DIR/server.crt"
    
    print_success "证书格式修复完成"
}

# 证书管理菜单
certificate_management() {
    while true; do
        clear
        echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║            证书管理工具              ║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
        echo ""
        echo "1) 🔐 申请新证书"
        echo "2) 🔄 更新现有证书"
        echo "3) 🗑️  删除证书"
        echo "4) 📊 查看证书状态"
        echo "5) 🔧 修复证书格式"
        echo "0) 🔙 返回主菜单"
        echo ""
        
        local choice
        read -p "请选择 [0-5]: " choice
        
        case $choice in
            1)
                request_certificate
                ;;
            2)
                if [[ -n "$DOMAIN" ]] || [[ -f "$CERT_DIR/server.crt" ]]; then
                    # 提取域名
                    local domain="$DOMAIN"
                    if [[ -z "$domain" && -f "$CERT_DIR/server.crt" ]]; then
                        domain=$(openssl x509 -in "$CERT_DIR/server.crt" -noout -subject 2>/dev/null | grep -o 'CN=[^,]*' | cut -d'=' -f2)
                    fi
                    
                    if [[ -n "$domain" ]]; then
                        DOMAIN="$domain"
                        export DOMAIN
                        print_info "更新域名 $domain 的证书"
                        # 强制更新
                        ~/.acme.sh/acme.sh --renew -d "$domain" --force
                        if [[ $? -eq 0 ]]; then
                            print_success "证书更新成功"
                        else
                            print_error "证书更新失败"
                        fi
                    else
                        print_error "未找到域名信息"
                    fi
                else
                    print_error "未找到现有证书"
                fi
                ;;
            3)
                read -p "请输入要删除的域名: " del_domain
                if [[ -n "$del_domain" ]]; then
                    read -p "确认删除域名 $del_domain 的证书？(y/n): " confirm
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        delete_certificate "$del_domain"
                    fi
                else
                    print_error "域名不能为空"
                fi
                ;;
            4)
                show_certificate_status
                ;;
            5)
                fix_certificate_format
                ;;
            0)
                break
                ;;
            *)
                print_error "无效选项"
                ;;
        esac
        
        read -p "按回车继续..."
    done
}

# 显示证书状态
show_certificate_status() {
    print_info "证书状态检查..."
    
    echo -e "${BLUE}已安装证书:${NC}"
    if [[ -f "$CERT_DIR/server.crt" ]]; then
        local issuer=$(openssl x509 -in "$CERT_DIR/server.crt" -noout -issuer 2>/dev/null | sed 's/.*CN=//' | cut -d',' -f1)
        local expires=$(openssl x509 -in "$CERT_DIR/server.crt" -noout -enddate 2>/dev/null | cut -d'=' -f2)
        local domain_cert=$(openssl x509 -in "$CERT_DIR/server.crt" -noout -subject 2>/dev/null | grep -o 'CN=[^,]*' | cut -d'=' -f2)
        
        print_success "✅ 找到证书文件"
        echo "  域名: $domain_cert"
        echo "  颁发者: $issuer"  
        echo "  过期时间: $expires"
        
        # 计算剩余天数
        if command -v date >/dev/null 2>&1; then
            local expire_date=$(date -d "$expires" +%s 2>/dev/null || echo "0")
            local current_date=$(date +%s)
            if [[ "$expire_date" -gt 0 ]]; then
                local days_left=$(( (expire_date - current_date) / 86400 ))
                if [[ $days_left -gt 30 ]]; then
                    echo -e "  剩余天数: ${GREEN}$days_left 天${NC}"
                elif [[ $days_left -gt 7 ]]; then
                    echo -e "  剩余天数: ${YELLOW}$days_left 天${NC}"
                else
                    echo -e "  剩余天数: ${RED}$days_left 天 (建议更新)${NC}"
                fi
            fi
        fi
    else
        print_warning "❌ 未找到证书文件"
    fi
    
    echo ""
    echo -e "${BLUE}acme.sh 管理的证书:${NC}"
    if [[ -d ~/.acme.sh ]]; then
        ~/.acme.sh/acme.sh --list 2>/dev/null || print_warning "未找到 acme.sh 管理的证书"
    else
        print_warning "acme.sh 未安装"
    fi
}

# 🔧 修复：改进的端口跳跃配置保存
save_port_hopping_config() {
    local interface="$1"
    local actual_port="$2"
    local start_port="$3"
    local end_port="$4"
    
    # 使用更安全的配置格式，避免日期格式问题
    cat > "$HYSTERIA_DIR/port-hopping.conf" << EOF
# Hysteria 2 端口跳跃配置
# 请勿手动编辑此文件
ENABLED="true"
INTERFACE="$interface"
ACTUAL_PORT="$actual_port"
START_PORT="$start_port"
END_PORT="$end_port"
CREATED_TIMESTAMP="$(date +%s)"
CREATED_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
EOF
    
    print_success "端口跳跃配置已保存"
}

# 🔧 修复：安全的配置文件读取
load_port_hopping_config() {
    if [[ -f "$HYSTERIA_DIR/port-hopping.conf" ]]; then
        # 安全地读取配置，忽略可能的错误行
        while IFS='=' read -r key value; do
            # 跳过注释和空行
            [[ "$key" =~ ^#.*$ ]] && continue
            [[ -z "$key" ]] && continue
            
            # 清理值（移除引号）
            value=$(echo "$value" | sed 's/^"//;s/"$//')
            
            case "$key" in
                "ENABLED") HOPPING_ENABLED="$value" ;;
                "INTERFACE") HOPPING_INTERFACE="$value" ;;
                "ACTUAL_PORT") HOPPING_ACTUAL_PORT="$value" ;;
                "START_PORT") HOPPING_START_PORT="$value" ;;
                "END_PORT") HOPPING_END_PORT="$value" ;;
                "CREATED_DATE") HOPPING_CREATED="$value" ;;
            esac
        done < "$HYSTERIA_DIR/port-hopping.conf"
        
        return 0
    else
        return 1
    fi
}

# 配置端口跳跃功能
setup_port_hopping() {
    print_step "配置端口跳跃功能..."
    
    echo -e "${CYAN}端口跳跃配置选项：${NC}"
    echo "1) 启用端口跳跃"
    echo "2) 禁用端口跳跃"
    echo "3) 查看当前状态"
    echo ""
    
    local hop_choice
    read -p "请选择 [1-3]: " hop_choice
    
    case $hop_choice in
        1)
            configure_port_hopping
            ;;
        2)
            disable_port_hopping
            ;;
        3)
            show_port_hopping_status
            ;;
        *)
            print_error "无效选项"
            return 1
            ;;
    esac
}

# 🔧 修复：改进的端口跳跃配置函数
configure_port_hopping() {
    print_info "配置端口跳跃参数..."
    
    # 获取网络接口
    local interface=$(ip route | grep default | awk '{print $5}' | head -1)
    if [[ -z "$interface" ]]; then
        interface="eth0"  # 默认接口
        print_warning "无法自动检测网络接口，使用默认: $interface"
    else
        print_info "检测到网络接口: $interface"
    fi
    
    # 获取实际监听端口
    local actual_port="${PORT:-443}"
    if [[ -f "$CONFIG_FILE" ]]; then
        actual_port=$(grep "listen:" "$CONFIG_FILE" | awk -F: '{print $NF}' | tr -d ' ')
    fi
    
    # 获取端口跳跃范围
    local start_port
    local end_port
    
    echo ""
    echo -e "${CYAN}端口跳跃配置说明:${NC}"
    echo "• 客户端可连接到指定端口范围内的任意端口"
    echo "• 服务器将这些端口的流量重定向到实际监听端口"
    echo "• 建议端口范围: 20000-40000"
    echo ""
    
    while true; do
        read -p "起始端口 (建议 20000): " start_port
        start_port=${start_port:-20000}
        if [[ "$start_port" =~ ^[1-9][0-9]{3,4}$ ]] && [[ $start_port -ge 1024 && $start_port -le 65000 ]]; then
            break
        fi
        print_error "端口范围: 1024-65000"
    done
    
    while true; do
        read -p "结束端口 (建议 40000): " end_port
        end_port=${end_port:-40000}
        if [[ "$end_port" =~ ^[1-9][0-9]{3,4}$ ]] && [[ $end_port -gt $start_port && $end_port -le 65535 ]]; then
            break
        fi
        print_error "结束端口必须大于起始端口且不超过65535"
    done
    
    print_info "配置端口跳跃: $start_port-$end_port -> $actual_port"
    
    # 创建 iptables 规则脚本
    mkdir -p "$HYSTERIA_DIR"
    cat > "$IPTABLES_RULES_FILE" << EOF
#!/bin/bash
# Hysteria 2 端口跳跃规则

# 网络接口
INTERFACE="$interface"

# 实际监听端口
ACTUAL_PORT=$actual_port

# 端口跳跃范围
START_PORT=$start_port
END_PORT=$end_port

# 清理旧规则
cleanup_rules() {
    echo "清理端口跳跃规则..."
    
    # IPv4 规则清理
    iptables -t nat -D PREROUTING -i \$INTERFACE -p udp --dport \$START_PORT:\$END_PORT -j REDIRECT --to-ports \$ACTUAL_PORT 2>/dev/null || true
    iptables -t nat -D PREROUTING -p udp --dport \$START_PORT:\$END_PORT -j REDIRECT --to-ports \$ACTUAL_PORT 2>/dev/null || true
    
    # IPv6 规则清理 (如果支持)
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -t nat -D PREROUTING -i \$INTERFACE -p udp --dport \$START_PORT:\$END_PORT -j REDIRECT --to-ports \$ACTUAL_PORT 2>/dev/null || true
        ip6tables -t nat -D PREROUTING -p udp --dport \$START_PORT:\$END_PORT -j REDIRECT --to-ports \$ACTUAL_PORT 2>/dev/null || true
    fi
}

# 应用规则
apply_rules() {
    echo "应用端口跳跃规则: \$START_PORT-\$END_PORT -> \$ACTUAL_PORT"
    
    # 先清理旧规则
    cleanup_rules
    
    # IPv4 规则
    if iptables -t nat -A PREROUTING -p udp --dport \$START_PORT:\$END_PORT -j REDIRECT --to-ports \$ACTUAL_PORT; then
        echo "✅ IPv4 端口跳跃规则应用成功"
    else
        echo "❌ IPv4 端口跳跃规则应用失败"
        return 1
    fi
    
    # IPv6 规则 (如果支持)
    if command -v ip6tables >/dev/null 2>&1; then
        if ip6tables -t nat -A PREROUTING -p udp --dport \$START_PORT:\$END_PORT -j REDIRECT --to-ports \$ACTUAL_PORT 2>/dev/null; then
            echo "✅ IPv6 端口跳跃规则应用成功"
        else
            echo "⚠️  IPv6 端口跳跃规则应用失败 (可能不支持)"
        fi
    fi
    
    echo "端口跳跃规则配置完成"
}

# 检查规则状态
check_rules() {
    echo "=== IPv4 NAT 规则 ==="
    iptables -t nat -L PREROUTING -n --line-numbers | grep -E "(REDIRECT|$start_port|$end_port|$actual_port)" || echo "未找到相关规则"
    
    if command -v ip6tables >/dev/null 2>&1; then
        echo ""
        echo "=== IPv6 NAT 规则 ==="
        ip6tables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | grep -E "(REDIRECT|$start_port|$end_port|$actual_port)" || echo "未找到相关规则"
    fi
    
    echo ""
    echo "=== 端口监听状态 ==="
    if lsof -i:\$ACTUAL_PORT >/dev/null 2>&1; then
        echo "✅ 端口 \$ACTUAL_PORT 正在监听"
        lsof -i:\$ACTUAL_PORT
    else
        echo "❌ 端口 \$ACTUAL_PORT 未监听"
    fi
}

# 主要逻辑
case "\$1" in
    "start"|"apply")
        apply_rules
        ;;
    "stop"|"cleanup")
        cleanup_rules
        echo "端口跳跃规则已清理"
        ;;
    "status"|"check")
        check_rules
        ;;
    "restart")
        apply_rules
        ;;
    *)
        echo "用法: \$0 {start|stop|status|restart}"
        echo ""
        echo "命令说明:"
        echo "  start   - 应用端口跳跃规则"
        echo "  stop    - 清理端口跳跃规则"
        echo "  status  - 查看规则状态"
        echo "  restart - 重新应用规则"
        exit 1
        ;;
esac
EOF
    
    chmod +x "$IPTABLES_RULES_FILE"
    
    # 应用规则
    print_info "应用 iptables 规则..."
    if "$IPTABLES_RULES_FILE" start; then
        print_success "端口跳跃规则应用成功"
    else
        print_error "端口跳跃规则应用失败"
        return 1
    fi
    
    # 保存配置（使用修复的函数）
    save_port_hopping_config "$interface" "$actual_port" "$start_port" "$end_port"
    
    # 保存 iptables 规则（持久化）
    save_iptables_rules
    
    # 创建系统服务
    create_port_hopping_service
    
    print_success "端口跳跃配置完成！"
    echo ""
    echo -e "${CYAN}配置信息:${NC}"
    echo "  跳跃端口范围: $start_port-$end_port"
    echo "  实际监听端口: $actual_port"
    echo "  网络接口: $interface"
    echo ""
    echo -e "${YELLOW}客户端配置说明:${NC}"
    echo "  • 在客户端配置中使用端口范围格式"
    echo "  • 服务器地址: yourdomain.com:$start_port-$end_port"
    echo "  • 客户端会自动在此范围内选择端口连接"
}

# 🔧 修复：禁用端口跳跃
disable_port_hopping() {
    print_info "禁用端口跳跃..."
    
    # 清理 iptables 规则
    if [[ -f "$IPTABLES_RULES_FILE" ]]; then
        "$IPTABLES_RULES_FILE" stop
        print_success "端口跳跃规则已清理"
    fi
    
    # 停用系统服务
    systemctl stop hysteria2-port-hopping 2>/dev/null || true
    systemctl disable hysteria2-port-hopping 2>/dev/null || true
    
    # 更新配置文件
    if [[ -f "$HYSTERIA_DIR/port-hopping.conf" ]]; then
        sed -i 's/ENABLED="true"/ENABLED="false"/' "$HYSTERIA_DIR/port-hopping.conf"
        print_success "端口跳跃配置已禁用"
    fi
    
    print_success "端口跳跃功能已完全禁用"
}

# 🔧 修复：改进的端口跳跃状态显示
show_port_hopping_status() {
    print_info "端口跳跃状态检查..."
    
    if load_port_hopping_config; then
        echo -e "${BLUE}配置信息:${NC}"
        echo "  状态: ${HOPPING_ENABLED:-false}"
        echo "  端口范围: ${HOPPING_START_PORT:-未配置}-${HOPPING_END_PORT:-未配置}"
        echo "  实际端口: ${HOPPING_ACTUAL_PORT:-未配置}"
        echo "  网络接口: ${HOPPING_INTERFACE:-未配置}"
        echo "  创建时间: ${HOPPING_CREATED:-未知}"
        echo ""
        
        # 检查规则状态
        if [[ -f "$IPTABLES_RULES_FILE" ]]; then
            echo -e "${BLUE}规则状态:${NC}"
            "$IPTABLES_RULES_FILE" status
        fi
    else
        print_warning "未找到端口跳跃配置"
    fi
}

# 保存 iptables 规则
save_iptables_rules() {
    print_info "保存 iptables 规则..."
    
    if command -v iptables-save >/dev/null 2>&1; then
        if command -v netfilter-persistent >/dev/null 2>&1; then
            # Ubuntu/Debian 方式
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            if command -v ip6tables-save >/dev/null 2>&1; then
                ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
            fi
            print_success "规则已保存 (netfilter-persistent)"
        elif command -v service >/dev/null 2>&1 && service iptables status >/dev/null 2>&1; then
            # CentOS/RHEL 方式
            service iptables save 2>/dev/null || true
            print_success "规则已保存 (iptables service)"
        else
            print_warning "无法自动保存规则，重启后可能丢失"
        fi
    fi
}

# 创建端口跳跃服务
create_port_hopping_service() {
    print_info "创建端口跳跃系统服务..."
    
    cat > "/etc/systemd/system/hysteria2-port-hopping.service" << EOF
[Unit]
Description=Hysteria 2 Port Hopping Rules
After=network.target
Before=hysteria2.service

[Service]
Type=oneshot
ExecStart=$IPTABLES_RULES_FILE start
ExecStop=$IPTABLES_RULES_FILE stop
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable hysteria2-port-hopping
    
    print_success "端口跳跃服务创建完成"
}

# 生成配置（修改：在服务端添加 bandwidth 配置）
generate_config() {
    print_step "生成配置文件..."
    
    # 获取端口
    local port
    while true; do
        read -p "监听端口 (默认 443): " port
        port=${port:-443}
        if [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && [[ $port -le 65535 ]]; then
            break
        fi
        print_error "端口范围: 1-65535"
    done
    
    # 获取密码
    local password
    while true; do
        read -p "连接密码: " password
        if [[ ${#password} -ge 6 ]]; then
            break
        fi
        print_error "密码至少6位"
    done
    
    # 伪装网站
    read -p "伪装网站 (默认 https://www.bing.com): " masquerade
    masquerade=${masquerade:-https://www.bing.com}
    
    # 询问带宽设置（可选）
    local bandwidth_up="1 gbps"
    local bandwidth_down="1 gbps"
    
    echo ""
    echo -e "${YELLOW}带宽设置 (服务端限制):${NC}"
    read -p "上行带宽 (默认 1 gbps): " input_up
    read -p "下行带宽 (默认 1 gbps): " input_down
    
    [[ -n "$input_up" ]] && bandwidth_up="$input_up"
    [[ -n "$input_down" ]] && bandwidth_down="$input_down"
    
    # 保存到全局变量
    PORT="$port"
    PASSWORD="$password"
    export PORT PASSWORD
    
    # 创建配置（添加 bandwidth 配置）
    mkdir -p "$HYSTERIA_DIR"
    cat > "$CONFIG_FILE" << EOF
listen: :$PORT

tls:
  cert: $CERT_DIR/server.crt
  key: $CERT_DIR/server.key

auth:
  type: password
  password: "$PASSWORD"

masquerade:
  type: proxy
  proxy:
    url: $masquerade
    rewriteHost: true

bandwidth:
  up: $bandwidth_up
  down: $bandwidth_down

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
EOF
    
    print_success "配置文件生成完成"
    
    echo -e "${CYAN}服务端配置信息:${NC}"
    echo "域名: ${DOMAIN:-未设置}"
    echo "端口: $PORT"
    echo "密码: $PASSWORD"
    echo "服务端带宽限制: 上行 $bandwidth_up / 下行 $bandwidth_down"
    echo "伪装: $masquerade"
}

# 改进的验证配置文件函数
validate_config() {
    print_info "验证配置文件..."
    
    # 检查配置文件是否存在
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "配置文件不存在: $CONFIG_FILE"
        return 1
    fi
    
    # 检查证书文件
    if [[ ! -f "$CERT_DIR/server.crt" ]] || [[ ! -f "$CERT_DIR/server.key" ]]; then
        print_error "证书文件不存在"
        return 1
    fi
    
    # 验证证书文件格式
    if ! openssl x509 -in "$CERT_DIR/server.crt" -noout -text >/dev/null 2>&1; then
        print_error "证书文件格式错误"
        return 1
    fi
    
    # 改进的私钥验证（支持多种格式）
    local key_valid=false
    
    # 尝试验证 RSA 私钥
    if openssl rsa -in "$CERT_DIR/server.key" -check -noout >/dev/null 2>&1; then
        key_valid=true
        print_success "RSA 私钥验证通过"
    # 尝试验证 EC 私钥
    elif openssl ec -in "$CERT_DIR/server.key" -check -noout >/dev/null 2>&1; then
        key_valid=true
        print_success "EC 私钥验证通过"
    # 尝试验证 PKCS#8 格式
    elif openssl pkey -in "$CERT_DIR/server.key" -noout >/dev/null 2>&1; then
        key_valid=true
        print_success "PKCS#8 私钥验证通过"
    fi
    
    if [[ "$key_valid" = false ]]; then
        print_warning "私钥格式验证失败，尝试修复..."
        fix_certificate_format
        
        # 重新验证
        if openssl pkey -in "$CERT_DIR/server.key" -noout >/dev/null 2>&1; then
            print_success "私钥格式修复成功"
        else
            print_error "私钥格式仍然无效"
            return 1
        fi
    fi
    
    # 验证证书和私钥是否匹配
    local cert_modulus=$(openssl x509 -in "$CERT_DIR/server.crt" -noout -modulus 2>/dev/null)
    local key_modulus=$(openssl rsa -in "$CERT_DIR/server.key" -noout -modulus 2>/dev/null || openssl ec -in "$CERT_DIR/server.key" -noout 2>/dev/null | echo "match")
    
    if [[ -n "$cert_modulus" && "$cert_modulus" = "$key_modulus" ]] || [[ "$key_modulus" = "match" ]]; then
        print_success "证书和私钥匹配"
    else
        print_warning "无法验证证书私钥匹配性，但继续执行"
    fi
    
    # 检查配置文件语法 (简单检查)
    if ! grep -q "listen:" "$CONFIG_FILE" || \
       ! grep -q "auth:" "$CONFIG_FILE" || \
       ! grep -q "tls:" "$CONFIG_FILE"; then
        print_error "配置文件格式不完整"
        return 1
    fi
    
    print_success "配置验证通过"
    return 0
}

# 修复：创建灵活的系统服务（不强制依赖端口跳跃服务）
create_service() {
    print_step "创建系统服务..."
    
    # 检查是否存在端口跳跃服务
    local has_port_hopping=false
    if systemctl list-unit-files | grep -q "hysteria2-port-hopping.service"; then
        has_port_hopping=true
    fi
    
    # 根据是否有端口跳跃服务创建不同的依赖
    if [[ "$has_port_hopping" = true ]]; then
        cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Hysteria 2 Server
After=network.target nss-lookup.target hysteria2-port-hopping.service
Wants=network.target hysteria2-port-hopping.service

[Service]
Type=simple
User=root
ExecStart=$HYSTERIA_BINARY server -c $CONFIG_FILE
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    else
        cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Hysteria 2 Server
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
User=root
ExecStart=$HYSTERIA_BINARY server -c $CONFIG_FILE
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    fi
    
    systemctl daemon-reload
    systemctl enable hysteria2
    print_success "服务创建完成"
}

# 修复：启动服务（不强制要求端口跳跃服务）
start_service() {
    print_step "启动服务..."
    
    # 检查 Hysteria 2 二进制文件
    if [[ ! -f "$HYSTERIA_BINARY" ]]; then
        print_error "Hysteria 2 程序不存在，请先安装"
        return 1
    fi
    
    # 使用改进的验证方法
    if validate_config; then
        print_success "配置验证通过"
    else
        print_error "配置验证失败"
        return 1
    fi
    
    # 尝试启动端口跳跃服务（如果存在且未启动）
    if systemctl list-unit-files | grep -q "hysteria2-port-hopping.service"; then
        print_info "检测到端口跳跃服务，尝试启动..."
        if systemctl restart hysteria2-port-hopping 2>/dev/null; then
            print_success "端口跳跃服务启动成功"
        else
            print_warning "端口跳跃服务启动失败，继续启动主服务"
        fi
        sleep 2
    else
        print_info "未检测到端口跳跃服务配置"
    fi
    
    # 启动服务
    print_info "启动 Hysteria 2 服务..."
    systemctl restart hysteria2
    
    # 等待服务启动
    sleep 5
    
    # 检查服务状态
    if systemctl is-active --quiet hysteria2; then
        print_success "✅ 服务启动成功"
        
        # 检查端口监听
        local port="${PORT:-$(grep 'listen:' "$CONFIG_FILE" | awk -F: '{print $NF}' | tr -d ' ')}"
        if lsof -i:$port >/dev/null 2>&1; then
            print_success "✅ 端口 $port 监听正常"
        else
            print_warning "⚠️  端口 $port 监听检查失败"
            print_info "可能需要检查防火墙设置"
        fi
        
        return 0
    else
        print_error "❌ 服务启动失败"
        print_info "查看错误日志:"
        journalctl -u hysteria2 --no-pager -n 20
        return 1
    fi
}

# 重启服务函数
restart_service() {
    print_step "重启 Hysteria 2 服务..."
    
    # 检查 Hysteria 2 二进制文件
    if [[ ! -f "$HYSTERIA_BINARY" ]]; then
        print_error "Hysteria 2 程序不存在，请先安装"
        return 1
    fi
    
    # 检查配置文件
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "配置文件不存在，请先生成配置"
        return 1
    fi
    
    # 验证配置
    print_info "验证配置..."
    if ! validate_config; then
        print_error "配置验证失败，取消重启"
        return 1
    fi
    
    # 重启端口跳跃服务（如果存在）
    if systemctl list-unit-files | grep -q hysteria2-port-hopping; then
        print_info "重启端口跳跃服务..."
        if systemctl restart hysteria2-port-hopping 2>/dev/null; then
            print_success "端口跳跃服务重启成功"
        else
            print_warning "端口跳跃服务重启失败，继续重启主服务"
        fi
        sleep 2
    fi
    
    # 重启主服务
    print_info "重启主服务..."
    systemctl restart hysteria2
    
    # 等待服务启动
    print_info "等待服务启动..."
    sleep 5
    
    # 检查服务状态
    if systemctl is-active --quiet hysteria2; then
        print_success "✅ 服务重启成功"
        
        # 检查端口监听
        local port=$(grep "listen:" "$CONFIG_FILE" | awk -F: '{print $NF}' | tr -d ' ')
        if lsof -i:$port >/dev/null 2>&1; then
            print_success "✅ 端口 $port 监听正常"
        else
            print_warning "⚠️  端口 $port 监听检查失败"
        fi
        
        # 显示运行状态
        echo ""
        echo -e "${GREEN}服务状态:${NC}"
        systemctl status hysteria2 --no-pager -l | head -20
        
        return 0
    else
        print_error "❌ 服务重启失败"
        print_info "错误日志:"
        journalctl -u hysteria2 --no-pager -n 10
        return 1
    fi
}

# 🔧 修复：改进的客户端配置生成
generate_client_config() {
    print_step "生成客户端配置..."
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "配置文件不存在，请先完成服务器配置"
        return 1
    fi
    
    # 读取配置
    local domain="${DOMAIN:-$(openssl x509 -in "$CERT_DIR/server.crt" -noout -subject 2>/dev/null | grep -o 'CN=[^,]*' | cut -d'=' -f2)}"
    local password="${PASSWORD:-$(grep 'password:' "$CONFIG_FILE" | sed 's/.*password: *"//' | sed 's/".*//')}"
    local port="${PORT:-$(grep 'listen:' "$CONFIG_FILE" | awk -F: '{print $NF}' | tr -d ' ')}"
    
    # 检查是否配置了端口跳跃
    local server_address="$domain:$port"
    local port_hopping_info=""
    
    if load_port_hopping_config && [[ "$HOPPING_ENABLED" == "true" ]]; then
        server_address="$domain:$HOPPING_START_PORT-$HOPPING_END_PORT"
        port_hopping_info="端口跳跃: $HOPPING_START_PORT-$HOPPING_END_PORT -> $HOPPING_ACTUAL_PORT"
        print_info "检测到端口跳跃配置，使用端口范围: $HOPPING_START_PORT-$HOPPING_END_PORT"
    fi
    
    # 生成客户端配置文件
    cat > "/root/hysteria2-client.yaml" << EOF
# Hysteria 2 客户端配置
# 生成时间: $(date)

server: $server_address
auth: "$password"

tls:
  sni: $domain
  insecure: false

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s

bandwidth:
  up: 1 gbps
  down: 1 gbps

socks5:
  listen: 127.0.0.1:1080

http:
  listen: 127.0.0.1:8080

# 可选：TCP 转发配置示例
# tcpForwarding:
#   - listen: 127.0.0.1:2080
#     remote: 127.0.0.1:80
#   - listen: 127.0.0.1:2443
#     remote: 127.0.0.1:443

# 可选：UDP 转发配置示例  
# udpForwarding:
#   - listen: 127.0.0.1:5353
#     remote: 8.8.8.8:53
EOF
    
    print_success "客户端配置文件: /root/hysteria2-client.yaml"
    
    # 显示连接信息
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              客户端连接信息                   ║${NC}"
    echo -e "${CYAN}╠═══════════════════════════════════════════════╣${NC}"
    printf "${CYAN}║${NC} ${GREEN}服务器:${NC} %-35s ${CYAN}║${NC}\n" "$server_address"
    printf "${CYAN}║${NC} ${GREEN}密码:${NC} %-37s ${CYAN}║${NC}\n" "$password"
    printf "${CYAN}║${NC} ${GREEN}带宽:${NC} %-37s ${CYAN}║${NC}\n" "上行 1 Gbps / 下行 1 Gbps"
    printf "${CYAN}║${NC} ${GREEN}SOCKS5:${NC} %-33s ${CYAN}║${NC}\n" "127.0.0.1:1080"
    printf "${CYAN}║${NC} ${GREEN}HTTP:${NC} %-35s ${CYAN}║${NC}\n" "127.0.0.1:8080"
    
    # 显示端口跳跃信息
    if [[ -n "$port_hopping_info" ]]; then
        printf "${CYAN}║${NC} ${YELLOW}%s${NC} %*s ${CYAN}║${NC}\n" "$port_hopping_info" $((43 - ${#port_hopping_info})) ""
    fi
    
    echo -e "${CYAN}╚═══════════════════════════════════════════════╝${NC}"
    echo ""
    
    # 显示使用说明
    echo -e "${YELLOW}客户端使用说明:${NC}"
    echo "1. 下载 Hysteria 2 客户端程序"
    echo "2. 使用生成的配置文件启动客户端"
    echo "3. 配置浏览器代理为 SOCKS5: 127.0.0.1:1080"
    echo "4. 或使用 HTTP 代理: 127.0.0.1:8080"
    
    if [[ -n "$port_hopping_info" ]]; then
        echo ""
        echo -e "${CYAN}端口跳跃说明:${NC}"
        echo "• 客户端会在 $HOPPING_START_PORT-$HOPPING_END_PORT 范围内随机选择端口"
        echo "• 服务器自动将流量重定向到实际监听端口 $HOPPING_ACTUAL_PORT"
        echo "• 这可以有效避免端口封锁"
    fi
}

# 查看状态
show_status() {
    print_step "系统状态检查..."
    
    echo -e "${BLUE}📊 Hysteria 2 服务状态:${NC}"
    if systemctl is-active --quiet hysteria2; then
        print_success "✅ 服务正在运行"
        
        # 显示运行时间
        local uptime=$(systemctl show hysteria2 --property=ActiveEnterTimestamp --value)
        echo "   启动时间: $uptime"
    else
        print_error "❌ 服务未运行"
        
        # 显示最近的错误日志
        echo -e "${YELLOW}最近的错误日志:${NC}"
        journalctl -u hysteria2 --no-pager -n 5
    fi
    
    echo ""
    echo -e "${BLUE}🔌 端口监听状态:${NC}"
    if [[ -f "$CONFIG_FILE" ]]; then
        local port=$(grep "listen:" "$CONFIG_FILE" | awk -F: '{print $NF}' | tr -d ' ')
        if lsof -i:$port >/dev/null 2>&1; then
            print_success "✅ 端口 $port 正在监听"
            lsof -i:$port
        else
            print_error "❌ 端口 $port 未监听"
        fi
    else
        print_warning "配置文件不存在"
    fi
    
    echo ""
    echo -e "${BLUE}🚀 端口跳跃状态:${NC}"
    show_port_hopping_status
    
    echo ""
    echo -e "${BLUE}🔐 证书状态:${NC}"
    if [[ -f "$CERT_DIR/server.crt" ]]; then
        local issuer=$(openssl x509 -in "$CERT_DIR/server.crt" -noout -issuer 2>/dev/null | sed 's/.*CN=//')
        local expires=$(openssl x509 -in "$CERT_DIR/server.crt" -noout -enddate 2>/dev/null | cut -d'=' -f2)
        local domain_cert=$(openssl x509 -in "$CERT_DIR/server.crt" -noout -subject 2>/dev/null | grep -o 'CN=[^,]*' | cut -d'=' -f2)
        
        print_success "✅ 证书文件存在"
        echo "   域名: $domain_cert"
        echo "   颁发者: $issuer"
        echo "   过期时间: $expires"
        
        # 计算剩余天数
        if command -v date >/dev/null 2>&1; then
            local expire_date=$(date -d "$expires" +%s 2>/dev/null || echo "0")
            local current_date=$(date +%s)
            if [[ "$expire_date" -gt 0 ]]; then
                local days_left=$(( (expire_date - current_date) / 86400 ))
                if [[ $days_left -gt 30 ]]; then
                    echo -e "   剩余天数: ${GREEN}$days_left 天${NC}"
                elif [[ $days_left -gt 7 ]]; then
                    echo -e "   剩余天数: ${YELLOW}$days_left 天${NC}"
                else
                    echo -e "   剩余天数: ${RED}$days_left 天 (需要更新)${NC}"
                fi
            fi
        fi
    else
        print_error "❌ 证书文件不存在"
    fi
    
    echo ""
    echo -e "${BLUE}📦 程序信息:${NC}"
    if [[ -f "$HYSTERIA_BINARY" ]]; then
        print_success "✅ 程序文件存在"
        if "$HYSTERIA_BINARY" version >/dev/null 2>&1; then
            local version_info=$("$HYSTERIA_BINARY" version 2>/dev/null | head -1)
            echo "   版本: $version_info"
        fi
    else
        print_error "❌ 程序文件不存在"
    fi
    
    echo ""
    echo -e "${BLUE}⚙️ 服务端配置信息:${NC}"
    if [[ -f "$CONFIG_FILE" ]]; then
        local server_bandwidth_up=$(grep -A1 "bandwidth:" "$CONFIG_FILE" | grep "up:" | awk '{print $2}')
        local server_bandwidth_down=$(grep -A2 "bandwidth:" "$CONFIG_FILE" | grep "down:" | awk '{print $2}')
        if [[ -n "$server_bandwidth_up" && -n "$server_bandwidth_down" ]]; then
            echo "   服务端带宽限制: 上行 $server_bandwidth_up / 下行 $server_bandwidth_down"
        else
            print_warning "   未配置服务端带宽限制"
        fi
    fi
}

# 🆕 添加：网络诊断功能
network_diagnosis() {
    print_step "网络连接诊断..."
    
    echo -e "${BLUE}=== 基础网络信息 ===${NC}"
    
    # 获取服务器IP
    local server_ip=$(curl -s --connect-timeout 10 ipv4.icanhazip.com 2>/dev/null || curl -s --connect-timeout 10 ifconfig.me 2>/dev/null)
    if [[ -n "$server_ip" ]]; then
        print_success "服务器公网IP: $server_ip"
    else
        print_error "无法获取服务器公网IP"
    fi
    
    # 检查域名解析
    if [[ -n "$DOMAIN" ]]; then
        echo ""
        echo -e "${BLUE}=== 域名解析检查 ===${NC}"
        local domain_ip=$(dig +short "$DOMAIN" @8.8.8.8 2>/dev/null | head -1)
        if [[ -n "$domain_ip" ]]; then
            if [[ "$server_ip" == "$domain_ip" ]]; then
                print_success "域名解析正确: $DOMAIN -> $domain_ip"
            else
                print_warning "域名解析不匹配！"
                echo "  服务器IP: $server_ip"
                echo "  域名解析: $domain_ip"
            fi
        else
            print_error "域名解析失败: $DOMAIN"
        fi
    fi
    
    # 检查端口连通性
    echo ""
    echo -e "${BLUE}=== 端口连通性检查 ===${NC}"
    
    if [[ -f "$CONFIG_FILE" ]]; then
        local port=$(grep "listen:" "$CONFIG_FILE" | awk -F: '{print $NF}' | tr -d ' ')
        
        # 检查本地监听
        if lsof -i:$port >/dev/null 2>&1; then
            print_success "端口 $port 本地监听正常"
        else
            print_error "端口 $port 本地未监听"
        fi
        
        # 检查防火墙
        if command -v ufw >/dev/null 2>&1; then
            if ufw status | grep -q "$port"; then
                print_success "UFW 防火墙已开放端口 $port"
            else
                print_warning "UFW 防火墙可能未开放端口 $port"
            fi
        fi
        
        if command -v firewall-cmd >/dev/null 2>&1; then
            if firewall-cmd --list-ports | grep -q "$port"; then
                print_success "Firewalld 已开放端口 $port"
            else
                print_warning "Firewalld 可能未开放端口 $port"
            fi
        fi
    fi
    
    # 检查端口跳跃规则
    if load_port_hopping_config && [[ "$HOPPING_ENABLED" == "true" ]]; then
        echo ""
        echo -e "${BLUE}=== 端口跳跃规则检查 ===${NC}"
        if [[ -f "$IPTABLES_RULES_FILE" ]]; then
            "$IPTABLES_RULES_FILE" status
        fi
    fi
    
    echo ""
    echo -e "${BLUE}=== 系统资源状态 ===${NC}"
    
    # CPU 和内存
    local cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | awk -F'%' '{print $1}')
    local mem_usage=$(free | grep Mem | awk '{printf "%.1f", $3/$2 * 100.0}')
    
    echo "CPU 使用率: ${cpu_usage}%"
    echo "内存使用率: ${mem_usage}%"
    
    # 磁盘空间
    local disk_usage=$(df -h / | awk 'NR==2{print $5}')
    echo "磁盘使用率: $disk_usage"
}

# 完整安装
full_install() {
    print_step "🚀 开始完整安装..."
    
    echo -e "${YELLOW}安装前确认:${NC}"
    echo "✓ 域名已解析到服务器"
    echo "✓ 防火墙开放 80、443 端口"
    echo "✓ 准备邮箱地址"
    echo ""
    
    read -p "确认开始？(y/n): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { print_info "已取消"; return; }
    
    # 执行安装
    check_system || return 1
    install_hysteria2 || return 1
    install_acme_clean || return 1
    request_certificate || return 1
    generate_config || return 1
    create_service || return 1
    start_service || return 1
    
    # 询问是否配置端口跳跃
    echo ""
    read -p "是否配置端口跳跃功能？(y/n): " enable_hopping
    if [[ "$enable_hopping" =~ ^[Yy]$ ]]; then
        configure_port_hopping
        # 重新创建服务文件以包含端口跳跃依赖
        create_service
        # 重新生成客户端配置以包含端口跳跃信息
        generate_client_config
    else
        generate_client_config
    fi
    
    print_success "🎉 安装完成！"
    show_status
}

# 菜单
show_menu() {
    while true; do
        clear
        echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║        Hysteria 2 管理工具           ║${NC}"
        echo -e "${CYAN}║      (支持端口跳跃功能)              ║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
        echo ""
        echo "1) 🚀 完整安装"
        echo "2) 📦 仅安装程序"
        echo "3) 🛠️  证书管理"
        echo "4) ⚙️  生成配置"
        echo "5) 🔧 修复证书格式"
        echo "6) ▶️  启动服务"
        echo "7) 🔄 重启服务"
        echo "8) 📊 查看状态"
        echo "9) 📝 客户端配置"
        echo "10) 🚀 端口跳跃配置"
        echo "11) 🔍 网络诊断"
        echo "12) 🗑️ 卸载"
        echo "0) 🚪 退出"
        echo ""
        
        read -p "请选择 [0-12]: " choice
        echo ""
        
        case $choice in
            1) full_install ;;
            2) check_system && install_hysteria2 ;;
            3) certificate_management ;;
            4) generate_config ;;
            5) fix_certificate_format ;;
            6) start_service ;;
            7) restart_service ;;
            8) show_status ;;
            9) generate_client_config ;;
            10) setup_port_hopping ;;
            11) network_diagnosis ;;
            12)
                read -p "确认卸载？(y/n): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    # 清理端口跳跃规则
                    if [[ -f "$IPTABLES_RULES_FILE" ]]; then
                        "$IPTABLES_RULES_FILE" stop
                    fi
                    
                    # 停止并删除服务
                    systemctl stop hysteria2 2>/dev/null || true
                    systemctl disable hysteria2 2>/dev/null || true
                    systemctl stop hysteria2-port-hopping 2>/dev/null || true
                    systemctl disable hysteria2-port-hopping 2>/dev/null || true
                    
                    # 删除文件
                    rm -f "$SERVICE_FILE" "$HYSTERIA_BINARY"
                    rm -f "/etc/systemd/system/hysteria2-port-hopping.service"
                    rm -rf "$HYSTERIA_DIR"
                    
                    systemctl daemon-reload
                    print_success "卸载完成"
                fi
                ;;
            0) print_info "再见！"; exit 0 ;;
            *) print_error "无效选项" ;;
        esac
        
        read -p "按回车继续..."
    done
}

# 主函数
main() {
    case "${1:-menu}" in
        "install"|"i") full_install ;;
        "status"|"s") show_status ;;
        "cert"|"c") certificate_management ;;
        "fix") fix_certificate_format ;;
        "hopping"|"h") setup_port_hopping ;;
        "restart"|"r") restart_service ;;
        "diagnosis"|"d") network_diagnosis ;;
        *) show_menu ;;
    esac
}

main "$@"
