#!/usr/bin/env bash
# N100 All-in-One 初始化脚本 (重构优化版)
set -euo pipefail
IFS=$'\n\t'

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log(){ echo -e "${GREEN}[√]${NC} $*"; }
warn(){ echo -e "${YELLOW}[!]${NC} $*"; }
error(){ echo -e "${RED}[×]${NC} $*" >&2; }

# 帮助信息
if [[ "${1:-}" == "-h" ]]; then
  echo "用法: $0   适用于N100 AIO一键初始化"
  exit 0
fi

# 必须root
if [[ $EUID -ne 0 ]]; then error "请用 root 或 sudo 运行此脚本"; exit 1; fi

BASE_DIR="/mnt/usbdata"
COMPOSE_DIR="$BASE_DIR/docker/compose"
MOUNTS=(/mnt/usbdata1 /mnt/usbdata2 /mnt/usbdata3)

# ---------------------- 基础功能 -----------------------

# 环境检测
env_check(){
  . /etc/os-release
  VERSION_ID=${VERSION_ID%%.*}
  case "$VERSION_ID" in
    9) CODENAME="stretch";; 10) CODENAME="buster";; 11) CODENAME="bullseye";; 12) CODENAME="bookworm";; *) CODENAME="bookworm";;
  esac
  log "系统: Debian $VERSION_ID ($CODENAME)"
  avail_kb=$(df --output=avail "$BASE_DIR" 2>/dev/null | tail -1 || df --output=avail / | tail -1)
  (( avail_kb < 5*1024*1024 )) && error "磁盘可用 <5GB" && exit 1
  mem_mb=$(free -m | awk '/^Mem:/ {print $2}')
  (( mem_mb < 1024 )) && error "内存 <1GB" && exit 1
  log "环境检测通过: 磁盘 $(awk "BEGIN{printf '%.1fGB', $avail_kb/1024/1024}")，内存 ${mem_mb}MB"
}
env_check

# 目录创建
log "创建目录结构: $BASE_DIR"
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

# 获取本机IP
detect_ip(){
  IP_ADDR="$(hostname -I | awk '{print $1}')"
  log "本机IP: $IP_ADDR"
}
detect_ip

read -e -rp "请输入泛域名 (如 *.example.com): " WILDCARD_DOMAIN
log "使用域名: $WILDCARD_DOMAIN"

# ---------------------- 网络设置 ------------------------
network_detect(){
  log "网络接口与IP："
  ip -brief addr show
  log "路由表："
  ip route show
}

network_config(){
  while true; do
    echo -e "\n--- 网络配置子菜单 ---"
    echo "1) DHCP（动态IP）"
    echo "2) 静态IP"
    echo "q) 返回上一级"
    read -e -rp "请选择: " nopt
    case "$nopt" in
      1)
        iface=$(ip -o link show | awk -F': ' '/state UP/ {print $2}' | head -1)
        [[ -z "$iface" ]] && { warn "无可用接口"; continue; }
        cat >/etc/network/interfaces.d/$iface.cfg <<EOF
auto $iface
iface $iface inet dhcp
EOF
        systemctl restart networking && log "DHCP 配置应用完成"
        ;;
      2)
        iface=$(ip -o link show | awk -F': ' '/state UP/ {print $2}' | head -1)
        [[ -z "$iface" ]] && { warn "无可用接口"; continue; }
        read -e -rp "静态IP (如 192.168.1.100/24): " sip
        read -e -rp "网关 (如 192.168.1.1): " gtw
        [[ -z "$sip" || -z "$gtw" ]] && { warn "静态IP或网关不能为空"; continue; }
        cat >/etc/network/interfaces.d/$iface.cfg <<EOF
auto $iface
iface $iface inet static
  address $sip
  gateway $gtw
EOF
        systemctl restart networking && log "静态IP 配置应用完成"
        ;;
      q) break ;;
      *) warn "无效选项";;
    esac
  done
}

# ---------------------- SSH 设置 ------------------------
check_ssh_status(){
  systemctl is-active --quiet ssh && log "SSH 服务已启动" || warn "SSH 未运行"
  cfg=/etc/ssh/sshd_config
  if [[ -f $cfg ]]; then
    port=$(grep -E '^Port ' $cfg | awk '{print $2}'); port=${port:-22}
    pr=$(grep -E '^PermitRootLogin ' $cfg | awk '{print $2}'); pr=${pr:-no}
    pa=$(grep -E '^PasswordAuthentication ' $cfg | awk '{print $2}'); pa=${pa:-yes}
    echo -e "端口: $port\nPermitRootLogin: $pr\nPasswordAuthentication: $pa"
  fi
  if command -v ufw &>/dev/null; then
    ufw status | grep -q '22/tcp' && echo "UFW: SSH已开放" || echo "UFW: SSH未开放"
  elif command -v iptables &>/dev/null; then
    iptables -L | grep -q 'dpt:22' && echo "iptables: SSH已允许" || echo "iptables: SSH未允许"
  fi
}

