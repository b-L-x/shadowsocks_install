#!/bin/bash

RED="\033[31m"
WHITE="\033[37m"
GRAY="\033[90m"
RESET="\033[0m"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Run with sudo.${RESET}"
  exit 1
fi

detect_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    OS_VERSION=$VERSION_ID
  elif [ -f /etc/centos-release ]; then
    OS="centos"
    OS_VERSION=$(grep -oE '[0-9]+' /etc/centos-release | head -1)
  else
    echo -e "${RED}Unsupported distribution.${RESET}"
    exit 1
  fi

  case "$OS" in
    ubuntu|debian)
      DISTRO_FAMILY="debian"
      ;;
    centos|rhel|rocky|almalinux)
      DISTRO_FAMILY="rhel"
      CENTOS_VERSION=$(echo "$OS_VERSION" | cut -d. -f1)
      ;;
    *)
      echo -e "${RED}Unsupported distribution: $OS${RESET}"
      exit 1
      ;;
  esac

  echo -e "${GRAY}Detected: $OS $OS_VERSION${RESET}"
}

detect_os

echo -e "${RED}Enter the Shadowsocks port (default 8388):${RESET}"
read PORT
if [ -z "$PORT" ]; then
  PORT=8388
fi

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  echo -e "${RED}Invalid port. Using default 8388.${RESET}"
  PORT=8388
fi

echo -e "${GRAY}Updating system...${RESET}"

if [ "$DISTRO_FAMILY" = "debian" ]; then
  apt update && apt upgrade -y
  echo -e "${GRAY}Installing shadowsocks-libev...${RESET}"
  apt install shadowsocks-libev curl -y

elif [ "$DISTRO_FAMILY" = "rhel" ]; then
  if [ "$CENTOS_VERSION" -ge 8 ]; then
    PKG_MGR="dnf"
    dnf update -y
    echo -e "${GRAY}Installing EPEL and dependencies...${RESET}"
    dnf install epel-release -y
    dnf config-manager --set-enabled crb 2>/dev/null || \
    dnf config-manager --set-enabled powertools 2>/dev/null || true
    echo -e "${GRAY}Installing shadowsocks-libev...${RESET}"
    dnf install shadowsocks-libev curl -y
  else
    PKG_MGR="yum"
    yum update -y
    echo -e "${GRAY}Installing build dependencies for CentOS 7...${RESET}"
    yum install -y epel-release curl gcc autoconf libtool make \
      zlib-devel openssl-devel libev-devel c-ares-devel \
      libsodium-devel pcre-devel tar wget
    echo -e "${GRAY}Building shadowsocks-libev from source...${RESET}"
    SS_VERSION="3.3.5"
    SS_TAR="shadowsocks-libev-${SS_VERSION}.tar.gz"
    SS_URL="https://github.com/shadowsocks/shadowsocks-libev/releases/download/v${SS_VERSION}/${SS_TAR}"
    wget -q "$SS_URL" -O "/tmp/${SS_TAR}"
    tar xf "/tmp/${SS_TAR}" -C /tmp
    cd "/tmp/shadowsocks-libev-${SS_VERSION}"
    ./configure --prefix=/usr --disable-documentation
    make -j"$(nproc)" && make install
    cd /
    rm -rf "/tmp/shadowsocks-libev-${SS_VERSION}" "/tmp/${SS_TAR}"
  fi
fi

if ! command -v ss-server &>/dev/null; then
  echo -e "${RED}Error: ss-server not found after installation. Aborting.${RESET}"
  exit 1
fi

SS_BIN=$(command -v ss-server)

PASSWORD=$(openssl rand -base64 16)

SERVER_IP=$(curl -s --max-time 5 ifconfig.me)
if [ -z "$SERVER_IP" ]; then
  SERVER_IP=$(hostname -I | awk '{print $1}')
fi

METHOD="chacha20-ietf-poly1305"

echo -e "${GRAY}Writing configuration...${RESET}"
mkdir -p /etc/shadowsocks-libev
cat <<EOF > /etc/shadowsocks-libev/config.json
{
    "server": "0.0.0.0",
    "server_port": $PORT,
    "password": "$PASSWORD",
    "timeout": 300,
    "method": "$METHOD",
    "mode": "tcp_and_udp",
    "fast_open": true
}
EOF

echo -e "${GRAY}Applying kernel optimizations...${RESET}"
cat <<EOF > /etc/sysctl.d/local.conf
fs.file-max = 51200
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 4096
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.ip_local_port_range = 10000 65000
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mem = 25600 51200 102400
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_congestion_control = hybla
EOF
sysctl --system

cat <<EOF >> /etc/security/limits.conf
* soft nofile 51200
* hard nofile 51200
root soft nofile 51200
root hard nofile 51200
EOF
ulimit -n 51200

echo -e "${GRAY}Configuring systemd service...${RESET}"
systemctl stop shadowsocks-libev 2>/dev/null || true
systemctl disable shadowsocks-libev 2>/dev/null || true
cat <<EOF > /etc/systemd/system/shadowsocks-libev.service
[Unit]
Description=Shadowsocks-libev Server
After=network.target

[Service]
ExecStart=$SS_BIN -c /etc/shadowsocks-libev/config.json
Restart=always
User=root
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable shadowsocks-libev
systemctl start shadowsocks-libev

echo -e "${GRAY}Configuring firewall...${RESET}"
if [ "$DISTRO_FAMILY" = "debian" ]; then
  if command -v ufw &>/dev/null; then
    ufw allow $PORT/tcp
    ufw allow $PORT/udp
    ufw reload
  else
    echo -e "${GRAY}ufw not found, applying iptables rules.${RESET}"
    iptables -I INPUT -p tcp --dport $PORT -j ACCEPT
    iptables -I INPUT -p udp --dport $PORT -j ACCEPT
  fi

elif [ "$DISTRO_FAMILY" = "rhel" ]; then
  if systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port=$PORT/tcp
    firewall-cmd --permanent --add-port=$PORT/udp
    firewall-cmd --reload
  else
    echo -e "${GRAY}firewalld inactive, applying iptables rules.${RESET}"
    iptables -I INPUT -p tcp --dport $PORT -j ACCEPT
    iptables -I INPUT -p udp --dport $PORT -j ACCEPT
  fi
fi

echo -e "${WHITE}Installation complete! Shadowsocks client info:${RESET}"
echo -e "${GRAY}Server IP:${RESET} ${WHITE}$SERVER_IP${RESET}"
echo -e "${GRAY}Port:${RESET} ${WHITE}$PORT${RESET}"
echo -e "${GRAY}Password:${RESET} ${WHITE}$PASSWORD${RESET}"
echo -e "${GRAY}Method:${RESET} ${WHITE}$METHOD${RESET}"
echo -e "${RED}Copy these details into your client (e.g. Outline, Shadowsocks app).${RESET}"
