#!/bin/bash

# ============================================
# serv00 / CT8 / Hostuno  Hysteria2 单节点脚本
# 独立运行，只管理 UDP，不与 00_vl_xhttp.sh 冲突
# ============================================

re="\033[0m"
red="\033[1;91m"
green="\e[1;32m"
yellow="\e[1;33m"
purple="\e[1;35m"
red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }

export LC_ALL=C
HOSTNAME=$(hostname)
USERNAME=$(whoami | tr '[:upper:]' '[:lower:]')

# ===== UUID =====
if [[ -n "${FIXED_UUID}" ]]; then
    if [[ ! "${FIXED_UUID}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ \
       && ! "${FIXED_UUID}" =~ ^[0-9a-fA-F]{32}$ ]]; then
        red "FIXED_UUID 格式无效" >&2
        exit 1
    fi
    export UUID="${FIXED_UUID}"
else
    if command -v md5sum >/dev/null 2>&1; then
        _MD5=$(echo -n "$USERNAME+$HOSTNAME" | md5sum | head -c 32)
    else
        _MD5=$(echo -n "$USERNAME+$HOSTNAME" | md5 -q | head -c 32)
    fi
    export UUID=${UUID:-$(echo "$_MD5" | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')}
    unset _MD5
fi

export SUB_TOKEN=${SUB_TOKEN:-${UUID:0:8}}
export CHAT_ID=${CHAT_ID:-${TELEGRAM_CHAT_ID:-''}}
export BOT_TOKEN=${BOT_TOKEN:-${TELEGRAM_BOT_TOKEN:-''}}
export HY2_PORT=${HY2_PORT:-''}                 # 可手动指定 UDP 端口
export HY2_PASSWORD=${HY2_PASSWORD:-$UUID}

# 域名判断
if [[ "$HOSTNAME" =~ ct8 ]]; then
    CURRENT_DOMAIN="ct8.pl"
elif [[ "$HOSTNAME" =~ hostuno ]]; then
    CURRENT_DOMAIN="useruno.com"
else
    CURRENT_DOMAIN="serv00.net"
fi

WORKDIR="${HOME}/domains/${USERNAME}.${CURRENT_DOMAIN}/logs"
FILE_PATH="${HOME}/domains/${USERNAME}.${CURRENT_DOMAIN}/public_html"
KEEP_PATH="${HOME}/domains/keep.${USERNAME}.${CURRENT_DOMAIN}/public_nodejs"

rm -rf "$WORKDIR" && mkdir -p "$WORKDIR" "$FILE_PATH"
chmod 700 "$WORKDIR" && chmod 755 "$FILE_PATH" >/dev/null 2>&1

# 清理当前用户相关进程（保留 sshd 和 bash）
bash -c 'ps aux | grep $(whoami) | grep -v "sshd\|bash\|grep" | awk "{print \$2}" | xargs -r kill -9 >/dev/null 2>&1' >/dev/null 2>&1

if command -v curl &>/dev/null; then
    COMMAND="curl -sL -o"
elif command -v wget &>/dev/null; then
    COMMAND="wget -qO"
else
    red "Error: neither curl nor wget found"
    exit 1
fi

#############################################
# 1. 只管理 UDP 端口
#############################################
check_udp_port() {
    purple "正在检查/申请 UDP 端口..."
    port_list=$(devil port list 2>/dev/null)
    udp_count=$(echo "$port_list" | grep -c "udp" || true)

    if [[ -n "$HY2_PORT" ]]; then
        result=$(devil port add udp "$HY2_PORT" 2>&1)
        if [[ $result == *"Ok"* ]] || echo "$port_list" | grep -q "$HY2_PORT.*udp"; then
            green "使用指定 UDP 端口: $HY2_PORT"
            PORT=$HY2_PORT
        else
            red "指定端口 $HY2_PORT 添加失败，请换一个或留空自动申请"
            exit 1
        fi
    else
        if [[ $udp_count -ge 1 ]]; then
            PORT=$(echo "$port_list" | awk '/udp/ {print $1}' | head -n1)
            green "使用已有 UDP 端口: $PORT"
        else
            while true; do
                PORT=$(shuf -i 10000-65535 -n 1)
                result=$(devil port add udp $PORT 2>&1)
                if [[ $result == *"Ok"* ]]; then
                    green "已申请新 UDP 端口: $PORT"
                    break
                else
                    yellow "端口 $PORT 不可用，重试中..."
                fi
            done
        fi
    fi
    export PORT
    purple "Hysteria2 将使用 UDP 端口: $PORT"
}
check_udp_port

#############################################
# 2. 下载官方 FreeBSD 二进制
#############################################
ARCH=$(uname -m)
case "$ARCH" in
    arm|arm64|aarch64) HY2_BIN_NAME="hysteria-freebsd-arm64" ;;
    *)                 HY2_BIN_NAME="hysteria-freebsd-amd64" ;;
esac

HY2_URL="https://github.com/apernet/hysteria/releases/latest/download/${HY2_BIN_NAME}"
HY2_BIN="$WORKDIR/hy2"

purple "正在下载官方 Hysteria2 ($HY2_BIN_NAME)..."
if $COMMAND "$HY2_BIN" "$HY2_URL"; then
    chmod +x "$HY2_BIN"
    # 简单校验
    if ! "$HY2_BIN" version >/dev/null 2>&1; then
        red "下载的二进制无法运行，请检查网络或手动下载"
        exit 1
    fi
    green "下载成功: $($HY2_BIN version | head -n1)"
else
    red "下载失败: $HY2_URL"
    exit 1
fi

#############################################
# 3. 生成自签证书 + 配置
#############################################
openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout "$WORKDIR/server.key" -out "$WORKDIR/server.crt" \
    -subj "/CN=www.bing.com" -days 36500 >/dev/null 2>&1

# 获取可用 IP
get_ip() {
    IP_LIST=($(devil vhost list 2>/dev/null | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ {print $1}'))
    if [[ ${#IP_LIST[@]} -gt 0 ]]; then
        echo "${IP_LIST[0]}"
    else
        curl -s4 --max-time 5 https://icanhazip.com 2>/dev/null || echo "127.0.0.1"
    fi
}
HOST_IP=$(get_ip)
purple "当前使用 IP: $HOST_IP"

cat > "$WORKDIR/config.yaml" << EOF
listen: ${HOST_IP}:${PORT}

tls:
  cert: ${WORKDIR}/server.crt
  key: ${WORKDIR}/server.key

auth:
  type: password
  password: "${HY2_PASSWORD}"

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520

bandwidth:
  up: 1 gbps
  down: 1 gbps

ignoreClientBandwidth: false
fastOpen: true
EOF

#############################################
# 4. 启动 Hysteria2
#############################################
pkill -f "$HY2_BIN" >/dev/null 2>&1
nohup "$HY2_BIN" server -c "$WORKDIR/config.yaml" > "$WORKDIR/hy2.log" 2>&1 &
sleep 2

if pgrep -f "$HY2_BIN" >/dev/null; then
    green "Hysteria2 启动成功"
else
    red "Hysteria2 启动失败，请查看日志: $WORKDIR/hy2.log"
    exit 1
fi

#############################################
# 5. 生成订阅
#############################################
get_name() {
    if [ "$HOSTNAME" = "s1.ct8.pl" ]; then
        echo "CT8"
    else
        echo "$(echo "$HOSTNAME" | cut -d '.' -f 1)"
    fi
}
NAME="$(get_name)-hy2-${USERNAME}"

cat > "${FILE_PATH}/${SUB_TOKEN}.log" << EOF
hysteria2://${HY2_PASSWORD}@${HOST_IP}:${PORT}/?sni=www.bing.com&alpn=h3&insecure=1#${NAME}
EOF

green "\n===== 节点信息 ====="
cat "${FILE_PATH}/${SUB_TOKEN}.log"
echo
green "订阅链接: https://${USERNAME}.${CURRENT_DOMAIN}/${SUB_TOKEN}.log"
echo

#############################################
# 6. 基础保活（Node.js）
#############################################
install_keepalive() {
    purple "正在配置保活..."
    devil www del keep.${USERNAME}.${CURRENT_DOMAIN} >/dev/null 2>&1
    devil www add keep.${USERNAME}.${CURRENT_DOMAIN} nodejs /usr/local/bin/node18 >/dev/null 2>&1

    mkdir -p "$KEEP_PATH"

    cat > "${KEEP_PATH}/app.js" << 'JS'
const http = require('http');
const { exec } = require('child_process');
const fs = require('fs');
const path = require('path');

const PORT = process.env.PORT || 3000;
const WORKDIR = process.env.WORKDIR || '';

const server = http.createServer((req, res) => {
  if (req.url.includes('/status')) {
    exec('pgrep -f "hysteria|hy2"', (err, stdout) => {
      res.writeHead(200, {'Content-Type': 'text/plain'});
      res.end(stdout ? 'running' : 'stopped');
    });
  } else {
    res.writeHead(200, {'Content-Type': 'text/plain'});
    res.end('hy2 keepalive ok');
  }
});

server.listen(PORT, () => {
  console.log(`Keepalive listening on ${PORT}`);
});
JS

    cat > "${KEEP_PATH}/.env" << EOF
UUID=${UUID}
HY2_PASSWORD=${HY2_PASSWORD}
SUB_TOKEN=${SUB_TOKEN}
PORT=${PORT}
HOST_IP=${HOST_IP}
WORKDIR=${WORKDIR}
CHAT_ID=${CHAT_ID}
BOT_TOKEN=${BOT_TOKEN}
EOF

    chmod 600 "${KEEP_PATH}/.env"
    cd "$KEEP_PATH" && npm install dotenv --silent >/dev/null 2>&1 || true

    devil www restart keep.${USERNAME}.${CURRENT_DOMAIN} >/dev/null 2>&1
    green "保活已配置: keep.${USERNAME}.${CURRENT_DOMAIN}"
}
install_keepalive

#############################################
# 7. Telegram 通知（可选）
#############################################
if [[ -n "$CHAT_ID" && -n "$BOT_TOKEN" ]]; then
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d chat_id="${CHAT_ID}" \
        --data-urlencode text="✅ ${NAME} Hysteria2 部署完成
端口: ${PORT}
订阅: https://${USERNAME}.${CURRENT_DOMAIN}/${SUB_TOKEN}.log" >/dev/null 2>&1
fi

#############################################
# 8. 卸载提示
#############################################
cat > "$WORKDIR/uninstall.sh" << EOF
#!/bin/bash
echo "正在卸载 Hysteria2..."
pkill -f "$WORKDIR/hy2" 2>/dev/null
devil port del udp $PORT 2>/dev/null
devil www del keep.${USERNAME}.${CURRENT_DOMAIN} 2>/dev/null
rm -rf "$WORKDIR" "$FILE_PATH/${SUB_TOKEN}.log"
echo "卸载完成（仅清理本脚本相关内容，未动任何 TCP 端口）"
EOF
chmod +x "$WORKDIR/uninstall.sh"

green "\nHysteria2 单节点安装完成！"
yellow "卸载命令: bash $WORKDIR/uninstall.sh"
yellow "注意：此脚本与 00_vl_xhttp.sh 互斥，请勿同时运行。"
echo