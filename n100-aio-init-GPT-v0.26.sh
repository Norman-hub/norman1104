#!/usr/bin/env bash
# N100 AIO 初始化脚本 v0.26 / Simplified & Automated (修复版)
set -euo pipefail
IFS=$'\n\t'

# 颜色定义
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m';  BLUE='\033[0;34m'; NC='\033[0m'
log()   { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# 确保以 root 身份运行
if [[ $EUID -ne 0 ]]; then
  error "请以 root 用户运行此脚本"
  exit 1
fi

########## 本机信息显示 ##########
show_system_info() {
  echo -e "${BLUE}=================系统信息 / System Info=================${NC}"
  echo -e " 主机名   : $(hostname)"
  echo -e " OS       : $(grep -oP '(?<=PRETTY_NAME=").*(?=")' /etc/os-release)"
  echo -e " 内存     : $(free -h | awk '/^Mem:/ {print $2 " total, " $3 " used, " $4 " free"}')"
  echo -e " CPU      : $(nproc) 核心 / cores ($(lscpu | grep 'Model name' | cut -d: -f2 | xargs))"
  echo -e " 磁盘使用情况:"
  df -h --output=source,size,used,avail,target | sed '1s/^/设备        容量  已用  可用  挂载点\n/'
  echo -e "\n本机 IPv4:"
  ip -4 addr show scope global | awk '/inet/ {print $NF": "$2}'
}

########## SSH 管理 / SSH Management ##########
ssh_auto_enable() {
  log "检测 SSH 服务状态..."
  if ! systemctl is-active ssh >/dev/null 2>&1; then
    log "安装并启动 openssh-server..."
    apt-get update
    apt-get install -y openssh-server
    systemctl enable ssh
    systemctl start ssh
  else
    log "SSH 服务已运行"
  fi

  local conf="/etc/ssh/sshd_config"
  if grep -qE '^\s*PermitRootLogin\s+yes' "$conf"; then
    log "已允许 root 登录"
  else
    log "配置 PermitRootLogin yes 并重载 sshd..."
    cp "$conf" "${conf}.bak-$(date +%F_%T)"
    sed -i 's@^\s*#\?\(PermitRootLogin\s*\).*@\1yes@' "$conf"
    systemctl reload ssh
  fi
  log "SSH 管理完成"
}

########## 网络管理 / Network Management ##########
list_interfaces() {
  mapfile -t ifs < <(ip -o -4 addr show | awk '{print $2}')
  echo "可用网络接口:"
  for i in "${!ifs[@]}"; do
    ip_addr=$(ip -o -4 addr show "${ifs[i]}" | awk '{print $4}')
    printf "  %d) %s  IP: %s\n" "$((i+1))" "${ifs[i]}" "${ip_addr:-无}"
  done
}

configure_static_ip() {
  list_interfaces
  while true; do
    read -rp "请输入编号选择接口: " idx
    [[ $idx =~ ^[0-9]+$ && idx -ge 1 && idx -le ${#ifs[@]} ]] && break
    warn "无效编号，请重新输入"
  done
  iface=${ifs[$((idx-1))]}
  while true; do
    read -rp "输入静态IP (带掩码 192.168.1.100/24): " ip_addr
    [[ $ip_addr =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] && break
    warn "格式错误，请重新输入"
  done
  read -rp "输入网关 (e.g. 192.168.1.1): " gw
  read -rp "输入DNS服务器 (空格分隔): " dns

  backup="/etc/network/interfaces.bak-$(date +%F_%T)"
  cp /etc/network/interfaces "$backup"
  log "已备份原文件至 $backup"

  cat > /etc/network/interfaces <<EOF
auto $iface
iface $iface inet static
    address $ip_addr
    gateway $gw
    dns-nameservers $dns
EOF

  if systemctl restart networking; then
    log "静态IP 配置成功"
  else
    warn "网络重启失败，请检查"
  fi
}

configure_dhcp() {
  list_interfaces
  while true; do
    read -rp "请输入编号选择接口: " idx
    [[ $idx =~ ^[0-9]+$ && idx -ge 1 && idx -le ${#ifs[@]} ]] && break
    warn "无效编号，请重新输入"
  done
  iface=${ifs[$((idx-1))]}

  backup="/etc/network/interfaces.bak-$(date +%F_%T)"
  cp /etc/network/interfaces "$backup"
  log "已备份原文件至 $backup"

  cat > /etc/network/interfaces <<EOF
auto $iface
iface $iface inet dhcp
EOF

  if systemctl restart networking; then
    log "DHCP 配置成功"
  else
    warn "网络重启失败，请检查"
  fi
}

network_menu() {
  while true; do
    echo -e "\n=== 网络管理 ==="
    echo "1) 查看网络状态"
    echo "2) 静态IP 配置"
    echo "3) DHCP 配置"
    echo "b) 返回"
    read -rp "请选择: " opt
    case "$opt" in
      1) ip addr show; ip route show ;;
      2) configure_static_ip ;;
      3) configure_dhcp ;;
      b|B) break ;;
      *) warn "无效选项" ;;
    esac
  done
}

########## 磁盘管理 / Disk Management ##########
disk_status() {
  echo -e "\n磁盘状态 / Disk Status:"
  lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT,LABEL | \
    awk 'NR==1{print; next}
         $1 ~ /^[[:alnum:]]+$/ && $2=="disk" && $4=="" {
           printf "%-8s %-6s %-8s %-10s %-12s %-10s 未分区\n",
                  $1,$2,$3,$4,$5,$6; next }
         {print}'
}

disk_partition() {
  echo -e "${YELLOW}磁盘分区具有破坏性，请输入 yes 确认:${NC}"
  read -r confirm
  [[ "$confirm" == "yes" ]] || { log "已取消"; return; }

  while true; do
    read -rp "输入磁盘设备 (例如 /dev/sdb): " disk_dev
    [[ -b "$disk_dev" ]] && break
    error "设备不存在，请重新输入"
  done

  cat <<EOF
———————————————————————————  分区步骤说明  ———————————————————————————
新建:(n) 主分区:(p) 分区号:(1-4) 默认扇区:(回车2次) 保存退出:(w) 删除:(d)
EOF
  fdisk "$disk_dev"

  while true; do
    read -rp "请输入新分区设备 (如 /dev/sdb1): " part_dev
    [[ -b "$part_dev" ]] && break
    error "分区设备无效，请重新输入"
  done

  read -rp "是否格式化为 ext4? (yes/no): " fmt_confirm
  if [[ "$fmt_confirm" == "yes" ]]; then
    read -rp "请输入卷标 (留空则不加): " vol_label
    if [[ -n "$vol_label" ]]; then
      mkfs.ext4 -L "$vol_label" "$part_dev"
    else
      mkfs.ext4 "$part_dev"
    fi
    log "格式化完成"
  else
    warn "跳过格式化"
  fi
}

disk_mount() {
  while true; do
    read -rp "输入分区设备 (如 /dev/sdb1): " dev
    [[ -b "$dev" ]] && break
    error "设备无效，请重新输入"
  done
  read -rp "输入挂载点 (如 /mnt/usbdata): " mnt
  [[ -n "$mnt" ]] || { error "挂载点不能为空"; return; }
  mkdir -p "$mnt"
  mount "$dev" "$mnt" && log "挂载成功 $dev -> $mnt" || warn "挂载失败"

  read -rp "写入 /etc/fstab 实现开机挂载? (yes/no): " f
  if [[ "$f" == "yes" ]]; then
    uuid=$(blkid -s UUID -o value "$dev")
    [[ -n "$uuid" ]] || { error "无法获取 UUID"; return; }
    backup_fstab="/etc/fstab.bak-$(date +%F_%T)"
    cp /etc/fstab "$backup_fstab"
    echo "UUID=$uuid   $mnt   ext4   defaults   0   2" >> /etc/fstab
    log "已追加至 /etc/fstab (备份: $backup_fstab)"
  fi
}

disk_menu() {
  while true; do
    echo -e "\n=== 磁盘管理 ==="
    echo "1) 查看磁盘状态"
    echo "2) 磁盘分区"
    echo "3) 磁盘挂载"
    echo "b) 返回"
    read -rp "请选择: " opt
    case "$opt" in
      1) disk_status ;;
      2) disk_partition ;;
      3) disk_mount ;;
      b|B) break ;;
      *) warn "无效选项" ;;
    esac
  done
}

