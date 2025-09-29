#!/bin/bash
# 无root权限版代理脚本 (已集成保活功能 - 优化版)

set +e

# --- 基础工具函数 ---
b64enc() {
  if base64 --help 2>/dev/null | grep -q '\-w'; then
    printf '%s' "$1" | base64 -w 0
  else
    printf '%s' "$1" | base64 | tr -d '\n'
  fi
}

need_cmd() { 
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "错误: 需要 $1 命令，请联系管理员安装" >&2
    exit 1
  fi
}

die() { echo "ERROR: $*" >&2; exit 1; }

detect_os() {
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-}"
  else
    OS_ID=""
  fi

  case "$OS_ID" in
    alpine)
      IS_ALPINE=1
      ;;
    *)
      IS_ALPINE=0
      ;;
  esac
}

kill_proc_safe() {
  local pat="$1" is_alpine="$2"
  if [ "$is_alpine" = "1" ]; then
    kill -9 $(ps | grep -F "$pat" | grep -v grep | awk '{print $1}') >/dev/null 2>&1 || true
  else
    kill -9 $(ps -ef | grep -F "$pat" | grep -v grep | awk '{print $2}') >/dev/null 2>&1 || true
  fi
}

# --- 分流配置 ---
PROXY_OUT_IP="172.233.171.224"
PROXY_OUT_PORT=16416
PROXY_OUT_ID="8c1b9bea-cb51-43bb-a65c-0af31bbbf145"

# --- 用户目录 ---
SUOHA_DIR="$HOME/.suoha"
mkdir -p "$SUOHA_DIR" || die "无法创建目录 $SUOHA_DIR（请检查权限）"

# --- 初始化 ---
detect_os
need_cmd curl
need_cmd unzip
need_cmd awk
need_cmd grep
need_cmd tr
need_cmd ps
need_cmd kill
need_cmd nohup  # 保活功能需要

# --- 核心功能函数 ---

# 启动服务 (内部函数)
_start_service_inner() {
  local protocol="$1"
  local ips="$2"

  rm -rf "$SUOHA_DIR/xray" "$SUOHA_DIR/cloudflared" "$SUOHA_DIR/xray.zip" "$SUOHA_DIR/argo.log"

  arch="$(uname -m)"
  case "$arch" in
    x86_64|x64|amd64 )
      curl -fsSL https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o "$SUOHA_DIR/xray.zip" || die "下载Xray失败"
      curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o "$SUOHA_DIR/cloudflared" || die "下载cloudflared失败"
      ;;
    i386|i686 )
      curl -fsSL https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-32.zip -o "$SUOHA_DIR/xray.zip" || die "下载Xray失败"
      curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386 -o "$SUOHA_DIR/cloudflared" || die "下载cloudflared失败"
      ;;
    armv8|arm64|aarch64 )
      curl -fsSL https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip -o "$SUOHA_DIR/xray.zip" || die "下载Xray失败"
      curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 -o "$SUOHA_DIR/cloudflared" || die "下载cloudflared失败"
      ;;
    armv7l )
      curl -fsSL https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm32-v7a.zip -o "$SUOHA_DIR/xray.zip" || die "下载Xray失败"
      curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm -o "$SUOHA_DIR/cloudflared" || die "下载cloudflared失败"
      ;;
    * )
      echo "不支持的架构: $(uname -m)"; exit 1;;
  esac

  mkdir -p "$SUOHA_DIR/xray"
  unzip -q -d "$SUOHA_DIR/xray" "$SUOHA_DIR/xray.zip" || die "解压Xray失败"
  chmod +x "$SUOHA_DIR/cloudflared" "$SUOHA_DIR/xray/xray"
  rm -f "$SUOHA_DIR/xray.zip"

  uuid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "uuid-$(date +%s)")"
  urlpath="$(echo "$uuid" | awk -F- '{print $1}')"
  port=$((RANDOM % 10000 + 20000))

  if [ "$protocol" = "1" ]; then
