#!/bin/bash
# Hysteria2 超级自动化安装脚本
# 支持自动检测系统、自动配置防火墙、自动生成随机密码等

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 全局变量
DOMAIN=""
PASSWORD=""
PORT=443
PORT_RANGE="20000-50000"
PORT_INTERVAL=30
USE_PORT_HOPPING=false
USE_OBFS=false
OBFS_PASSWORD=""
CONFIG_FILE="/etc/hysteria/config.yaml"
CLIENT_CONFIG="/root/hysteria2-client.yaml"

# 打印带颜色的信息
print_info() { echo -e "${BLUE}[信息]${NC} $1"; }
print_ok() { echo -e "${GREEN}[成功]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[警告]${NC} $1"; }
print_error() { echo -e "${RED}[错误]${NC} $1"; }

# 检测系统
detect_system() {
    print_info "检测系统环境..."
    
    if [[ $EUID -ne 0 ]]; then
        print_error "请使用root用户运行此脚本"
        exit 1
    fi

    # 检测系统类型
    if [[ -f /etc/redhat-release ]]; then
        OS="centos"
        PM="yum"
    elif [[ -f /etc/debian_version ]]; then
        OS="debian"
        PM="apt"
    else
        print_error "不支持的系统类型"
        exit 1
    fi
    
    print_ok "系统类型: $OS"
}

# 自动获取服务器IP
get_server_ip() {
    SERVER_IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)
    if [[ -z "$SERVER_IP" ]]; then
        SERVER_IP=$(wget -qO- ipv4.icanhazip.com || wget -qO- ifconfig.me)
    fi
    print_info "服务器IP: $SERVER_IP"
}

# 用户输入或自动生成
get_user_input() {
    print_info "配置参数..."
    
    # 域名输入
    read -p "请输入域名 (直接回车使用IP): " input_domain
    if [[ -n "$input_domain" ]]; then
        DOMAIN="$input_domain"
        USE_DOMAIN=true
    else
        DOMAIN="$SERVER_IP"
        USE_DOMAIN=false
        print_warn "未输入域名，将使用自签名证书"
    fi
    
    # 端口配置选择
    echo ""
    print_info "端口配置选项："
    echo "1) 单端口模式 (传统模式)"
    echo "2) 端口跳跃模式 (推荐，防封锁)"
    read -p "请选择模式 [1-2] (默认2): " port_mode
    port_mode=${port_mode:-2}
    
    if [[ "$port_mode" == "1" ]]; then
        read -p "请输入端口 (默认443): " input_port
        PORT=${input_port:-443}
        USE_PORT_HOPPING=false
    else
        read -p "请输入主端口 (默认443): " input_port
        PORT=${input_port:-443}
        read -p "端口跳跃范围 (默认20000-50000): " input_range
        PORT_RANGE=${input_range:-"20000-50000"}
        read -p "跳跃间隔(秒) (默认30): " input_interval
        PORT_INTERVAL=${input_interval:-30}
        USE_PORT_HOPPING=true
        print_ok "已启用端口跳跃: $PORT_RANGE, 间隔: ${PORT_INTERVAL}秒"
    fi
    
    # 密码自动生成或手动输入
    read -p "请输入密码 (直接回车自动生成): " input_password
    if [[ -n "$input_password" ]]; then
        PASSWORD="$input_password"
    else
        PASSWORD=$(openssl rand -base64 16)
        print_ok "自动生成密码: $PASSWORD"
    fi
    
    # 混淆配置
    read -p "是否启用混淆 (y/n，默认y): " enable_obfs
    enable_obfs=${enable_obfs:-y}
    if [[ "$enable_obfs" == "y" ]]; then
        OBFS_PASSWORD=$(openssl rand -base64 12)
        USE_OBFS=true
        print_ok "已启用混淆，密码: $OBFS_PASSWORD"
    else
        USE_OBFS=false
    fi
}