enable_ssh(){
  apt-get update && apt-get install -y openssh-server
  sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  systemctl enable ssh && systemctl restart ssh
  log "SSH 已启用 (root登录+密码登录)"
}

ssh_config_edit(){
  cfg=/etc/ssh/sshd_config
  while true; do
    echo -e "\n--- SSH 配置修改子菜单 ---"
    echo "1) 修改SSH端口"
    echo "2) 开启/关闭 root 登录"
    echo "3) 开启/关闭 密码登录"
    echo "q) 返回上一级"
    read -e -rp "请选择: " sopt
    case "$sopt" in
      1)
        read -e -rp "输入新端口 (默认22): " sshport
        [[ -z "$sshport" ]] && { warn "未输入端口，已取消"; continue; }
        sed -i "s/^#\?Port .*/Port $sshport/" $cfg
        systemctl restart ssh
        log "SSH 端口已修改为 $sshport"
        ;;
      2)
        read -e -rp "允许root登录？(yes/no): " rlogin
        [[ "$rlogin" != "yes" && "$rlogin" != "no" ]] && { warn "无效输入"; continue; }
        sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin $rlogin/" $cfg
        systemctl restart ssh
        log "PermitRootLogin 已设为 $rlogin"
        ;;
      3)
        read -e -rp "允许密码登录？(yes/no): " pauth
        [[ "$pauth" != "yes" && "$pauth" != "no" ]] && { warn "无效输入"; continue; }
        sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication $pauth/" $cfg
        systemctl restart ssh
        log "PasswordAuthentication 已设为 $pauth"
        ;;
      q) break ;;
      *) warn "无效选项";;
    esac
  done
}

# ---------------------- 磁盘分区与挂载 ------------------------
partition_disk(){
  if ! command -v parted &>/dev/null; then
    log "安装 parted..."
    apt-get update && apt-get install -y parted
  fi
  while true; do
    lsblk -dn -o NAME,SIZE | nl
    read -e -rp "磁盘编号 (q返回): " idx
    [[ "$idx" == "q" ]] && return
    dev=$(lsblk -dn -o NAME | sed -n "${idx}p")
    if [[ -z "$dev" ]]; then warn "无效编号"; continue; fi
    read -e -rp "确认分区 /dev/$dev ? [y/N]: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { warn "操作取消"; return; }
    parted /dev/$dev --script mklabel gpt mkpart primary ext4 1MiB 100%
    mkfs.ext4 /dev/${dev}1
    read -e -rp "请输入挂载点 (如 /mnt/data): " mnt
    [[ -z "$mnt" ]] && { warn "挂载点不能为空"; return; }
    mkdir -p "$mnt" && mount /dev/${dev}1 "$mnt"
    if ! grep -qs "/dev/${dev}1" /etc/fstab; then
      echo "/dev/${dev}1 $mnt ext4 defaults 0 2" >> /etc/fstab
      log "已挂载 /dev/${dev}1 -> $mnt (写入fstab)"
    else
      log "已挂载 /dev/${dev}1 -> $mnt"
    fi
    return
  done
}

mount_disk_and_fstab(){
  lsblk -f
  read -e -rp "请输入要挂载的设备名(如 sda1): " dev
  read -e -rp "请输入挂载点(如 /mnt/data): " mnt
  [[ -z "$dev" || -z "$mnt" ]] && { warn "设备和挂载点不能为空"; return; }
  mkdir -p "$mnt" && mount /dev/$dev "$mnt"
  if ! grep -qs "/dev/$dev" /etc/fstab; then
    echo "/dev/$dev $mnt ext4 defaults 0 2" >> /etc/fstab
    log "已挂载 /dev/$dev -> $mnt (写入fstab)"
  else
    log "已挂载 /dev/$dev -> $mnt"
  fi
}

# ---------------------- Docker 管理 ------------------------
install_docker(){
  if ! command -v curl &>/dev/null; then
    log "安装 curl..."
    apt-get update && apt-get install -y curl
  fi
  if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sh
    apt-get install -y docker-compose-plugin
    usermod -aG docker "${SUDO_USER:-$(logname)}"
    log "Docker 安装完毕，请重启系统并重运行本脚本"; exit 0
  else
    log "Docker 已安装"
  fi
}

