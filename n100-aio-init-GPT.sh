#!/usr/bin/env bash
# N100 AIO 初始化脚本 v0.26 / Enhanced UI & fixes
set -euo pipefail
IFS=$'\n\t'

# 颜色定义 / Color definitions
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()   { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

draw_line() { printf "%0.s─" {1..60}; echo; }
# 检查 root
if [[ $EUID -ne 0 ]]; then error "请以 root 用户运行 / Run as root"; exit 1; fi

# 显示系统信息 / Show system info
show_sysinfo() {
  draw_line
  echo -e "${BLUE}系统信息 / System Info:${NC}"
  echo -e " 主机名   : $(hostname)"
  echo -e " OS       : $(grep -oP '(?<=PRETTY_NAME=").*(?=")' /etc/os-release)"
  echo -e " 内存     : $(free -h | awk '/^Mem:/ {print $2 " total, " $3 " used, " $4 " free"}')"
  echo -e " CPU      : $(nproc) 核心 / cores ($(lscpu | grep 'Model name' | cut -d: -f2 | xargs))"
  echo -e " 磁盘使用 : $(df -h / | awk 'NR==2{print $2 " total, " $3 " used, " $4 " avail"}')"
  draw_line
}

########## SSH 管理 ##########
ssh_auto_enable() {
  log "检测 SSH 服务... / Checking SSH..."
  if ! systemctl is-active ssh >/dev/null 2>&1; then
    log "安装 openssh-server 并启动 / Installing and starting SSH..."
    apt-get update && apt-get install -y openssh-server
    systemctl enable ssh && systemctl start ssh
  else log "SSH 正在运行 / SSH already running"; fi
  conf=/etc/ssh/sshd_config
  if grep -Eq '^\s*PermitRootLogin\s+yes' "$conf"; then
    log "Root 登录已启用 / Root login permitted";
  else
    log "配置 PermitRootLogin yes / Enabling root login"
    cp "$conf" "${conf}.bak-$(date +%F_%T)"
    sed -i 's@^#\?PermitRootLogin .*@PermitRootLogin yes@' "$conf"
    systemctl reload ssh
  fi
  log "SSH 管理完成 / SSH setup done"
}

########## 网络管理 ##########
get_interfaces() { mapfile -t IFS_LIST < <(ip -o -4 addr show | awk '{print $2}'); }
list_interfaces() {
  get_interfaces
  echo -e "${BLUE}可用网络接口 / Available Interfaces:${NC}"
  for i in "${!IFS_LIST[@]}"; do
    ipinfo=$(ip -o -4 addr show ${IFS_LIST[i]} | awk '{print $4}');
    printf "  %d) %-8s IP:%s\n" "$((i+1))" "${IFS_LIST[i]}" "${ipinfo:-无}";
  done
  draw_line
}
configure_static_ip() {
  list_interfaces
  read -rp "选择编号: " idx
  [[ $idx =~ ^[0-9]+$ ]] || { error "无效编号"; return; }
  iface=${IFS_LIST[idx-1]}
  read -rp "静态IP (带掩码 如192.168.1.100/24): " ip_addr
  read -rp "网关 (如192.168.1.1): " gw
  read -rp "DNS 服务器(空格分隔): " dns
  cp /etc/network/interfaces /etc/network/interfaces.bak-$(date +%F_%T)
  cat >/etc/network/interfaces <<EOF
auto $iface
iface $iface inet static
    address $ip_addr
    gateway $gw
    dns-nameservers $dns
EOF
  systemctl restart networking && log "静态IP设置完成" || warn "网络重启失败"
}
configure_dhcp() {
  list_interfaces
  read -rp "选择编号: " idx
  [[ $idx =~ ^[0-9]+$ ]] || { error "无效编号"; return; }
  iface=${IFS_LIST[idx-1]}
  cp /etc/network/interfaces /etc/network/interfaces.bak-$(date +%F_%T)
  cat >/etc/network/interfaces <<EOF
auto $iface
iface $iface inet dhcp
EOF
  systemctl restart networking && log "DHCP设置完成" || warn "网络重启失败"
}
network_menu() {
  while :; do
    echo -e "\n${BLUE}网络管理 / Network Menu${NC}"
    echo "1) 查看状态  2) 静态IP  3) DHCP  b) 返回"
    read -rp "请选择: " o
    case $o in
      1) ip addr; ip route ;; 2) configure_static_ip ;; 3) configure_dhcp ;; [bB]) break ;; *) warn "无效选项";;
    esac
    draw_line
  done
}

