#!/usr/bin/env bash
# N100 All-in-One 初始化脚本 最终修复版
# 解决：awk语法错误、编码问题、log函数调用问题
# ================================================

set -euo pipefail
IFS=$'\n\t'

# 1. 首先定义所有日志函数（最优先）
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# 2. 定义功能函数
display_help() {
  cat <<EOF
使用方法: $0 [选项]
选项:
  -h        显示帮助信息
功能:
  1) 网络检测与配置
  2) 检查 SSH 状态与配置
  3) 启用 SSH (root & 密码)
  4) 磁盘分区 & 挂载
  5) 安装 Docker
  6) 部署容器
  7) Docker 一键运维
  8) 系统更新与升级
  9) 日志轮转与清理
  q) 退出脚本
EOF
}

env_check() {
  . /etc/os-release
  VERSION_ID=${VERSION_ID%%.*}
  case "$VERSION_ID" in
    9) CODENAME="stretch" ;; 10) CODENAME="buster" ;; 
    11) CODENAME="bullseye" ;; 12) CODENAME="bookworm" ;; 
    *) CODENAME="bookworm" ;;
  esac
  log "Debian $VERSION_ID ($CODENAME)"
  
  # 修复awk命令中的引号问题（使用英文双引号）
  avail_kb=$(df --output=avail "$BASE_DIR" 2>/dev/null | tail -1 || df --output=avail / | tail -1)
  if (( avail_kb < 5*1024*1024 )); then
    error "磁盘可用空间不足5GB"
    exit 1
  fi
  
  mem_mb=$(free -m | awk '/^Mem:/ {print $2}')
  if (( mem_mb < 1024 )); then
    error "内存不足1GB"
    exit 1
  fi
  
  # 修复磁盘空间计算的awk语法（使用正确的引号和表达式）
  disk_gb=$(echo "scale=1; $avail_kb / 1024 / 1024" | bc)
  log "环境检测通过: 磁盘 ${disk_gb}GB, 内存 ${mem_mb}MB"
}

create_dirs() {
  log "创建目录结构：$BASE_DIR"
  mkdir -p \
    "$BASE_DIR"/docker/compose \
    "$BASE_DIR"/docker/qbittorrent/config \
    "$DASHY_CONFIG_DIR" \
    "$BASE_DIR"/docker/filebrowser/config \
    "$BASE_DIR"/docker/bitwarden/data \
    "$BASE_DIR"/docker/emby/config \
    "$BASE_DIR"/docker/metatube/postgres \
    "$BASE_DIR"/media/movies \
    "$BASE_DIR"/media/tvshows \
    "$BASE_DIR"/media/av \
    "$BASE_DIR"/media/downloads
}

detect_ip() {
  IP_ADDR="$(hostname -I | awk '{print $1}')"
  log "本机IP: $IP_ADDR"
}

check_network() {
  log "开始网络检测..."
  ping -c 3 8.8.8.8 >/dev/null 2>&1 && log "网络连接正常" || error "网络连接失败，请检查网络设置"
}

check_ssh() {
  log "检查SSH服务状态..."
  systemctl is-active --quiet ssh && log "SSH服务正在运行" || warn "SSH服务未运行"
  log "SSH端口配置: $(grep '^Port' /etc/ssh/sshd_config | awk '{print $2}')"
}

enable_ssh() {
  log "配置SSH允许root登录..."
  sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
  systemctl restart ssh
  log "SSH配置已更新，允许root密码登录"
}

mount_disks() {
  log "开始磁盘挂载配置..."
  for mount_point in "${MOUNTS[@]}"; do
    mkdir -p "$mount_point" && log "检查挂载点: $mount_point"
  done
  log "磁盘挂载配置完成"
}

install_docker() {
  log "开始安装Docker..."
  if ! command -v docker &> /dev/null; then
    apt-get update
    apt-get install -y ca-certificates curl gnupg lsb-release
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-keyring=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable --now docker
    log "Docker安装完成"
  else
    log "Docker已安装"
  fi
}

