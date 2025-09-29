#!/bin/bash
# 无root权限版代理脚本

set +e

# 基础工具函数
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
    pids=$(ps | grep -F "$pat" | grep -v grep | awk '{print $1}' 2>/dev/null)
    [ -n "$pids" ] && kill -9 $pids >/dev/null 2>&1
  else
    pids=$(ps -ef | grep -F "$pat" | grep -v grep | awk '{print $2}' 2>/dev/null)
    [ -n "$pids" ] && kill -9 $pids >/dev/null 2>&1
  fi
}

# 分流配置
PROXY_OUT_IP="172.233.171.224"
PROXY_OUT_PORT=16416
PROXY_OUT_ID="8c1b9bea-cb51-43bb-a65c-0af31bbbf145"

# 用户目录（非root可访问）
SUOHA_DIR="$HOME/.suoha"
mkdir -p "$SUOHA_DIR" || die "无法创建目录 $SUOHA_DIR（请检查权限）"

# 初始化
detect_os
need_cmd curl
need_cmd unzip
need_cmd awk
need_cmd grep
need_cmd tr
need_cmd ps
need_cmd kill

# 启动服务
start_service() {
  # 清理旧文件
  rm -rf "$SUOHA_DIR/xray" "$SUOHA_DIR/cloudflared" "$SUOHA_DIR/xray.zip" "$SUOHA_DIR/argo.log"

  # 下载对应架构的程序
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

  # 解压并授权
  mkdir -p "$SUOHA_DIR/xray"
  unzip -q -d "$SUOHA_DIR/xray" "$SUOHA_DIR/xray.zip" || die "解压Xray失败"
  chmod +x "$SUOHA_DIR/cloudflared" "$SUOHA_DIR/xray/xray"
  rm -f "$SUOHA_DIR/xray.zip"

  # 生成随机配置
  uuid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "uuid-$(date +%s)")"
  urlpath="$(echo "$uuid" | awk -F- '{print $1}')"
  port=$((RANDOM % 10000 + 20000))  # 非root端口

  # 生成Xray配置
  if [ "$protocol" = "1" ]; then
cat > "$SUOHA_DIR/xray/config.json" <<EOF
{
  "inbounds": [{
    "port": $port,
    "listen": "localhost",
    "protocol": "vmess",
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
      {
        "type": "field",
        "domain": [
          "youtube.com", "googlevideo.com", "ytimg.com", "gstatic.com",
          "googleapis.com", "ggpht.com", "googleusercontent.com"
        ],
        "outboundTag": "proxy"
      },
      {
        "type": "field",
        "domain": [
          "openai.com", "chat.openai.com", "api.openai.com",
          "auth0.openai.com", "cdn.openai.com", "oaiusercontent.com"
        ],
        "outboundTag": "proxy"
      }
    ]
  }
}
EOF
  elif [ "$protocol" = "2" ]; then
cat > "$SUOHA_DIR/xray/config.json" <<EOF
{
  "inbounds": [{
    "port": $port,
    "listen": "localhost",
    "protocol": "vless",
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
      {
        "type": "field",
        "domain": [
          "youtube.com", "googlevideo.com", "ytimg.com", "gstatic.com",
          "googleapis.com", "ggpht.com", "googleusercontent.com"
        ],
        "outboundTag": "proxy"
      },
      {
        "type": "field",
        "domain": [
          "openai.com", "chat.openai.com", "api.openai.com",
          "auth0.openai.com", "cdn.openai.com", "oaiusercontent.com"
        ],
        "outboundTag": "proxy"
      }
    ]
  }
}
EOF
  else
    die "未知协议（请输入1或2）"
  fi

  # 启动服务
  "$SUOHA_DIR/xray/xray" run -config "$SUOHA_DIR/xray/config.json" >"$SUOHA_DIR/xray.log" 2>&1 &
  "$SUOHA_DIR/cloudflared" tunnel --url "http://localhost:$port" --no-autoupdate --edge-ip-version "$ips" --protocol http2 > "$SUOHA_DIR/argo.log" 2>&1 &
  sleep 1

  # 获取Argo地址
  n=0
  while :; do
    n=$((n+1))
    clear
    echo "等待Cloudflare Argo生成地址（$n秒）"
    argo_url="$(grep -oE 'https://[a-zA-Z0-9.-]+trycloudflare\.com' "$SUOHA_DIR/argo.log" | tail -n1)"

    if [ $n -ge 30 ]; then
      n=0
      kill_proc_safe "$SUOHA_DIR/cloudflared" "$IS_ALPINE"
      kill_proc_safe "$SUOHA_DIR/xray/xray" "$IS_ALPINE"
      rm -f "$SUOHA_DIR/argo.log"
      echo "超时，重试中..."
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

  clear
  argo_host="${argo_url#https://}"

  # 生成代理链接
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
  echo "停止服务: $0 stop"
}

# 停止服务
stop_service() {
  kill_proc_safe "$SUOHA_DIR/cloudflared" "$IS_ALPINE"
  kill_proc_safe "$SUOHA_DIR/xray/xray" "$IS_ALPINE"
  echo "服务已停止"
}

