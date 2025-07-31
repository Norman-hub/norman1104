#!/usr/bin/env bash
# ---------------------------------------------------------------------------- #
# N100 All-in-One 交互式初始化脚本 v11.1
# Interactive AIO Initialization Script for N100 Mini-PC v11.1
# ---------------------------------------------------------------------------- #

set -euo pipefail
IFS=$'\n\t'

# 颜色输出 / Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log(){ echo -e "${GREEN}[INFO]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
error(){ echo -e "${RED}[ERROR]${NC} $*" >&2; }

# 帮助信息 / Usage
display_help(){
  cat <<EOF
使用方法: $0 [选项]
选项:
  -h        显示帮助
功能:
  环境检测 (自动)
  网络检测与配置
  检查 SSH 状态与配置
  启用 SSH (root & 密码)
  磁盘分区 & 挂载
  安装 Docker
  部署容器
  Docker 一键操作
  系统更新与升级
  日志轮转与清理
EOF
}

# 根权限检测
if [[ $EUID -ne 0 ]]; then
  error "请使用 root 或 sudo 运行此脚本"
  exit 1
fi
# 解析 -h
if [[ "${1:-}" == "-h" ]]; then
display_help; exit 0; fi

# 全局变量
BASE_DIR="/mnt/usbdata"
COMPOSE_DIR="$BASE_DIR/docker/compose"
MOUNTS=(/mnt/usbdata1 /mnt/usbdata2 /mnt/usbdata3)

# ---------------------------------------------------------------------------- #
# 环境检测 / Environment check
env_check(){
  . /etc/os-release
  VERSION_ID=${VERSION_ID%%.*}
  case "$VERSION_ID" in
    9) CODENAME="stretch" ;; 10) CODENAME="buster" ;; 11) CODENAME="bullseye" ;; 12) CODENAME="bookworm" ;; *) CODENAME="bookworm" ;;
  esac
  log "Debian $VERSION_ID ($CODENAME)"
  avail_kb=$(df --output=avail "$BASE_DIR" 2>/dev/null | tail -1 || df --output=avail / | tail -1)
  (( avail_kb < 5*1024*1024 )) && error "磁盘可用 <5GB" && exit 1
  mem_mb=$(free -m | awk '/^Mem:/ {print $2}')
  (( mem_mb < 1024 )) && error "内存 <1GB" && exit 1
  log "环境检测通过: 磁盘 $(awk "BEGIN{printf '%.1fGB', $avail_kb/1024/1024}" ), 内存 ${mem_mb}MB"
}
env_check

# ---------------------------------------------------------------------------- #
# IP 与域名 / IP & Domain
detect_ip(){ IP_ADDR="$(hostname -I | awk '{print $1}')"; log "本机IP: $IP_ADDR"; }
detect_ip
read -rp "请输入泛域名 (如 *.example.com): " WILDCARD_DOMAIN
log "使用域名: $WILDCARD_DOMAIN"

# ---------------------------------------------------------------------------- #
# 网络检测与配置 / Network functions
# ---------------------------------------------------------------------------- #
network_detect(){
  log "网络接口 & IP:"
  ip -brief addr show
  log "路由表:"
  ip route show
}
network_config(){
  echo -e "1) DHCP\n2) 静态IP"
  read -rp "选择: " nopt
  iface=$(ip -o link show | awk -F': ' '/state UP/ {print $2}' | head -1)
  [[ -z "$iface" ]] && { warn "无可用接口"; return; }
  case $nopt in
    1)
      cat>/etc/network/interfaces.d/$iface.cfg<<EOF
auto $iface
iface $iface inet dhcp
EOF
      ;;
    2)
      read -rp "静态IP (e.g.192.168.1.100/24): " sip
      read -rp "网关 (e.g.192.168.1.1): " gtw
      cat>/etc/network/interfaces.d/$iface.cfg<<EOF
auto $iface
iface $iface inet static
  address $sip
  gateway $gtw
EOF
      ;;
    *) warn "无效"; return;;
  esac
  systemctl restart networking && log "网络已应用"
}

# ---------------------------------------------------------------------------- #
# SSH 功能 / SSH functions
# ---------------------------------------------------------------------------- #
check_ssh_status(){
  systemctl is-active --quiet ssh && log "SSH 运行中" || warn "SSH 未运行"
  cfg=/etc/ssh/sshd_config
  [[ -f $cfg ]] && {
    port=$(grep -E '^Port ' $cfg | awk '{print $2}'); port=${port:-22}
    pr=$(grep -E '^PermitRootLogin ' $cfg | awk '{print $2}'); pr=${pr:-no}
    pa=$(grep -E '^PasswordAuthentication ' $cfg | awk '{print $2}'); pa=${pa:-yes}
    echo "Port:$port, PermitRootLogin:$pr, PasswordAuth:$pa"
  }
  if command -v ufw; then ufw status | grep -q '22/tcp' && echo UFW:开放; else iptables -L|grep -q 'dpt:22'&&echo IPTABLES:开放; fi
}
enable_ssh(){
  apt-get update && apt-get install -y openssh-server
  sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  systemctl enable ssh && systemctl restart ssh
  log "SSH 启用"
}