cat > "$SUOHA_DIR/xray/config.json" <<EOF
{
  "inbounds": [{
    "port": $port, "listen": "localhost", "protocol": "vmess",
    "settings": { "clients": [{ "id": "$uuid", "alterId": 0 }] },
    "streamSettings": { "network": "ws", "wsSettings": { "path": "$urlpath" } }
  }],
  "outbounds": [
    { "protocol": "freedom", "settings": {}, "tag": "direct" },
    { "protocol": "vmess", "tag": "proxy",
      "settings": { "vnext": [{ "address": "$PROXY_OUT_IP", "port": $PROXY_OUT_PORT,
        "users": [{ "id": "$PROXY_OUT_ID", "alterId": 0 }] }] } },
    { "protocol": "blackhole", "tag": "block", "settings": {} }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "domain": ["youtube.com","googlevideo.com","ytimg.com","gstatic.com","googleapis.com","ggpht.com","googleusercontent.com"], "outboundTag": "proxy" },
      { "type": "field", "domain": ["openai.com","chat.openai.com","api.openai.com","auth0.openai.com","cdn.openai.com","oaiusercontent.com"], "outboundTag": "proxy" }
    ]
  }
}
EOF
  elif [ "$protocol" = "2" ]; then
cat > "$SUOHA_DIR/xray/config.json" <<EOF
{
  "inbounds": [{
    "port": $port, "listen": "localhost", "protocol": "vless",
    "settings": { "decryption": "none", "clients": [{ "id": "$uuid" }] },
    "streamSettings": { "network": "ws", "wsSettings": { "path": "$urlpath" } }
  }],
  "outbounds": [
    { "protocol": "freedom", "settings": {}, "tag": "direct" },
    { "protocol": "vmess", "tag": "proxy",
      "settings": { "vnext": [{ "address": "$PROXY_OUT_IP", "port": $PROXY_OUT_PORT,
        "users": [{ "id": "$PROXY_OUT_ID", "alterId": 0 }] }] } },
    { "protocol": "blackhole", "tag": "block", "settings": {} }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "domain": ["youtube.com","googlevideo.com","ytimg.com","gstatic.com","googleapis.com","ggpht.com","googleusercontent.com"], "outboundTag": "proxy" },
      { "type": "field", "domain": ["openai.com","chat.openai.com","api.openai.com","auth0.openai.com","cdn.openai.com","oaiusercontent.com"], "outboundTag": "proxy" }
    ]
  }
}
EOF
  else
    die "未知协议"
  fi

  "$SUOHA_DIR/xray/xray" run -config "$SUOHA_DIR/xray/config.json" >"$SUOHA_DIR/xray.log" 2>&1 &
  "$SUOHA_DIR/cloudflared" tunnel --url "http://localhost:$port" --no-autoupdate --edge-ip-version "$ips" --protocol http2 > "$SUOHA_DIR/argo.log" 2>&1 &
  sleep 1

  n=0
  while :; do
    n=$((n+1))
    argo_url="$(grep -oE 'https://[a-zA-Z0-9.-]+trycloudflare\.com' "$SUOHA_DIR/argo.log" 2>/dev/null | tail -n1)"
    if [ $n -ge 30 ]; then
      n=0
      kill_proc_safe "$SUOHA_DIR/cloudflared" "$IS_ALPINE"
      kill_proc_safe "$SUOHA_DIR/xray/xray" "$IS_ALPINE"
      rm -f "$SUOHA_DIR/argo.log"
      "$SUOHA_DIR/cloudflared" tunnel --url "http://localhost:$port" --no-autoupdate --edge-ip-version "$ips" --protocol http2 > "$SUOHA_DIR/argo.log" 2>&1 &
      "$SUOHA_DIR/xray/xray" run -config "$SUOHA_DIR/xray/config.json" >"$SUOHA_DIR/xray.log" 2>&1 &
      sleep 1
    elif [ -z "$argo_url" ]; then
      sleep 1
    else
      rm -f "$SUOHA_DIR/argo.log"
      break
    fi
  done

  argo_host="${argo_url#https://}"

  if [ "$protocol" = "1" ]; then
    {
      echo -e "VMess链接（含YouTube和ChatGPT分流）\n"
      json_tls='{"add":"x.cf.090227.xyz","aid":"0","host":"'"$argo_host"'","id":"'"$uuid"'","net":"ws","path":"'"$urlpath"'","port":"2053","ps":"X-荷兰_TLS","tls":"tls","type":"none","v":"2"}'
      echo "vmess://$(b64enc "$json_tls")"
      echo -e "\nTLS端口: 2053/2083/2087/2096/8443\n"
      json_nontls='{"add":"x.cf.090227.xyz","aid":"0","host":"'"$argo_host"'","id":"'"$uuid"'","net":"ws","path":"'"$urlpath"'","port":"2052","ps":"X-荷兰","tls":"","type":"none","v":"2"}'
      echo "vmess://$(b64enc "$json_nontls")"
      echo -e "\n非TLS端口: 2052/2082/2086/2095/8080/8880"
    } > "$SUOHA_DIR/v2ray.txt"
  else
    {
      echo -e "VLESS链接（含YouTube和ChatGPT分流）\n"
      echo "vless://${uuid}@x.cf.090227.xyz:2053?encryption=none&security=tls&type=ws&host=${argo_host}&path=${urlpath}#X-荷兰_TLS"
      echo -e "\nTLS端口: 2053/2083/2087/2096/8443\n"
      echo "vless://${uuid}@x.cf.090227.xyz:2052?encryption=none&security=none&type=ws&host=${argo_host}&path=${urlpath}#X-荷兰"
      echo -e "\n非TLS端口: 2052/2082/2086/2095/8080/8880"
    } > "$SUOHA_DIR/v2ray.txt"
  fi

  cat "$SUOHA_DIR/v2ray.txt"
  echo -e "\n链接已保存至 $SUOHA_DIR/v2ray.txt"
}

