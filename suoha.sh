#!/bin/bash
# onekey suoha (fixed & hardened; YouTube split routing; 优选域名替换为 x.cf.090227.xyz)

# ---------------------------
# helpers
# ---------------------------
set +e

b64enc() {
  # base64 without line-wrap; works on both GNU and BusyBox
  if base64 --help 2>/dev/null | grep -q '\-w'; then
    printf '%s' "$1" | base64 -w 0
  else
    printf '%s' "$1" | base64 | tr -d '\n'
  fi
}

need_cmd() { command -v "$1" >/dev/null 2>&1; }

die() { echo "ERROR: $*" >&2; exit 1; }

detect_pkg() {
  # Derive PKG_UPDATE / PKG_INSTALL from /etc/os-release
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-}"
  else
    OS_ID=""
  fi

  case "$OS_ID" in
    debian|ubuntu)
      PKG_UPDATE="apt-get update -y"
      PKG_INSTALL="apt-get install -y"
      OS_NAME="Debian/Ubuntu"
      ;;
    centos|rhel)
      if command -v dnf >/dev/null 2>&1; then
        PKG_UPDATE="dnf -y update"
        PKG_INSTALL="dnf -y install"
      else
        PKG_UPDATE="yum -y update"
        PKG_INSTALL="yum -y install"
      fi
      OS_NAME="CentOS/RHEL"
      ;;
    fedora)
      PKG_UPDATE="dnf -y update"
      PKG_INSTALL="dnf -y install"
      OS_NAME="Fedora"
      ;;
    alpine)
      PKG_UPDATE="apk update"
      PKG_INSTALL="apk add -f"
      OS_NAME="Alpine"
      ;;
    *)
      echo "当前系统未适配（ID=$OS_ID），默认按 Debian/Ubuntu 处理（APT）"
      PKG_UPDATE="apt-get update -y"
      PKG_INSTALL="apt-get install -y"
      OS_NAME="Debian/Ubuntu(Default)"
      ;;
  esac
}

ensure_tools() {
  if ! need_cmd unzip; then
    eval "$PKG_UPDATE"
    eval "$PKG_INSTALL unzip"
  fi
  if ! need_cmd curl; then
    eval "$PKG_UPDATE"
    eval "$PKG_INSTALL curl"
  fi
}

kill_proc_safe() {
  # $1: pattern; $2: is_alpine (1/0)
  local pat="$1" is_alpine="$2"
  if [ "$is_alpine" = "1" ]; then
    # BusyBox ps：第一列通常是 PID
    kill -9 $(ps | grep -F "$pat" | grep -v grep | awk '{print $1}') >/dev/null 2>&1
  else
    # procps ps -ef：第二列是 PID
    kill -9 $(ps -ef | grep -F "$pat" | grep -v grep | awk '{print $2}') >/dev/null 2>&1
  fi
}

# ---------------------------
# YouTube outbound settings
# ---------------------------
YOUTUBE_OUT_IP="172.233.171.224"
YOUTUBE_OUT_PORT=16416
YOUTUBE_OUT_ID="8c1b9bea-cb51-43bb-a65c-0af31bbbf145"

# ---------------------------
# bootstrap
# ---------------------------
detect_pkg
ensure_tools

IS_ALPINE=0
if echo "$OS_NAME" | grep -qi alpine; then IS_ALPINE=1; fi