# 等待dpkg锁释放
wait_for_dpkg_lock() {
    print_info "检查dpkg锁..."
    local max_attempts=30
    local attempt=1
    local wait_time=10

    # 预先停止所有apt相关服务和定时器
    print_info "停止apt相关服务和定时器..."
    systemctl stop apt-daily.timer apt-daily-upgrade.timer unattended-upgrades >/dev/null 2>&1 || true
    pkill -9 apt apt-get dpkg >/dev/null 2>&1 || true

    # 检查文件系统是否可写
    if mount | grep -q '/.*ro,'; then
        print_error "文件系统为只读状态，尝试重新挂载为读写..."
        mount -o remount,rw / >/dev/null 2>&1 || {
            print_error "无法重新挂载文件系统为读写，请手动运行 'sudo mount -o remount,rw /' 后重试。"
            exit 1
        }
    fi

    while [[ -f /var/lib/dpkg/lock-frontend ]]; do
        lock_holder=$(lsof /var/lib/dpkg/lock-frontend 2>/dev/null | awk 'NR>1 {print $2}' | sort -u)
        if [[ -n "$lock_holder" ]]; then
            print_error "dpkg锁被以下进程占用："
            ps -p $lock_holder -o pid,comm
            if [[ $attempt -gt $max_attempts ]]; then
                print_error "无法获取dpkg锁，建议手动检查以下进程："
                ps aux | grep -E 'apt|dpkg|unattended' | grep -v grep
                print_error "请终止进程（例如：sudo kill -9 <PID>）或等待其完成，然后重试。"
                exit 1
            fi
            print_warn "dpkg锁被占用，等待${wait_time}秒 (尝试 ${attempt}/${max_attempts})..."
            sleep $wait_time
            ((attempt++))
        else
            print_warn "未找到占用锁的进程，尝试清理锁文件..."
            rm -f /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock /var/lib/apt/lists/lock 2>/dev/null || {
                print_error "无法删除锁文件，请检查权限或文件系统状态："
                ls -l /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock /var/lib/apt/lists/lock 2>/dev/null
                print_error "手动运行以下命令后重试："
                print_error "sudo rm -f /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock /var/lib/apt/lists/lock"
                print_error "sudo dpkg --configure -a"
                exit 1
            }
            dpkg --configure -a >/dev/null 2>&1
            if [[ -f /var/lib/dpkg/lock-frontend ]]; then
                print_error "锁文件清理失败，请手动运行以下命令后重试："
                print_error "sudo rm -f /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock /var/lib/apt/lists/lock"
                print_error "sudo dpkg --configure -a"
                exit 1
            fi
            break
        fi
    done

    # 确保apt系统一致
    dpkg --configure -a >/dev/null 2>&1
    print_ok "dpkg锁已释放，继续执行..."
}

# 安装依赖
install_dependencies() {
    print_info "安装系统依赖..."
    
    if [[ "$OS" == "debian" ]]; then
        wait_for_dpkg_lock
        apt update -y
        apt install -y curl wget socat cron openssl uuid-runtime
        # 恢复apt定时任务
        systemctl start apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
    else
        yum update -y
        yum install -y curl wget socat crontabs openssl util-linux
        systemctl enable crond
        systemctl start crond
    fi
}

