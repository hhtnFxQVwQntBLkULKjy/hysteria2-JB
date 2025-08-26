#!/bin/bash

# Hysteria2 自动安装/更新脚本
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

# 自动更新配置
AUTO_UPDATE="true"                   # 是否启用自动更新检查
UPDATE_CHECK_INTERVAL="weekly"       # 更新检查间隔: daily, weekly, monthly

# ==================== 脚本开始 ====================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

# 显示使用方法
show_usage() {
    echo -e "${BLUE}Hysteria2 管理脚本${NC}"
    echo "使用方法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  install    - 安装 Hysteria2"
    echo "  update     - 更新 Hysteria2 到最新版本"
    echo "  uninstall  - 卸载 Hysteria2"
    echo "  status     - 显示服务状态"
    echo "  restart    - 重启服务"
    echo "  logs       - 显示日志"
    echo "  config     - 显示客户端配置"
    echo "  version    - 显示版本信息"
    echo "  check      - 检查更新"
    echo ""
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

# 获取架构信息
get_architecture() {
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
}

# 获取最新版本信息
get_latest_version() {
    log_info "获取最新版本信息..."
    LATEST_VERSION=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | grep '"tag_name"' | cut -d'"' -f4)
    if [[ -z "$LATEST_VERSION" ]]; then
        log_error "无法获取最新版本信息"
        exit 1
    fi
    log_info "最新版本: $LATEST_VERSION"
}

# 获取当前安装的版本
get_current_version() {
    if [[ -f /usr/local/bin/hysteria ]]; then
        CURRENT_VERSION=$(/usr/local/bin/hysteria version 2>/dev/null | grep -o "app/[^ ]*" | cut -d'/' -f2 | cut -d'@' -f1)
        if [[ -z "$CURRENT_VERSION" ]]; then
            CURRENT_VERSION="unknown"
        fi
    else
        CURRENT_VERSION="not installed"
    fi
}

# 检查是否需要更新
check_update_needed() {
    get_current_version
    get_latest_version
    
    if [[ "$CURRENT_VERSION" == "not installed" ]]; then
        log_info "Hysteria2 未安装"
        return 0
    elif [[ "$CURRENT_VERSION" == "unknown" ]]; then
        log_warn "无法确定当前版本，建议更新"
        return 0
    elif [[ "$CURRENT_VERSION" != "$LATEST_VERSION" ]]; then
        log_info "发现新版本: $CURRENT_VERSION -> $LATEST_VERSION"
        return 0
    else
        log_info "已是最新版本: $CURRENT_VERSION"
        return 1
    fi
}

# 下载 Hysteria2
download_hysteria2() {
    local version=${1:-$LATEST_VERSION}
    
    log_info "下载 Hysteria2 $version..."
    
    # 创建临时目录
    TMP_DIR=$(mktemp -d)
    cd $TMP_DIR
    
    get_architecture
    
    # 构建下载URL
    DOWNLOAD_URL="https://github.com/apernet/hysteria/releases/download/${version}/hysteria-linux-${ARCH}"
    
    # 下载文件
    if ! wget -O hysteria "$DOWNLOAD_URL"; then
        log_error "下载失败"
        cd /
        rm -rf $TMP_DIR
        exit 1
    fi
    
    # 验证下载的文件
    if [[ ! -f hysteria ]] || [[ ! -s hysteria ]]; then
        log_error "下载的文件无效"
        cd /
        rm -rf $TMP_DIR
        exit 1
    fi
    
    chmod +x hysteria
}

# 安装/更新 Hysteria2 二进制文件
install_binary() {
    log_info "安装 Hysteria2 二进制文件..."
    
    # 如果服务正在运行，先停止
    if systemctl is-active --quiet hysteria-server 2>/dev/null; then
        log_info "停止 Hysteria2 服务..."
        systemctl stop hysteria-server
        SERVICE_WAS_RUNNING=true
    fi
    
    # 备份旧版本
    if [[ -f /usr/local/bin/hysteria ]]; then
        cp /usr/local/bin/hysteria /usr/local/bin/hysteria.backup
        log_info "已备份旧版本到 /usr/local/bin/hysteria.backup"
    fi
    
    # 安装新版本
    mv hysteria /usr/local/bin/
    
    # 创建用户（如果不存在）
    if ! id "hysteria" &>/dev/null; then
        useradd -r -s /bin/false hysteria
    fi
    
    # 清理临时文件
    cd /
    rm -rf $TMP_DIR
    
    # 重新启动服务
    if [[ "$SERVICE_WAS_RUNNING" == "true" ]]; then
        log_info "重新启动 Hysteria2 服务..."
        systemctl start hysteria-server
    fi
}

# 安装依赖
install_dependencies() {
    log_info "安装系统依赖..."
    
    if [[ $OS == "centos" ]]; then
        $PACKAGE_MANAGER update -y
        $PACKAGE_MANAGER install -y curl wget unzip socat cron
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
    
    mkdir -p /etc/hysteria
    
    ~/.acme.sh/acme.sh --issue -d $DOMAIN --standalone
    
    ~/.acme.sh/acme.sh --installcert -d $DOMAIN \
        --key-file $TLS_KEY_PATH \
        --fullchain-file $TLS_CERT_PATH \
        --reloadcmd "systemctl restart hysteria-server"
        
    chmod 600 $TLS_KEY_PATH
    chmod 644 $TLS_CERT_PATH
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
        firewall-cmd --permanent --add-port=$LISTEN_PORT/tcp
        firewall-cmd --permanent --add-port=$LISTEN_PORT/udp
        firewall-cmd --reload
    elif command -v ufw &> /dev/null; then
        ufw allow $LISTEN_PORT/tcp
        ufw allow $LISTEN_PORT/udp
    elif command -v iptables &> /dev/null; then
        iptables -A INPUT -p tcp --dport $LISTEN_PORT -j ACCEPT
        iptables -A INPUT -p udp --dport $LISTEN_PORT -j ACCEPT
        
        if [[ $OS == "centos" ]]; then
            service iptables save
        else
            iptables-save > /etc/iptables/rules.v4
        fi
    fi
}

# 设置自动更新
setup_auto_update() {
    if [[ "$AUTO_UPDATE" == "true" ]]; then
        log_info "设置自动更新..."
        
        # 创建更新脚本
        cat > /usr/local/bin/hysteria2-update-check.sh << 'EOF'
#!/bin/bash
SCRIPT_PATH="/usr/local/bin/hysteria2-manager.sh"
if [[ -f "$SCRIPT_PATH" ]]; then
    $SCRIPT_PATH check && $SCRIPT_PATH update
fi
EOF
        chmod +x /usr/local/bin/hysteria2-update-check.sh
        
        # 添加 cron 任务
        case $UPDATE_CHECK_INTERVAL in
            "daily")
