#!/bin/bash

#================================================================================
# Hysteria 2 安装与管理脚本
#
# Author: Gemini
# Version: 1.1.0
#
# 功能:
#   - 交互式安装与配置 Hysteria 2
#   - 自动安装依赖、申请 SSL 证书 (acme.sh)
#   - 自动配置防火墙 (ufw, firewalld)
#   - 设置 systemd 服务
#   - 生成客户端分享链接
#   - 提供完整的卸载功能
#================================================================================

# --- 全局变量与颜色定义 ---
RESET="\033[0m"
BOLD="\033[1m"
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"

HYSTERIA_CONFIG_PATH="/etc/hysteria/config.yaml"
HYSTERIA_OFFICIAL_INSTALLER_URL="https://get.hy2.sh/"
ACME_SH_INSTALLER_URL="https://get.acme.sh"

# --- 辅助函数 ---
log() {
    echo -e "${BLUE}[信息]${RESET} $1"
}

warn() {
    echo -e "${YELLOW}[警告]${RESET} $1"
}

error() {
    echo -e "${RED}[错误]${RESET} $1" >&2
    exit 1
}

confirm() {
    read -rp "$1 [y/N]: " response
    case "$response" in
        [yY][eE][sS]|[yY])
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# --- 环境检查函数 ---
check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        error "此脚本必须以 root 权限运行。请使用 'sudo' 执行。"
    fi
}

check_system() {
    if ! command -v systemctl &> /dev/null; then
        error "未检测到 systemd。此脚本目前仅支持基于 systemd 的系统。"
    fi
    log "检测到 systemd，检查通过。"
}

check_dependencies() {
    local deps=("curl" "wget" "jq" "socat")
    local missing_deps=()
    log "正在检查所需依赖..."
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done

    if [ ${#missing_deps[@]} -gt 0 ]; then
        warn "缺失以下依赖: ${missing_deps[*]}。正在尝试自动安装..."
        # 使用 /etc/os-release 文件判断发行版
        if [ -f /etc/os-release ]; then
            source /etc/os-release
            case "$ID" in
                ubuntu|debian)
                    apt-get update && apt-get install -y "${missing_deps[@]}"
                    ;;
                centos|rocky|almalinux|fedora)
                    dnf install -y "${missing_deps[@]}"
                    ;;
                *)
                    error "不支持的 Linux 发行版: $ID。请手动安装缺失的依赖后重试。"
                    ;;
            esac
        else
            error "无法确定 Linux 发行版。请手动安装缺失的依赖后重试。"
        fi
        
        # 再次检查
        for dep in "${missing_deps[@]}"; do
            if ! command -v "$dep" &> /dev/null; then
                 error "依赖 '$dep' 自动安装失败。请手动安装后重试。"
            fi
        done
    fi
    log "所有依赖均已满足。"
}

# --- 核心功能函数 ---

install_acme() {
    if [ ! -f "$HOME/.acme.sh/acme.sh" ]; then
        log "正在安装 acme.sh..."
        curl "${ACME_SH_INSTALLER_URL}" | sh -s email=my@example.com
        if [ $? -ne 0 ]; then
            error "acme.sh 安装失败。"
        fi
        log "acme.sh 安装成功。"
    else
        log "acme.sh 已安装。"
    fi
    # shellcheck source=/root/.acme.sh/acme.sh.env
    source "$HOME/.acme.sh/acme.sh.env"
}