# ---------------------------
# Quick Tunnel mode
# ---------------------------
quicktunnel() {
  rm -rf xray cloudflared-linux xray.zip

  arch="$(uname -m)"
  case "$arch" in
    x86_64|x64|amd64 )
      curl -fsSL https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip || die "下载 Xray 失败"
      curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o cloudflared-linux || die "下载 cloudflared 失败"
      ;;
    i386|i686 )
      curl -fsSL https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-32.zip -o xray.zip || die "下载 Xray 失败"
      curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386 -o cloudflared-linux || die "下载 cloudflared 失败"
      ;;
    armv8|arm64|aarch64 )
      curl -fsSL https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip -o xray.zip || die "下载 Xray 失败"
      curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 -o cloudflared-linux || die "下载 cloudflared 失败"
      ;;
    armv7l )
      curl -fsSL https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm32-v7a.zip -o xray.zip || die "下载 Xray 失败"
      curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm -o cloudflared-linux || die "下载 cloudflared 失败"
      ;;
    * )
      echo "当前架构 $(uname -m) 没有适配"; exit 1;;
  esac

  mkdir -p xray
  unzip -q -d xray xray.zip || die "解压 Xray 失败"
  chmod +x cloudflared-linux xray/xray
  rm -f xray.zip

  uuid="$(cat /proc/sys/kernel/random/uuid)"
  urlpath="$(echo "$uuid" | awk -F- '{print $1}')"
  port=$((RANDOM % 10000 + 10000))

  # ----- Xray config with YouTube split routing -----
  if [ "$protocol" = "1" ]; then
cat > xray/config.json <<EOF
{
  "inbounds": [{
    "port": $port,
    "listen": "localhost",
    "protocol": "vmess",
    "settings": { "clients": [{ "id": "$uuid", "alterId": 0 }] },
    "streamSettings": { "network": "ws", "wsSettings": { "path": "$urlpath" } }
  }],
  "outbounds": [
    { "protocol": "freedom", "settings": {} },
    { "protocol": "vmess", "tag": "youtube",
      "settings": { "vnext": [{ "address": "$YOUTUBE_OUT_IP", "port": $YOUTUBE_OUT_PORT,
        "users": [{ "id": "$YOUTUBE_OUT_ID", "alterId": 0 }] }] } },
    { "protocol": "blackhole", "tag": "block", "settings": {} }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [{
      "type": "field",
      "domain": [
        "youtube.com","googlevideo.com","ytimg.com","gstatic.com",
        "googleapis.com","ggpht.com","googleusercontent.com"
      ],
      "outboundTag": "youtube"
    }]
  }
}
EOF
  elif [ "$protocol" = "2" ]; then
