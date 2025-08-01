#!/usr/bin/env bash
# N100 AIO 初始化脚本 v0.24 精简版
# 仅保留指定模块：
# - SSH管理
# - 网络管理
# - 磁盘管理
# - Docker管理（含一键运维）
# - 系统管理（更新升级）
# 其他代码全部剔除，保持简洁易用

set -euo pipefail
IFS=$'\n\t'

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

log()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()  { echo -e "${RED}[ERROR]${NC} $*"; }

# 权限检测
if [[ $EUID -ne 0 ]]; then
  error "请以 root 用户运行此脚本"
  exit 1
fi

######### SSH管理 #########

ssh_menu() {
  while true; do
    echo -e "\n=== SSH管理 ==="
    echo "1) 查看SSH状态"
    echo "2) 安装并启用SSH服务"
    echo "3) 配置SSH允许root登录"
    echo "b) 返回主菜单"
    read -rp "请选择: " opt
    case "$opt" in
      1)
        systemctl is-active ssh &>/dev/null && log "SSH服务运行中" || warn "SSH服务未运行"
        ;;
      2)
        if ! command -v sshd &>/dev/null; then
          log "安装openssh-server..."
          apt-get update
          apt-get install -y openssh-server
        else
          log "已安装SSH"
        fi
        systemctl enable ssh
        systemctl start ssh
        log "SSH服务已启用且启动"
        ;;
      3)
        local conf="/etc/ssh/sshd_config"
        if grep -q "^PermitRootLogin yes" "$conf"; then
          log "已允许root登录"
        else
          sed -i.bak 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "$conf" || echo "PermitRootLogin yes" >> "$conf"
          systemctl reload ssh
          log "已配置允许root登录，并重载SSH服务"
        fi
        ;;
      b|B) break ;;
      *) warn "无效选项" ;;
    esac
  done
}

######### 网络管理 #########

list_interfaces() {
  echo "当前接口及IP列表："
  ip -o -4 addr show | awk '{print NR": "$2 "  IP:"$4}'
}

configure_static_ip() {
  list_interfaces
  read -rp "请输入接口名（如 eth0）: " iface
  if ! ip link show "$iface" &>/dev/null; then
    error "接口不存在"
    return
  fi
  read -rp "请输入静态IP(带掩码 如 192.168.1.100/24): " ip_addr
  read -rp "请输入网关: " gw
  read -rp "请输入DNS服务器(多个空格分隔): " dns_entry

  cp /etc/network/interfaces /etc/network/interfaces.bak."$(date +%F_%T)"
  {
    echo "auto $iface"
    echo "iface $iface inet static"
    echo "  address $ip_addr"
    echo "  gateway $gw"
    echo "  dns-nameservers $dns_entry"
  } > /etc/network/interfaces

  if systemctl restart networking; then
    log "静态IP配置成功并重启网络服务"
  else
    warn "网络服务重启失败，请检查配置"
  fi
}

configure_dhcp() {
  list_interfaces
  read -rp "请输入接口名（如 eth0）: " iface
  if ! ip link show "$iface" &>/dev/null; then
    error "接口不存在"
    return
  fi

  cp /etc/network/interfaces /etc/network/interfaces.bak."$(date +%F_%T)"
  {
    echo "auto $iface"
    echo "iface $iface inet dhcp"
  } > /etc/network/interfaces

  if systemctl restart networking; then
    log "DHCP配置成功并重启网络服务"
  else
    warn "网络服务重启失败，请检查配置"
  fi
}

network_menu() {
  while true; do
    echo -e "\n=== 网络管理 ==="
    echo "1) 查看网络状态"
    echo "2) 配置网络 (DHCP/静态IP)"
    echo "b) 返回主菜单"
    read -rp "请选择: " opt
    case "$opt" in
      1)
        ip addr show
        ip route show
        ;;
      2)
        echo "1) 静态IP配置"
        echo "2) DHCP动态获取IP"
        read -rp "请选择: " c
        case "$c" in
          1) configure_static_ip ;;
          2) configure_dhcp ;;
          *) warn "无效选项" ;;
        esac
        ;;
      b|B) break ;;
      *) warn "无效选项" ;;
    esac
  done
}

######### 磁盘管理 #########

