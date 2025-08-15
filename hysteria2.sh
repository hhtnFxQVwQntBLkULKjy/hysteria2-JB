#!/bin/bash

# Hysteria 2 自动安装与更新脚本（带端口跳跃功能）
# 适用于 Linux 系统 (x86_64 和 arm64 架构)

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 默认配置参数
DEFAULT_PORT=8443
DEFAULT_PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
DEFAULT_OBFS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 8)
DEFAULT_HOP_INTERVAL=60
DEFAULT_HOP_PORTS="10000-20000"

# 检查是否为 root 用户
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}错误: 此脚本必须以 root 用户身份运行${NC}" >&2
    exit 1
fi

# 获取系统架构
ARCH=$(uname -m)
case $ARCH in
    x86_64)
        ARCH="amd64"
        ;;
    aarch64)
        ARCH="arm64"
        ;;
    *)
        echo -e "${RED}错误: 不支持的架构 ${ARCH}${NC}"
        exit 1
        ;;
esac

# 获取最新版本
get_latest_version() {
    echo -e "${YELLOW}正在获取 Hysteria 2 最新版本...${NC}"
    LATEST_VERSION=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "$LATEST_VERSION" ]; then
        echo -e "${RED}错误: 无法获取最新版本${NC}"
        exit 1
    fi
    echo -e "${GREEN}最新版本: ${LATEST_VERSION}${NC}"
}

# 生成配置文件
generate_config() {
    local config_file="/etc/hysteria/config.yaml"
    
    echo -e "${YELLOW}生成 Hysteria 2 配置文件...${NC}"
    
    # 询问用户配置参数
    read -p "请输入监听端口 (默认: ${DEFAULT_PORT}): " port
    port=${port:-$DEFAULT_PORT}
    
    read -p "请输入认证密码 (默认随机生成): " password
    password=${password:-$DEFAULT_PASSWORD}
    
    read -p "请输入混淆字符串 (默认随机生成): " obfs
    obfs=${obfs:-$DEFAULT_OBFS}
    
    echo -e "${BLUE}端口跳跃配置:${NC}"
    read -p "是否启用端口跳跃? (y/n, 默认 y): " enable_hop
    enable_hop=${enable_hop:-y}
    
    if [[ $enable_hop =~ ^[Yy]$ ]]; then
        read -p "请输入端口跳跃间隔(秒) (默认 ${DEFAULT_HOP_INTERVAL}): " hop_interval
        hop_interval=${hop_interval:-$DEFAULT_HOP_INTERVAL}
        
        read -p "请输入端口范围 (格式: 10000-20000, 默认 ${DEFAULT_HOP_PORTS}): " hop_ports
        hop_ports=${hop_ports:-$DEFAULT_HOP_PORTS}
    fi
    
    # 生成配置文件
    mkdir -p /etc/hysteria
    cat > $config_file <<EOF
listen: :${port}

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: ${password}

obfs:
  type: salamander
  salamander:
    password: ${obfs}

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  maxIncomingStreams: 1024
  disablePathMTUDiscovery: false
EOF

    # 添加端口跳跃配置
    if [[ $enable_hop =~ ^[Yy]$ ]]; then
        cat >> $config_file <<EOF

portHopping:
  enabled: true
  ports: ${hop_ports}
  interval: ${hop_interval}s
EOF
    fi

    # 生成自签名证书
    echo -e "${YELLOW}生成自签名证书...${NC}"
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt \
        -subj "/CN=www.example.com" -days 36500
    
    chmod 600 /etc/hysteria/server.key
    
    echo -e "${GREEN}配置文件已生成: ${config_file}${NC}"
    echo -e "${GREEN}服务器配置信息:${NC}"
    echo -e "端口: ${port}"
    echo -e "密码: ${password}"
    echo -e "混淆: ${obfs}"
    if [[ $enable_hop =~ ^[Yy]$ ]]; then
        echo -e "端口跳跃: 启用 (间隔: ${hop_interval}秒, 端口范围: ${hop_ports})"
    else
        echo -e "端口跳跃: 禁用"
    fi
}