cat > xray/config.json <<EOF
{
  "inbounds": [{
    "port": $port,
    "listen": "localhost",
    "protocol": "vless",
    "settings": { "decryption": "none", "clients": [{ "id": "$uuid" }] },
    "streamSettings": { "network": "ws", "wsSettings": { "path": "$urlpath" } }
  }],
  "outbounds": [
    { "protocol": "freedom", "settings": {} },
    { "protocol": "vmess", "tag": "youtube",
      "settings": { "vnext": [{ "address": "$YOUTUBE_OUT_IP", "port": $YOUTUBE_OUT_PORT,
        "users": [{ "id": "$YOUTUBE_OUT_ID", "alterId": 0 }] }] } },
    { "protocol": "blackhole", "tag": "block", "settings": {} }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [{
      "type": "field",
      "domain": [
        "youtube.com","googlevideo.com","ytimg.com","gstatic.com",
        "googleapis.com","ggpht.com","googleusercontent.com"
      ],
      "outboundTag": "youtube"
    }]
  }
}
EOF
  else
    die "未知协议（protocol=$protocol）"
  fi

  ./xray/xray run >/dev/null 2>&1 &
  ./cloudflared-linux tunnel --url "http://localhost:$port" --no-autoupdate --edge-ip-version "$ips" --protocol http2 > argo.log 2>&1 &
  sleep 1

  n=0
  while :; do
    n=$((n+1))
    clear
    echo "等待 Cloudflare Argo 生成地址，已等待 $n 秒"
    # 抓取所有 trycloudflare.com 地址，取最后一条最稳
    argo_url="$(grep -oE 'https://[a-zA-Z0-9.-]+trycloudflare\.com' argo.log | tail -n1)"

    if [ $n -ge 15 ]; then
      n=0
      if [ "$IS_ALPINE" = "1" ]; then
        kill_proc_safe "cloudflared-linux" 1
      else
        kill_proc_safe "cloudflared-linux" 0
      fi
      rm -f argo.log
      clear
      echo "argo 获取超时，重试中..."
      ./cloudflared-linux tunnel --url "http://localhost:$port" --no-autoupdate --edge-ip-version "$ips" --protocol http2 > argo.log 2>&1 &
      sleep 1
    elif [ -z "$argo_url" ]; then
      sleep 1
    else
      rm -f argo.log
      break
    fi
  done

  clear
  argo_host="${argo_url#https://}"

  if [ "$protocol" = "1" ]; then
    {
      echo -e "vmess 链接已经生成，x.cf.090227.xyz 可替换为 优选域名\n"
      json_tls='{"add":"x.cf.090227.xyz","aid":"0","host":"'"$argo_host"'","id":"'"$uuid"'","net":"ws","path":"'"$urlpath"'","port":"443","ps":"'"$(echo "$isp" | sed 's/_/ /g')"'_tls","tls":"tls","type":"none","v":"2"}'
      echo "vmess://$(b64enc "$json_tls")"
      echo -e "\n端口 443 可改为 2053 2083 2087 2096 8443\n"
      json_nontls='{"add":"x.cf.090227.xyz","aid":"0","host":"'"$argo_host"'","id":"'"$uuid"'","net":"ws","path":"'"$urlpath"'","port":"80","ps":"'"$(echo "$isp" | sed 's/_/ /g')"'","tls":"","type":"none","v":"2"}'
      echo "vmess://$(b64enc "$json_nontls")"
      echo -e "\n端口 80 可改为 8080 8880 2052 2082 2086 2095"
    } > v2ray.txt
  else
    {
      echo -e "vless 链接已经生成，x.cf.090227.xyz 可替换为 优选域名\n"
      echo "vless://${uuid}@x.cf.090227.xyz:443?encryption=none&security=tls&type=ws&host=${argo_host}&path=${urlpath}#$(echo "$isp" | sed -e 's/_/%20/g' -e 's/,/%2C/g')_tls"
      echo -e "\n端口 443 可改为 2053 2083 2087 2096 8443\n"
      echo "vless://${uuid}@x.cf.090227.xyz:80?encryption=none&security=none&type=ws&host=${argo_host}&path=${urlpath}#$(echo "$isp" | sed -e 's/_/%20/g' -e 's/,/%2C/g')"
      echo -e "\n端口 80 可改为 8080 8880 2052 2082 2086 2095"
    } > v2ray.txt
  fi

  cat v2ray.txt
  echo -e "\n信息已经保存在 /root/v2ray.txt, 再次查看请运行:  cat /root/v2ray.txt"
  echo -e "注意：梭哈模式重启服务器后失效！！！"
}

# ---------------------------
# Install (persistent) mode
# ---------------------------
installtunnel() {
  mkdir -p /opt/suoha/ >/dev/null 2>&1
  rm -rf xray cloudflared-linux xray.zip

  arch="$(uname -m)"
  case "$arch" in
    x86_64|x64|amd64 )
      curl -fsSL https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip || die "下载 Xray 失败"
      curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o cloudflared-linux || die "下载 cloudflared 失败"
      ;;
    i386|i686 )
      curl -fsSL https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-32.zip -o xray.zip || die "下载 Xray 失败"
      curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386 -o cloudflared-linux || die "下载 cloudflared 失败"
      ;;
    armv8|arm64|aarch64 )
      curl -fsSL https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip -o xray.zip || die "下载 Xray 失败"
      curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 -o cloudflared-linux || die "下载 cloudflared 失败"
      ;;
    armv7l )
      curl -fsSL https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm32-v7a.zip -o xray.zip || die "下载 Xray 失败"
      curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm -o cloudflared-linux || die "下载 cloudflared 失败"
      ;;
    * ) echo "当前架构 $(uname -m) 没有适配"; exit 1;;
  esac

  mkdir -p xray
  unzip -q -d xray xray.zip || die "解压 Xray 失败"
  chmod +x cloudflared-linux xray/xray
  mv -f cloudflared-linux /opt/suoha/
  mv -f xray/xray /opt/suoha/
  rm -rf xray xray.zip

  uuid="$(cat /proc/sys/kernel/random/uuid)"
  urlpath="$(echo "$uuid" | awk -F- '{print $1}')"
  port=$((RANDOM % 10000 + 10000))

  # xray config
  if [ "$protocol" = "1" ]; then
