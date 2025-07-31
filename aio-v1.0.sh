#!/usr/bin/env bash
# ---------------------------------------------------------------------------- #
# N100 All-in-One 交互式初始化脚本 v10.0
# Interactive AIO Initialization Script for N100 Mini-PC v10.0
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
  环境检测 (自动执行)
  检查 SSH 状态与配置
  启用 SSH (root & 密码)
  磁盘分区 & 挂载
  安装 Docker
  部署容器 (支持从 URL 下载 compose 文件)
  一键操作
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
display_help
exit 0
fi

# 全局变量
BASE_DIR="/mnt/usbdata"
COMPOSE_DIR="$BASE_DIR/docker/compose"
MOUNTS=(/mnt/usbdata1 /mnt/usbdata2 /mnt/usbdata3)

# 环境检测 / Environment check
env_check(){
  log "检测系统版本..."
  . /etc/os-release
  VERSION_ID=${VERSION_ID%%.*}
  case "$VERSION_ID" in
    9) CODENAME="stretch" ;; 10) CODENAME="buster" ;; 11) CODENAME="bullseye" ;; 12) CODENAME="bookworm" ;;
    *) CODENAME="bookworm" ;;
  esac
  log "Debian 版本: $VERSION_ID ($CODENAME)"

  log "检测磁盘空间..."
  avail_kb=$(df --output=avail "$BASE_DIR" 2>/dev/null | tail -1)
  [[ -z "$avail_kb" ]] && avail_kb=$(df --output=avail / | tail -1)
  if (( avail_kb < 5 * 1024 * 1024 )); then
    error "可用磁盘空间不足 (要求 ≥5GB)"; exit 1
  fi

  log "检测内存..."
  mem_mb=$(free -m | awk '/^Mem:/ {print $2}')
  if (( mem_mb < 1024 )); then
    error "可用内存不足 (要求 ≥1GB)"; exit 1
  fi

  log "环境检测通过: 磁盘 $(awk "BEGIN{printf '%.1fGB', $avail_kb/1024/1024}" ), 内存 ${mem_mb}MB"
}
env_check

# 自动探测本机IP
detect_ip(){
  IP_ADDR="$(hostname -I | awk '{print $1}')"
  log "检测到本机IP: $IP_ADDR"
}
detect_ip

# 输入泛域名
debug_domain(){
  read -rp "请输入泛域名 (例如 *.example.com): " WILDCARD_DOMAIN
  log "使用泛域名: $WILDCARD_DOMAIN"
}
debug_domain

# ---------------------------------------------------------------------------- #
# 功能函数 / Functions
# ---------------------------------------------------------------------------- #

# 检查 SSH 状态与配置
check_ssh_status(){
  log "检查 SSH 服务..."
  systemctl is-active --quiet ssh && log "SSH 运行中" || warn "SSH 未运行"
  cfg="/etc/ssh/sshd_config"
  if [[ -f "$cfg" ]]; then
    port=$(grep -Ei '^Port ' "$cfg" | awk '{print $2}' | head -1 || echo 22)
    root_login=$(grep -Ei '^PermitRootLogin ' "$cfg" | awk '{print $2}' | head -1 || echo no)
    pwd_auth=$(grep -Ei '^PasswordAuthentication ' "$cfg" | awk '{print $2}' | head -1 || echo yes)
    echo "  - Port: $port"
    echo "  - PermitRootLogin: $root_login"
    echo "  - PasswordAuthentication: $pwd_auth"
  else warn "无 SSH 配置文件"
  fi
  log "检查防火墙..."
  if command -v ufw &>/dev/null; then
    ufw status | grep -q '22/tcp' && echo "UFW: SSH 已开放" || echo "UFW: SSH 未开放"
  elif command -v iptables &>/dev/null; then
    iptables -L | grep -q 'tcp dpt:22' && echo "iptables: SSH 允许" || echo "iptables: SSH 未允许"
  fi
}

# 启用 SSH (root & 密码)
enable_ssh(){
  log "安装/配置 SSH 服务..."
  apt-get update && apt-get install -y openssh-server
  sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  systemctl enable ssh && systemctl restart ssh
  log "SSH 已启用"
}

# 磁盘分区 & 挂载
partition_disk(){
  log "列出可用磁盘..."
  lsblk -dn -o NAME,SIZE | nl
  read -rp "选择磁盘编号 (或 q 退出): " idx
  [[ "$idx" == "q" ]] && return
  dev=$(lsblk -dn -o NAME | sed -n "${idx}p")
  read -rp "确认 /dev/$dev? [y/N]: " yn
  [[ ! "$yn" =~ ^[Yy]$ ]] && { warn "取消分区"; return; }
  parted /dev/$dev --script mklabel gpt mkpart primary ext4 0% 100%
  mkfs.ext4 /dev/${dev}1
  read -rp "输入挂载点 (如 /mnt/data): " mnt
  mkdir -p "$mnt" && mount /dev/${dev}1 "$mnt"
  log "挂载完成: /dev/${dev}1 -> $mnt"
}

