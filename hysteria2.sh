#!/bin/bash

#================================================================================
# Hysteria 2 全功能管理脚本 (v4 - NAT 转发逻辑已修正)
#
# Author: Gemini
# Version: 4.0.0
#
# 功能:
#   - 菜单式管理界面
#   - 强制使用 Let's Encrypt 申请证书
#   - 正确使用 iptables/ip6tables 的 NAT 规则处理端口跳跃
#   - 自动处理 iptables 规则的持久化
#   - 一键更新 Hysteria 2 核心
#   - 自动安装、配置、卸载及服务管理
#================================================================================

# --- 全局变量与颜色定义 ---
RESET="\033[0m"
BOLD="\033[1m"
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"

HYSTERIA_CONFIG_PATH="/etc/hysteria/config.yaml"
HYSTERIA_PORT_INFO_PATH="/etc/hysteria/port.info"
HYSTERIA_SERVICE_NAME="hysteria-server.service"
HYSTERIA_OFFICIAL_INSTALLER_URL="https://get.hy2.sh/"
ACME_SH_INSTALLER_URL="https://get.acme.sh"

# --- 辅助函数 ---
log() { echo -e "${BLUE}[信息]${RESET} $1"; }
warn() { echo -e "${YELLOW}[警告]${RESET} $1"; }
error() { echo -e "${RED}[错误]${RESET} $1" >&2; exit 1; }
confirm() {
    read -rp "$1 [y/N]: " response
    case "$response" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

# --- 环境检查 ---
check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        error "此脚本必须以 root 权限运行。请使用 'sudo' 执行。"
    fi
}

check_system() {
    if ! command -v systemctl &> /dev/null; then
        error "未检测到 systemd。此脚本目前仅支持基于 systemd 的系统。"
    fi
}

# --- 核心功能 ---

install_acme() {
    if [ ! -f "$HOME/.acme.sh/acme.sh" ]; then
        log "正在安装 acme.sh，首次安装需要您的邮箱。"
        read -rp "请输入您的电子邮箱: " user_email
        [[ -z "$user_email" ]] && error "邮箱不能为空。"
        curl "${ACME_SH_INSTALLER_URL}" | sh -s email="${user_email}"
        [[ $? -ne 0 ]] && error "acme.sh 安装失败。"
        log "acme.sh 安装成功。"
    else
        log "acme.sh 已安装。"
    fi
    # shellcheck source=/root/.acme.sh/acme.sh.env
    source "$HOME/.acme.sh/acme.sh.env"
}

issue_le_certificate() {
    local domain="$1"
    
    log "正在将默认证书颁发机构切换到 Let's Encrypt..."
    "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt &>/dev/null
    
    log "正在为 '$domain' 申请 Let's Encrypt 证书 (需要开放 TCP 80 端口)..."
    if "$HOME/.acme.sh/acme.sh" --renew -d "$domain" --ecc &>/dev/null; then
        log "证书已存在且有效，跳过申请。"
        return
    fi
    
    if lsof -i :80 &>/dev/null; then
        error "80 端口已被占用。无法使用 standalone 模式申请证书。请先停止占用 80 端口的程序再重试。"
    fi
    
    "$HOME/.acme.sh/acme.sh" --issue -d "$domain" --standalone -k ec-256
    [[ $? -ne 0 ]] && error "为 '$domain' 申请证书失败。请检查域名解析和防火墙设置 (TCP 80 端口)。"
    log "域名 '$domain' 的证书申请成功。"
}