cat > /opt/suoha/config.json <<EOF
{
  "inbounds": [{
    "port": $port, "listen": "localhost", "protocol": "vmess",
    "settings": { "clients": [{ "id": "$uuid", "alterId": 0 }] },
    "streamSettings": { "network": "ws", "wsSettings": { "path": "$urlpath" } }
  }],
  "outbounds": [
    { "protocol": "freedom", "settings": {} },
    { "protocol": "vmess", "tag": "youtube",
      "settings": { "vnext": [{ "address": "$YOUTUBE_OUT_IP", "port": $YOUTUBE_OUT_PORT,
        "users": [{ "id": "$YOUTUBE_OUT_ID", "alterId": 0 }] }] } },
    { "protocol": "blackhole", "tag": "block", "settings": {} }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [{
      "type": "field",
      "domain": [
        "youtube.com","googlevideo.com","ytimg.com","gstatic.com",
        "googleapis.com","ggpht.com","googleusercontent.com"
      ],
      "outboundTag": "youtube"
    }]
  }
}
EOF
  else
cat > /opt/suoha/config.json <<EOF
{
  "inbounds": [{
    "port": $port, "listen": "localhost", "protocol": "vless",
    "settings": { "decryption": "none", "clients": [{ "id": "$uuid" }] },
    "streamSettings": { "network": "ws", "wsSettings": { "path": "$urlpath" } }
  }],
  "outbounds": [
    { "protocol": "freedom", "settings": {} },
    { "protocol": "vmess", "tag": "youtube",
      "settings": { "vnext": [{ "address": "$YOUTUBE_OUT_IP", "port": $YOUTUBE_OUT_PORT,
        "users": [{ "id": "$YOUTUBE_OUT_ID", "alterId": 0 }] }] } },
    { "protocol": "blackhole", "tag": "block", "settings": {} }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [{
      "type": "field",
      "domain": [
        "youtube.com","googlevideo.com","ytimg.com","gstatic.com",
        "googleapis.com","ggpht.com","googleusercontent.com"
      ],
      "outboundTag": "youtube"
    }]
  }
}
EOF
  fi

  clear
  echo "复制下面的链接到浏览器打开并授权需要绑定的域名；授权完成后继续"
  /opt/suoha/cloudflared-linux --edge-ip-version "$ips" --protocol http2 tunnel login || die "cloudflared 登录失败"

  clear
  /opt/suoha/cloudflared-linux --edge-ip-version "$ips" --protocol http2 tunnel list > argo.log 2>&1
  echo -e "ARGO TUNNEL 当前已经绑定的服务如下\n"
  sed '1,2d' argo.log | awk '{print $2}'
  echo -e "\n自定义一个完整二级域名，例如 xxx.example.com"
  echo "必须是网页里授权的域名才生效，不能乱输入"
  read -r -p "输入绑定域名的完整二级域名: " domain
  if [ -z "$domain" ] || ! echo "$domain" | grep -q '\.'; then
    die "域名为空或格式不正确"
  fi
  name="$(printf '%s' "$domain" | awk -F. '{print $1}')"

  # 若不存在则创建 Tunnel；存在则清理残留
  if ! sed '1,2d' argo.log | awk '{print $2}' | grep -qw "$name"; then
    echo "创建 TUNNEL $name"
    /opt/suoha/cloudflared-linux --edge-ip-version "$ips" --protocol http2 tunnel create "$name" > argo.log 2>&1 || die "创建 TUNNEL 失败"
    echo "TUNNEL $name 创建成功"
  else
    echo "TUNNEL $name 已经存在，执行 cleanup"
    /opt/suoha/cloudflared-linux --edge-ip-version "$ips" --protocol http2 tunnel cleanup "$name" > /dev/null 2>&1
  fi

  # 重新拿 UUID（第一列是 ID）
  /opt/suoha/cloudflared-linux --edge-ip-version "$ips" --protocol http2 tunnel list > argo.log 2>&1
  tunneluuid="$(sed '1,2d' argo.log | awk -v tname="$name" '$2==tname {print $1; exit}')"
  [ -n "$tunneluuid" ] || die "未获取到 Tunnel UUID"

  echo "绑定 TUNNEL $name 到域名 $domain"
  /opt/suoha/cloudflared-linux --edge-ip-version "$ips" --protocol http2 tunnel route dns --overwrite-dns "$name" "$domain" >/dev/null 2>&1 || die "绑定域名失败"
  echo "$domain 绑定成功"

  # 导出链接
  if [ "$protocol" = "1" ]; then
    {
      echo -e "vmess 链接已经生成，x.cf.090227.xyz 可替换为 优选域名\n"
      json_tls='{"add":"x.cf.090227.xyz","aid":"0","host":"'"$domain"'","id":"'"$uuid"'","net":"ws","path":"'"$urlpath"'","port":"443","ps":"'"$(echo "$isp" | sed 's/_/ /g')"'","tls":"tls","type":"none","v":"2"}'
      echo "vmess://$(b64enc "$json_tls")"
      echo -e "\n端口 443 可改为 2053 2083 2087 2096 8443\n"
      json_nontls='{"add":"x.cf.090227.xyz","aid":"0","host":"'"$domain"'","id":"'"$uuid"'","net":"ws","path":"'"$urlpath"'","port":"80","ps":"'"$(echo "$isp" | sed 's/_/ /g')"'","tls":"","type":"none","v":"2"}'
      echo "vmess://$(b64enc "$json_nontls")"
      echo -e "\n端口 80 可改为 8080 8880 2052 2082 2086 2095\n"
      echo "注意: 如果 80/8080/8880/2052/2082/2086/2095 端口无法正常使用"
      echo "请前往 Cloudflare 控制台 检查 SSL/TLS - 边缘证书 - 始终使用 HTTPS 是否关闭"
    } > /opt/suoha/v2ray.txt
  else
    {
      echo -e "vless 链接已经生成，x.cf.090227.xyz 可替换为 优选域名\n"
      echo "vless://${uuid}@x.cf.090227.xyz:443?encryption=none&security=tls&type=ws&host=${domain}&path=${urlpath}#$(echo "$isp" | sed -e 's/_/%20/g' -e 's/,/%2C/g')_tls'"
      echo -e "\n端口 443 可改为 2053 2083 2087 2096 8443\n"
      echo "vless://${uuid}@x.cf.090227.xyz:80?encryption=none&security=none&type=ws&host=${domain}&path=${urlpath}#$(echo "$isp" | sed -e 's/_/%20/g' -e 's/,/%2C/g')"
      echo -e "\n端口 80 可改为 8080 8880 2052 2082 2086 2095"
      echo "注意: 如以上端口异常，同样检查 Cloudflare 的“始终使用 HTTPS”"
    } > /opt/suoha/v2ray.txt
  fi
  rm -f argo.log

  # cloudflared config.yaml（修正：hostname 赋值 + 兜底路由）