# ---------------------------------------------------------------------------- #
# 磁盘分区 & 挂载 / Disk partition
# ---------------------------------------------------------------------------- #
partition_disk(){
  lsblk -dn -o NAME,SIZE | nl
  read -rp "磁盘编号/q退出: " idx
  [[ $idx == q ]] && return
  dev=$(lsblk -dn -o NAME | sed -n "${idx}p")
  read -rp "确认 /dev/$dev? [y/N]: " y
  [[ ! $y =~ [Yy] ]] && { warn 取消; return; }
  parted /dev/$dev --script mklabel gpt mkpart primary ext4 0%100%
  mkfs.ext4 /dev/${dev}1
  read -rp "挂载点 (e.g. /mnt/data): " mnt
  mkdir -p "$mnt" && mount /dev/${dev}1 "$mnt"
  log "挂载完成"
}

# ---------------------------------------------------------------------------- #
# Docker 安装
install_docker(){
  if ! command -v docker; then
    curl -fsSL https://get.docker.com | sh
    apt-get install -y docker-compose-plugin
    usermod -aG docker "$SUDO_USER"
    log "Docker 安装完毕，请重启并重跑脚本"; exit 0
  fi; log "Docker 已安装"
}

# ---------------------------------------------------------------------------- #
# 容器部署 / Deploy containers
deploy_containers(){
  mkdir -p "$COMPOSE_DIR"
  echo -e "1) 默认URL\n2) 自定义URL"
  read -rp "选择: " o
  if [[ $o == 2 ]]; then
    read -rp "输入URL: " URL
  else
    URL="https://raw.githubusercontent.com/norman110/N100/refs/heads/main/docker-compose.yml"
  fi
  curl -fsSL "$URL" -o "$COMPOSE_DIR/docker-compose.yml"
  cd "$COMPOSE_DIR" && docker compose up -d
  CONF="$BASE_DIR/docker/dashy/config/conf.yml"; mkdir -p "$(dirname $CONF)"
  cat > $CONF <<EOF
appConfig:
  theme: nord
  language: zh
pageInfo:
  title: AIO 控制面板
sections:
  - name: 服务导航
    items:
EOF
  for c in $(docker ps --format '{{.Names}}'); do
    p=$(docker port $c | head -1 | awk -F: '{print $2}')
    echo "      - title: $c" >> $CONF
    echo "        url: http://$IP_ADDR:$p" >> $CONF
  done
  log "部署 & Dashy 配置完成"
}

# ---------------------------------------------------------------------------- #
# Docker 一键运维 / Docker One-Click
# ---------------------------------------------------------------------------- #
docker_one_click(){
  echo -e "1) 停止
2) 启动
3) 重启
4) 删除容器
5) 删除镜像
6) 清理 & 重置
7) 日志
8) 备份"
  read -rp "选: " x
  case $x in
    1)docker stop $(docker ps -q);;
    2)docker start $(docker ps -aq);;
    3)docker restart $(docker ps -q);;
    4)docker rm -f $(docker ps -aq);;
    5)docker rmi -f $(docker images -q);;
    6)docker system prune -af && rm -rf "$BASE_DIR/docker";;
    7)
      mapfile -t a< <(docker ps -a--format'{{.Names}}')
      for i in "${!a[@]}";do echo "$((i+1)). ${a[i]}";done
      read -rp"序号: " i; docker logs ${a[i-1]};;
    8)
      echo "挂载: ${MOUNTS[*]}";read -rp"目录: " b;mkdir -p $b && cp -r $BASE_DIR/docker $b;log "备份完"
      ;;
  esac
}

# ---------------------------------------------------------------------------- #
# 系统更新 & 日志清理
update_system(){
  sed -i "s|^deb .*|deb http://deb.debian.org/debian ${CODENAME} main contrib non-free|" /etc/apt/sources.list
  apt-get update && apt-get upgrade -y
  log "系统更新完毕"
}
log_rotate(){
  for c in $(docker ps -a--format '{{.Names}}'); do
    f="/var/log/${c}.log"; docker logs $c &> $f; find $f -mtime +7 -delete
  done; log "日志清理完毕"
}

# ---------------------------------------------------------------------------- #
# 主菜单 / Main Menu
# ---------------------------------------------------------------------------- #
while true; do
  cat <<EOF
====== N100 AIO 初始化 v11.1 ======
1) 网络检测与配置
2) 检查 SSH
3) 启用 SSH
4) 分区 & 挂载
5) 安装 Docker
6) 部署容器
7) Docker 一键运维
8) 系统更新
9) 日志清理
q) 退出
EOF
  read -rp"选: " ch
  case $ch in
    1)
      echo -e "1) 检测
2) 配置";read -rp"子: " s; [[ $s==1 ]]&&network_detect;[[ $s==2 ]]&&network_config
      ;;
    2)check_ssh_status;;3)enable_ssh;;4)partition_disk;;5)install_docker;;6)deploy_containers;;7)docker_one_click;;8)update_system;;9)log_rotate;;
    q)log退出;break;;*)warn无效;;
  esac
done
echo
log "脚本完成"