# 配置防火墙
setup_firewall() {
    print_info "配置防火墙..."
    
    if [[ "$USE_PORT_HOPPING" == true ]]; then
        # 解析端口范围
        IFS='-' read -ra RANGE <<< "$PORT_RANGE"
        START_PORT=${RANGE[0]}
        END_PORT=${RANGE[1]}
        
        print_info "开放端口范围: $START_PORT-$END_PORT"
        
        if command -v ufw >/dev/null 2>&1; then
            ufw allow $PORT/tcp
            ufw allow $PORT/udp
            ufw allow $START_PORT:$END_PORT/tcp
            ufw allow $START_PORT:$END_PORT/udp
            print_ok "UFW防火墙已配置端口跳跃"
        elif command -v firewall-cmd >/dev/null 2>&1; then
            firewall-cmd --permanent --add-port=$PORT/tcp
            firewall-cmd --permanent --add-port=$PORT/udp
            firewall-cmd --permanent --add-port=$START_PORT-$END_PORT/tcp
            firewall-cmd --permanent --add-port=$START_PORT-$END_PORT/udp
            firewall-cmd --reload
            print_ok "Firewalld防火墙已配置端口跳跃"
        elif command -v iptables >/dev/null 2>&1; then
            iptables -A INPUT -p tcp --dport $PORT -j ACCEPT
            iptables -A INPUT -p udp --dport $PORT -j ACCEPT
            iptables -A INPUT -p tcp --dport $START_PORT:$END_PORT -j ACCEPT
            iptables -A INPUT -p udp --dport $START_PORT:$END_PORT -j ACCEPT
            service iptables save >/dev/null 2>&1 || true
            print_ok "iptables防火墙已配置端口跳跃"
        fi
    else
        if command -v ufw >/dev/null 2>&1; then
            ufw allow $PORT/tcp
            ufw allow $PORT/udp
            print_ok "UFW防火墙已配置"
        elif command -v firewall-cmd >/dev/null 2>&1; then
            firewall-cmd --permanent --add-port=$PORT/tcp
            firewall-cmd --permanent --add-port=$PORT/udp
            firewall-cmd --reload
            print_ok "Firewalld防火墙已配置"
        elif command -v iptables >/dev/null 2>&1; then
            iptables -A INPUT -p tcp --dport $PORT -j ACCEPT
            iptables -A INPUT -p udp --dport $PORT -j ACCEPT
            service iptables save >/dev/null 2>&1 || true
            print_ok "iptables防火墙已配置"
        fi
    fi

    # 检查 SELinux/AppArmor
    if command -v sestatus >/dev/null 2>&1 && sestatus | grep -q "SELinux status:.*enabled"; then
        print_info "检测到SELinux启用，调整上下文..."
        chcon -R -t hysteria_data_t /etc/hysteria/ || chcon -R -t default_t /etc/hysteria/
    fi
    if command -v aa-status >/dev/null 2>&1 && aa-status | grep -q "hysteria"; then
        print_info "检测到AppArmor启用，建议检查配置文件"
    fi
}

# 安装证书
setup_certificate() {
    mkdir -p /etc/hysteria
    
    if [[ "$USE_DOMAIN" == true ]]; then
        print_info "申请Let's Encrypt证书..."
        
        # 安装acme.sh
        curl https://get.acme.sh | sh >/dev/null 2>&1
        source ~/.bashrc
        
        # 申请证书
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1
        
        # 停止可能占用80端口的服务
        systemctl stop nginx >/dev/null 2>&1 || true
        systemctl stop apache2 >/dev/null 2>&1 || true
        systemctl stop httpd >/dev/null 2>&1 || true
        
        if ~/.acme.sh/acme.sh --issue -d $DOMAIN --standalone --force; then
            ~/.acme.sh/acme.sh --installcert -d $DOMAIN \
                --key-file /etc/hysteria/private.key \
                --fullchain-file /etc/hysteria/cert.crt \
                --reloadcmd "systemctl restart hysteria-server" >/dev/null 2>&1
            print_ok "Let's Encrypt证书申请成功"
        else
            print_warn "Let's Encrypt证书申请失败，使用自签名证书"
            USE_DOMAIN=false
        fi
    fi
    
    if [[ "$USE_DOMAIN" == false ]]; then
        print_info "生成自签名证书..."
        openssl req -x509 -nodes -newkey rsa:2048 \
            -keyout /etc/hysteria/private.key \
            -out /etc/hysteria/cert.crt \
            -days 3650 \
            -subj "/C=US/ST=State/L=City/O=Organization/OU=Unit/CN=$DOMAIN" >/dev/null 2>&1
        print_ok "自签名证书生成完成"
    fi
    
    # 自动设置证书文件权限（假设 Hysteria2 以 hysteria 用户运行）
    chown hysteria:hysteria /etc/hysteria/private.key /etc/hysteria/cert.crt || true
    chmod 600 /etc/hysteria/private.key
    chmod 644 /etc/hysteria/cert.crt

    # 验证证书文件
    if ! openssl x509 -in /etc/hysteria/cert.crt -noout 2>/dev/null || ! openssl rsa -in /etc/hysteria/private.key -check 2>/dev/null; then
        print_error "证书文件无效，请检查"
        exit 1
    fi
}