cat > /opt/suoha/config.yaml <<EOF
tunnel: $tunneluuid
credentials-file: /root/.cloudflared/$tunneluuid.json

ingress:
  - hostname: $domain
    service: http://localhost:$port
  - service: http_status:404
EOF

  if [ "$IS_ALPINE" = "1" ]; then
    # Alpine 自启动
    cat > /etc/local.d/cloudflared.start <<EOF
/opt/suoha/cloudflared-linux --edge-ip-version $ips --protocol http2 tunnel --config /opt/suoha/config.yaml run $name &
EOF
    cat > /etc/local.d/xray.start <<EOF
/opt/suoha/xray run -config /opt/suoha/config.json &
EOF
    chmod +x /etc/local.d/cloudflared.start /etc/local.d/xray.start
    rc-update add local
    /etc/local.d/cloudflared.start >/dev/null 2>&1
    /etc/local.d/xray.start >/dev/null 2>&1
  else
    # systemd 服务
    cat > /lib/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
TimeoutStartSec=0
Type=simple
ExecStart=/opt/suoha/cloudflared-linux --edge-ip-version $ips --protocol http2 tunnel --config /opt/suoha/config.yaml run $name
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    cat > /lib/systemd/system/xray.service <<EOF
[Unit]
Description=Xray
After=network.target

