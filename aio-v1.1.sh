#!/usr/bin/env bash
# ---------------------------------------------------------------------------- #
# 磁盘分区 & 挂载 / Disk partition
# ---------------------------------------------------------------------------- #
partition_disk(){
  # Ensure parted is installed
  if ! command -v parted &>/dev/null; then
    log "检测到 parted 未安装，正在安装 parted..."
    apt-get update && apt-get install -y parted
  fi

  while true; do
    # List disks
    lsblk -dn -o NAME,SIZE | nl
    read -e -rp "磁盘编号 (或 q 返回): " idx
    [[ "$idx" == "q" ]] && return
    dev=$(lsblk -dn -o NAME | sed -n "${idx}p")
    if [[ -z "$dev" ]]; then
      warn "无效编号，请重新输入"
      continue
    fi
    read -e -rp "确认 /dev/$dev 进行分区? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      warn "操作已取消"
      return
    fi

    # Partition and format
    log "正在分区 /dev/$dev"
    parted /dev/$dev --script mklabel gpt mkpart primary ext4 0%100%
    mkfs.ext4 /dev/${dev}1

    # Mount
    read -e -rp "请输入挂载点 (例如 /mnt/data): " mnt
    mkdir -p "$mnt"
    mount /dev/${dev}1 "$mnt"
    log "挂载完成: /dev/${dev}1 -> $mnt"
    return
  done
}

# ---------------------------------------------------------------------------- #
partition_disk(){
  # Ensure parted is installed
  if ! command -v parted &>/dev/null; then
    log "检测到 parted 未安装，正在安装 parted..."
    apt-get update && apt-get install -y parted
  fi

  while true; do
    # List disks
    lsblk -dn -o NAME,SIZE | nl
    read -e -rp "磁盘编号 (或 q 返回): " idx
    [[ "$idx" == "q" ]] && return
    dev=$(lsblk -dn -o NAME | sed -n "${idx}p")
    if [[ -z "$dev" ]]; then
      warn "无效编号，请重新输入"
      continue
    fi
    read -e -rp "确认 /dev/$dev 进行分区? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      warn "操作已取消"
      return
    fi
    # Partition and format
    log "正在分区 /dev/$dev"
    parted /dev/$dev --script mklabel gpt mkpart primary ext4 0%100%
    mkfs.ext4 /dev/${dev}1
    # Mount
    read -e -rp "请输入挂载点 (例如 /mnt/data): " mnt
    mkdir -p "$mnt"
    mount /dev/${dev}1 "$mnt"
    log "挂载完成: /dev/${dev}1 -> $mnt"
    return
  done
}

# ---------------------------------------------------------------------------- #

set -euo pipefail
IFS=$'\n\t'

stty sane  # 恢复输入编辑功能，确保删除键可用

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
detect_ip(){
  IP_ADDR="$(hostname -I | awk '{print $1}')"
  log "本机IP: $IP_ADDR"
}
detect_ip
read -e -rp "请输入泛域名 (如 *.example.com): " WILDCARD_DOMAIN
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
  while true; do
    echo
    echo "网络配置子菜单："
    echo "1) DHCP (动态IP)"
    echo "2) 静态IP"
    echo "q) 返回主菜单"
    read -e -rp "选择: " nopt
    case "$nopt" in
      1)
        iface=$(ip -o link show | awk -F': ' '/state UP/ {print $2}' | head -1)
        [[ -z "$iface" ]] && { warn "无可用接口"; continue; }
        cat >/etc/network/interfaces.d/$iface.cfg <<EOF
auto $iface
iface $iface inet dhcp
EOF
        systemctl restart networking && log "DHCP 配置应用完成";;
      2)
        iface=$(ip -o link show | awk -F': ' '/state UP/ {print $2}' | head -1)
        [[ -z "$iface" ]] && { warn "无可用接口"; continue; }
        read -e -rp "静态IP (如 192.168.1.100/24): " sip
        read -e -rp "网关 (如 192.168.1.1): " gtw
        cat >/etc/network/interfaces.d/$iface.cfg <<EOF