########## Docker 管理 / Docker Management ##########
install_docker() {
  if command -v docker >/dev/null && command -v docker-compose >/dev/null; then
    log "已安装 Docker & docker-compose"
    return
  fi
  log "安装 Docker..."
  curl -fsSL https://get.docker.com | sh
  apt-get install -y docker-compose-plugin
  systemctl enable docker && systemctl start docker
}

deploy_containers() {
  COMPOSE_DIR="/mnt/data/docker/compose"
  mkdir -p "$COMPOSE_DIR"
  echo "1) 使用默认 URL"
  echo "2) 手动输入 URL"
  while true; do
    read -rp "请选择下载方式 (1/2): " choice
    case "$choice" in
      1)
        url="https://raw.githubusercontent.com/norman110/N100/refs/heads/main/docker-compose.yml"
        break
        ;;
      2)
        read -rp "请输入完整 URL: " url
        if [[ $url =~ ^https?://.+\.ya?ml$ ]]; then
          break
        else
          warn "URL 格式错误，请以 http(s):// 开头并以 .yml 或 .yaml 结尾"
        fi
        ;;
      *)
        warn "请输入 1 或 2"
        ;;
    esac
  done

  log "下载 docker-compose.yml"
  curl -fsSL "$url" -o "$COMPOSE_DIR/docker-compose.yml"
  if [[ -s "$COMPOSE_DIR/docker-compose.yml" ]]; then
    (cd "$COMPOSE_DIR" && docker compose up -d)
    log "容器部署完成"
  else
    error "下载失败或文件为空，请检查 URL"
  fi
}