[Service]
TimeoutStartSec=0
Type=simple
ExecStart=/opt/suoha/xray run -config /opt/suoha/config.json
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    systemctl enable cloudflared.service >/dev/null 2>&1
    systemctl enable xray.service       >/dev/null 2>&1
    systemctl --system daemon-reload
    systemctl start cloudflared.service
    systemctl start xray.service
  fi

  # 管理脚本
  if [ "$IS_ALPINE" = "1" ]; then
    cat > /opt/suoha/suoha.sh <<'EOF'
#!/bin/bash
while true; do
  if [ $(ps | grep -F cloudflared-linux | grep -v grep | wc -l) -eq 0 ]; then argostatus=stop; else argostatus=running; fi
  if [ $(ps | grep -F xray | grep -v grep | wc -l) -eq 0 ]; then xraystatus=stop; else xraystatus=running; fi
  echo "argo $argostatus"
  echo "xray $xraystatus"
  echo "1.管理TUNNEL"
  echo "2.启动服务"
  echo "3.停止服务"
  echo "4.重启服务"
  echo "5.卸载服务"
  echo "6.查看当前v2ray链接"
  echo "0.退出"
  read -r -p "请选择菜单(默认0): " menu
  menu=${menu:-0}
  if [ "$menu" = "1" ]; then
    clear
    while true; do
      echo "ARGO TUNNEL 当前已经绑定的服务如下"
      /opt/suoha/cloudflared-linux tunnel list
      echo "1.删除TUNNEL"
      echo "0.退出"
      read -r -p "请选择菜单(默认0): " tunneladmin
      tunneladmin=${tunneladmin:-0}
      if [ "$tunneladmin" = "1" ]; then
        read -r -p "请输入要删除的 TUNNEL NAME: " tunnelname
        echo "断开 TUNNEL $tunnelname"
        /opt/suoha/cloudflared-linux tunnel cleanup "$tunnelname"
        echo "删除 TUNNEL $tunnelname"
        /opt/suoha/cloudflared-linux tunnel delete "$tunnelname"
      else
        break
      fi
    done
  elif [ "$menu" = "2" ]; then
    kill -9 $(ps | grep -F xray | grep -v grep | awk '{print $1}') >/dev/null 2>&1
    kill -9 $(ps | grep -F cloudflared-linux | grep -v grep | awk '{print $1}') >/dev/null 2>&1
    /etc/local.d/cloudflared.start >/dev/null 2>&1
    /etc/local.d/xray.start >/dev/null 2>&1
    clear; sleep 1
  elif [ "$menu" = "3" ]; then
    kill -9 $(ps | grep -F xray | grep -v grep | awk '{print $1}') >/dev/null 2>&1
    kill -9 $(ps | grep -F cloudflared-linux | grep -v grep | awk '{print $1}') >/dev/null 2>&1
    clear; sleep 2
  elif [ "$menu" = "4" ]; then
    kill -9 $(ps | grep -F xray | grep -v grep | awk '{print $1}') >/dev/null 2>&1
    kill -9 $(ps | grep -F cloudflared-linux | grep -v grep | awk '{print $1}') >/dev/null 2>&1
    /etc/local.d/cloudflared.start >/dev/null 2>&1
    /etc/local.d/xray.start >/dev/null 2>&1
    clear; sleep 1
  elif [ "$menu" = "5" ]; then
    kill -9 $(ps | grep -F xray | grep -v grep | awk '{print $1}') >/dev/null 2>&1
    kill -9 $(ps | grep -F cloudflared-linux | grep -v grep | awk '{print $1}') >/dev/null 2>&1
    rm -rf /opt/suoha /etc/local.d/cloudflared.start /etc/local.d/xray.start /usr/bin/suoha ~/.cloudflared
    echo "所有服务都卸载完成"
    echo "彻底删除授权记录：访问 https://dash.cloudflare.com/profile/api-tokens 删除 Argo Tunnel API Token"
    exit 0
  elif [ "$menu" = "6" ]; then
    clear; cat /opt/suoha/v2ray.txt
  elif [ "$menu" = "0" ]; then
    echo "退出成功"; exit 0
  fi