# 启动服务 (原功能)
start_service() {
  read -r -p "选择协议 (1.vmess 2.vless, 默认1): " protocol
  protocol=${protocol:-1}
  [ "$protocol" != "1" ] && [ "$protocol" != "2" ] && die "请输入1或2"
  
  read -r -p "IP版本 (4/6, 默认4): " ips
  ips=${ips:-4}
  [ "$ips" != "4" ] && [ "$ips" != "6" ] && die "请输入4或6"

  stop_service
  _start_service_inner "$protocol" "$ips"
  echo "停止服务: $0 stop"
}

# 停止服务
stop_service() {
  # 停止保活守护进程 (通过grep脚本名和关键字'keepalive_monitor'来精确定位)
  kill_proc_safe "$0 keepalive_monitor" "$IS_ALPINE"
  # 停止主服务进程
  kill_proc_safe "$SUOHA_DIR/cloudflared" "$IS_ALPINE"
  kill_proc_safe "$SUOHA_DIR/xray/xray" "$IS_ALPINE"
  echo "服务和保活进程已停止"
}

# 查看状态
check_status() {
  if [ "$IS_ALPINE" = "1" ]; then
    [ $(ps | grep -F "$SUOHA_DIR/cloudflared" | grep -v grep | wc -l) -gt 0 ] && echo "cloudflared: 运行中" || echo "cloudflared: 已停止"
    [ $(ps | grep -F "$SUOHA_DIR/xray/xray" | grep -v grep | wc -l) -gt 0 ] && echo "xray: 运行中" || echo "xray: 已停止"
    [ $(ps | grep -F "$0 keepalive_monitor" | grep -v grep | wc -l) -gt 0 ] && echo "保活守护: 运行中" || echo "保活守护: 已停止"
  else
    [ $(ps -ef | grep -F "$SUOHA_DIR/cloudflared" | grep -v grep | wc -l) -gt 0 ] && echo "cloudflared: 运行中" || echo "cloudflared: 已停止"
    [ $(ps -ef | grep -F "$SUOHA_DIR/xray/xray" | grep -v grep | wc -l) -gt 0 ] && echo "xray: 运行中" || echo "xray: 已停止"
    [ $(ps -ef | grep -F "$0 keepalive_monitor" | grep -v grep | wc -l) -gt 0 ] && echo "保活守护: 运行中" || echo "保活守护: 已停止"
  fi
  
  [ -f "$SUOHA_DIR/v2ray.txt" ] && echo -e "\n当前链接:\n$(cat "$SUOHA_DIR/v2ray.txt")" || echo -e "\n未找到链接"
}