docker_one_click(){
  while true; do
    echo -e "\n--- Docker 一键运维 ---"
    echo "1) 停止所有容器"
    echo "2) 启动所有容器"
    echo "3) 重启所有容器"
    echo "4) 删除所有容器"
    echo "5) 删除所有镜像"
    echo "6) 清理 & 重置"
    echo "7) 查看容器日志"
    echo "8) 备份配置"
    echo "q) 返回上一级"
    read -e -rp "请选择: " x
    case "$x" in
      1) docker stop $(docker ps -q) ;;
      2) docker start $(docker ps -aq) ;;
      3) docker restart $(docker ps -q) ;;
      4) docker rm -f $(docker ps -aq) ;;
      5) docker rmi -f $(docker images -q) ;;
      6) docker system prune -af && rm -rf "$BASE_DIR/docker" ;;
      7)
        mapfile -t a < <(docker ps -a --format '{{.Names}}')
        for i in "${!a[@]}"; do echo "$((i+1)). ${a[i]}"; done
        read -e -rp "日志编号: " i
        [[ "$i" =~ ^[0-9]+$ ]] && docker logs "${a[i-1]}" || warn "无效编号"
        ;;
      8)
        echo "挂载点: ${MOUNTS[*]}"
        read -e -rp "备份目录: " b
        [[ -z "$b" ]] && { warn "备份目录不能为空"; continue; }
        mkdir -p "$b" && cp -r "$BASE_DIR/docker" "$b/"
        log "配置备份到: $b/docker"
        ;;
      q) break ;;
      *) warn "无效选项" ;;
    esac
  done
}

# ---------------------- 容器部署 ------------------------
deploy_containers(){
  if ! command -v curl &>/dev/null; then
    log "安装 curl..."
    apt-get update && apt-get install -y curl
  fi
  while true; do
    mkdir -p "$COMPOSE_DIR"
    echo -e "\n--- 容器部署 ---"
    echo "1) 默认 Compose URL 部署"
    echo "2) 手动输入 Compose URL 部署"
    echo "q) 返回上一级"
    read -e -rp "请选择: " o
    case "$o" in
      1) 网站="https://raw.githubusercontent.com/norman110/N100/refs/heads/main/docker-compose.yml";;
      2) read -e -rp "输入 Compose URL: " URL;;
      q) return;;
      *) warn "无效选项"; continue;;
    esac
    if [[ "$URL" =~ github\.com/.*/blob/.* ]]; then
      网站="${URL/\/blob\//\/raw\/}"
      log "已转换为 Raw URL: $URL"
    fi
    log "下载 compose 文件: $URL"
    curl -fsSL "$URL" -o "$COMPOSE_DIR/docker-compose.yml"
    cd "$COMPOSE_DIR" && docker compose up -d
    log "容器部署完成"
    return
  done
}

# ---------------------- 系统更新与清理 ------------------------
update_system(){
  cp /etc/apt/sources.list /etc/apt/sources.list.bak
  sed -i "s|^deb .*|deb http://deb.debian.org/debian ${CODENAME} main contrib non-free|" /etc/apt/sources.list
  apt-get update && apt-get upgrade -y
  log "系统更新完毕"
}

log_rotate(){
  for c in $(docker ps -a --format '{{.Names}}'); do
    f="/var/log/${c}.log"
    docker logs "$c" &> "$f"
    find "$f" -mtime +7 -delete
  done
  log "日志清理完毕"
}

# ---------------------- 主菜单 ------------------------
while true; do
  echo -e "\n====== N100 AIO 初始化 ======"
  echo "1) 网络设置"
  echo "2) SSH 设置"
  echo "3) 磁盘分区与挂载"
  echo "4) Docker 管理"
  echo "5) 容器部署"
  echo "6) 系统更新与清理"
  echo "q) 退出脚本"
  read -e -rp "请输入选项 [1-6/q]: " main_opt
  case "$main_opt" in
    1)  # 网络设置
      while true; do
        echo -e "\n--- 网络设置 ---"
        echo "1) 网络状态检测"
        echo "2) 网络配置（DHCP/静态IP）"
        echo "q) 返回主菜单"
        read -e -rp "请选择: " net_opt
        case "$net_opt" in
          1) network_detect ;;
          2) network_config ;;
          q) break ;;
          *) warn "无效选项";;
        esac
      done
      ;;
    2)  # SSH 设置
      while true; do
        echo -e "\n--- SSH 设置 ---"
        echo "1) 检查 SSH 状态与配置"
        echo "2) 安装/启用 SSH (root&密码)"
        echo "3) 修改 SSH 配置（端口/root登录/密码登录）"
        echo "q) 返回主菜单"
        read -e -rp "请选择: " ssh_opt
        case "$ssh_opt" in
          1) check_ssh_status ;;
          2) enable_ssh ;;
          3) ssh_config_edit ;;
          q) break ;;
          *) warn "无效选项";;
        esac
      done
      ;;
    3)  # 磁盘分区与挂载
      while true; do
        echo -e "\n--- 磁盘分区与挂载 ---"
        echo "1) 列出磁盘/
