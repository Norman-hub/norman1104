#!/usr/bin/env bash
# N100 AIO 初始化脚本 v0.25 / Simplified & Automated
# 保留模块：SSH管理、网络管理、磁盘管理、Docker管理、系统管理（含脚本自升级）
set -euo pipefail
IFS=$'\n\t'

# 颜色定义 / Color definitions
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()   { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# 确保以 root 身份运行 / Ensure running as root
if [[ $EUID -ne 0 ]]; then
  error "请以 root 用户运行此脚本 / Please run as root"
  exit 1
fi

########## SSH 管理 / SSH Management ##########
ssh_auto_enable() {
  log "检测 SSH 服务状态 / Checking SSH service..."
  if ! systemctl is-active ssh >/dev/null 2>&1; then
    log "安装并启动 openssh-server / Installing and starting openssh-server..."
    apt-get update
    apt-get install -y openssh-server
    systemctl enable ssh
    systemctl start ssh
  else
    log "SSH 服务已运行 / SSH is already running"
  fi

  local conf="/etc/ssh/sshd_config"
  if grep -qE '^\s*PermitRootLogin\s+yes' "$conf"; then
    log "已允许 root 登录 / Root login already permitted"
  else
    log "配置 PermitRootLogin yes 并重载 SSH / Enabling root login and reloading sshd..."
    cp "$conf" "${conf}.bak-$(date +%F_%T)"
    sed -i 's@^\s*#\?\(PermitRootLogin\s*\).*@\1yes@' "$conf"
    systemctl reload ssh
  fi
  log "SSH 管理完成 / SSH setup complete"
}

########## 网络管理 / Network Management ##########
list_interfaces() {
  # 列出编号接口 / List interfaces with index
  mapfile -t ifs < <(ip -o -4 addr show | awk '{print $2}')
  echo "可用网络接口 / Available interfaces:"
  for i in "${!ifs[@]}"; do
    ip_addr=$(ip -o -4 addr show "${ifs[i]}" | awk '{print $4}')
    printf "  %d) %s  IP:%s\n" "$((i+1))" "${ifs[i]}" "${ip_addr:-无}" 
  done
}

configure_static_ip() {
  list_interfaces
  read -rp "请输入编号选择接口 (e.g. 1): " idx
  if ! [[ $idx =~ ^[0-9]+$ ]] || (( idx<1 || idx>${#ifs[@]} )); then
    error "无效编号 / Invalid selection"
    return
  fi
  iface=${ifs[$((idx-1))]}
  read -rp "输入静态IP (带掩码, 例如 192.168.1.100/24): " ip_addr
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
    log "静态IP 配置成功 / Static IP configured successfully"
  else
    warn "网络重启失败，请检查 / Networking restart failed, please check"
  fi
}

configure_dhcp() {
  list_interfaces
  read -rp "请输入编号选择接口 (e.g. 2): " idx
  if ! [[ $idx =~ ^[0-9]+$ ]] || (( idx<1 || idx>${#ifs[@]} )); then
    error "无效编号 / Invalid selection"
    return
  fi
  iface=${ifs[$((idx-1))]}

  backup="/etc/network/interfaces.bak-$(date +%F_%T)"
  cp /etc/network/interfaces "$backup"
  log "已备份原文件至 $backup"

  cat > /etc/network/interfaces <<EOF
auto $iface
iface $iface inet dhcp
EOF

  if systemctl restart networking; then
    log "DHCP 配置成功 / DHCP configured successfully"
  else
    warn "网络重启失败，请检查 / Networking restart failed, please check"
  fi
}

network_menu() {
  while true; do
    echo -e "\n=== 网络管理 / Network ==="
    echo "1) 查看网络状态 / Show status"
    echo "2) 静态IP 配置 / Static IP"
    echo "3) DHCP 配置 / DHCP"
    echo "b) 返回 / Back"
    read -rp "请选择: " opt
    case "$opt" in
      1)
        ip addr show
        ip route show
        ;;
      2) configure_static_ip ;;
      3) configure_dhcp ;;
      b|B) break ;;
      *) warn "无效选项 / Invalid option" ;;
    esac
  done
}

########## 磁盘管理 / Disk Management ##########
disk_status() {
  echo "磁盘状态 (未分区磁盘标注“未分区”) / Disk status (unpartitioned disks marked):"
  lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT,LABEL | \
    awk 'NR==1{print; next}
         $2=="disk" && $4=="" {printf "%-8s %-6s %-8s %-10s %-12s %-10s 未分区\n", $1,$2,$3,$4,$5,$6; next}
         {print}'
}

disk_partition() {
  echo -e "${YELLOW}磁盘分区具有破坏性，请确认后继续 (yes):${NC}"
  read -r confirm
  [[ "$confirm" == "yes" ]] || { log "已取消 / Aborted"; return; }

  read -rp "输入磁盘设备 (例如 /dev/sdb): " disk_dev
  [[ -b "$disk_dev" ]] || { error "设备不存在 / Not a block device"; return; }

  cat <<EOF
—— 分区步骤说明（全中文）——
1) 新建分区: 输入 n
2) 类型选择: 输入 p（主分区）
3) 分区编号: 默认输入 1
4) 起始扇区: 回车使用默认
5) 结束扇区: 回车使用整盘
6) 保存并退出: 输入 w
如需删除旧分区，输入 d
EOF

  fdisk "$disk_dev"

  read -rp "请输入新分区设备 (如 /dev/sdb1): " part_dev
  [[ -b "$part_dev" ]] || { error "分区设备无效 / Invalid partition"; return; }

  read -rp "是否格式化为 ext4? (yes/no): " fmt_confirm
  if [[ "$fmt_confirm" == "yes" ]]; then
    read -rp "请输入卷标 (留空则不添加): " vol_label
    if [[ -n "$vol_label" ]]; then
      mkfs.ext4 -L "$vol_label" "$part_dev"
    else
      mkfs.ext4 "$part_dev"
    fi
    log "格式化完成 / Formatted as ext4"
  else
    warn "跳过格式化 / Skipped formatting"
  fi
}