auto $iface
iface $iface inet static
  address $sip
  gateway $gtw
EOF
        systemctl restart networking && log "静态IP 配置应用完成";;
      q) break;;
      *) warn "无效选项";;
    esac
  done
}

# ---------------------------------------------------------------------------- #
# SSH 功能 / SSH functions
# ---------------------------------------------------------------------------- #
check_ssh_status(){
  systemctl is-active --quiet ssh && log "SSH 运行中" || warn "SSH 未运行"
  cfg=/etc/ssh/sshd_config
  if [[ -f $cfg ]]; then
    port=$(grep -E '^Port ' $cfg | awk '{print $2}'); port=${port:-22}
    pr=$(grep -E '^PermitRootLogin ' $cfg | awk '{print $2}'); pr=${pr:-no}
    pa=$(grep -E '^PasswordAuthentication ' $cfg | awk '{print $2}'); pa=${pa:-yes}
    echo "Port: $port, PermitRootLogin: $pr, PasswordAuthentication: $pa"
  fi
  if command -v ufw &>/dev/null; then
    ufw status | grep -q '22/tcp' && echo "UFW: SSH 已开放" || echo "UFW: SSH 未开放"
  elif command -v iptables &>/dev/null; then
    iptables -L | grep -q 'dpt:22' && echo "iptables: SSH 已允许" || echo "iptables: SSH 未允许"
  fi
}
enable_ssh(){
  while true; do
    echo
    echo "启用 SSH 子菜单："
    echo "1) 安装并启用 SSH (root & 密码)"
    echo "q) 返回主菜单"
    read -e -rp "选择: "
    case "$s" in
      1)
        apt-get update && apt-get install -y openssh-server
        sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
        sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
        systemctl enable ssh && systemctl restart ssh
        log "SSH 启用完成";;
      q) break;;
      *) warn "无效选项";;
    esac
  done
}

# ---------------------------------------------------------------------------- #
# 磁盘分区 & 挂载 / Disk partition
# ---------------------------------------------------------------------------- #
partition_disk(){
  # Ensure parted is installed
  if ! command -v parted &>/dev/null; then
    log "检测到 parted 未安装，正在安装 parted..."
    apt-get update && apt-get install -y parted
  fi
  while true; do
  while true; do
    lsblk -dn -o NAME,SIZE | nl
    read -e -rp "磁盘编号 (或 q 返回): " idx
    [[ "$idx" == "q" ]] && break
    dev=$(lsblk -dn -o NAME | sed -n "${idx}p")
    [[ -z "$dev" ]] && { warn "无效编号"; continue; }
    read -e -rp "确认 /dev/$dev? [y/N]: " y
    [[ ! "$y" =~ ^[Yy]$ ]] && { warn "操作取消"; continue; }
    parted /dev/$dev --script mklabel gpt mkpart primary ext4 0%100%
    mkfs.ext4 /dev/${dev}1
    read -e -rp "挂载点 (如 /mnt/data): " mnt
    mkdir -p "$mnt" && mount /dev/${dev}1 "$mnt"
    log "挂载完成: /dev/${dev}1 -> $mnt"
    break
  done
}

# ---------------------------------------------------------------------------- #
# Docker 安装 / Install Docker
# ---------------------------------------------------------------------------- #
install_docker(){
  if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sh
    apt-get install -y docker-compose-plugin
    usermod -aG docker "$SUDO_USER"
    log "Docker 安装完毕，请重启系统并重新运行此脚本"; exit 0
  else
    log "Docker 已安装，跳过"
  fi
}

