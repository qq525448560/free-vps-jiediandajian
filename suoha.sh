#!/bin/bash
# onekey suoha (无root权限版; 保留YouTube和ChatGPT分流)

# ---------------------------
# helpers
# ---------------------------
set +e

b64enc() {
  if base64 --help 2>/dev/null | grep -q '\-w'; then
    printf '%s' "$1" | base64 -w 0
  else
    printf '%s' "$1" | base64 | tr -d '\n'
  fi
}

need_cmd() { 
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "错误: 需要 $1 命令，但未找到。请联系管理员安装。" >&2
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
      OS_NAME="Alpine"
      ;;
    *)
      IS_ALPINE=0
      OS_NAME="Other Linux"
      ;;
  esac
}

kill_proc_safe() {
  local pat="$1" is_alpine="$2"
  if [ "$is_alpine" = "1" ]; then
    kill -9 $(ps | grep -F "$pat" | grep -v grep | awk '{print $1}') >/dev/null 2>&1
  else
    kill -9 $(ps -ef | grep -F "$pat" | grep -v grep | awk '{print $2}') >/dev/null 2>&1
  fi
}

# ---------------------------
# 分流目标配置
# ---------------------------
# YouTube和ChatGPT共用的分流出口
PROXY_OUT_IP="172.233.171.224"
PROXY_OUT_PORT=16416
PROXY_OUT_ID="8c1b9bea-cb51-43bb-a65c-0af31bbbf145"

# ---------------------------
# 用户目录配置
# ---------------------------
SUOHA_DIR="$HOME/.suoha"
mkdir -p "$SUOHA_DIR" || die "无法创建目录 $SUOHA_DIR"

# ---------------------------
# 初始化
# ---------------------------
detect_os

# 检查必要命令
need_cmd curl
need_cmd unzip
need_cmd awk
need_cmd grep
need_cmd tr
need_cmd ps
need_cmd kill