# 安装 Hysteria 2
install_hysteria() {
    echo -e "${YELLOW}开始安装 Hysteria 2...${NC}"
    
    # 创建安装目录
    mkdir -p /usr/local/hysteria
    
    # 下载并解压
    HYST_URL="https://github.com/apernet/hysteria/releases/download/${LATEST_VERSION}/hysteria-linux-${ARCH}"
    echo -e "${YELLOW}下载 Hysteria 2...${NC}"
    if ! curl -L -o /usr/local/hysteria/hysteria "$HYST_URL"; then
        echo -e "${RED}错误: 下载失败${NC}"
        exit 1
    fi
    
    # 设置权限
    chmod +x /usr/local/hysteria/hysteria
    
    # 创建 systemd 服务文件
    echo -e "${YELLOW}创建 systemd 服务...${NC}"
    cat > /etc/systemd/system/hysteria.service <<EOF
[Unit]
Description=Hysteria 2 Server
After=network.target

[Service]
User=root
WorkingDirectory=/usr/local/hysteria
ExecStart=/usr/local/hysteria/hysteria server --config /etc/hysteria/config.yaml
Restart=always
RestartSec=3
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    
    # 生成配置文件
    generate_config
    
    # 重载 systemd
    systemctl daemon-reload
    
    echo -e "${GREEN}Hysteria 2 安装完成!${NC}"
    echo -e "可执行文件路径: /usr/local/hysteria/hysteria"
    echo -e "配置文件路径: /etc/hysteria/config.yaml"
    echo -e "服务管理命令:"
    echo -e "  启动服务: systemctl start hysteria"
    echo -e "  停止服务: systemctl stop hysteria"
    echo -e "  查看状态: systemctl status hysteria"
    echo -e "  开机自启: systemctl enable hysteria"
}

# 更新 Hysteria 2
update_hysteria() {
    echo -e "${YELLOW}开始更新 Hysteria 2...${NC}"
    
    # 停止服务
    systemctl stop hysteria
    
    # 备份旧版本
    mv /usr/local/hysteria/hysteria /usr/local/hysteria/hysteria.bak
    
    # 下载新版本
    HYST_URL="https://github.com/apernet/hysteria/releases/download/${LATEST_VERSION}/hysteria-linux-${ARCH}"
    echo -e "${YELLOW}下载 Hysteria 2 新版本...${NC}"
    if ! curl -L -o /usr/local/hysteria/hysteria "$HYST_URL"; then
        echo -e "${RED}错误: 下载失败，恢复旧版本${NC}"
        mv /usr/local/hysteria/hysteria.bak /usr/local/hysteria/hysteria
        systemctl start hysteria
        exit 1
    fi
    
    # 设置权限
    chmod +x /usr/local/hysteria/hysteria
    
    # 启动服务
    systemctl start hysteria
    
    # 检查服务状态
    if systemctl is-active --quiet hysteria; then
        echo -e "${GREEN}Hysteria 2 更新成功!${NC}"
        echo -e "当前版本: $(${HYST_BIN} version)"
    else
        echo -e "${RED}错误: 服务启动失败，恢复旧版本${NC}"
        mv /usr/local/hysteria/hysteria.bak /usr/local/hysteria/hysteria
        systemctl start hysteria
        exit 1
    fi
}

# 主函数
main() {
    get_latest_version
    
    # 检查是否已安装
    if [ -f "/usr/local/hysteria/hysteria" ]; then
        CURRENT_VERSION=$("/usr/local/hysteria/hysteria" version | awk '{print $3}')
        echo -e "${YELLOW}当前安装版本: ${CURRENT_VERSION}${NC}"
        
        if [ "$CURRENT_VERSION" != "$LATEST_VERSION" ]; then
            echo -e "${YELLOW}发现新版本，准备更新...${NC}"
            update_hysteria
        else
            echo -e "${GREEN}已安装最新版本，无需更新${NC}"
        fi
    else
        echo -e "${YELLOW}未检测到 Hysteria 2 安装，准备安装...${NC}"
        install_hysteria
    fi
}

main