done
EOF
  else
    cat > /opt/suoha/suoha.sh <<'EOF'
#!/bin/bash
clear
while true; do
  echo -n "argo "; systemctl is-active cloudflared.service 2>/dev/null
  echo -n "xray "; systemctl is-active xray.service 2>/dev/null
  echo "1.管理TUNNEL"
  echo "2.启动服务"
  echo "3.停止服务"
  echo "4.重启服务"
  echo "5.卸载服务"
  echo "6.查看当前v2ray链接"
  echo "0.退出"
  read -r -p "请选择菜单(默认0): " menu
  menu=${menu:-0}
  if [ "$menu" = "1" ]; then
    clear
    while true; do
      echo "ARGO TUNNEL 当前已经绑定的服务如下"
      /opt/suoha/cloudflared-linux tunnel list
      echo "1.删除TUNNEL"
      echo "0.退出"
      read -r -p "请选择菜单(默认0): " tunneladmin
      tunneladmin=${tunneladmin:-0}
      if [ "$tunneladmin" = "1" ]; then
        read -r -p "请输入要删除的 TUNNEL NAME: " tunnelname
        echo "断开 TUNNEL $tunnelname"
        /opt/suoha/cloudflared-linux tunnel cleanup "$tunnelname"
        echo "删除 TUNNEL $tunnelname"
        /opt/suoha/cloudflared-linux tunnel delete "$tunnelname"
      else
        break
      fi
    done
  elif [ "$menu" = "2" ]; then
    systemctl start cloudflared.service
    systemctl start xray.service
    clear
  elif [ "$menu" = "3" ]; then
    systemctl stop cloudflared.service
    systemctl stop xray.service
    clear
  elif [ "$menu" = "4" ]; then
    systemctl restart cloudflared.service
    systemctl restart xray.service
    clear
  elif [ "$menu" = "5" ]; then
    systemctl stop cloudflared.service
    systemctl stop xray.service
    systemctl disable cloudflared.service
    systemctl disable xray.service
    kill -9 $(ps -ef | grep -F xray | grep -v grep | awk '{print $2}') >/dev/null 2>&1
    kill -9 $(ps -ef | grep -F cloudflared-linux | grep -v grep | awk '{print $2}') >/dev/null 2>&1
    rm -rf /opt/suoha /lib/systemd/system/cloudflared.service /lib/systemd/system/xray.service /usr/bin/suoha ~/.cloudflared
    systemctl --system daemon-reload
    echo "所有服务都卸载完成"
    echo "彻底删除授权记录：访问 https://dash.cloudflare.com/profile/api-tokens 删除 Argo Tunnel API Token"
    exit 0
  elif [ "$menu" = "6" ]; then
    clear; cat /opt/suoha/v2ray.txt
  elif [ "$menu" = "0" ]; then
    echo "退出成功"; exit 0
  fi
done
EOF
  fi

  chmod +x /opt/suoha/suoha.sh
  ln -sf /opt/suoha/suoha.sh /usr/bin/suoha
}

# ---------------------------
# main menu (kept behavior)
# ---------------------------
echo "1. 梭哈模式（无需 Cloudflare 域名，重启会失效）"
echo "2. 安装服务（需要 Cloudflare 域名，重启不失效）"
echo "3. 卸载服务"
echo "4. 清空缓存"
echo "5. 管理服务"
echo "0. 退出脚本"
read -r -p "请选择模式(默认1): " mode
mode=${mode:-1}

if [ "$mode" = "2" ] && [ -f "/usr/bin/suoha" ]; then
  echo "服务已经安装，正在跳转到管理菜单..."
  suoha
  exit 0
fi

