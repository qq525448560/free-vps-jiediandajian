#!/bin/bash
# 轻量化代理脚本（减少内存占用，适配低资源环境）

set -e

# 基础工具检查
need_cmd() { 
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "错误: 缺少依赖 $1，请安装：apk add $1" >&2
    exit 1
  fi
}

need_cmd curl
need_cmd unzip
need_cmd awk
need_cmd grep

# 配置参数（精简）
SUOHA_DIR="$HOME/.suoha"
mkdir -p "$SUOHA_DIR" || { echo "无法创建目录 $SUOHA_DIR"; exit 1; }

# 清理旧进程和文件（释放资源）
cleanup_old() {
  pkill -f "$SUOHA_DIR/xray/xray" >/dev/null 2>&1 || true
  pkill -f "$SUOHA_DIR/cloudflared" >/dev/null 2>&1 || true
  rm -rf "$SUOHA_DIR/xray" "$SUOHA_DIR/cloudflared" "$SUOHA_DIR/*.log"
}

# 搭建节点（轻量化配置）
setup_node() {
  # 选择协议和IP版本
  read -r -p "选择协议 (1.vmess 2.vless, 默认1): " protocol
  protocol=${protocol:-1}
  [ "$protocol" != "1" ] && [ "$protocol" != "2" ] && { echo "请输入1或2"; exit 1; }
  
  read -r -p "IP版本 (4/6, 默认4): " ips
  ips=${ips:-4}
  [ "$ips" != "4" ] && [ "$ips" != "6" ] && { echo "请输入4或6"; exit 1; }

  # 清理旧资源（关键：释放内存）
  cleanup_old
  
  # 下载核心程序（使用稳定版本）
  echo "正在下载核心程序（轻量化版本）..."
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64 )
      xray_url="https://github.com/XTLS/Xray-core/releases/download/v1.8.13/Xray-linux-64.zip"  # 较旧版本，内存占用更低
      cloudflared_url="https://github.com/cloudflare/cloudflared/releases/download/2024.5.1/cloudflared-linux-amd64"
      ;;
    * )
      xray_url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"  # 其他架构用最新版
      cloudflared_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
      ;;
  esac

  # 下载并解压（增加超时控制）
  curl -fsSL --connect-timeout 10 "$xray_url" -o "$SUOHA_DIR/xray.zip" || { echo "Xray下载失败"; exit 1; }
  mkdir -p "$SUOHA_DIR/xray"
  unzip -q -d "$SUOHA_DIR/xray" "$SUOHA_DIR/xray.zip" || { echo "Xray解压失败"; exit 1; }
  chmod +x "$SUOHA_DIR/xray/xray"
  rm -f "$SUOHA_DIR/xray.zip"

  curl -fsSL --connect-timeout 10 "$cloudflared_url" -o "$SUOHA_DIR/cloudflared" || { echo "Cloudflared下载失败"; exit 1; }
  chmod +x "$SUOHA_DIR/cloudflared"

  # 生成配置（简化路由，减少内存占用）
  uuid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "uuid-$(date +%s)")"
  urlpath="$(echo "$uuid" | awk -F- '{print $1}')"
  port=$((RANDOM % 10000 + 20000))

  echo "正在生成精简配置文件..."
  if [ "$protocol" = "1" ]; then
    cat > "$SUOHA_DIR/xray/config.json" <<EOF
{
  "log": { "loglevel": "error" },  # 只记录错误日志，减少IO和内存
  "inbounds": [{
    "port": $port, "listen": "127.0.0.1", "protocol": "vmess",
    "settings": { "clients": [{ "id": "$uuid", "alterId": 0 }] },
    "streamSettings": { "network": "ws", "wsSettings": { "path": "/$urlpath" } }
  }],
  "outbounds": [{ "protocol": "freedom", "settings": {} }]
}
EOF
  else
    cat > "$SUOHA_DIR/xray/config.json" <<EOF
{
  "log": { "loglevel": "error" },  # 只记录错误日志
  "inbounds": [{
    "port": $port, "listen": "127.0.0.1", "protocol": "vless",
    "settings": { "decryption": "none", "clients": [{ "id": "$uuid" }] },
    "streamSettings": { "network": "ws", "wsSettings": { "path": "/$urlpath" } }
  }],
  "outbounds": [{ "protocol": "freedom", "settings": {} }]
}
EOF
  fi

  # 启动服务（限制内存使用）
  echo "正在启动服务（低资源模式）..."
  # 使用ulimit限制内存（单位：KB，根据实际情况调整）
  ulimit -v 524288  # 限制最大使用512MB内存
  "$SUOHA_DIR/xray/xray" run -config "$SUOHA_DIR/xray/config.json" >"$SUOHA_DIR/xray.log" 2>&1 &
  "$SUOHA_DIR/cloudflared" tunnel --url "http://localhost:$port" --no-autoupdate --edge-ip-version "$ips" >"$SUOHA_DIR/cloudflared.log" 2>&1 &
  sleep 3

  # 检查Xray是否存活
  if ! pgrep -f "$SUOHA_DIR/xray/xray" >/dev/null; then
    echo "Xray启动失败！可能内存不足，日志：$SUOHA_DIR/xray.log"
    exit 1
  fi

  # 获取隧道链接
  echo "正在获取节点链接..."
  n=0
  while [ $n -lt 30 ]; do
    argo_url="$(grep -oE 'https://[a-zA-Z0-9.-]+trycloudflare\.com' "$SUOHA_DIR/cloudflared.log" 2>/dev/null | tail -n1)"
    [ -n "$argo_url" ] && break
    n=$((n+1))
    sleep 1
  done

  if [ -z "$argo_url" ]; then
    echo "获取链接失败，日志：$SUOHA_DIR/cloudflared.log"
    exit 1
  fi

  # 输出节点信息
  argo_host="${argo_url#https://}"
  if [ "$protocol" = "1" ]; then
    echo -e "\nVMess节点（轻量化）："
    echo "地址：$argo_host"
    echo "端口：443"
    echo "ID：$uuid"
    echo "传输：ws，路径：/$urlpath"
  else
    echo -e "\nVLESS节点（轻量化）："
    echo "地址：$argo_host"
    echo "端口：443"
    echo "ID：$uuid"
    echo "传输：ws，路径：/$urlpath"
  fi

  echo -e "\n节点启动成功（低资源模式）"
}

# 停止服务
stop_node() {
  pkill -f "$SUOHA_DIR/xray/xray" >/dev/null 2>&1 || true
  pkill -f "$SUOHA_DIR/cloudflared" >/dev/null 2>&1 || true
  echo "服务已停止"
}

# 查看状态
check_status() {
  pgrep -f "$SUOHA_DIR/xray/xray" >/dev/null && echo "Xray: 运行中" || echo "Xray: 已停止"
  pgrep -f "$SUOHA_DIR/cloudflared" >/dev/null && echo "Cloudflared: 运行中" || echo "Cloudflared: 已停止"
}

# 主菜单
echo "1. 搭建节点（轻量化）"
echo "2. 停止服务"
echo "3. 查看状态"
echo "0. 退出"
read -r -p "请选择(默认1): " mode
mode=${mode:-1}

case "$mode" in
  1) setup_node ;;
  2) stop_node ;;
  3) check_status ;;
  0) echo "退出"; exit 0 ;;
  *) echo "无效选择"; exit 1 ;;
esac