########## 磁盘管理 ##########
disk_status() {
  echo -e "${BLUE}磁盘状态 / Disk Status:${NC}"
  lsblk -dn -o NAME,SIZE | while read name size; do
    dev=/dev/$name
    if lsblk -n $dev -o NAME | grep -qE "${name}[0-9]"; then
      echo "  $name  $size  已分区"
    else
      echo "  $name  $size  未分区"
    fi
  done
  draw_line
}
disk_partition() {
  echo -e "${YELLOW}注意: 分区操作会清除数据！请输入 yes 继续:${NC}"
  read -r c; [[ $c == yes ]] || { log "取消分区"; return; }
  read -rp "磁盘设备 (如/dev/sdb): " disk
  [[ -b $disk ]] || { error "设备不存在"; return; }
  cat <<EOF
分区步骤:
1) n  2) p  3) 1  4) 回车  5) 回车  6) w
EOF
  fdisk $disk
  log "分区完成: 请记住分区名称，如 ${disk}1"
}
disk_mount() {
  read -rp "分区设备 (如/dev/sdb1): " part
  [[ -b $part ]] || { error "设备无效"; return; }
  read -rp "挂载点 (如/mnt/usbdata): " mnt
  mkdir -p $mnt
  mount $part $mnt && log "挂载成功 $part 至 $mnt"
  read -rp "写入 fstab? yes/no: " f
  if [[ $f == yes ]]; then
    uuid=$(blkid -s UUID -o value $part)
    cp /etc/fstab /etc/fstab.bak-$(date +%F_%T)
    echo "UUID=$uuid  $mnt  ext4  defaults 0 2" >>/etc/fstab
    log "/etc/fstab 已追加"
  fi
  draw_line
}
disk_menu() {
  while :; do
    echo -e "\n${BLUE}磁盘管理 / Disk Menu${NC}"
    echo "1) 状态  2) 分区  3) 挂载  b) 返回"
    read -rp "请选择: " o
    case $o in
      1) disk_status ;; 2) disk_partition ;; 3) disk_mount ;; [bB]) break ;; *) warn "无效";;
    esac
    draw_line
  done
}

########## Docker 管理 ##########
install_docker() {
  if command -v docker &>/dev/null; then log "Docker 已安装"; return; fi
  log "安装 Docker..."
  curl -fsSL https://get.docker.com | sh
  apt-get install -y docker-compose-plugin
  systemctl enable docker && systemctl.start docker
}
deploy_containers() {
  read -rp "使用默认 URL 下载 docker-compose.yml? yes/no: " m
  if [[ $m == yes ]]; then
    url="https://raw.githubusercontent.com/norman110/N100/refs/heads/main/docker-compose.yml"
  else
    read -rp "请输入 yml 文件 URL: " url
  fi
  dir="/mnt/data/docker/compose"
  mkdir -p $dir
  curl -fsSL $url -o $dir/docker-compose.yml
  (cd $dir && docker compose up -d)
  log "容器已部署"
  draw_line
}
docker_one_click() {
  PS3="请选择操作: "
  select act in "查看状态" "单容器操作" "重启全部" "停止全部" "清理资源" "清理日志" 返回; do
    case $REPLY in
      1) docker ps -a ;; 2)
         read -rp "容器ID/名称: " id; read -rp "动作(start/stop/restart): " a; docker $a $id;;
      3) docker restart $(docker ps -q) ;; 4) docker stop $(docker ps -q) ;;
      5) docker system prune -a -f --volumes;;
      6) for f in /var/lib/docker/containers/*/*.log; do :> $f; done; log "日志清理完成";;
      7) break;; *) warn "无效";;
    esac
    draw_line
  done
}
docker_menu() {
  while :; do
    echo -e "\n${BLUE}Docker 管理 / Docker Menu${NC}"
    echo "1) 安装"
    echo "2) 部署"
    echo "3) 运维"
    echo "b) 返回"
    read -rp "请选择: " o
    case $o in
      1) install_docker ;; 2) deploy_containers ;; 3) docker_one_click ;; [bB]) break;; *) warn "无效";;
    esac
    draw_line
  done
}

########## 系统管理 ##########
system_update() { apt-get update && apt-get upgrade -y && log "系统已更新"; draw_line; }
script_self_upgrade() {
  tmp=/tmp/$(basename $0)
  url="https://raw.githubusercontent.com/norman110/N100/refs/heads/main/n100-aio-init-GPT4.1.sh"
  curl -fsSL $url -o $tmp
  [[ -s $tmp ]] && { cp $0 $0.bak-$(date +%F_%T); mv $tmp $0; chmod +x $0; log "脚本升级完成，请重新运行"; exit 0; } || warn "升级失败"; draw_line;
}
system_menu() {
  while :; do
    echo -e "\n${BLUE}系统管理 / System Menu${NC}"
    echo "1) 更新升级"
    echo "2) 脚本自升级"
    echo "b) 返回"
    read -rp "请选择: " o
    case $o in
      1) system_update ;; 2) script_self_upgrade ;; [bB]) break;; *) warn "无效";;
    esac
    draw_line
  done
}

########## 主菜单 ##########
main_menu() {
  show_sysinfo
  while :; do
    echo -e "\n${BLUE}====== N100 AIO 初始化 v0.26 ======${NC}"
    echo "1) SSH 管理"
    echo "2) 网络管理"
    echo "3) 磁盘管理"
    echo "4) Docker 管理"
    echo "5) 系统管理"
    echo "q) 退出"
    read -rp "请选择: " c
    case $c in
      1) ssh_auto_enable ;; 2) network_menu ;; 3) disk_menu ;; 4) docker_menu ;; 5) system_menu ;; [qQ]) log "退出"; exit 0;; *) warn "无效";;
    esac
    draw_line
  done
}

main_menu
