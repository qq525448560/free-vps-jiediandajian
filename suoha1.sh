#!/bin/bash
# 无root权限版代理脚本 (已集成保活功能)

set -e

# 设置脚本所在目录为工作目录
SUOHADIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SUOHADIR

# 基础工具函数
b64enc() {
 if base64 --help 2>/dev/null | grep -q '-w'; then
  printf '%s' "$1" | base64 -w 0
 else
  printf '%s' "$1" | base64
 fi
}

# 下载工具函数
download() {
 local url="$1"
 local output="$2"
 
 if command -v wget >/dev/null 2>&1; then
  wget -q -O "$output" "$url"
 elif command -v curl >/dev/null 2>&1; then
  curl -s -L -o "$output" "$url"
 else
  echo "错误：需要 wget 或 curl"
  exit 1
 fi
}

# 检查必要文件是否存在
check_files() {
 local missing=()
 
 [ ! -f "$SUOHADIR/xray/xray" ] && missing+=("xray")
 [ ! -f "$SUOHADIR/cloudflared/cloudflared" ] && missing+=("cloudflared")
 
 if [ ${#missing[@]} -gt 0 ]; then
  echo "错误：缺少必要文件: ${missing[*]}"
  echo "请先运行选项1搭建节点"
  exit 1
 fi
}

# 启动服务
start_service() {
 echo "正在启动服务..."
 
 # 启动Xray
 nohup "$SUOHADIR/xray/xray" -c "$SUOHADIR/xray/config.json" > "$SUOHADIR/logs/xray.log" 2>&1 &
 XRAY_PID=$!
 echo $XRAY_PID > "$SUOHADIR/xray.pid"
 
 # 启动Cloudflared
 nohup "$SUOHADIR/cloudflared/cloudflared" tunnel --url http://127.0.0.1:8080 > "$SUOHADIR/logs/cloudflared.log" 2>&1 &
 CLOUDFLARED_PID=$!
 echo $CLOUDFLARED_PID > "$SUOHADIR/cloudflared.pid"
 
 # 等待服务启动
 sleep 5
 
 # 检查服务状态
 if kill -0 $XRAY_PID 2>/dev/null && kill -0 $CLOUDFLARED_PID 2>/dev/null; then
  echo "服务启动成功！"
  show_links
 else
  echo "服务启动失败！"
  stop_service
  exit 1
 fi
}

# 停止服务
stop_service() {
 echo "正在停止服务..."
 
 # 停止Xray
 if [ -f "$SUOHADIR/xray.pid" ]; then
  XRAY_PID=$(cat "$SUOHADIR/xray.pid")
  kill $XRAY_PID 2>/dev/null
  rm -f "$SUOHADIR/xray.pid"
 fi
 
 # 停止Cloudflared
 if [ -f "$SUOHADIR/cloudflared.pid" ]; then
  CLOUDFLARED_PID=$(cat "$SUOHADIR/cloudflared.pid")
  kill $CLOUDFLARED_PID 2>/dev/null
  rm -f "$SUOHADIR/cloudflared.pid"
 fi
 
 # 停止保活服务
 if [ -f "$SUOHADIR/keepalive.pid" ]; then
  KEEPALIVE_PID=$(cat "$SUOHADIR/keepalive.pid")
  kill $KEEPALIVE_PID 2>/dev/null
  rm -f "$SUOHADIR/keepalive.pid"
 fi
 
 echo "服务已停止"
}

# 查看状态
show_status() {
 echo "当前状态:"
 
 # 检查Xray状态
 if [ -f "$SUOHADIR/xray.pid" ] && kill -0 $(cat "$SUOHADIR/xray.pid") 2>/dev/null; then
  echo "Xray: 运行中 (PID: $(cat "$SUOHADIR/xray.pid"))"
 else
  echo "Xray: 已停止"
 fi
 
 # 检查Cloudflared状态
 if [ -f "$SUOHADIR/cloudflared.pid" ] && kill -0 $(cat "$SUOHADIR/cloudflared.pid") 2>/dev/null; then
  echo "Cloudflared: 运行中 (PID: $(cat "$SUOHADIR/cloudflared.pid"))"
 else
  echo "Cloudflared: 已停止"
 fi
 
 # 检查保活服务状态
 if [ -f "$SUOHADIR/keepalive.pid" ] && kill -0 $(cat "$SUOHADIR/keepalive.pid") 2>/dev/null; then
  echo "保活守护: 运行中 (PID: $(cat "$SUOHADIR/keepalive.pid"))"
 else
  echo "保活守护: 已停止"
 fi
}

# 显示链接
show_links() {
 echo ""
 echo "当前链接:"
 
 # 获取Cloudflared地址
 CLOUDFLARED_URL=$(grep -o "https://[a-zA-Z0-9.-]*\.trycloudflare\.com" "$SUOHADIR/logs/cloudflared.log" | head -1)
 
 if [ -n "$CLOUDFLARED_URL" ]; then
  # 生成VLESS链接
  UUID=$(cat /proc/sys/kernel/random/uuid)
  VLESS_LINK="vless://$UUID@${CLOUDFLARED_URL#https://}:443?encryption=none&security=none&type=ws&host=${CLOUDFLARED_URL#https://}&path=/$(b64enc "91c20f76")#X-荷兰"
  
  echo "VLESS链接（含YouTube和ChatGPT分流）:"
  echo "$VLESS_LINK"
  echo ""
  echo "非TLS端口: 2052/2082/2086/2095/8080/8880"
 else
  echo "警告：无法获取Cloudflared地址"
 fi
}

# 清理文件
clean_files() {
 echo "正在清理文件..."
 
 # 停止服务
 stop_service
 
 # 删除文件
 rm -rf "$SUOHADIR/xray"
 rm -rf "$SUOHADIR/cloudflared"
 rm -rf "$SUOHADIR/logs"
 rm -f "$SUOHADIR/xray.pid"
 rm -f "$SUOHADIR/cloudflared.pid"
 rm -f "$SUOHADIR/keepalive.pid"
 rm -f "$SUOHADIR/proxykeepalive.log"
 
 echo "文件已清理"
}

# 保活功能
keepalive_service() {
 if [ -f "$SUOHADIR/keepalive.pid" ] && kill -0 $(cat "$SUOHADIR/keepalive.pid") 2>/dev/null; then
  echo "正在停止保活功能..."
  kill $(cat "$SUOHADIR/keepalive.pid")
  rm -f "$SUOHADIR/keepalive.pid"
  echo "保活功能已停止"
 else
  echo "正在启动保活功能..."
  
  # 检查必要文件
  check_files
  
  # 启动保活守护进程
  nohup bash -c "
   while true; do
    # 检查Xray状态
    if [ ! -f \"$SUOHADIR/xray.pid\" ] || ! kill -0 \$(cat \"$SUOHADIR/xray.pid\") 2>/dev/null; then
     echo \"\$(date): Xray已停止，正在重启...\" >> \"$SUOHADIR/proxykeepalive.log\"
     nohup \"$SUOHADIR/xray/xray\" -c \"$SUOHADIR/xray/config.json\" > \"$SUOHADIR/logs/xray.log\" 2>&1 &
     echo \$! > \"$SUOHADIR/xray.pid\"
    fi
    
    # 检查Cloudflared状态
    if [ ! -f \"$SUOHADIR/cloudflared.pid\" ] || ! kill -0 \$(cat \"$SUOHADIR/cloudflared.pid\") 2>/dev/null; then
     echo \"\$(date): Cloudflared已停止，正在重启...\" >> \"$SUOHADIR/proxykeepalive.log\"
     nohup \"$SUOHADIR/cloudflared/cloudflared\" tunnel --url http://127.0.0.1:8080 > \"$SUOHADIR/logs/cloudflared.log\" 2>&1 &
     echo \$! > \"$SUOHADIR/cloudflared.pid\"
    fi
    
    sleep 10
   done
  " > "$SUOHADIR/proxykeepalive.log" 2>&1 &
  
  echo $! > "$SUOHADIR/keepalive.pid"
  echo "保活功能已启动"
 fi
}

# 主菜单
mainmenu() {
 while true; do
  echo ""
  echo "1. 启动服务（含YouTube和ChatGPT分流）"
  echo "2. 停止服务"
  echo "3. 查看状态"
  echo "4. 清理文件"
  echo "5. 切换保活功能（启动/关闭）"
  echo "0. 退出"
  read -p "请选择(默认1): " choice
  choice=${choice:-1}
  
  case $choice in
   1)
    # 检查必要文件
    if [ ! -f "$SUOHADIR/xray/xray" ] || [ ! -f "$SUOHADIR/cloudflared/cloudflared" ]; then
     echo "正在下载必要文件..."
     
     # 创建目录
     mkdir -p "$SUOHADIR/xray"
     mkdir -p "$SUOHADIR/cloudflared"
     mkdir -p "$SUOHADIR/logs"
     
     # 下载Xray
     echo "下载Xray..."
     download "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip" "$SUOHADIR/xray.zip"
     unzip -qo "$SUOHADIR/xray.zip" -d "$SUOHADIR/xray"
     chmod +x "$SUOHADIR/xray/xray"
     rm -f "$SUOHADIR/xray.zip"
     
     # 下载Cloudflared
     echo "下载Cloudflared..."
     download "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb" "$SUOHADIR/cloudflared.deb"
     dpkg -x "$SUOHADIR/cloudflared.deb" "$SUOHADIR/cloudflared"
     mv "$SUOHADIR/cloudflared/usr/local/bin/cloudflared" "$SUOHADIR/cloudflared/"
     chmod +x "$SUOHADIR/cloudflared/cloudflared"
     rm -f "$SUOHADIR/cloudflared.deb"
     rm -rf "$SUOHADIR/cloudflared/usr"
     
     # 生成Xray配置
     cat > "$SUOHADIR/xray/config.json" << EOF
{
  "inbounds": [
    {
      "port": 8080,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$(cat /proc/sys/kernel/random/uuid)"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/$(b64enc "91c20f76")"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "blocked"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "outboundTag": "blocked",
        "domain": [
          "geosite:category-ads-all"
        ]
      },
      {
        "type": "field",
        "outboundTag": "blocked",
        "ip": [
          "geoip:private"
        ]
      }
    ]
  }
}
EOF
    fi
    
    # 启动服务
    start_service
    ;;
   2)
    stop_service
    ;;
   3)
    show_status
    ;;
   4)
    clean_files
    ;;
   5)
    keepalive_service
    ;;
   0)
    exit 0
    ;;
   *)
    echo "无效选择"
    ;;
  esac
  
  read -p "按回车键继续..."
 done
}

# 初始化工作目录
mkdir -p "$SUOHADIR/xray"
mkdir -p "$SUOHADIR/cloudflared"
mkdir -p "$SUOHADIR/logs"
touch "$SUOHADIR/proxykeepalive.log"

# 启动主菜单
mainmenu
