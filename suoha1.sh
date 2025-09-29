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

# 初始化工作目录
init_dir() {
    mkdir -p "$SUOHADIR/xray"
    mkdir -p "$SUOHADIR/cloudflared"
    mkdir -p "$SUOHADIR/logs"
    touch "$SUOHADIR/proxykeepalive.log"
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
        echo "错误: 需要wget或curl"
        exit 1
    fi
}

# 下载Xray
download_xray() {
    echo "正在下载Xray..."
    local arch=$(uname -m)
    case $arch in
        x86_64) arch="64" ;;
        aarch64) arch="arm64-v8a" ;;
        *) echo "不支持的架构: $arch"; exit 1 ;;
    esac
    
    download "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-$arch.zip" "$SUOHADIR/xray.zip"
    unzip -o "$SUOHADIR/xray.zip" -d "$SUOHADIR/xray" >/dev/null
    chmod +x "$SUOHADIR/xray/xray"
    rm -f "$SUOHADIR/xray.zip"
}

# 下载Cloudflared
download_cloudflared() {
    echo "正在下载Cloudflared..."
    local arch=$(uname -m)
    case $arch in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *) echo "不支持的架构: $arch"; exit 1 ;;
    esac
    
    download "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$arch" "$SUOHADIR/cloudflared/cloudflared"
    chmod +x "$SUOHADIR/cloudflared/cloudflared"
}

# 生成Xray配置
generate_config() {
    local uuid=$(cat /proc/sys/kernel/random/uuid)
    local path=$(echo $uuid | cut -d'-' -f1)
    
    cat > "$SUOHADIR/xray/config.json" <<EOF
{
    "log": {
        "loglevel": "warning"
    },
    "inbounds": [
        {
            "listen": "127.0.0.1",
            "port": 10800,
            "protocol": "socks",
            "settings": {
                "auth": "noauth",
                "udp": true
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "vless",
            "settings": {
                "vnext": [
                    {
                        "address": "paso-land-focus-tied.trycloudflare.com",
                        "port": 443,
                        "users": [
                            {
                                "id": "$uuid",
                                "encryption": "none"
                            }
                        ]
                    }
                ]
            },
            "streamSettings": {
                "network": "ws",
                "wsSettings": {
                    "path": "/$path"
                }
            }
        },
        {
            "protocol": "freedom",
            "tag": "direct",
            "settings": {}
        },
        {
            "protocol": "blackhole",
            "tag": "block",
            "settings": {}
        }
    ],
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {
                "type": "field",
                "domain": [
                    "geosite:youtube",
                    "geosite:openai"
                ],
                "outboundTag": "direct"
            },
            {
                "type": "field",
                "ip": [
                    "geoip:private",
                    "geoip:cn"
                ],
                "outboundTag": "direct"
            },
            {
                "type": "field",
                "domain": [
                    "geosite:category-ads-all"
                ],
                "outboundTag": "block"
            }
        ]
    }
}
EOF

    # 保存UUID和路径
    echo "$uuid" > "$SUOHADIR/uuid.txt"
    echo "$path" > "$SUOHADIR/path.txt"
}

# 启动服务
start_service() {
    # 检查必要文件
    if [ ! -f "$SUOHADIR/xray/xray" ]; then
        download_xray
    fi
    
    if [ ! -f "$SUOHADIR/cloudflared/cloudflared" ]; then
        download_cloudflared
    fi
    
    if [ ! -f "$SUOHADIR/xray/config.json" ]; then
        generate_config
    fi
    
    # 启动Cloudflared
    nohup "$SUOHADIR/cloudflared/cloudflared" tunnel --url http://localhost:8080 --logfile "$SUOHADIR/logs/cloudflared.log" >/dev/null 2>&1 &
    echo $! > "$SUOHADIR/cloudflared.pid"
    
    # 启动Xray
    nohup "$SUOHADIR/xray/xray" run -c "$SUOHADIR/xray/config.json" >/dev/null 2>&1 &
    echo $! > "$SUOHADIR/xray.pid"
    
    # 等待服务启动
    sleep 5
    
    # 获取连接信息
    local uuid=$(cat "$SUOHADIR/uuid.txt")
    local path=$(cat "$SUOHADIR/path.txt")
    local domain=$(grep -oP 'hostname=\K[^ ]+' "$SUOHADIR/logs/cloudflared.log" | tail -1)
    
    if [ -z "$domain" ]; then
        domain="paso-land-focus-tied.trycloudflare.com"
    fi
    
    # 显示连接信息
    echo -e "\n当前链接:"
    echo "VLESS链接（含YouTube和ChatGPT分流）"
    echo ""
    echo "vless://$uuid@$domain:443?encryption=none&security=none&type=ws&host=$domain&path=/$path#X-荷兰"
    echo ""
    echo "非TLS端口: 2052/2082/2086/2095/8080/8880"
}

# 停止服务
stop_service() {
    # 停止Xray
    if [ -f "$SUOHADIR/xray.pid" ]; then
        kill $(cat "$SUOHADIR/xray.pid") 2>/dev/null
        rm -f "$SUOHADIR/xray.pid"
    fi
    
    # 停止Cloudflared
    if [ -f "$SUOHADIR/cloudflared.pid" ]; then
        kill $(cat "$SUOHADIR/cloudflared.pid") 2>/dev/null
        rm -f "$SUOHADIR/cloudflared.pid"
    fi
    
    # 停止保活服务
    if [ -f "$SUOHADIR/keepalive.pid" ]; then
        kill $(cat "$SUOHADIR/keepalive.pid") 2>/dev/null
        rm -f "$SUOHADIR/keepalive.pid"
    fi
    
    echo "服务已停止"
}