# ---------------------------
# 启动服务函数 (保留完整分流功能)
# ---------------------------
start_service() {
  # 清理旧文件
  rm -rf "$SUOHA_DIR/xray" "$SUOHA_DIR/cloudflared" "$SUOHA_DIR/xray.zip" "$SUOHA_DIR/argo.log"

  # 架构检测与下载
  arch="$(uname -m)"
  case "$arch" in
    x86_64|x64|amd64 )
      curl -fsSL https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o "$SUOHA_DIR/xray.zip" || die "下载 Xray 失败"
      curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o "$SUOHA_DIR/cloudflared" || die "下载 cloudflared 失败"
      ;;
    i386|i686 )
      curl -fsSL https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-32.zip -o "$SUOHA_DIR/xray.zip" || die "下载 Xray 失败"
      curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386 -o "$SUOHA_DIR/cloudflared" || die "下载 cloudflared 失败"
      ;;
    armv8|arm64|aarch64 )
      curl -fsSL https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip -o "$SUOHA_DIR/xray.zip" || die "下载 Xray 失败"
      curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 -o "$SUOHA_DIR/cloudflared" || die "下载 cloudflared 失败"
      ;;
    armv7l )
      curl -fsSL https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm32-v7a.zip -o "$SUOHA_DIR/xray.zip" || die "下载 Xray 失败"
      curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm -o "$SUOHA_DIR/cloudflared" || die "下载 cloudflared 失败"
      ;;
    * )
      echo "当前架构 $(uname -m) 没有适配"; exit 1;;
  esac

  # 解压并设置权限
  mkdir -p "$SUOHA_DIR/xray"
  unzip -q -d "$SUOHA_DIR/xray" "$SUOHA_DIR/xray.zip" || die "解压 Xray 失败"
  chmod +x "$SUOHA_DIR/cloudflared" "$SUOHA_DIR/xray/xray"
  rm -f "$SUOHA_DIR/xray.zip"

  # 生成随机配置
  uuid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "default-uuid-$(date +%s)")"
  urlpath="$(echo "$uuid" | awk -F- '{print $1}')"
  port=$((RANDOM % 10000 + 20000))  # 非root用户只能使用1024以上端口

  # ----- Xray 配置 (包含YouTube和ChatGPT分流) -----
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
    die "未知协议（protocol=$protocol）"
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
    echo "等待 Cloudflare Argo 生成地址，已等待 $n 秒"
    argo_url="$(grep -oE 'https://[a-zA-Z0-9.-]+trycloudflare\.com' "$SUOHA_DIR/argo.log" | tail -n1)"

    if [ $n -ge 30 ]; then
      n=0
      if [ "$IS_ALPINE" = "1" ]; then
        kill_proc_safe "cloudflared" 1
        kill_proc_safe "xray" 1
      else
        kill_proc_safe "cloudflared" 0
        kill_proc_safe "xray" 0
      fi
      rm -f "$SUOHA_DIR/argo.log"
      clear
      echo "argo 获取超时，重试中..."
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

  # 生成链接
  if [ "$protocol" = "1" ]; then
    {
      echo -e "vmess 链接已生成（包含YouTube和ChatGPT分流）\n"
      json_tls='{"add":"x.cf.090227.xyz","aid":"0","host":"'"$argo_host"'","id":"'"$uuid"'","net":"ws","path":"'"$urlpath"'","port":"2053","ps":"分流代理_tls","tls":"tls","type":"none","v":"2"}'
      echo "vmess://$(b64enc "$json_tls")"
      echo -e "\nTLS端口: 2053 2083 2087 2096 8443\n"
      json_nontls='{"add":"x.cf.090227.xyz","aid":"0","host":"'"$argo_host"'","id":"'"$uuid"'","net":"ws","path":"'"$urlpath"'","port":"2052","ps":"分流代理","tls":"","type":"none","v":"2"}'
      echo "vmess://$(b64enc "$json_nontls")"
      echo -e "\n非TLS端口: 2052 2082 2086 2095 8080 8880"
    } > "$SUOHA_DIR/v2ray.txt"
  else
    {
      echo -e "vless 链接已生成（包含YouTube和ChatGPT分流）\n"
      echo "vless://${uuid}@x.cf.090227.xyz:2053?encryption=none&security=tls&type=ws&host=${argo_host}&path=${urlpath}#分流代理_tls"
      echo -e "\nTLS端口: 2053 2083 2087 2096 8443\n"
      echo "vless://${uuid}@x.cf.090227.xyz:2052?encryption=none&security=none&type=ws&host=${argo_host}&path=${urlpath}#分流代理"
      echo -e "\n非TLS端口: 2052 2082 2086 2095 8080 8880"
    } > "$SUOHA_DIR/v2ray.txt"
  fi

  cat "$SUOHA_DIR/v2ray.txt"
  echo -e "\n信息已保存至 $SUOHA_DIR/v2ray.txt"
  echo -e "服务日志: $SUOHA_DIR/xray.log"
  echo -e "停止服务: $0 stop"
}

# 停止服务
stop_service() {
  if [ "$IS_ALPINE" = "1" ]; then
    kill_proc_safe "$SUOHA_DIR/cloudflared" 1
    kill_proc_safe "$SUOHA_DIR/xray/xray" 1
  else
    kill_proc_safe "$SUOHA_DIR/cloudflared" 0
    kill_proc_safe "$SUOHA_DIR/xray/xray" 0
  fi
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
  
  [ -f "$SUOHA_DIR/v2ray.txt" ] && echo -e "\n当前链接:\n$(cat "$SUOHA_DIR/v2ray.txt")" || echo -e "\n未找到链接信息"
}

# 清理文件
cleanup() {
  stop_service
  rm -rf "$SUOHA_DIR"
  echo "已清理所有文件"
}

# ---------------------------
# 主菜单
# ---------------------------
echo "1. 启动服务（含YouTube和ChatGPT分流）"
echo "2. 停止服务"
echo "3. 查看状态"
echo "4. 清理文件"
echo "0. 退出"
read -r -p "请选择(默认1): " mode
mode=${mode:-1}

case "$mode" in
  1)
    read -r -p "选择协议 (1.vmess 2.vless, 默认1): " protocol
    protocol=${protocol:-1}
    [ "$protocol" != "1" ] && [ "$protocol" != "2" ] && die "请输入正确协议"
    
    read -r -p "IP版本 (4/6, 默认4): " ips
    ips=${ips:-4}
    [ "$ips" != "4" ] && [ "$ips" != "6" ] && die "请输入正确IP版本"
    
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
  0)
    echo "退出成功"; exit 0;;
  *)
    echo "无效选择"; exit 1;;
esac