disk_mount() {
  read -rp "输入分区设备 (如 /dev/sdb1): " dev
  [[ -b "$dev" ]] || { error "设备无效 / Invalid device"; return; }
  read -rp "输入挂载点 (如 /mnt/usbdata): " mnt
  [[ -n "$mnt" ]] || { error "挂载点不能为空 / Mount point empty"; return; }
  mkdir -p "$mnt"
  mount "$dev" "$mnt" && log "挂载成功 $dev -> $mnt" || warn "挂载失败 / mount failed"

  read -rp "是否写入 /etc/fstab 实现开机自动挂载? (yes/no): " f
  if [[ "$f" == "yes" ]]; then
    uuid=$(blkid -s UUID -o value "$dev")
    [[ -n "$uuid" ]] || { error "无法获取 UUID / Cannot get UUID"; return; }
    backup_fstab="/etc/fstab.bak-$(date +%F_%T)"
    cp /etc/fstab "$backup_fstab"
    echo "UUID=$uuid   $mnt   ext4   defaults   0   2" >> /etc/fstab
    log "已追加至 /etc/fstab (备份: $backup_fstab)"
  fi
}

disk_menu() {
  while true; do
    echo -e "\n=== 磁盘管理 / Disk ==="
    echo "1) 查看磁盘状态 / Status"
    echo "2) 磁盘分区 / Partition"
    echo "3) 磁盘挂载 / Mount"
    echo "b) 返回 / Back"
    read -rp "请选择: " opt
    case "$opt" in
      1) disk_status ;;
      2) disk_partition ;;
      3) disk_mount ;;
      b|B) break ;;
      *) warn "无效选项 / Invalid option" ;;
    esac
  done
}

