#!/bin/bash

# Hysteria2 一键安装脚本（支持 TLS + ACME 自动证书）
# 更新于 2024 年 2 月

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN="\033[0m"

CONFIG_FILE="/etc/hysteria2/config.json"
SERVICE_FILE="/etc/systemd/system/hysteria2.service"
CLIENT_FILE="/root/hysteria-client.json"

# 检测系统
check_system() {
    if [[ -f /etc/redhat-release ]]; then
        release="centos"
    elif grep -q -E -i "debian|ubuntu" /etc/issue; then
        release="debian"
    elif grep -q -E -i "centos|red hat|redhat" /etc/issue; then
        release="centos"
    elif grep -q -E -i "Arch|Manjaro" /etc/issue; then
        release="arch"
    elif grep -q -E -i "debian|ubuntu" /proc/version; then
        release="debian"
    elif grep -q -E -i "centos|red hat|redhat" /proc/version; then
        release="centos"
    else
        echo -e "${RED}未检测到系统版本，请手动安装${PLAIN}"
        exit 1
    fi
}

# 安装依赖
install_deps() {
    if [[ "${release}" == "centos" ]]; then
        yum update -y
        yum install -y wget curl tar openssl
    else
        apt update -y
        apt install -y wget curl tar openssl
    fi
}

# 安装 Hysteria2
install_hysteria() {
    echo -e "${BLUE}正在安装 Hysteria2...${PLAIN}"
    
    # 获取最新版本
    LATEST_VERSION=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | grep tag_name | cut -d '"' -f 4)
    
    # 下载并解压
    mkdir -p /etc/hysteria2
    wget -O /tmp/hysteria.tar.gz "https://github.com/apernet/hysteria/releases/download/${LATEST_VERSION}/hysteria-linux-amd64"
    tar -xzf /tmp/hysteria.tar.gz -C /usr/local/bin/
    chmod +x /usr/local/bin/hysteria
    
    # 创建服务文件
    cat > ${SERVICE_FILE} <<EOF
[Unit]
Description=Hysteria2 Server
After=network.target

[Service]
User=root
WorkingDirectory=/etc/hysteria2
ExecStart=/usr/local/bin/hysteria server --config ${CONFIG_FILE}
Restart=always
RestartSec=5s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable hysteria2
}

# 生成随机密码
generate_password() {
    openssl rand -hex 16
}

# 配置 Hysteria2 (TLS + ACME)
configure_hysteria() {
    echo -e "${BLUE}正在配置 Hysteria2 (TLS + ACME)...${PLAIN}"
    
    # 生成随机密码
    PASSWORD=$(generate_password)
    
    # 输入域名和邮箱
    read -p "请输入您的域名（已正确解析到本机IP）: " domain
    read -p "请输入您的邮箱（用于证书申请）: " email
    
    # 生成服务端配置
    cat > ${CONFIG_FILE} <<EOF
{
  "listen": ":443",
  "tls": {
    "cert": "/etc/hysteria2/cert.pem",
    "key": "/etc/hysteria2/key.pem"
  },
  "acme": {
    "domains": ["${domain}"],
    "email": "${email}",
    "disableHttp": false,
    "disableTlsAlpn": false,
    "altTlsAlpnPort": 443
  },
  "auth": {
    "type": "password",
    "password": "${PASSWORD}"
  }
}
EOF

    # 生成客户端配置
    cat > ${CLIENT_FILE} <<EOF
{
  "server": "${domain}:443",
  "auth": {
    "type": "password",
    "password": "${PASSWORD}"
  }
}
EOF

    # 开放防火墙端口
    if [[ "${release}" == "centos" ]]; then
        firewall-cmd --permanent --add-port=443/udp
        firewall-cmd --reload
    else
        ufw allow 443/udp
        ufw reload
    fi
}

# 启动服务
start_service() {
    echo -e "${BLUE}正在启动 Hysteria2 服务...${PLAIN}"
    systemctl start hysteria2
    sleep 2
    systemctl status hysteria2 --no-pager
}

# 显示配置信息
show_config() {
    echo -e "\n${GREEN}Hysteria2 安装完成！${PLAIN}"
    echo -e "${YELLOW}服务器配置已保存至: ${CONFIG_FILE}${PLAIN}"
    echo -e "${YELLOW}客户端配置已保存至: ${CLIENT_FILE}${PLAIN}"
    
    echo -e "\n${BLUE}====== TLS + ACME 模式配置信息 ======${PLAIN}"
    echo -e "${GREEN}服务器地址: ${domain}:443${PLAIN}"
    echo -e "${GREEN}认证密码: ${PASSWORD}${PLAIN}"
    
    echo -e "\n${YELLOW}客户端使用命令:${PLAIN}"
    echo -e "hysteria client --config ${CLIENT_FILE}"
}

# 主函数
main() {
    clear
    echo -e "${BLUE}Hysteria2 一键安装脚本 (TLS + ACME)${PLAIN}"
    
    check_system
    install_deps
    install_hysteria
    configure_hysteria
    start_service
    show_config
}

main