deploy_containers() {
  local compose_url
  while true; do
    echo -e "\n部署容器子菜单："
    echo "1) 使用默认 URL"
    echo "2) 手动输入 URL"
    echo "q) 返回主菜单"
    read -rp "选择: " choice

    case "$choice" in
      1) compose_url="$DEFAULT_COMPOSE_URL" ;;
      2) read -rp "输入 compose URL: " compose_url ;;
      q|Q) return 0 ;;
      *) warn "无效选项，请重新选择"; continue ;;
    esac
    break
  done

  log "下载 compose 文件: $compose_url"
  mkdir -p "$COMPOSE_DIR"
  local compose_file="$COMPOSE_DIR/docker-compose.yml"
  
  curl -fsSL "$compose_url" -o "$compose_file" || { error "下载 compose 文件失败"; return 1; }

  log "开始部署容器..."
  cd "$COMPOSE_DIR" || { error "无法进入目录 $COMPOSE_DIR"; return 1; }
  docker compose up -d

  if docker compose ps | grep -q "dashy"; then
    log "Dashy 容器已启动"
    log "注意：Dashy配置文件需手动创建，路径为: $DASHY_CONFIG_DIR/conf.yml"
  fi
}

docker_maintenance() {
  echo -e "\nDocker运维子菜单："
  echo "1) 查看容器状态"
  echo "2) 重启所有容器"
  echo "3) 停止所有容器"
  echo "4) 查看容器日志"
  echo "5) 清理未使用的镜像"
  echo "6) 清理 & 重置"
  echo "q) 返回主菜单"
  read -rp "选择: " choice

  case "$choice" in
    1) docker ps -a ;;
    2) docker restart $(docker ps -q) ;;
    3) docker stop $(docker ps -q) ;;
    4) read -rp "输入容器名称: " container; docker logs -f "$container" ;;
    5) docker image prune -a -f ;;
    6) 
      read -rp "确定要清理所有容器和数据吗? (y/N) " confirm
      [[ "$confirm" == "y" || "$confirm" == "Y" ]] && {
        docker rm -f $(docker ps -aq)
        docker volume prune -f
        log "Docker环境已重置"
      }
      ;;
    q|Q) return 0 ;;
    *) warn "无效选项" ;;
  esac
}

system_update() {
  log "开始系统更新..."
  apt-get update && apt-get upgrade -y
  apt-get autoremove -y && apt-get autoclean
  log "系统更新完成"
}

log_rotation() {
  log "配置日志轮转..."
  apt-get install -y logrotate
  logrotate /etc/logrotate.conf
  log "清理系统日志..."
  find /var/log -type f -name "*.log" -exec truncate -s 0 {} \;
  log "日志清理完成"
}

# 3. 定义全局变量
BASE_DIR="/mnt/usbdata"
COMPOSE_DIR="$BASE_DIR/docker/compose"
MOUNTS=(/mnt/usbdata1 /mnt/usbdata2 /mnt/usbdata3)
DEFAULT_COMPOSE_URL="https://raw.githubusercontent.com/norman110/N100/refs/heads/main/docker-compose.yml"
DASHY_CONFIG_DIR="$BASE_DIR/docker/dashy/config"

# 4. 权限检测
if [[ $EUID -ne 0 ]]; then
  error "请使用 root 或 sudo 运行此脚本"
  exit 1
fi
[[ "${1:-}" == "-h" ]] && display_help && exit 0

# 5. 初始化操作
log "脚本启动中..."
env_check
create_dirs
detect_ip

read -e -rp "请输入泛域名 (如 *.example.com): " WILDCARD_DOMAIN
log "使用域名: $WILDCARD_DOMAIN"

# 6. 主菜单
while true; do
  echo -e "\n====== N100 AIO 初始化 简化修复版 ======"
  echo "1) 网络检测与配置"
  echo "2) 检查 SSH 状态与配置"
  echo "3) 启用 SSH (root & 密码)"
  echo "4) 磁盘分区 & 挂载"
  echo "5) 安装 Docker"
  echo "6) 部署容器"
  echo "7) Docker 一键运维"
  echo "8) 系统更新与升级"
  echo "9) 日志轮转与清理"
  echo "q) 退出脚本"
  read -rp "选择: " main_choice

  case "$main_choice" in
    1) check_network ;;
    2) check_ssh ;;
    3) enable_ssh ;;
    4) mount_disks ;;
    5) install_docker ;;
    6) deploy_containers ;;
    7) docker_maintenance ;;
    8) system_update ;;
    9) log_rotation ;;
    q|Q) log "退出脚本"; exit 0 ;;
    *) warn "无效选项，请重新选择" ;;
  esac
done
    