# 查看状态
check_status() {
    # 检查Xray
    if [ -f "$SUOHADIR/xray.pid" ] && kill -0 $(cat "$SUOHADIR/xray.pid") 2>/dev/null; then
        echo "xray: 运行中 (PID: $(cat "$SUOHADIR/xray.pid"))"
    else
        echo "xray: 已停止"
    fi
    
    # 检查Cloudflared
    if [ -f "$SUOHADIR/cloudflared.pid" ] && kill -0 $(cat "$SUOHADIR/cloudflared.pid") 2>/dev/null; then
        echo "cloudflared: 运行中 (PID: $(cat "$SUOHADIR/cloudflared.pid"))"
    else
        echo "cloudflared: 已停止"
    fi
    
    # 检查保活服务
    if [ -f "$SUOHADIR/keepalive.pid" ] && kill -0 $(cat "$SUOHADIR/keepalive.pid") 2>/dev/null; then
        echo "保活守护: 运行中 (PID: $(cat "$SUOHADIR/keepalive.pid"))"
    else
        echo "保活守护: 已停止"
    fi
}

# 清理文件
clean_files() {
    stop_service
    rm -rf "$SUOHADIR/xray"
    rm -rf "$SUOHADIR/cloudflared"
    rm -f "$SUOHADIR/xray.zip"
    rm -f "$SUOHADIR/uuid.txt"
    rm -f "$SUOHADIR/path.txt"
    rm -f "$SUOHADIR/proxykeepalive.log"
    echo "文件已清理"
}

# 保活服务
keepalive_service() {
    if [ -f "$SUOHADIR/keepalive.pid" ] && kill -0 $(cat "$SUOHADIR/keepalive.pid") 2>/dev/null; then
        echo "正在停止保活功能..."
        kill $(cat "$SUOHADIR/keepalive.pid")
        rm -f "$SUOHADIR/keepalive.pid"
        echo "保活功能已停止"
    else
        echo "正在启动保活功能..."
        
        # 检查必要文件
        if [ ! -f "$SUOHADIR/xray/xray" ] || [ ! -f "$SUOHADIR/cloudflared/cloudflared" ]; then
            echo "错误: 请先启动服务 (选项1)"
            return 1
        fi
        
        # 创建保活脚本
        cat > "$SUOHADIR/keepalive.sh" << 'EOF'
#!/bin/bash
SUOHADIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGFILE="$SUOHADIR/proxykeepalive.log"

while true; do
    # 检查Xray
    if [ ! -f "$SUOHADIR/xray.pid" ] || ! kill -0 $(cat "$SUOHADIR/xray.pid") 2>/dev/null; then
        echo "$(date): Xray进程不存在，正在重启..." >> "$LOGFILE"
        nohup "$SUOHADIR/xray/xray" run -c "$SUOHADIR/xray/config.json" >/dev/null 2>&1 &
        echo $! > "$SUOHADIR/xray.pid"
    fi
    
    # 检查Cloudflared
    if [ ! -f "$SUOHADIR/cloudflared.pid" ] || ! kill -0 $(cat "$SUOHADIR/cloudflared.pid") 2>/dev/null; then
        echo "$(date): Cloudflared进程不存在，正在重启..." >> "$LOGFILE"
        nohup "$SUOHADIR/cloudflared/cloudflared" tunnel --url http://localhost:8080 --logfile "$SUOHADIR/logs/cloudflared.log" >/dev/null 2>&1 &
        echo $! > "$SUOHADIR/cloudflared.pid"
    fi
    
    sleep 10
done
EOF
        
        chmod +x "$SUOHADIR/keepalive.sh"
        
        # 启动保活服务
        nohup "$SUOHADIR/keepalive.sh" >> "$SUOHADIR/proxykeepalive.log" 2>&1 &
        echo $! > "$SUOHADIR/keepalive.pid"
        
        # 等待保活服务启动
        sleep 2
        
        # 检查保活服务是否成功启动
        if [ -f "$SUOHADIR/keepalive.pid" ] && kill -0 $(cat "$SUOHADIR/keepalive.pid") 2>/dev/null; then
            echo "保活功能已启动 (PID: $(cat "$SUOHADIR/keepalive.pid"))"
        else
            echo "错误: 保活功能启动失败，请检查日志: $SUOHADIR/proxykeepalive.log"
            return 1
        fi
    fi
}

# 主菜单
main_menu() {
    while true; do
        echo -e "\n1. 启动服务（含YouTube和ChatGPT分流）"
        echo "2. 停止服务"
        echo "3. 查看状态"
        echo "4. 清理文件"
        echo "5. 切换保活功能（启动/关闭）"
        echo "0. 退出"
        
        read -p "请选择(默认1): " choice
        choice=${choice:-1}
        
        case $choice in
            1) 
                init_dir
                start_service
                check_status
                ;;
            2) 
                stop_service
                ;;
            3) 
                check_status
                ;;
            4) 
                clean_files
                ;;
            5) 
                keepalive_service
                check_status
                ;;
            0) 
                exit 0
                ;;
            *) 
                echo "无效选择"
                ;;
        esac
    done
}

# 初始化工作目录
init_dir

# 启动主菜单
main_menu