docker_one_click() {
  while true; do
    echo -e "\n--- Docker 一键运维 ---"
    echo "1) 查看容器状态"
    echo "2) 单容器操作"
    echo "3) 重启全部"
    echo "4) 停止全部"
    echo "5) 清理无用资源"
    echo "6) 清理日志"
    echo "b) 返回"
    read -rp "请选择: " o
    case "$o" in
      1) docker ps -a ;;
      2)
        read -rp "容器 ID/名称: " cid
        read -rp "操作 (start/stop/restart): " act
        docker "$act" "$cid" && log "操作成功" || warn "操作失败"
        ;;
      3) docker restart $(docker ps -q) ;;
      4) docker stop $(docker ps -q) ;;
      5) docker system prune -a -f --volumes ;;
      6)
        for f in /var/lib/docker/containers/*/*.log; do :> "$f"; done
        log "日志清理完成"
        ;;
      b|B) break ;;
      *) warn "无效选项" ;;
    esac
  done
}

docker_menu() {
  while true; do
    echo -e "\n=== Docker 管理 ==="
    echo "1) 安装"
    echo "2) 部署"
    echo "3) 运维"
    echo "b) 返回"
    read -rp "请选择: " o
    case "$o" in
      1) install_docker ;;
      2) deploy_containers ;;
      3) docker_one_click ;;
      b|B) break ;;
      *) warn "无效选项" ;;
    esac
  done
}

########## 系统管理 / System Management ##########
system_update() {
  apt-get update && apt-get upgrade -y && log "系统更新完成"
}

script_self_upgrade() {
  src_url="https://raw.githubusercontent.com/norman110/N100/refs/heads/main/n100-aio-init-GPT-v0.26.sh"
  tmp="/tmp/$(basename "$0")"
  log "下载最新脚本..."
  curl -fsSL "$src_url" -o "$tmp"
  if [[ -s "$tmp" ]]; then
    cp "$0" "$0.bak-$(date +%F_%T)"
    mv "$tmp" "$0"
    chmod +x "$0"
    log "脚本已升级并备份旧版"
    log "请重新运行脚本"
    exit 0
  else
    warn "下载失败"
  fi
}

system_menu() {
  while true; do
    echo -e "\n=== 系统管理 ==="
    echo "1) 更新升级"
    echo "2) 脚本自升级"
    echo "b) 返回"
    read -rp "请选择: " opt
    case "$opt" in
      1) system_update ;;
      2) script_self_upgrade ;;
      b|B) break ;;
      *) warn "无效选项" ;;
    esac
  done
}

########## 主菜单 / Main Menu ##########
show_system_info
main_menu() {
  while true; do
    echo -e "\n====== N100 AIO 初始化 v0.26 ======"
    echo "1) SSH 管理"
    echo "2) 网络管理"
    echo "3) 磁盘管理"
    echo "4) Docker 管理"
    echo "5) 系统管理"
    echo "q) 退出"
    read -rp "请选择: " ch
    case "$ch" in
      1) ssh_auto_enable ;;
      2) network_menu ;;
      3) disk_menu ;;
      4) docker_menu ;;
      5) system_menu ;;
      q|Q) log "退出"; exit 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

main_menu