# ---------------------------------------------------------------------------- #
# 容器部署 / Deploy containers
deploy_containers(){
  while true; do
    mkdir -p "$COMPOSE_DIR"
    echo
    echo "部署容器子菜单："
    echo "1) 使用默认 URL"
    echo "2) 手动输入 URL"
    echo "q) 返回主菜单"
    read -e -rp "选择: " o
    case "$o" in
      1) 网站="https://raw.githubusercontent.com/norman110/N100/refs/heads/main/docker-compose.yml";;
      2) read -e -rp "输入 compose URL: " URL;;
      q) return;;
      *) warn "无效选项"; continue;;
    esac
    log "下载 compose 文件: $URL"
    curl -fsSL "$URL" -o "$COMPOSE_DIR/docker-compose.yml"
    cd "$COMPOSE_DIR" && docker compose up -d
    # 自动生成 Dashy 配置
    CONF="$BASE_DIR/docker/dashy/config/conf.yml"; mkdir -p "$(dirname \$CONF)"
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
    for c in $(docker ps --format '{{.Names}}'); do
      p=$(docker port "$c" | head -1 | awk -F: '{print \$2}')
      echo "      - title: $c" >> "$CONF"
      echo "        url: http://\$IP_ADDR:$p" >> "$CONF"
    done
    log "部署完成 & Dashy 配置生成: $CONF"
    break
  done
}

# ---------------------------------------------------------------------------- #
# Docker 一键运维 / Docker One-Click
# ---------------------------------------------------------------------------- #
docker_one_click(){
  while true; do
    echo
    echo "Docker 一键运维子菜单："
    echo "1) 停止所有容器"
    echo "2) 启动所有容器"
    echo "3) 重启所有容器"
    echo "4) 删除所有容器"
    echo "5) 删除所有镜像"
    echo "6) 清理 & 重置"
    echo "7) 查看容器日志"
    echo "8) 备份配置"
    echo "q) 返回主菜单"
    read -e -rp "选择: " x
    case "$x" in
      1) docker stop $(docker ps -q) ;; 2) docker start $(docker ps -aq) ;; 3) docker restart $(docker ps -q) ;;
      4) docker rm -f $(docker ps -aq) ;; 5) docker rmi -f $(docker images -q) ;;
      6) docker system prune -af && rm -rf "$BASE_DIR/docker" ;;  
      7)
        mapfile -t a < <(docker ps -a --format '{{.Names}}')
        for i in "${!a[@]}"; do echo "$((i+1)). ${a[i]}"; done
        read -e -rp "日志编号: " i; docker logs "${a[i-1]}" ;;  
      8)
        echo "挂载点: ${MOUNTS[*]}"
        read -e -rp "备份目录: " b
        mkdir -p "$b" && cp -r "$BASE_DIR/docker" "$b/"
        log "配置备份到: $b/docker" ;;  
      q) break ;;
      *) warn "无效选项" ;;  
    esac
  done
}

# ---------------------------------------------------------------------------- #
# 系统更新 & 日志清理
# ---------------------------------------------------------------------------- #
update_system(){
  sed -i "s|^deb .*|deb http://deb.debian.org/debian ${CODENAME} main contrib non-free|" /etc/apt/sources.list
  apt-get update && apt-get upgrade -y
  log "系统更新完毕"
}
log_rotate(){
  for c in $(docker ps -a --format '{{.Names}}'); do
    f="/var/log/${c}.log"; docker logs "$c" &> "$f"; find "$f" -mtime +7 -delete
  done
  log "日志清理完毕"
}

# ---------------------------------------------------------------------------- #
# 主菜单 / Main Menu
# ---------------------------------------------------------------------------- #
while true; do
  echo
  cat <<EOF
====== N100 AIO 初始化 v11.2 ======
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
  read -e -rp "选择: " ch
  case "$ch" in
    1)
      echo
      echo "1) 网络检测"
      echo "2) 网络配置"
      echo "q) 返回主菜单"
      read -e -rp "子菜单: " sub
      [[ "$sub" == "1" ]] && network_detect
      [[ "$sub" == "2" ]] && network_config
      ;;  
    2) check_ssh_status ;; 3) enable_ssh ;; 4) partition_disk ;; 5) install_docker ;; 6) deploy_containers ;; 7) docker_one_click ;;
    8) update_system ;; 9) log_rotate ;;
    q) log "退出脚本"; break ;;
    *) warn "无效选项" ;;  
  esac
done

log "脚本执行完毕"