disk_menu() {
  while true; do
    echo -e "\n=== 磁盘管理 ==="
    echo "1) 查看磁盘状态"
    echo "2) 磁盘分区"
    echo "3) 磁盘挂载"
    echo "b) 返回主菜单"
    read -rp "请选择: " opt
    case "$opt" in
      1)
        lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,LABEL | column -t
        ;;
      2)
        echo "磁盘分区有风险，请确认，输入 yes 继续："
        read -r confirm
        if [[ "$confirm" != "yes" ]]; then
          echo "操作取消"
          continue
        fi
        read -rp "请输入磁盘设备名（如 /dev/sdb）: " disk_dev
        if [[ ! -b "$disk_dev" ]]; then
          warn "设备不存在"
          continue
        fi
        echo -e "${YELLOW}fdisk 使用提示：n-新建 d-删除 p-查看 w-保存退出${NC}"
        fdisk "$disk_dev"
        ;;
      3)
        read -rp "请输入设备名(如 /dev/sdb1): " dev
        if [[ -z "$dev" || ! -b "$dev" ]]; then
          warn "设备无效"
          continue
        fi
        read -rp "请输入挂载目录(如 /mnt/data1): " mnt_dir
        if [[ -z "$mnt_dir" ]]; then
          warn "目录不能为空"
          continue
        fi
        mkdir -p "$mnt_dir"
        if mount "$dev" "$mnt_dir"; then
          log "挂载成功 $dev -> $mnt_dir"
        else
          echo -e "${RED}[警告] 挂载失败，请确认设备和文件系统是否正确${NC}"
        fi
        ;;
      b|B) break ;;
      *) warn "无效选项" ;;
    esac
  done
}

######### Docker管理 #########

install_docker() {
  if command -v docker &>/dev/null && command -v docker-compose &>/dev/null; then
    log "检测到Docker和docker-compose已安装"
    return
  fi

  log "安装Docker..."
  curl -fsSL https://get.docker.com | sh
  apt-get install -y docker-compose-plugin
  systemctl enable docker
  systemctl start docker
  log "Docker安装完成"
}

deploy_containers() {
  # 简易实现，下载默认docker-compose.yml并启动
  COMPOSE_DIR="/mnt/data/docker/compose"
  mkdir -p "$COMPOSE_DIR"
  local url="https://raw.githubusercontent.com/norman110/N100/refs/heads/main/docker-compose.yml"
  log "下载docker-compose.yml文件"
  curl -fsSL "$url" -o "$COMPOSE_DIR/docker-compose.yml"
  (cd "$COMPOSE_DIR" && docker compose up -d) && log "容器部署完成" || warn "容器部署失败"
}

docker_one_click() {
  while true; do
    echo -e "\n=== Docker一键运维 ==="
    echo "1) 查看所有容器状态"
    echo "2) 对单个容器进行操作"
    echo "3) 重启所有运行中的容器"
    echo "4) 停止所有运行中的容器"
    echo "5) 清理无用镜像和容器"
    echo "6) 清理容器日志"
    echo "b) 返回上级菜单"
    read -rp "请选择: " opt
    case "$opt" in
      1) docker ps -a || warn "无法获取容器列表" ;;
      2)
        read -rp "请输入容器ID或名称: " cid
        echo "可用操作：start(启动)，stop(停止)，restart(重启)"
        read -rp "请输入操作: " action
        if [[ "$action" =~ ^(start|stop|restart)$ ]]; then
          docker "$action" "$cid" && log "操作成功" || warn "操作失败"
        else
          warn "无效操作"
        fi
        ;;
      3) docker restart $(docker ps -q) && log "重启所有运行中容器成功" || warn "操作失败" ;;
      4) docker stop $(docker ps -q) && log "停止所有运行中容器成功" || warn "操作失败" ;;
      5) docker system prune -a -f --volumes && log "清理无用资源完成" || warn "清理失败" ;;
      6)
        for logfile in /var/lib/docker/containers/*/*.log; do
          : > "$logfile" || warn "日志清理失败: $logfile"
        done
        log "容器日志清理完成"
        ;;
      b|B) break ;;
      *) warn "无效选项" ;;
    esac
  done
}

docker_menu() {
  while true; do
    echo -e "\n=== Docker管理 ==="
    echo "1) 安装docker & docker-compose"
    echo "2) 部署容器"
    echo "3) Docker一键运维"
    echo "b) 返回主菜单"
    read -rp "请选择: " opt
    case "$opt" in
      1) install_docker ;;
      2) deploy_containers ;;
      3) docker_one_click ;;
      b|B) break ;;
      *) warn "无效选项" ;;
    esac
  done
}

######### 系统管理 #########

system_menu() {
  while true; do
    echo -e "\n=== 系统管理 ==="
    echo "1) 系统更新与升级"
    echo "b) 返回主菜单"
    read -rp "请选择: " opt
    case "$opt" in
      1)
        apt-get update && apt-get upgrade -y && log "系统更新升级完成" || warn "系统升级失败"
        ;;
      b|B) break ;;
      *) warn "无效选项" ;;
    esac
  done
}

######### 主菜单 #########

main_menu() {
  while true; do
    echo -e "\n====== N100 AIO 初始化 v0.24 ======"
    echo "1) SSH管理"
    echo "2) 网络管理"
    echo "3) 磁盘管理"
    echo "4) Docker管理"
    echo "5) 系统管理"
    echo "q) 退出脚本"
    read -rp "请选择: " ch
    case "$ch" in
      1) ssh_menu ;;
      2) network_menu ;;
      3) disk_menu ;;
      4) docker_menu ;;
      5) system_menu ;;
      q|Q)
        log "退出脚本，再见！"
        exit 0
        ;;
      *) warn "无效选项" ;;
    esac
  done
}

main_menu