# 清理文件
cleanup() {
  stop_service
  rm -rf "$SUOHA_DIR"
  echo "已清理所有文件"
}

# --- 新增：保活功能 (优化版) ---

# 保活监控函数 (直接作为函数运行)
keepalive_monitor() {
  local PROTOCOL="$1"
  local IP_VERSION="$2"

  local XRAY_PROC="$SUOHA_DIR/xray/xray"
  local CLOUDFLARED_PROC="$SUOHA_DIR/cloudflared"
  local KEEPALIVE_LOG="$SUOHA_DIR/proxy_keepalive.log"

  log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$KEEPALIVE_LOG"
  }

  log "保活守护进程启动 (PID=$$)"
  log "配置: 协议=$PROTOCOL, IP版本=$IP_VERSION"

  # 首次启动服务
  log "首次启动代理服务..."
  _start_service_inner "$PROTOCOL" "$IP_VERSION" > /dev/null 2>&1 # 首次启动的输出重定向，避免日志混乱

  # 循环检查
  while true; do
    # 检查Xray
    if ! pgrep -f "$XRAY_PROC" >/dev/null; then
      log "Xray进程已退出，重启中..."
      stop_service > /dev/null 2>&1
      _start_service_inner "$PROTOCOL" "$IP_VERSION" > /dev/null 2>&1
    fi
    # 检查Cloudflared
    if ! pgrep -f "$CLOUDFLARED_PROC" >/dev/null; then
      log "Cloudflared进程已退出，重启中..."
      stop_service > /dev/null 2>&1
      _start_service_inner "$PROTOCOL" "$IP_VERSION" > /dev/null 2>&1
    fi
    sleep 5 # 增加检查间隔，减少CPU占用
  done
}

# 启动保活服务 (新的菜单选项)
start_keepalive_service() {
  read -r -p "选择协议 (1.vmess 2.vless, 默认1): " protocol
  protocol=${protocol:-1}
  [ "$protocol" != "1" ] && [ "$protocol" != "2" ] && die "请输入1或2"
  
  read -r -p "IP版本 (4/6, 默认4): " ips
  ips=${ips:-4}
  [ "$ips" != "4" ] && [ "$ips" != "6" ] && die "请输入4或6"

  # 停止任何现有服务
  stop_service

  echo "正在启动保活服务..."
  # 直接在后台启动监控函数，不再创建临时脚本
  nohup bash -c "$(declare -f log keepalive_monitor _start_service_inner stop_service kill_proc_safe die detect_os); keepalive_monitor '$protocol' '$ips'" > "$SUOHA_DIR/keepalive.log" 2>&1 &
  
  # 等待一小会儿，让服务有时间启动
  sleep 3
  check_status
  echo -e "\n保活服务已在后台启动。日志文件: $SUOHA_DIR/keepalive.log"
  echo "停止保活服务: $0 stop"
}


# --- 主菜单 ---
echo "1. 启动服务（含YouTube和ChatGPT分流）"
echo "2. 停止服务"
echo "3. 查看状态"
echo "4. 清理文件"
echo "5. 启动保活服务（推荐）"
echo "0. 退出"
read -r -p "请选择(默认1): " mode
mode=${mode:-1}

case "$mode" in
  1)
    start_service
    ;;
  2)
    stop_service
    ;;
  3)
    check_status
    ;;
  4)
    read -r -p "确定清理所有文件? (y/N) " confirm
    [ "$confirm" = "y" ] && cleanup || echo "取消清理"
    ;;
  5)
    start_keepalive_service
    ;;
  0)
    echo "退出成功"; exit 0;;
  *)
    echo "无效选择"; exit 1;;
esac