########## Docker 管理 / Docker Management ##########
# 保持原有逻辑 / Kept as-is for brevity

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
  url="https://raw.githubusercontent.com/norman110/N100/refs/heads/main/docker-compose.yml"
  log "下载 docker-compose.yml"
  curl -fsSL "$url" -o "$COMPOSE_DIR/docker-compose.yml"
  (cd "$COMPOSE_DIR" && docker compose up -d) && log "容器部署完成"
}

docker_one_click() {
  while true; do
    echo -e "\n--- Docker 一键运维 ---"
    echo "1) 查看容器状态 2) 单容器操作 3) 重启全部 4) 停止全部"
    echo "5) 清理无用资源 6) 清理日志 b) 返回"
    read -rp "选项: " o
    case "$o" in
      1) docker ps -a ;;
      2)
        read -rp "容器ID/名称: " cid
        read -rp "操作 (start/stop/restart): " act
        docker "$act" "$cid" && log "操作成功" || warn "操作失败"
        ;;
      3) docker restart $(docker ps -q) ;;
      4) docker stop $(docker ps -q) ;;
      5) docker system prune -a -f --volumes ;;
      6) for f in /var/lib/docker/containers/*/*.log; do :> "$f"; done && log "日志清理完成" ;;
      b|B) break ;;
      *) warn "无效选项" ;;
    esac
  done
}

docker_menu() {
  while true; do
    echo -e "\n=== Docker 管理 ==="
    echo "1) 安装 2) 部署 3) 运维 b) 返回"
    read -rp "选: " o
    case "$o" in
      1) install_docker ;;
      2) deploy_containers ;;
      3) docker_one_click ;;
      b|B) break ;;
      *) warn "无效" ;;
    esac
  done
}

########## 系统管理 / System Management ##########
system_update() {
  apt-get update && apt-get upgrade -y && log "系统更新完成 / System updated"
}

script_self_upgrade() {
  src_url="https://raw.githubusercontent.com/norman110/N100/refs/heads/main/n100-aio-init-GPT4.1.sh"
  tmp="/tmp/$(basename "$0")"
  log "下载最新脚本 / Downloading latest script..."
  curl -fsSL "$src_url" -o "$tmp"
  if [[ -s "$tmp" ]]; then
    cp "$0" "$0.bak-$(date +%F_%T)"
    mv "$tmp" "$0"
    chmod +x "$0"
    log "脚本已升级并备份旧版至 $0.bak-*" 
    log "请重新运行脚本 / Please rerun the script"
    exit 0
  else
    warn "下载失败 / Download failed"
  fi
}

system_menu() {
  while true; do
    echo -e "\n=== 系统管理 / System ==="
    echo "1) 更新升级 / Update"
    echo "2) 脚本自升级 / Self-upgrade"
    echo "b) 返回 / Back"
    read -rp "选项: " opt
    case "$opt" in
      1) system_update ;;
      2) script_self_upgrade ;;
      b|B) break ;;
      *) warn "无效选项 / Invalid option" ;;
    esac
  done
}

########## 主菜单 / Main Menu ##########
main_menu() {
  while true; do
    echo -e "\n====== N100 AIO 初始化 v0.25 ======"
    echo "1) SSH 管理 / SSH"
    echo "2) 网络管理 / Network"
    echo "3) 磁盘管理 / Disk"
    echo "4) Docker 管理 / Docker"
    echo "5) 系统管理 / System"
    echo "q) 退出 / Quit"
    read -rp "请选择: " ch
    case "$ch" in
      1) ssh_auto_enable ;;
      2) network_menu ;;
      3) disk_menu ;;
      4) docker_menu ;;
      5) system_menu ;;
      q|Q) log "退出 / Bye"; exit 0 ;;
      *) warn "无效选项 / Invalid option" ;;
    esac
  done
}

main_menu