case "$mode" in
  1)
    read -r -p "请选择 xray 协议 (默认 1.vmess, 2.vless): " protocol
    protocol=${protocol:-1}
    if [ "$protocol" != "1" ] && [ "$protocol" != "2" ]; then die "请输入正确的 xray 协议"; fi
    read -r -p "请选择 Argo 连接模式 IPv4 或 IPv6 (输入 4 或 6，默认 4): " ips
    ips=${ips:-4}
    if [ "$ips" != "4" ] && [ "$ips" != "6" ]; then die "请输入正确的 Argo 连接模式"; fi
    isp="$(curl -s -"${ips}" https://speed.cloudflare.com/meta | awk -F\" '{print $26"-"$18"-"$30}' | sed -e 's/ /_/g')"

    if [ "$IS_ALPINE" = "1" ]; then
      kill_proc_safe "xray" 1
      kill_proc_safe "cloudflared-linux" 1
    else
      kill_proc_safe "xray" 0
      kill_proc_safe "cloudflared-linux" 0
    fi
    rm -rf xray cloudflared-linux v2ray.txt
    quicktunnel
    ;;
  2)
    read -r -p "请选择 xray 协议 (默认 1.vmess, 2.vless): " protocol
    protocol=${protocol:-1}
    if [ "$protocol" != "1" ] && [ "$protocol" != "2" ]; then die "请输入正确的 xray 协议"; fi
    read -r -p "请选择 Argo 连接模式 IPv4 或 IPv6 (输入 4 或 6，默认 4): " ips
    ips=${ips:-4}
    if [ "$ips" != "4" ] && [ "$ips" != "6" ]; then die "请输入正确的 Argo 连接模式"; fi
    isp="$(curl -s -"${ips}" https://speed.cloudflare.com/meta | awk -F\" '{print $26"-"$18"-"$30}' | sed -e 's/ /_/g')"

    if [ "$IS_ALPINE" = "1" ]; then
      kill_proc_safe "xray" 1
      kill_proc_safe "cloudflared-linux" 1
      rm -rf /opt/suoha /lib/systemd/system/cloudflared.service /lib/systemd/system/xray.service /usr/bin/suoha
    else
      systemctl stop cloudflared.service >/dev/null 2>&1
      systemctl stop xray.service        >/dev/null 2>&1
      systemctl disable cloudflared.service >/dev/null 2>&1
      systemctl disable xray.service        >/dev/null 2>&1
      kill_proc_safe "xray" 0
      kill_proc_safe "cloudflared-linux" 0
      rm -rf /opt/suoha /lib/systemd/system/cloudflared.service /lib/systemd/system/xray.service /usr/bin/suoha
      systemctl --system daemon-reload
    fi
    installtunnel
    cat /opt/suoha/v2ray.txt
    echo "服务安装完成，管理服务请运行命令：suoha"
    ;;
  3)
    if [ "$IS_ALPINE" = "1" ]; then
      kill_proc_safe "xray" 1
      kill_proc_safe "cloudflared-linux" 1
      rm -rf /opt/suoha /lib/systemd/system/cloudflared.service /lib/systemd/system/xray.service /usr/bin/suoha
    else
      systemctl stop cloudflared.service >/dev/null 2>&1
      systemctl stop xray.service        >/dev/null 2>&1
      systemctl disable cloudflared.service >/dev/null 2>&1
      systemctl disable xray.service        >/dev/null 2>&1
      kill_proc_safe "xray" 0
      kill_proc_safe "cloudflared-linux" 0
      rm -rf /opt/suoha /lib/systemd/system/cloudflared.service /lib/systemd/system/xray.service /usr/bin/suoha ~/.cloudflared
      systemctl --system daemon-reload
    fi
    clear
    echo "所有服务都卸载完成"
    echo "彻底删除授权记录：访问 https://dash.cloudflare.com/profile/api-tokens 删除 Argo Tunnel API Token"
    ;;
  4)
    if [ "$IS_ALPINE" = "1" ]; then
      kill_proc_safe "xray" 1
      kill_proc_safe "cloudflared-linux" 1
    else
      kill_proc_safe "xray" 0
      kill_proc_safe "cloudflared-linux" 0
    fi
    rm -rf xray cloudflared-linux v2ray.txt
    echo "清空完成"
    ;;
  5)
    if [ -f "/usr/bin/suoha" ]; then
      suoha
    else
      echo "管理服务未安装，请先安装服务（选择模式 2）"
    fi
    ;;
  0)
    echo "退出成功"; exit 0;;
  *)
    echo "无效选择"; exit 1;;
esac

# end of script