issue_certificate() {
    local domain="$1"
    local public_ip
    public_ip=$(curl -s4 http://ipv4.icanhazip.com)

    log "您的公网 IPv4 地址是: ${BOLD}$public_ip${RESET}"
    log "请确保您的域名 '${BOLD}$domain${RESET}' 已正确解析到此 IP 地址。"
    if ! confirm "确认域名解析正确并继续吗?"; then
        error "用户中止了证书申请流程。"
    fi

    log "正在为 '$domain' 申请证书 (使用 standalone 模式, 需占用 80 端口)..."
    if [ -f "$HOME/.acme.sh/${domain}_ecc/fullchain.cer" ]; then
        log "域名 '$domain' 的证书已存在，跳过申请。"
        return
    fi
    
    # 检查 80 端口是否被占用
    if lsof -i :80 &>/dev/null; then
        error "80 端口已被占用。无法使用 standalone 模式申请证书。请先停止占用 80 端口的程序再重试。"
    fi
    
    "$HOME/.acme.sh/acme.sh" --issue -d "$domain" --standalone -k ec-256
    if [ $? -ne 0 ]; then
        error "为 '$domain' 申请证书失败。"
    fi

    log "域名 '$domain' 的证书申请成功。"
}

install_hysteria() {
    log "正在运行 Hysteria 2 官方安装脚本..."
    bash <(curl -fsSL "${HYSTERIA_OFFICIAL_INSTALLER_URL}")
    if [ $? -ne 0 ]; then
        error "Hysteria 2 核心程序安装失败。"
    fi
    log "Hysteria 2 核心程序安装成功。"
}

configure_hysteria() {
    log "开始交互式配置..."
    
    local domain port password masquerade_url
    
    read -rp "请输入您的域名 (例如: your.domain.com): " domain
    [ -z "$domain" ] && error "域名不能为空。"

    read -rp "请输入 Hysteria 2 使用的端口 [1-65535] (默认: 443): " port
    port=${port:-443}

    read -rp "请输入认证密码 (留空则生成随机密码): " password
    if [ -z "$password" ]; then
        password=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
        log "已生成随机密码: ${BOLD}$password${RESET}"
    fi

    read -rp "请输入伪装网址 (默认: https://bing.com): " masquerade_url
    masquerade_url=${masquerade_url:-"https://bing.com"}

    # 申请证书
    install_acme
    issue_certificate "$domain"

    # 创建配置文件
    log "正在创建 Hysteria 2 配置文件于 ${HYSTERIA_CONFIG_PATH}..."
    
    local cert_path="$HOME/.acme.sh/${domain}_ecc/fullchain.cer"
    local key_path="$HOME/.acme.sh/${domain}_ecc/${domain}.key"

    mkdir -p "$(dirname "$HYSTERIA_CONFIG_PATH")"
    
    cat > "$HYSTERIA_CONFIG_PATH" << EOF
# 由 Hysteria 2 安装脚本生成
listen: :${port}

tls:
  cert: ${cert_path}
  key: ${key_path}

auth:
  type: password
  password: ${password}

masquerade:
  type: proxy
  proxy:
    url: ${masquerade_url}
    rewriteHost: true
EOF

    log "配置文件创建成功。"

    # 配置防火墙
    configure_firewall "$port"

    # 重启服务
    log "正在重启 Hysteria 2 服务..."
    systemctl restart hysteria-server.service
    systemctl enable hysteria-server.service

    # 检查服务状态
    sleep 2
    if systemctl is-active --quiet hysteria-server.service; then
        log "${GREEN}Hysteria 2 服务已成功启动！${RESET}"
    else
        error "Hysteria 2 服务启动失败。请使用 'journalctl -u hysteria-server -n 50 --no-pager' 查看日志。"
    fi

    # 显示客户端信息
    local client_uri="hy2://${password}@${domain}:${port}?sni=${domain}"
    echo -e "\n${BOLD}================ 客户端配置信息 ================${RESET}"
    echo -e "  ${BOLD}服务器地址:${RESET}\t$domain"
    echo -e "  ${BOLD}端口:${RESET}\t\t$port"
    echo -e "  ${BOLD}密码:${RESET}\t\t$password"
    echo -e "  ${BOLD}SNI:${RESET}\t\t$domain"
    echo -e "\n${GREEN}${BOLD}  分享链接 (URI):${RESET}"
    echo -e "  ${YELLOW}${client_uri}${RESET}\n"
    echo -e "====================================================\n"
}

configure_firewall() {
    local port=$1
    if command -v ufw &> /dev/null && ufw status | grep -q "active"; then
        log "检测到 ufw，正在开放端口 ${port}/udp..."
        ufw allow "${port}/udp"
    elif command -v firewall-cmd &> /dev/null && firewall-cmd --state | grep -q "running"; then
        log "检测到 firewalld，正在开放端口 ${port}/udp..."
        firewall-cmd --add-port="${port}/udp" --permanent
        firewall-cmd --reload
    else
        warn "未检测到活动的防火墙 (ufw 或 firewalld)。如果您的服务器有防火墙，请手动开放 UDP 端口 ${port}。"
    fi
}

uninstall_hysteria() {
    if confirm "${BOLD}${RED}您确定要完全卸载 Hysteria 2 吗？此操作将停止服务并删除相关文件。${RESET}"; then
        log "正在卸载 Hysteria 2..."
        bash <(curl -fsSL "${HYSTERIA_OFFICIAL_INSTALLER_URL}") --remove
        rm -rf /etc/hysteria
        log "Hysteria 2 已被卸载。"
        warn "注意: 由 acme.sh 申请的证书尚未移除，您可以手动管理。"
    else
        log "卸载操作已取消。"
    fi
}

# --- 主逻辑 ---
main() {
    if [[ "$1" == "--remove" ]]; then
        check_root
        uninstall_hysteria
        exit 0
    fi

    clear
    echo "=================================================="
    echo "       Hysteria 2 一键安装与管理脚本"
    echo "=================================================="
    echo

    check_root
    check_system
    check_dependencies
    
    install_hysteria
    configure_hysteria

    echo "=================================================="
    echo "             安装流程执行完毕"
    echo "=================================================="
}

main "$@"
