#!/bin/bash
set -e
BASE_DIR="/mnt/usbdata"
IP=$(hostname -I | awk '{print $1}')

echo "=== All-in-One 初始化脚本 v4.1 ==="

## 1. 目录
mkdir -p $BASE_DIR/{docker,media}
mkdir -p $BASE_DIR/media/{movies,tvshows,av,downloads}
mkdir -p $BASE_DIR/docker/compose

## 2. 安装 Docker（若未安装）
if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sh
    apt install -y docker-compose-plugin
    usermod -aG docker $USER
    echo "[提示] Docker 安装完成，请重新登录 SSH 后重跑脚本"
    exit 0
fi

## 3. 创建独立下载网络
if ! docker network ls | grep -q download_net; then
    docker network create download_net
fi

## 4. 生成 docker-compose.yml
COMPOSE_FILE="$BASE_DIR/docker/compose/docker-compose.yml"
cat > $COMPOSE_FILE << EOF
version: "3.8"

services:
  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    networks:
      - download_net
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Asia/Shanghai
      - WEBUI_PORT=8080
    volumes:
      - $BASE_DIR/docker/qbittorrent/config:/config
      - $BASE_DIR/media/downloads:/downloads
    ports:
      - 8080:8080
      - 6881:6881
      - 6881:6881/udp
    restart: unless-stopped

  xunlei:
    image: cnk3x/xunlei
    container_name: xunlei
    networks:
      - download_net
    ports:
      - 2345:2345
    volumes:
      - $BASE_DIR/docker/xunlei:/xunlei
      - $BASE_DIR/media/downloads:/downloads
    restart: unless-stopped

  emby:
    image: lscr.io/linuxserver/emby:latest
    container_name: emby
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Asia/Shanghai
    volumes:
      - $BASE_DIR/docker/emby/config:/config
      - $BASE_DIR/media:/mnt/media
    ports:
      - 8096:8096
    restart: unless-stopped

  dashy:
    image: lissy93/dashy:latest
    container_name: dashy
    ports:
      - 8081:80
    volumes:
      - $BASE_DIR/docker/dashy/config:/app/public
    restart: unless-stopped

  filebrowser:
    image: filebrowser/filebrowser:latest
    container_name: filebrowser
    ports:
      - 8082:80
    volumes:
      - $BASE_DIR:/srv
      - $BASE_DIR/docker/filebrowser/config:/config
    restart: unless-stopped

  nginxproxymanager:
    image: jc21/nginx-proxy-manager:latest
    container_name: nginxproxymanager
    ports:
      - 80:80
      - 81:81
      - 443:443
    volumes:
      - $BASE_DIR/docker/proxy/data:/data
      - $BASE_DIR/docker/proxy/letsencrypt:/etc/letsencrypt
    restart: unless-stopped

  bitwarden:
    image: vaultwarden/server:latest
    container_name: bitwarden
    ports:
      - 8083:80
    volumes:
      - $BASE_DIR/docker/bitwarden/data:/data
    restart: unless-stopped

  glances:
    image: nicolargo/glances:latest
    container_name: glances
    pid: host
    network_mode: host
    environment:
      - GLANCES_OPT=-w
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    restart: unless-stopped

networks:
  download_net:
    external: true
EOF

## 5. 写 Dashy 配置
DASHY_CONF="$BASE_DIR/docker/dashy/config/conf.yml"
mkdir -p "$(dirname $DASHY_CONF)"
cat > $DASHY_CONF << EOF
appConfig:
  theme: nord
  language: zh

pageInfo:
  title: 我的 AIO 控制面板
  description: 服务导航

sections:
  - name: 下载工具
    items:
      - title: qBittorrent
        url: http://$IP:8080
        icon: fas fa-cloud-download-alt
      - title: 迅雷
        url: http://$IP:2345
        icon: fas fa-bolt
  - name: 媒体服务
    items:
      - title: Emby
        url: http://$IP:8096
        icon: fas fa-film
      - title: TinyMediaManager
        url: http://$IP:5800
        icon: fas fa-tags
  - name: 管理面板
    items:
      - title: Dashy
        url: http://$IP:8081
        icon: fas fa-th
      - title: Filebrowser
        url: http://$IP:8082
        icon: fas fa-folder-open
      - title: Nginx Proxy Manager
        url: http://$IP:81
        icon: fas fa-random
      - title: Bitwarden
        url: http://$IP:8083
        icon: fas fa-key
  - name: 系统监控
    items:
      - title: Glances
        url: http://$IP:61208
        icon: fas fa-chart-line
EOF

## 6. 启动所有容器
cd $BASE_DIR/docker/compose
docker compose up -d

## 7. qBittorrent 移动宽带优化
echo "[调优] 配置 qBittorrent 适合移动宽带..."
QBIT_CONF="$BASE_DIR/docker/qbittorrent/config/qBittorrent.conf"
mkdir -p "$(dirname $QBIT_CONF)"
cat > $QBIT_CONF << EOF
[Preferences]
Connection\GlobalUPLimit=150        # 上传限速 150 KB/s
Connection\GlobalDLLimit=-1
Connection\MaxConnections=200
Connection\MaxConnectionsPerTorrent=60
Connection\MaxUploads=8
Connection\MaxUploadsPerTorrent=4
Downloads\SavePath=/downloads
Downloads\PreAllocation=true
Downloads\DiskWriteCacheSize=256
Queueing\MaxActiveDownloads=5
Queueing\MaxActiveTorrents=8
Queueing\MaxActiveUploads=5
Bittorrent\DHT=true
Bittorrent\PeX=true
Bittorrent\LSD=true
Bittorrent\uTP=true
Bittorrent\AnnounceToAllTrackers=true
WebUI\Port=8080
WebUI\Password_PBKDF2="@ByteArray(sha256加密后的默认密码)"
EOF

## 8. PT/BT 切换脚本
PT_SCRIPT="$BASE_DIR/docker/qbittorrent/config/switch-pt.sh"
cat > $PT_SCRIPT << 'EOF'
#!/bin/bash
CONF="/config/qBittorrent.conf"
if grep -q "Bittorrent\\\DHT=true" $CONF; then
  echo "[切换] 启用 PT 模式（禁用 DHT/PEX/uTP）"
  sed -i 's/Bittorrent\\\DHT=true/Bittorrent\\\DHT=false/' $CONF
  sed -i 's/Bittorrent\\\PeX=true/Bittorrent\\\PeX=false/' $CONF
  sed -i 's/Bittorrent\\\uTP=true/Bittorrent\\\uTP=false/' $CONF
else
  echo "[切换] 启用 BT 模式（恢复 DHT/PEX/uTP）"
  sed -i 's/Bittorrent\\\DHT=false/Bittorrent\\\DHT=true/' $CONF
  sed -i 's/Bittorrent\\\PeX=false/Bittorrent\\\PeX=true/' $CONF
  sed -i 's/Bittorrent\\\uTP=false/Bittorrent\\\uTP=true/' $CONF
fi
echo "[完成] 重启容器生效：docker restart qbittorrent"
EOF
chmod +x "$PT_SCRIPT"

echo "=== 部署完成！访问 Dashy http://$IP:8081，Emby http://$IP:8096 ==="
echo "切换 PT/BT 模式：docker exec -it qbittorrent bash /config/switch-pt.sh"