# 安装Hysteria2
install_hysteria2() {
    print_info "安装Hysteria2..."
    bash <(curl -fsSL https://get.hy2.sh/) >/dev/null 2>&1
    print_ok "Hysteria2安装完成"
}

# 生成配置文件
generate_config() {
    print_info "生成配置文件..."
    
    # 服务器配置
    cat > $CONFIG_FILE << EOF
listen: :$PORT

tls:
  cert: /etc/hysteria/cert.crt
  key: /etc/hysteria/private.key

auth:
  type: password
  password: "$PASSWORD"

EOF

    # 添加端口跳跃配置
    if [[ "$USE_PORT_HOPPING" == true ]]; then
        cat >> $CONFIG_FILE << EOF
# 端口跳跃配置
portHopping:
  range: "$PORT_RANGE"
  interval: ${PORT_INTERVAL}s

EOF
    fi

    # 添加混淆配置
    if [[ "$USE_OBFS" == true ]]; then
        cat >> $CONFIG_FILE << EOF
# 混淆配置
obfs:
  type: salamander
  salamander:
    password: "$OBFS_PASSWORD"

EOF
    fi

    # 添加其他配置
    cat >> $CONFIG_FILE << EOF
masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true

quic:
  initStreamReceiveWindow: 26214400
  maxStreamReceiveWindow: 26214400
  initConnReceiveWindow: 67108864
  maxConnReceiveWindow: 67108864
  maxIdleTimeout: 30s
  maxIncomingStreams: 1024
  disablePathMTUDiscovery: false

bandwidth:
  up: 1 gbps
  down: 1 gbps

ignoreClientBandwidth: false
fastOpen: true
EOF

    # 客户端配置
    cat > $CLIENT_CONFIG << EOF
server: $DOMAIN:$PORT
auth: $PASSWORD

tls:
  sni: $DOMAIN
  insecure: $(if [[ "$USE_DOMAIN" == false ]]; then echo "true"; else echo "false"; fi)

EOF

    # 客户端端口跳跃配置
    if [[ "$USE_PORT_HOPPING" == true ]]; then
        cat >> $CLIENT_CONFIG << EOF
# 端口跳跃配置
portHopping:
  range: "$PORT_RANGE"
  interval: ${PORT_INTERVAL}s

EOF
    fi

    # 客户端混淆配置
    if [[ "$USE_OBFS" == true ]]; then
        cat >> $CLIENT_CONFIG << EOF
# 混淆配置
obfs:
  type: salamander
  salamander:
    password: "$OBFS_PASSWORD"

EOF
    fi

    # 客户端其他配置
    cat >> $CLIENT_CONFIG << EOF
socks5:
  listen: 127.0.0.1:1080

http:
  listen: 127.0.0.1:8080

fastOpen: true
lazy: true

# 可选配置
# bandwidth:
#   up: 50 mbps
#   down: 100 mbps
EOF

    print_ok "配置文件生成完成"
}

# 启动服务
start_service() {
    print_info "启动Hysteria2服务..."
    
    systemctl daemon-reload
    systemctl enable hysteria-server >/dev/null 2>&1
    systemctl start hysteria-server
    
    sleep 3
    
    if systemctl is-active --quiet hysteria-server; then
        print_ok "Hysteria2服务启动成功"
    else
        print_error "Hysteria2服务启动失败"
        print_error "错误日志如下："
        journalctl -u hysteria-server --no-pager -n 50
        print_error "请检查 /etc/hysteria/config.yaml 和证书文件权限"
        exit 1
    fi
}

# 显示结果
show_result() {
    clear
    echo -e "${GREEN}================================${NC}"
    echo -e "${GREEN}    Hysteria2 安装完成！${NC}"
    echo -e "${GREEN}================================${NC}"
    echo -e ""
    echo -e "${YELLOW}服务器信息:${NC}"
    echo -e "  地址: ${GREEN}$DOMAIN${NC}"
    echo -e "  端口: ${GREEN}$PORT${NC}"
    if [[ "$USE_PORT_HOPPING" == true ]]; then
        echo -e "  端口跳跃: ${GREEN}已启用${NC} (范围: $PORT_RANGE, 间隔: ${PORT_INTERVAL}秒)"
    fi
    echo -e "  密码: ${GREEN}$PASSWORD${NC}"
    if [[ "$USE_OBFS" == true ]]; then
        echo -e "  混淆: ${GREEN}已启用${NC} (密码: $OBFS_PASSWORD)"
    fi
    echo -e ""
    echo -e "${YELLOW}客户端配置文件已保存到:${NC}"
    echo -e "  ${GREEN}$CLIENT_CONFIG${NC}"
    echo -e ""
    echo -e "${YELLOW}常用命令:${NC}"
    echo -e "  查看状态: ${GREEN}systemctl status hysteria-server${NC}"
    echo -e "  重启服务: ${GREEN}systemctl restart hysteria-server${NC}"
    echo -e "  查看日志: ${GREEN}journalctl -u hysteria-server -f${NC}"
    echo -e ""
    echo -e "${YELLOW}客户端下载:${NC}"
    echo -e "  官方地址: ${GREEN}https://github.com/apernet/hysteria/releases${NC}"
    echo -e ""
    
    # 生成导入链接
    CONFIG_LINK="hysteria2://$PASSWORD@$DOMAIN:$PORT"
    
    # 添加端口跳跃参数
    if [[ "$USE_PORT_HOPPING" == true ]]; then
        CONFIG_LINK="${CONFIG_LINK}?portHopping=${PORT_RANGE}&interval=${PORT_INTERVAL}"
    else
        CONFIG_LINK="${CONFIG_LINK}?"
    fi
    
    # 添加其他参数
    CONFIG_LINK="${CONFIG_LINK}&insecure=$(if [[ "$USE_DOMAIN" == false ]]; then echo "1"; else echo "0"; fi)&sni=$DOMAIN"
    
    # 添加混淆参数
    if [[ "$USE_OBFS" == true ]]; then
        CONFIG_LINK="${CONFIG_LINK}&obfs=salamander&obfs-password=$OBFS_PASSWORD"
    fi
    
    CONFIG_LINK="${CONFIG_LINK}#Hysteria2-Enhanced"
    
    echo -e "${YELLOW}快速导入链接:${NC}"
    echo -e "  ${GREEN}$CONFIG_LINK${NC}"
    echo -e ""
    
    if [[ "$USE_PORT_HOPPING" == true ]]; then
        echo -e "${BLUE}端口跳跃特性:${NC}"
        echo -e "  ✓ 自动在 $PORT_RANGE 范围内跳跃端口"
        echo -e "  ✓ 每 $PORT_INTERVAL 秒切换一次端口"
        echo -e "  ✓ 有效防止端口被封锁"
        echo -e ""
    fi
    
    if [[ "$USE_OBFS" == true ]]; then
        echo -e "${BLUE}混淆特性:${NC}"
        echo -e "  ✓ 使用 Salamander 协议混淆"
        echo -e "  ✓ 增强流量伪装能力"
        echo -e "  ✓ 提高连接稳定性"
        echo -e ""
    fi
}

# 主函数
main() {
    clear
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}   Hysteria2 超级自动化安装${NC}"
    echo -e "${BLUE}================================${NC}"
    echo ""
    
    detect_system
    get_server_ip
    get_user_input
    install_dependencies
    install_hysteria2
    setup_firewall
    setup_certificate
    generate_config
    start_service
    show_result
    
    print_ok "安装完成！请保存好配置信息。"
}

# 运行主函数
main
