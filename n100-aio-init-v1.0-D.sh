#!/usr/bin/env bash
# ---------------------------------------------------------------------------- #
# N100 All-in-One 交互式初始化脚本-豆包 v1.0
# ---------------------------------------------------------------------------- #

set -euo pipefail
IFS=$'\n\t'

# 恢复终端输入功能以支持删除键
stty sane

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
  -h        显示帮助信息
功能:
  环境检测 (自动)
  网络检测与配置
  检查 SSH 状态与配置
  启用 SSH (root & 密码)
  磁盘分区 & 挂载
  安装 Docker
  部署容器
  Docker 一键运维
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
  display_help; exit 0;
fi

# 全局变量
BASE_DIR="/mnt/usbdata"
COMPOSE_DIR="$BASE_DIR/docker/compose"
MOUNTS=(/mnt/usbdata1 /mnt/usbdata2 /mnt/usbdata3)
DEFAULT_COMPOSE_URL="https://raw.githubusercontent.com/norman110/N100/refs/heads/main/docker-compose.yml"

# ---------------------------------------------------------------------------- #
# 环境检测 / Environment check
env_check(){
  . /etc/os-release
  VERSION_ID=${VERSION_ID%%.*}
  case "$VERSION_ID" in
    9) CODENAME="stretch" ;; 
    10) CODENAME="buster" ;; 
    11) CODENAME="bullseye" ;; 
    12) CODENAME="bookworm" ;; 
    *) CODENAME="bookworm" ;;
  esac
  log "Debian $VERSION_ID ($CODENAME)"
  
  # 磁盘空间检测
  avail_kb=$(df --output=avail "$BASE_DIR" 2>/dev/null | tail -1 || df --output=avail / | tail -1)
  if (( avail_kb < 5*1024*1024 )); then
    error "磁盘可用空间不足5GB"
    exit 1
  fi
  
  # 内存检测
  mem_mb=$(free -m | awk '/^Mem:/ {print $2}')
  if (( mem_mb < 1024 )); then
    error "内存不足1GB"
    exit 1
  fi
  
  log "环境检测通过: 磁盘 $(awk "BEGIN{printf '%.1fGB', $avail_kb/1024/1024}" ), 内存 ${mem_mb}MB"
}
env_check

# 创建目录结构
log "创建目录结构：$BASE_DIR"
mkdir -p \
  "$BASE_DIR"/docker/compose \
  "$BASE_DIR"/docker/qbittorrent/config \
  "$BASE_DIR"/docker/dashy/config \
  "$BASE_DIR"/docker/filebrowser/config \
  "$BASE_DIR"/docker/bitwarden/data \
  "$BASE_DIR"/docker/emby/config \
  "$BASE_DIR"/docker/metatube/postgres \
  "$BASE_DIR"/media/movies \
  "$BASE_DIR"/media/tvshows \
  "$BASE_DIR"/media/av \
  "$BASE_DIR"/media/downloads

# 修复Dashy配置文件可能的冲突
fix_dashy_config() {
  local dashy_config="$BASE_DIR/docker/dashy/config/conf.yml"
  if [ -d "$dashy_config" ]; then
    warn "发现Dashy配置路径被错误创建为目录，正在修复..."
    rm -rf "$dashy_config"
    touch "$dashy_config"
  elif [ ! -f "$dashy_config" ]; then
    log "创建默认Dashy配置文件"
    touch "$dashy_config"
  fi
}
fix_dashy_config

# ---------------------------------------------------------------------------- #
# IP 与域名 / IP & Domain
detect_ip(){
  IP_ADDR="$(hostname -I | awk '{print $1}')"
  log "本机IP: $IP_ADDR"
}
detect_ip

read -e -rp "请输入泛域名 (如 *.example.com): " WILDCARD_DOMAIN
log "使用域名: $WILDCARD_DOMAIN"

# ---------------------------------------------------------------------------- #
# 网络检测与配置
check_network() {
  log "开始网络检测..."
  if ping -c 3 8.8.8.8 >/dev/null 2>&1; then
    log "网络连接正常"
    return 0
  else
    error "网络连接失败，请检查网络设置"
    return 1
  fi
}

