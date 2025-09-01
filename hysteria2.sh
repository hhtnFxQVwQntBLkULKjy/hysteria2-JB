#!/bin/bash

#================================================================================
# Hysteria 2 全功能管理脚本 (Advanced)
#
# Author: Gemini
# Version: 2.0.0
#
# 功能:
#   - 菜单式管理界面
#   - 强制使用 Let's Encrypt 申请证书
#   - 支持端口跳跃 (Port Hopping)
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
        log "正在安装 acme.sh..."
        curl "${ACME_SH_INSTALLER_URL}" | sh -s email=my@example.com
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
    
    # 强制切换到 Let's Encrypt
    log "正在将默认证书颁发机构切换到 Let's Encrypt..."
    "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt
    [[ $? -ne 0 ]] && error "切换到 Let's Encrypt 失败。"
    log "切换成功！"

    log "正在为 '$domain' 申请 Let's Encrypt 证书..."
    if [ -f "$HOME/.acme.sh/${domain}_ecc/fullchain.cer" ]; then
        log "域名 '$domain' 的证书已存在，跳过申请。"
        return
    fi
    
    if lsof -i :80 &>/dev/null; then
        error "80 端口已被占用。无法使用 standalone 模式申请证书。请先停止占用 80 端口的程序再重试。"
    fi
    
    "$HOME/.acme.sh/acme.sh" --issue -d "$domain" --standalone -k ec-256
    [[ $? -ne 0 ]] && error "为 '$domain' 申请证书失败。"
    log "域名 '$domain' 的证书申请成功。"
}

configure_firewall() {
    local port_or_range="$1"
    local proto="udp"
    # 将 20000-30000 转换为 20000:30000 适配 ufw
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

install_hysteria() {
    if [ -f "$HYSTERIA_CONFIG_PATH" ]; then
        warn "检测到 Hysteria 2 已安装。如果您想重新安装，请先执行卸载操作。"
        return
    fi
    
    # --- 依赖与环境检查 ---
    check_system
    log "正在检查所需依赖..."
    for dep in curl wget jq socat; do
        if ! command -v "$dep" &> /dev/null; then
            warn "缺失依赖: $dep, 正在尝试安装..."
            (apt-get update && apt-get install -y "$dep") || (dnf install -y "$dep") || (yum install -y "$dep") || error "依赖 '$dep' 自动安装失败。"
        fi
    done

    # --- 获取用户配置 ---
    local domain port_type listen_port password masquerade_url
    
    read -rp "请输入您的域名 (例如: your.domain.com): " domain
    [[ -z "$domain" ]] && error "域名不能为空。"

    echo -e "请选择端口模式:\n  1) 单端口 (默认)\n  2) 端口跳跃 (范围)"
    read -rp "请输入选项 [1-2]: " port_type
    case "$port_type" in
        2)
            read -rp "请输入端口范围 (例如: 20000-30000): " listen_port
            ;;
        *)
            read -rp "请输入单个端口 [1-65535] (默认: 443): " listen_port
            listen_port=${listen_port:-443}
            ;;
    esac
    [[ -z "$listen_port" ]] && error "端口设置不能为空。"

    read -rp "请输入认证密码 (留空则生成随机密码): " password
    [[ -z "$password" ]] && password=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16) && log "已生成随机密码: ${BOLD}$password${RESET}"

    read -rp "请输入伪装网址 (默认: https://bing.com): " masquerade_url
    masquerade_url=${masquerade_url:-"https://bing.com"}

    # --- 执行安装 ---
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

    # --- 启动服务 ---
    configure_firewall "$listen_port"
    log "正在启动并设置 Hysteria 2 服务开机自启..."
    systemctl restart "$HYSTERIA_SERVICE_NAME"
    systemctl enable "$HYSTERIA_SERVICE_NAME"

    sleep 2
    if ! systemctl is-active --quiet "$HYSTERIA_SERVICE_NAME"; then
        error "Hysteria 2 服务启动失败。请使用 'journalctl -u $HYSTERIA_SERVICE_NAME -n 50' 查看日志。"
    fi

    # --- 显示客户端信息 ---
    log "${GREEN}Hysteria 2 安装并启动成功！${RESET}"
    local client_uri="hy2://${password}@${domain}:${listen_port}?sni=${domain}"
    echo -e "\n${BOLD}================ 客户端配置信息 ================${RESET}"
    echo -e "  ${BOLD}服务器地址:${RESET}\t$domain"
    echo -e "  ${BOLD}端口:${RESET}\t\t$listen_port"
    echo -e "  ${BOLD}密码:${RESET}\t\t$password"
    echo -e "  ${BOLD}SNI/Server Name:${RESET}\t$domain"
    echo -e "\n${GREEN}${BOLD}  分享链接 (URI):${RESET}"
    echo -e "  ${YELLOW}${client_uri}${RESET}"
    warn "  如果使用了端口跳跃，请确保客户端也配置了相同的端口范围。"
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
    echo "       Hysteria 2 全功能管理脚本"
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