# 安装 Docker\install_docker(){
  if ! command -v docker &>/dev/null; then
    log "安装 Docker..."
    curl -fsSL https://get.docker.com | sh
    apt-get install -y docker-compose-plugin
    usermod -aG docker "$SUDO_USER"
    log "Docker 安装完成，请重新登录后重跑脚本"
    exit 0
  else
    log "Docker 已安装，跳过"
  fi
}

# 部署容器 (支持从 URL 下载 compose 文件)
deploy_containers(){
  log "创建目录结构..."
  mkdir -p "$BASE_DIR"/docker/{compose,qbittorrent/config,dashy/config,filebrowser/config,bitwarden/data,emby/config,metatube/postgres,proxy/{data,letsencrypt}} \
           "$BASE_DIR"/media/{movies,tvshows,av,downloads}
  mkdir -p "$COMPOSE_DIR"
  echo -e "请选择 docker-compose.yml 获取方式：\n1) 使用默认 URL\n2) 手动输入 URL"
  read -rp "编号: " opt
  case $opt in
    1)
      COMPOSE_URL="https://raw.githubusercontent.com/norman110/N100/refs/heads/main/docker-compose.yml"
      ;;
    2)
      read -rp "请输入 compose 文件 URL: " COMPOSE_URL
      ;;
    *) warn "无效，使用默认 URL" && COMPOSE_URL="https://raw.githubusercontent.com/norman110/N100/refs/heads/main/docker-compose.yml" ;;
  esac
  log "下载 compose 文件: $COMPOSE_URL"
  curl -fsSL "$COMPOSE_URL" -o "$COMPOSE_DIR/docker-compose.yml"

  log "启动容器..."
  cd "$COMPOSE_DIR" && docker compose up -d

  log "生成 Dashy 配置..."
  CONF="$BASE_DIR/docker/dashy/config/conf.yml"
  mkdir -p "$(dirname "$CONF")"
  cat > "$CONF" <<EOF
appConfig:
  theme: nord
  language: zh
pageInfo:
  title: AIO 控制面板
sections:
  - name: 服务导航
    items:
EOF
  # 自动根据运行容器获取服务列表
  for ct in $(docker ps --format '{{.Names}}'); do
    port=$(docker port "$ct" | head -1 | awk -F':' '{print $2}')
    echo "      - title: $ct" >> "$CONF"
    echo "        url: http://\$IP_ADDR:$port" >> "$CONF"
  done
  log "Dashy 配置已生成: $CONF"
}

# 一键操作
one_click(){
  cat <<EOF
1) 停止所有容器
2) 启动所有容器
3) 重启所有容器
4) 删除所有容器
5) 删除所有镜像
6) 清理数据 & 配置
7) 查看容器日志
8) 备份配置
q) 返回
EOF
  read -rp "编号: " opt
  case $opt in
    1) docker stop $(docker ps -q) ;; 2) docker start $(docker ps -aq) ;; 3) docker restart $(docker ps -q) ;; 4) docker rm -f $(docker ps -aq) ;;
    5) docker rmi -f $(docker images -q) ;; 6) docker rm -f $(docker ps -aq) && docker rmi -f $(docker images -q) && rm -rf "$BASE_DIR/docker" ;;
    7)
      mapfile -t arr < <(docker ps -a --format '{{.Names}}')
      for i in "${!arr[@]}"; do echo "$((i+1)). ${arr[i]}"; done
      read -rp "日志编号: " idx
      docker logs "${arr[idx-1]}"
      ;;
    8)
      echo "挂载点: ${MOUNTS[*]}"
      read -rp "选择备份目录: " bk
      mkdir -p "$bk" && cp -r "$BASE_DIR/docker" "$bk/"
      log "备份完成 -> $bk/docker"
      ;;
    q) return ;; *) warn "无效选项" ;;
  esac
}

# 系统更新与升级
update_system(){
  log "开始系统更新与升级..."
  sed -i "s|^deb .*|deb http://deb.debian.org/debian ${CODENAME} main contrib non-free|" /etc/apt/sources.list
  apt-get update && apt-get upgrade -y
  log "系统更新完毕"
}

# 日志轮转与清理
log_rotate(){
  log "执行日志轮转与清理..."
  for ct in $(docker ps -a --format '{{.Names}}'); do
    logfile="/var/log/${ct}.log"
    docker logs "$ct" &> "$logfile"
    log "轮转日志: $logfile"
    find "$logfile" -mtime +7 -exec rm -f {} \;
  done
  log "日志清理完毕"
}

# ---------------------------------------------------------------------------- #
# 主菜单 / Main Menu
# ---------------------------------------------------------------------------- #
while true; do
  cat <<EOF
====== N100 AIO 初始化 v10.0 ======
1) 检查 SSH 状态与配置
2) 启用 SSH (root & 密码)
3) 磁盘分区 & 挂载
4) 安装 Docker
5) 部署容器
6) 一键操作
7) 系统更新与升级
8) 日志轮转与清理
q) 退出脚本
EOF
  read -rp "选择: " choice
  case $choice in
    1) check_ssh_status ;; 2) enable_ssh ;; 3) partition_disk ;; 4) install_docker ;; 5) deploy_containers ;; 6) one_click ;;
    7) update_system ;; 8) log_rotate ;;
    q) log "退出脚本"; break ;; *) warn "无效选项" ;;
  esac
done

log "脚本执行完毕"