configure_firewall() {
    local port_or_range="$1"
    local proto="udp"
    local ufw_port_range=${port_or_range//-/:}

    if command -v ufw &> /dev/null && ufw status | grep -q "active"; then
        log "检测到 ufw，正在开放端口 ${port_or_range}/${proto}..."
        ufw allow "${ufw_port_range}/${proto}"
    elif command -v firewall-cmd &> /dev/null && firewall-cmd --state | grep -q "running"; then
        log "检测到 firewalld，正在开放端口 ${port_or_range}/${proto}..."
        firewall-cmd --add-port="${port_or_range}/${proto}" --permanent
        firewall-cmd --reload
    else
        warn "未检测到活动的防火墙 (ufw 或 firewalld)。如果您的服务器有防火墙，请手动开放 UDP 端口 ${port_or_range}。"
    fi
}

setup_dnat_rules() {
    local listen_port="$1"
    local port_range="$2"
    local ipt_port_range=${port_range//-/:}
    
    local interface
    interface=$(ip -o -4 route show to default | awk '{print $5}')
    [[ -z "$interface" ]] && error "无法自动检测主网络接口。"
    log "检测到主网络接口为: $interface"

    log "正在配置 iptables NAT 转发规则..."
    iptables -t nat -A PREROUTING -i "$interface" -p udp --dport "$ipt_port_range" -j REDIRECT --to-ports "$listen_port"
    ip6tables -t nat -A PREROUTING -i "$interface" -p udp --dport "$ipt_port_range" -j REDIRECT --to-ports "$listen_port"

    log "正在设置 iptables 规则持久化..."
    if command -v apt-get &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent &>/dev/null
        netfilter-persistent save
    elif command -v dnf &>/dev/null || command -v yum &>/dev/null; then
        yum install -y iptables-services &>/dev/null
        systemctl enable --now iptables
        iptables-save > /etc/sysconfig/iptables
        ip6tables-save > /etc/sysconfig/ip6tables
    else
        warn "无法自动配置 iptables 持久化。重启后 NAT 规则可能会丢失。"
    fi
    log "NAT 规则配置完成。"
}

remove_dnat_rules() {
    if [ ! -f "$HYSTERIA_PORT_INFO_PATH" ]; then
        warn "未找到端口配置文件，跳过移除 NAT 规则。"
        return
    fi
    
    # shellcheck source=/etc/hysteria/port.info
    source "$HYSTERIA_PORT_INFO_PATH"
    
    # 检查是否配置了端口跳跃
    if [ -z "$PORT_RANGE" ] || [ "$LISTEN_PORT" == "$PORT_RANGE" ]; then
        log "未配置端口跳跃，无需移除 NAT 规则。"
        return
    fi

    local ipt_port_range=${PORT_RANGE//-/:}
    local interface
    interface=$(ip -o -4 route show to default | awk '{print $5}')
    [[ -z "$interface" ]] && warn "无法自动检测主网络接口，可能无法正确移除 NAT 规则。"

    log "正在移除 iptables NAT 转发规则..."
    iptables -t nat -D PREROUTING -i "$interface" -p udp --dport "$ipt_port_range" -j REDIRECT --to-ports "$LISTEN_PORT"
    ip6tables -t nat -D PREROUTING -i "$interface" -p udp --dport "$ipt_port_range" -j REDIRECT --to-ports "$LISTEN_PORT"

    log "正在保存 iptables 规则..."
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save
    elif command -v iptables-save &>/dev/null; then
        iptables-save > /etc/sysconfig/iptables
        ip6tables-save > /etc/sysconfig/ip6tables
    fi
    log "NAT 规则已移除。"
}

install_hysteria() {
    if [ -f "$HYSTERIA_CONFIG_PATH" ]; then
        warn "检测到 Hysteria 2 已安装。如果您想重新安装，请先执行卸载操作。"
        return
    fi
    
    check_system
    log "正在检查所需依赖..."
    for dep in curl wget jq socat iptables; do
        if ! command -v "$dep" &> /dev/null; then
            warn "缺失依赖: $dep, 正在尝试安装..."
            (apt-get update && apt-get install -y "$dep") || (dnf install -y "$dep") || (yum install -y "$dep") || error "依赖 '$dep' 自动安装失败。"
        fi
    done

    local domain listen_port client_port_config port_range password masquerade_url
    
    read -rp "请输入您的域名 (例如: your.domain.com): " domain
    [[ -z "$domain" ]] && error "域名不能为空。"

    read -rp "请输入 Hysteria 2 【服务器】要监听的【单个】端口 [1-65535] (例如: 443): " listen_port
    [[ -z "$listen_port" ]] && error "服务器监听端口不能为空。"
    client_port_config="$listen_port" 

    if confirm "是否为【客户端】启用端口跳跃 (Port Hopping) 功能？"; then
        read -rp "请输入【客户端】使用的端口范围 (例如: 20000-30000): " port_range
        [[ -z "$port_range" ]] && error "端口范围不能为空。"
        client_port_config="$port_range" 
    fi

    read -rp "请输入认证密码 (留空则生成随机密码): " password
    [[ -z "$password" ]] && password=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16) && log "已生成随机密码: ${BOLD}$password${RESET}"

    read -rp "请输入伪装网址 (默认: https://bing.com): " masquerade_url
    masquerade_url=${masquerade_url:-"https://bing.com"}

    install_acme
    issue_le_certificate "$domain"

    log "正在运行 Hysteria 2 官方安装脚本..."
    bash <(curl -fsSL "${HYSTERIA_OFFICIAL_INSTALLER_URL}")
    [[ $? -ne 0 ]] && error "Hysteria 2 核心程序安装失败。"
    
    log "正在创建 Hysteria 2 配置文件..."
    local cert_path="$HOME/.acme.sh/${domain}_ecc/fullchain.cer"
    local key_path="$HOME/.acme.sh/${domain}_ecc/${domain}.key"
    mkdir -p "$(dirname "$HYSTERIA_CONFIG_PATH")"
    
    cat > "$HYSTERIA_CONFIG_PATH" << EOF
# 由 Hysteria 2 管理脚本生成
listen: :${listen_port}
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

    # 保存端口信息，供卸载时使用
    echo "LISTEN_PORT=${listen_port}" > "$HYSTERIA_PORT_INFO_PATH"
    echo "PORT_RANGE=${port_range}" >> "$HYSTERIA_PORT_INFO_PATH"

    configure_firewall "$client_port_config"
    if [[ -n "$port_range" ]]; then
        setup_dnat_rules "$listen_port" "$port_range"
    fi

    log "正在启动并设置 Hysteria 2 服务开机自启..."
    systemctl restart "$HYSTERIA_SERVICE_NAME"
    systemctl enable "$HYSTERIA_SERVICE_NAME"

    sleep 2
    if ! systemctl is-active --quiet "$HYSTERIA_SERVICE_NAME"; then
        error "Hysteria 2 服务启动失败。请使用 'journalctl -u $HYSTERIA_SERVICE_NAME -n 50' 查看日志。"
    fi

    log "${GREEN}Hysteria 2 安装并启动成功！${RESET}"
    local client_uri="hy2://${password}@${domain}:${client_port_config}?sni=${domain}"
    echo -e "\n${BOLD}================ 客户端配置信息 ================${RESET}"
    echo -e "  ${BOLD}服务器地址:${RESET}\t$domain"
    echo -e "  ${BOLD}服务器监听端口:${RESET}\t${BOLD}${YELLOW}$listen_port${RESET}"
    echo -e "  ${BOLD}客户端连接端口:${RESET}\t${BOLD}${YELLOW}$client_port_config${RESET} ${RESET}"
    echo -e "  ${BOLD}密码:${RESET}\t\t$password"
    echo -e "  ${BOLD}SNI/Server Name:${RESET}\t$domain"
    echo -e "\n${GREEN}${BOLD}  分享链接 (URI):${RESET}"
    echo -e "  ${YELLOW}${client_uri}${RESET}"
    [[ -n "$port_range" ]] && warn "  提示: 您已启用端口跳跃。服务器通过 NAT 将 ${port_range} 的流量转发到 ${listen_port} 端口。"
    echo -e "====================================================\n"
}

update_hysteria() {
    log "正在拉取并安装 Hysteria 2 最新版本..."
    bash <(curl -fsSL "${HYSTERIA_OFFICIAL_INSTALLER_URL}")
    [[ $? -ne 0 ]] && error "Hysteria 2 更新失败。"
    
    log "正在重启服务以应用更新..."
    systemctl restart "$HYSTERIA_SERVICE_NAME"
    log "${GREEN}Hysteria 2 更新完成！${RESET}"
}

uninstall_hysteria() {
    if confirm "${BOLD}${RED}您确定要完全卸载 Hysteria 2 吗？${RESET}"; then
        log "正在卸载 Hysteria 2..."
        systemctl disable --now "$HYSTERIA_SERVICE_NAME" &>/dev/null
        
        remove_dnat_rules
        
        bash <(curl -fsSL "${HYSTERIA_OFFICIAL_INSTALLER_URL}") --remove
        rm -rf /etc/hysteria
        log "Hysteria 2 已被卸载。"
        warn "由 acme.sh 申请的证书尚未移除，您可以手动管理。"
    else
        log "卸载操作已取消。"
    fi
}

manage_service() {
    echo -e "请选择要执行的操作:"
    echo -e "  1) 启动服务\n  2) 停止服务\n  3) 重启服务\n  4) 查看状态\n  5) 查看实时日志"
    read -rp "请输入选项 [1-5]: " action
    case "$action" in
        1) systemctl start "$HYSTERIA_SERVICE_NAME" ;;
        2) systemctl stop "$HYSTERIA_SERVICE_NAME" ;;
        3) systemctl restart "$HYSTERIA_SERVICE_NAME" ;;
        4) systemctl status "$HYSTERIA_SERVICE_NAME" ;;
        5) journalctl -u "$HYSTERIA_SERVICE_NAME" -f --no-pager ;;
        *) echo "无效选项" ;;
    esac
}

# --- 主菜单 ---
main_menu() {
    clear
    echo "=================================================="
    echo "       Hysteria 2 全功能管理脚本 (v4)"
    echo "=================================================="
    echo -e "  ${GREEN}1.${RESET} 安装 Hysteria 2"
    echo -e "  ${GREEN}2.${RESET} 更新 Hysteria 2"
    echo -e "  ${GREEN}3.${RESET} 卸载 Hysteria 2"
    echo "--------------------------------------------------"
    echo -e "  ${YELLOW}4.${RESET} 管理 Hysteria 2 服务"
    echo -e "  ${YELLOW}0.${RESET} 退出脚本"
    echo "=================================================="
    read -rp "请输入选项 [0-4]: " choice
    
    case "$choice" in
        1) install_hysteria ;;
        2) update_hysteria ;;
        3) uninstall_hysteria ;;
        4) manage_service ;;
        0) exit 0 ;;
        *) error "无效输入，请输入 0-4 之间的数字。" ;;
    esac
}

check_root
main_menu