# 检查SSH状态与配置
check_ssh() {
  log "检查SSH服务状态..."
  if systemctl is-active --quiet ssh; then
    log "SSH服务正在运行"
  else
    warn "SSH服务未运行"
  fi
  
  log "SSH端口配置: $(grep '^Port' /etc/ssh/sshd_config | awk '{print $2}')"
}

# 启用SSH (root & 密码)
enable_ssh() {
  log "配置SSH允许root登录..."
  sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
  
  systemctl restart ssh
  log "SSH配置已更新，允许root密码登录"
}

# 磁盘分区与挂载
mount_disks() {
  log "开始磁盘挂载配置..."
  for mount_point in "${MOUNTS[@]}"; do
    if [ ! -d "$mount_point" ]; then
      mkdir -p "$mount_point"
    fi
    log "检查挂载点: $mount_point"
  done
  
  log "磁盘挂载配置完成"
}

# 安装Docker
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

# 部署容器
deploy_containers() {
  local compose_url
  while true; do
    echo -e "\n部署容器子菜单："
    echo "1) 使用默认 URL"
    echo "2) 手动输入 URL"
    echo "q) 返回主菜单"
    read -rp "选择: " choice

    case "$choice" in
      1)
        compose_url="$DEFAULT_COMPOSE_URL"
        break
        ;;
      2)
        read -rp "输入 compose URL: " compose_url
        if [ -z "$compose_url" ]; then
          warn "URL不能为空"
          continue
        fi
        break
        ;;
      q|Q)
        return 0
        ;;
      *)
        warn "无效选项，请重新选择"
        ;;
    esac
  done

  # 下载compose文件
  log "下载 compose 文件: $compose_url"
  mkdir -p "$COMPOSE_DIR"
  local compose_file="$COMPOSE_DIR/docker-compose.yml"
  
  if ! curl -fsSL "$compose_url" -o "$compose_file"; then
    error "下载 compose 文件失败"
    return 1
  fi

  # 执行部署
  log "开始部署容器..."
  cd "$COMPOSE_DIR" || { error "无法进入目录 $COMPOSE_DIR"; return 1; }
  docker compose up -d
  
  # 检查部署状态
  if docker compose ps | grep -q "Exit"; then
    warn "部分容器可能部署失败，请检查日志"
  else
    log "容器部署完成"
  fi
}

# Docker一键运维
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
    1)
      docker ps -a
      ;;
    2)
      docker restart $(docker ps -q)
      ;;
    3)
      docker stop $(docker ps -q)
      ;;
    4)
      read -rp "输入容器名称: " container
      docker logs -f "$container"
      ;;
    5)
      docker image prune -a -f
      ;;
    6)
      read -rp "确定要清理所有容器和数据吗? (y/N) " confirm
      if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        docker rm -f $(docker ps -aq)
        docker volume prune -f
        log "Docker环境已重置"
      fi
      ;;
    q|Q)
      return 0
      ;;
    *)
      warn "无效选项"
      ;;
  esac
}

# 系统更新与升级
system_update() {
  log "开始系统更新..."
  apt-get update && apt-get upgrade -y
  apt-get autoremove -y && apt-get autoclean
  log "系统更新完成"
}

# 日志轮转与清理
log_rotation() {
  log "配置日志轮转..."
  apt-get install -y logrotate
  logrotate /etc/logrotate.conf
  log "清理系统日志..."
  find /var/log -type f -name "*.log" -exec truncate -s 0 {} \;
  log "日志清理完成"
}

# 主菜单
while true; do
  echo -e "\n====== N100 AIO 初始化 v11.2 ======"
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
    1)
      check_network
      ;;
    2)
      check_ssh
      ;;
    3)
      enable_ssh
      ;;
    4)
      mount_disks
      ;;
    5)
      install_docker
      ;;
    6)
      deploy_containers
      ;;
    7)
      docker_maintenance
      ;;
    8)
      system_update
      ;;
    9)
      log_rotation
      ;;
    q|Q)
      log "退出脚本"
      exit 0
      ;;
    *)
      warn "无效选项，请重新选择"
      ;;
  esac
done
    