# 查看状态
check_status() {
  if [ "$IS_ALPINE" = "1" ]; then
    [ $(ps | grep -F "$SUOHA_DIR/cloudflared" | grep -v grep | wc -l) -gt 0 ] && echo "cloudflared: 运行中" || echo "cloudflared: 已停止"
    [ $(ps | grep -F "$SUOHA_DIR/xray/xray" | grep -v grep | wc -l) -gt 0 ] && echo "xray: 运行中" || echo "xray: 已停止"
  else
    [ $(ps -ef | grep -F "$SUOHA_DIR/cloudflared" | grep -v grep | wc -l) -gt 0 ] && echo "cloudflared: 运行中" || echo "cloudflared: 已停止"
    [ $(ps -ef | grep -F "$SUOHA_DIR/xray/xray" | grep -v grep | wc -l) -gt 0 ] && echo "xray: 运行中" || echo "xray: 已停止"
  fi
  
  [ -f "$SUOHA_DIR/v2ray.txt" ] && echo -e "\n当前链接:\n$(cat "$SUOHA_DIR/v2ray.txt")" || echo -e "\n未找到链接"
}

# 清理文件
cleanup() {
  stop_service
  rm -rf "$SUOHA_DIR"
  echo "已清理所有文件"
}

# 保活服务功能
keepalive_service() {
  echo "启动保活服务监控..."
  echo "按 Ctrl+C 停止保活监控"
  
  while true; do
    # 检查Xray进程
    if [ "$IS_ALPINE" = "1" ]; then
      xray_running=$(ps | grep -F "$SUOHA_DIR/xray/xray" | grep -v grep | wc -l)
      cloudflared_running=$(ps | grep -F "$SUOHA_DIR/cloudflared" | grep -v grep | wc -l)
    else
      xray_running=$(ps -ef | grep -F "$SUOHA_DIR/xray/xray" | grep -v grep | wc -l)
      cloudflared_running=$(ps -ef | grep -F "$SUOHA_DIR/cloudflared" | grep -v grep | wc -l)
    fi
    
    # 如果Xray不在运行，重启它
    if [ $xray_running -eq 0 ]; then
      echo "$(date): Xray进程停止，正在重启..." >> "$SUOHA_DIR/keepalive.log" 2>/dev/null
      if [ -f "$SUOHA_DIR/xray/xray" ] && [ -f "$SUOHA_DIR/xray/config.json" ]; then
        "$SUOHA_DIR/xray/xray" run -config "$SUOHA_DIR/xray/config.json" >"$SUOHA_DIR/xray.log" 2>&1 &
        echo "$(date): Xray重启完成" >> "$SUOHA_DIR/keepalive.log" 2>/dev/null
      else
        echo "$(date): 错误: 找不到Xray可执行文件或配置文件" >> "$SUOHA_DIR/keepalive.log" 2>/dev/null
      fi
    fi
    
    # 如果Cloudflared不在运行，重启它
    if [ $cloudflared_running -eq 0 ]; then
      echo "$(date): Cloudflared进程停止，正在重启..." >> "$SUOHA_DIR/keepalive.log" 2>/dev/null
      if [ -f "$SUOHA_DIR/cloudflared" ] && [ -f "$SUOHA_DIR/xray/config.json" ]; then
        # 从配置文件中获取端口
        port=$(grep '"port":' "$SUOHA_DIR/xray/config.json" | awk '{print $2}' | tr -d ',')
        "$SUOHA_DIR/cloudflared" tunnel --url "http://localhost:$port" --no-autoupdate --edge-ip-version "$ips" --protocol http2 > "$SUOHA_DIR/argo.log" 2>&1 &
        echo "$(date): Cloudflared重启完成" >> "$SUOHA_DIR/keepalive.log" 2>/dev/null
      else
        echo "$(date): 错误: 找不到Cloudflared可执行文件或配置文件" >> "$SUOHA_DIR/keepalive.log" 2>/dev/null
      fi
    fi
    
    # 等待5秒后再次检查
    sleep 5
  done
}

# 主菜单
echo "1. 启动服务（含YouTube和ChatGPT分流）"
echo "2. 停止服务"
echo "3. 查看状态"
echo "4. 清理文件"
echo "5. 保活服务（监控并自动重启进程）"
echo "0. 退出"
read -r -p "请选择(默认1): " mode
mode=${mode:-1}

case "$mode" in
  1)
    read -r -p "选择协议 (1.vmess 2.vless, 默认1): " protocol
    protocol=${protocol:-1}
    [ "$protocol" != "1" ] && [ "$protocol" != "2" ] && die "请输入1或2"
    
    read -r -p "IP版本 (4/6, 默认4): " ips
    ips=${ips:-4}
    [ "$ips" != "4" ] && [ "$ips" != "6" ] && die "请输入4或6"
    
    isp="$(curl -s -"${ips}" https://speed.cloudflare.com/meta 2>/dev/null | awk -F\" '{print $26"-"$18"-"$30}' | sed 's/ /_/g')"
    [ -z "$isp" ] && isp="unknown-$(date +%s)"

    stop_service
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
    # 检查是否已经配置过服务
    if [ ! -f "$SUOHA_DIR/xray/config.json" ] || [ ! -f "$SUOHA_DIR/xray/xray" ] || [ ! -f "$SUOHA_DIR/cloudflared" ]; then
      echo "错误: 请先使用选项1配置并启动服务"
      exit 1
    fi
    echo "保活服务已启动，正在监控Xray和Cloudflared进程..."
    echo "监控日志保存在: $SUOHA_DIR/keepalive.log"
    keepalive_service
    ;;
  0)
    echo "退出成功"; exit 0;;
  *)
    echo "无效选择"; exit 1;;
esac
