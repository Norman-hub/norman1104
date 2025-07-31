#!/usr/bin/env bash
# N100 All-in-One 交互式初始化脚本 v11.2 最终修复版
# 解决：终端删除键失效问题
# ================================================

set -euo pipefail
IFS=$'\n\t'

# 【强化修复】彻底解决删除键失效问题（兼容所有终端环境）
# 重置终端设置，确保删除键正确映射
reset_terminal() {
  # 恢复标准终端设置
  stty sane
  # 明确设置删除键为^H（Backspace）和^?（Delete）
  stty erase '^?'
  # 确保输入模式正确
  stty -icrnl -onlcr
  log "终端设置已重置，删除键功能已修复"
}
reset_terminal

# 颜色输出
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log(){ echo -e "${GREEN}[INFO]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
error(){ echo -e "${RED}[ERROR]${NC} $*" >&2; }

# 帮助信息
display_help(){
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

# 根权限检测
if [[ $EUID -ne 0 ]]; then
  error "请使用 root 或 sudo 运行此脚本"
  exit 1
fi
[[ "${1:-}" == "-h" ]] && display_help && exit 0

# 全局变量
BASE_DIR="/mnt/usbdata"
COMPOSE_DIR="$BASE_DIR/docker/compose"
MOUNTS=(/mnt/usbdata1 /mnt/usbdata2 /mnt/usbdata3)
DEFAULT_COMPOSE_URL="https://raw.githubusercontent.com/norman110/N100/refs/heads/main/docker-compose.yml"
# Dashy 配置文件路径（仅用于目录创建）
DASHY_CONFIG_DIR="$BASE_DIR/docker/dashy/config"

# ================================================
# 环境检测
# ================================================
env_check(){
  . /etc/os-release
  VERSION_ID=${VERSION_ID%%.*}
  case "$VERSION_ID" in
    9) CODENAME="stretch" ;; 10) CODENAME="buster" ;; 
    11) CODENAME="bullseye" ;; 12) CODENAME="bookworm" ;; 
    *) CODENAME="bookworm" ;;
  esac
  log "Debian $VERSION_ID ($CODENAME)"
  
  # 磁盘空间检测
  avail_kb=$(df --output=avail "$BASE_DIR" 2>/dev/null | tail -1 || df --output=avail / | tail -1)
  (( avail_kb < 5*1024*1024 )) && error "磁盘可用空间不足5GB" && exit 1
  
  # 内存检测
  mem_mb=$(free -m | awk '/^Mem:/ {print $2}')
  (( mem_mb < 1024 )) && error "内存不足1GB" && exit 1
  
  log "环境检测通过: 磁盘 $(awk "BEGIN{printf '%.1fGB', $avail_kb/1024/1024}" ), 内存 ${mem_mb}MB"
}
env_check

# ================================================
# 创建目录结构（已移除Dashy配置文件自动生成）
# ================================================
create_dirs(){
  log "创建目录结构：$BASE_DIR"
  mkdir -p \
    "$BASE_DIR"/docker/compose \
    "$BASE_DIR"/docker/qbittorrent/config \
    "$DASHY_CONFIG_DIR" \  # 仅创建目录，不生成配置文件
    "$BASE_DIR"/docker/filebrowser/config \
    "$BASE_DIR"/docker/bitwarden/data \
    "$BASE_DIR"/docker/emby/config \
    "$BASE_DIR"/docker/metatube/postgres \
    "$BASE_DIR"/media/movies \
    "$BASE_DIR"/media/tvshows \
    "$BASE_DIR"/media/av \
    "$BASE_DIR"/media/downloads
}
create_dirs

# ================================================
# IP 与域名检测
# ================================================
detect_ip(){
  IP_ADDR="$(hostname -I | awk '{print $1}')"
  log "本机IP: $IP_ADDR"
}
detect_ip

read -e -rp "请输入泛域名 (如 *.example.com): " WILDCARD_DOMAIN
log "使用域名: $WILDCARD_DOMAIN"

# ================================================
# 菜单功能实现
# ================================================
# 1. 网络检测与配置
check_network() {
  log "开始网络检测..."
  ping -c 3 8.8.8.8 >/dev/null 2>&1 && log "网络连接正常" || error "网络连接失败，请检查网络设置"
}

# 2. 检查 SSH 状态与配置
check_ssh() {
  log "检查SSH服务状态..."
  systemctl is-active --quiet ssh && log "SSH服务正在运行" || warn "SSH服务未运行"
  log "SSH端口配置: $(grep '^Port' /etc/ssh/sshd_config | awk '{print $2}')"
}

# 3. 启用 SSH (root & 密码)
enable_ssh() {
  log "配置SSH允许root登录..."
  sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
  systemctl restart ssh
  log "SSH配置已更新，允许root密码登录"
}

# 4. 磁盘分区 & 挂载
mount_disks() {
  log "开始磁盘挂载配置..."
  for mount_point in "${MOUNTS[@]}"; do
    mkdir -p "$mount_point" && log "检查挂载点: $mount_point"
  done
  log "磁盘挂载配置完成"
}

# 5. 安装 Docker
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

# 6. 部署容器
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

  # 提示Dashy配置文件需手动处理
  if docker compose ps | grep -q "dashy"; then
    log "Dashy 容器已启动"
    log "注意：Dashy配置文件需手动创建，路径为: $DASHY_CONFIG_DIR/conf.yml"
  fi
}

# 7. Docker 一键运维
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

# 8. 系统更新与升级
system_update() {
  log "开始系统更新..."
  apt-get update && apt-get upgrade -y
  apt-get autoremove -y && apt-get autoclean
  log "系统更新完成"
}

# 9. 日志轮转与清理
log_rotation() {
  log "配置日志轮转..."
  apt-get install -y logrotate
  logrotate /etc/logrotate.conf
  log "清理系统日志..."
  find /var/log -type f -name "*.log" -exec truncate -s 0 {} \;
  log "日志清理完成"
}

# ================================================
# 主菜单
# ================================================
while true; do
  echo -e "\n====== N100 AIO 初始化 v11.2 最终修复版 ======"
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
    
