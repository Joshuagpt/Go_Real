#!/bin/bash

re="\033[0m"
red="\033[1;91m"
green="\e[1;32m"
yellow="\e[1;33m"
purple="\e[1;35m"
red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }
reading() { read -p "$(red "$1")" "$2"; }
export LC_ALL=C
HOSTNAME=$(hostname)
USERNAME=$(whoami | tr '[:upper:]' '[:lower:]')

# === UUID 模式 ===
if [[ -n "${FIXED_UUID}" ]]; then
    # 仅接受标准 UUID（8-4-4-4-12）或 32 位无连字符十六进制，避免坏值写入 config.json/.env
    if [[ ! "${FIXED_UUID}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ \
       && ! "${FIXED_UUID}" =~ ^[0-9a-fA-F]{32}$ ]]; then
        echo -e "\e[1;91mFIXED_UUID 格式无效：需为标准 UUID 或 32 位十六进制\033[0m" >&2
        exit 1
    fi
    export UUID="${FIXED_UUID}"
else
    # md5sum 不存在时回退到 FreeBSD 的 md5 -q，输出同为 32 位十六进制，UUID 不变
    if command -v md5sum >/dev/null 2>&1; then
        _MD5=$(echo -n "$USERNAME+$HOSTNAME" | md5sum | head -c 32)
    else
        _MD5=$(echo -n "$USERNAME+$HOSTNAME" | md5 -q | head -c 32)
    fi
    export UUID=${UUID:-$(echo "$_MD5" | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')}
    unset _MD5
fi

export ARGO_DOMAIN=${ARGO_DOMAIN:-''}       
export ARGO_AUTH=${ARGO_AUTH:-''}           
export CFIP=${CFIP:-'ali.ztyawc.de'}      
export CFPORT=${CFPORT:-'443'}               
export SUB_TOKEN=${SUB_TOKEN:-${UUID:0:8}}
export ARGO_PROTOCOL=${ARGO_PROTOCOL:-'quic'}
# 保活服务管理接口（/list /stop /restart）的访问令牌，默认沿用 SUB_TOKEN，建议单独设置
export ADMIN_TOKEN=${ADMIN_TOKEN:-${SUB_TOKEN}}
# 下载/重启地址均可用环境变量覆盖，便于固定到指定 tag 或 commit；这些值会写入保活的 .env，重启时保持一致
export XRAY_REPO=${XRAY_REPO:-'https://github.com/Joshuagpt/xray-freebsd/releases/latest/download'}
export CF_REPO=${CF_REPO:-'https://github.com/Joshuagpt/cloudflared-freebsd/releases/latest/download'}
export ALIVE_URL=${ALIVE_URL:-'https://raw.githubusercontent.com/Joshuagpt/Go_Real/main/alive.js'}
export INDEX_URL=${INDEX_URL:-'https://raw.githubusercontent.com/Joshuagpt/Go_Real/main/index.html'}
export RESTART_SCRIPT_URL=${RESTART_SCRIPT_URL:-'https://raw.githubusercontent.com/Joshuagpt/Go_Real/main/00_vl_xhttp.sh'}
# 可选：填写重启脚本的 SHA256，保活重启时校验不一致则拒绝执行
export RESTART_SCRIPT_SHA256=${RESTART_SCRIPT_SHA256:-''}

# === Path 固定（取 UUID 第 9-24 个字符；标准 UUID 格式下首尾为连字符，32 位无连字符格式下为 16 位十六进制）===
XHTTP_PATH=$(echo -n "$UUID" | cut -c 9-24)

# 兼容保活 .env 里的 TELEGRAM_* 变量名
export CHAT_ID=${CHAT_ID:-${TELEGRAM_CHAT_ID:-''}}
export BOT_TOKEN=${BOT_TOKEN:-${TELEGRAM_BOT_TOKEN:-''}}
export UPLOAD_URL=${UPLOAD_URL:-''}

if [[ "$HOSTNAME" =~ ct8 ]]; then
    CURRENT_DOMAIN="ct8.pl"
elif [[ "$HOSTNAME" =~ hostuno ]]; then
    CURRENT_DOMAIN="useruno.com"
else
    CURRENT_DOMAIN="serv00.net"
fi
WORKDIR="${HOME}/domains/${USERNAME}.${CURRENT_DOMAIN}/logs"
FILE_PATH="${HOME}/domains/${USERNAME}.${CURRENT_DOMAIN}/public_html"
rm -rf "$WORKDIR" "$FILE_PATH" && mkdir -p "$WORKDIR" "$FILE_PATH" && chmod 700 "$WORKDIR" && chmod 755 "$FILE_PATH" >/dev/null 2>&1
if [[ "${KEEPALIVE_RESTART}" == "1" ]]; then
    # 由保活进程（alive.js）触发：只清理 xray / cloudflared，不能杀掉保活进程自身
    pkill -f -- '-c config\.json' >/dev/null 2>&1
    pkill -f -- 'tunnel --edge-ip-version' >/dev/null 2>&1
    sleep 1
else
    bash -c 'ps aux | grep $(whoami) | grep -v "sshd\|bash\|grep" | awk "{print \$2}" | xargs -r kill -9 >/dev/null 2>&1' >/dev/null 2>&1
fi
if command -v curl &>/dev/null; then
    COMMAND="curl -so"
elif command -v wget &>/dev/null; then
    COMMAND="wget -qO"
else
    red "Error: neither curl nor wget found, please install one of them." >&2
    exit 1
fi

check_port () {
  clear 2>/dev/null || true
  purple "正在安装中,请稍等..."
  port_list=$(devil port list)
  tcp_ports=$(echo "$port_list" | grep -c "tcp")
  udp_ports=$(echo "$port_list" | grep -c "udp")

  if [[ $tcp_ports -lt 1 ]]; then
      red "没有可用的TCP端口,正在调整..."
      if [[ $udp_ports -ge 3 ]]; then
          udp_port_to_delete=$(echo "$port_list" | awk '/udp/ {print $1}' | head -n 1)
          devil port del udp $udp_port_to_delete
          green "已删除udp端口: $udp_port_to_delete"
      fi

      while true; do
          tcp_port=$(shuf -i 10000-65535 -n 1)
          result=$(devil port add tcp $tcp_port 2>&1)
          if [[ $result == *"Ok"* ]]; then
              green "已添加TCP端口: $tcp_port"
              tcp_port1=$tcp_port
              break
          else
              yellow "端口 $tcp_port 不可用，尝试其他端口..."
          fi
      done

      green "端口已调整完成, 将断开SSH连接, 请重新连接SSH并重新执行脚本"
      devil binexec on >/dev/null 2>&1
      kill -9 $(ps -o ppid= -p $$) >/dev/null 2>&1
  else
      tcp_ports=$(echo "$port_list" | awk '/tcp/ {print $1}')
      tcp_port1=$(echo "$tcp_ports" | sed -n '1p')
  fi

  export PORT=$tcp_port1
  purple "使用tcp端口: $tcp_port1"
}
check_port

argo_configure() {
  if [[ -z $ARGO_AUTH || -z $ARGO_DOMAIN ]]; then
    green "ARGO_DOMAIN or ARGO_AUTH is empty,use quick tunnel"
    return
  fi

  if [[ $ARGO_AUTH =~ TunnelSecret ]]; then
    _old_umask=$(umask); umask 077   # 凭据文件仅属主可读写
    printf '%s' "$ARGO_AUTH" > tunnel.json
    cat > tunnel.yml << EOF
tunnel: $(cut -d\" -f12 <<< "$ARGO_AUTH")
credentials-file: tunnel.json
protocol: ${ARGO_PROTOCOL}

ingress:
  - hostname: $ARGO_DOMAIN
    service: http://localhost:$PORT
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
    umask "$_old_umask"
  else
    yellow "当前使用的是token,请在云flare后台设置隧道端口为${purple}${PORT}${re}"
  fi
}
argo_configure
wait

ARCH=$(uname -m) && DOWNLOAD_DIR="." && mkdir -p "$DOWNLOAD_DIR" && FILE_INFO=()

MY_REPO="${CF_REPO}"
case "$ARCH" in
  arm|arm64|aarch64) BOT_URL="$MY_REPO/cloudflared-freebsd-arm64" ;;
  *) BOT_URL="$MY_REPO/cloudflared-freebsd-amd64" ;;
esac
# XRAY_REPO 已在文件开头由环境变量定义
case "$ARCH" in
  arm|arm64|aarch64) XRAY_ASSET="xray-freebsd-arm64" ;;
  *) XRAY_ASSET="xray-freebsd-amd64" ;;
esac
FILE_INFO=("$XRAY_REPO/$XRAY_ASSET web" "$BOT_URL bot")

declare -A FILE_MAP
generate_random_name() {
    local chars=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890
    local name=""
    for i in {1..6}; do
        name="$name${chars:RANDOM%${#chars}:1}"
    done
    echo "$name"
}

for entry in "${FILE_INFO[@]}"; do
    URL=$(echo "$entry" | cut -d ' ' -f 1)
    RANDOM_NAME=$(generate_random_name)
    NEW_FILENAME="$DOWNLOAD_DIR/$RANDOM_NAME"
    if [ -e "$NEW_FILENAME" ]; then
        green "$NEW_FILENAME already exists, Skipping download"
    else
        if curl -fL -sS -o "$NEW_FILENAME" "$URL"; then
            green "Downloading $NEW_FILENAME"
        else
            KEY=$(echo "$entry" | cut -d ' ' -f 2)
            rm -f "$NEW_FILENAME"
            red "下载失败: $URL"
            exit 1
        fi
    fi
    chmod +x "$NEW_FILENAME"
    FILE_MAP[$(echo "$entry" | cut -d ' ' -f 2)]="$NEW_FILENAME"
done
wait

WEB_BIN="$(basename ${FILE_MAP[web]})"
if ! curl -fL -sS -o SHA256SUMS "$XRAY_REPO/SHA256SUMS"; then
    red "SHA256SUMS 下载失败: $XRAY_REPO/SHA256SUMS"
    exit 1
fi
WANT_SUM=$(awk -v f="$XRAY_ASSET" '$2==f {print $1}' SHA256SUMS)
if command -v sha256sum >/dev/null 2>&1; then
    GOT_SUM=$(sha256sum "$WEB_BIN" | awk '{print $1}')
else
    GOT_SUM=$(sha256 -q "$WEB_BIN")
fi
rm -f SHA256SUMS
if [ -z "$WANT_SUM" ] || [ "$WANT_SUM" != "$GOT_SUM" ]; then
    red "xray 校验失败 (期望: ${WANT_SUM:-空}, 实际: ${GOT_SUM:-空})"
    exit 1
fi
if ! "./$WEB_BIN" version >/dev/null 2>&1; then
    red "xray 无法运行，请检查: $XRAY_REPO/$XRAY_ASSET"
    exit 1
fi
green "$("./$WEB_BIN" version | head -n 1)"

# cloudflared：发布页提供 SHA256SUMS 时进行校验；没有则提示并继续
BOT_BIN="$(basename ${FILE_MAP[bot]})"
BOT_ASSET="${BOT_URL##*/}"
if curl -fL -sS -o SHA256SUMS_BOT "$MY_REPO/SHA256SUMS" 2>/dev/null; then
    BOT_WANT=$(awk -v f="$BOT_ASSET" '$2==f {print $1}' SHA256SUMS_BOT)
    if command -v sha256sum >/dev/null 2>&1; then
        BOT_GOT=$(sha256sum "$BOT_BIN" | awk '{print $1}')
    else
        BOT_GOT=$(sha256 -q "$BOT_BIN")
    fi
    rm -f SHA256SUMS_BOT
    if [ -n "$BOT_WANT" ]; then
        if [ "$BOT_WANT" != "$BOT_GOT" ]; then
            red "cloudflared 校验失败 (期望: ${BOT_WANT}, 实际: ${BOT_GOT:-空})"
            exit 1
        fi
    else
        yellow "SHA256SUMS 中没有 ${BOT_ASSET} 的条目，跳过 cloudflared 校验"
    fi
else
    rm -f SHA256SUMS_BOT
    yellow "未找到 cloudflared 的 SHA256SUMS，跳过校验"
fi

if [ ! -s "$(basename ${FILE_MAP[bot]})" ] || ! "./$(basename ${FILE_MAP[bot]})" --version >/dev/null 2>&1; then
    red "cloudflared 下载或运行失败，请检查: $BOT_URL"
    exit 1
fi

generate_config() {
  cat > config.json << EOF
{
    "log":{"access":"/dev/null","error":"/dev/null","loglevel":"none"},
    "inbounds":[
        {
          "tag":"xhttp-in",
          "port": ${PORT},
          "listen": "127.0.0.1",
          "protocol": "vless",
            "settings": {
                "clients": [{"id": "${UUID}", "flow": ""}],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "xhttp",
                "xhttpSettings": {
                    "path": "/${XHTTP_PATH}",
                    "mode": "auto"
                }
            },
            "sniffing": {"enabled": true,"destOverride":["http","tls","quic"],"metadataOnly":false}
        }
    ],
    "dns":{"servers":["https+local://8.8.8.8/dns-query"]},
    "outbounds": [
        {"protocol": "freedom","tag": "direct"},
        {"protocol": "blackhole","tag": "blocked"}
    ] 
}
EOF
}
generate_config
wait

if [ -e "$(basename ${FILE_MAP[web]})" ]; then
    nohup ./"$(basename ${FILE_MAP[web]})" run -c config.json >/dev/null 2>&1 &
    sleep 2
    pgrep -x "$(basename ${FILE_MAP[web]})" > /dev/null && green "$(basename ${FILE_MAP[web]}) is running" || { red "$(basename ${FILE_MAP[web]}) is not running, restarting..."; pkill -x "$(basename ${FILE_MAP[web]})" && nohup ./"$(basename ${FILE_MAP[web]})" run -c config.json >/dev/null 2>&1 & sleep 2; purple "$(basename ${FILE_MAP[web]}) restarted"; }
fi

if [ -e "$(basename ${FILE_MAP[bot]})" ]; then
    if [[ $ARGO_AUTH =~ ^[A-Z0-9a-z=]{120,250}$ ]]; then
      args="tunnel --edge-ip-version auto --no-autoupdate --protocol ${ARGO_PROTOCOL} run --token ${ARGO_AUTH}"
    elif [[ $ARGO_AUTH =~ TunnelSecret ]]; then
      args="tunnel --edge-ip-version auto --config tunnel.yml run"
    else
      args="tunnel --edge-ip-version auto --no-autoupdate --protocol ${ARGO_PROTOCOL} --logfile ${WORKDIR}/boot.log --loglevel info --url http://localhost:$PORT"
    fi
    nohup ./"$(basename ${FILE_MAP[bot]})" $args >/dev/null 2>&1 &
    sleep 2
    pgrep -x "$(basename ${FILE_MAP[bot]})" > /dev/null && green "$(basename ${FILE_MAP[bot]}) is running" || { red "$(basename ${FILE_MAP[bot]}) is not running, restarting..."; pkill -x "$(basename ${FILE_MAP[bot]})" && nohup ./"$(basename ${FILE_MAP[bot]})" $args >/dev/null 2>&1 & sleep 2; purple "$(basename ${FILE_MAP[bot]}) restarted"; }
fi

"./$(basename ${FILE_MAP[bot]})" --version
for key in "${!FILE_MAP[@]}"; do
    if [ -e "$(basename ${FILE_MAP[$key]})" ]; then
        rm -rf "$(basename ${FILE_MAP[$key]})" >/dev/null 2>&1
    fi
done

get_argodomain() {
  if [[ -n $ARGO_AUTH ]]; then
    echo "$ARGO_DOMAIN"
  else
    local retry=0
    local max_retries=6
    local argodomain=""
    while [[ $retry -lt $max_retries ]]; do
      ((retry++))
      argodomain=$(grep -oE 'https://[[:alnum:]+\.-]+\.trycloudflare\.com' "${WORKDIR}/boot.log" | sed 's@https://@@') 
      if [[ -n $argodomain ]]; then
        break
      fi
      sleep 1
    done
    echo "$argodomain"
  fi
}

install_keepalive () {
    if [[ "${KEEPALIVE_RESTART}" == "1" ]]; then
        # 由保活进程自身触发的重启：不删除/重建保活站点（否则会把自己杀掉），只补齐首页
        [ -f "${FILE_PATH}/index.html" ] || $COMMAND "${FILE_PATH}/index.html" "$INDEX_URL"
        green "保活进程仍在运行，已跳过保活服务重装"
        return 0
    fi
    purple "正在安装保活服务中,请稍等......"
    devil www del keep.${USERNAME}.${CURRENT_DOMAIN} > /dev/null 2>&1
    devil www add keep.${USERNAME}.${CURRENT_DOMAIN} nodejs /usr/local/bin/node18 > /dev/null 2>&1
    keep_path="$HOME/domains/keep.${USERNAME}.${CURRENT_DOMAIN}/public_nodejs"
    [ -d "$keep_path" ] || mkdir -p "$keep_path"
    app_file_url="$ALIVE_URL"
    $COMMAND "${keep_path}/app.js" "$app_file_url"
    if [ ! -s "${keep_path}/app.js" ] || ! /usr/local/bin/node18 --check "${keep_path}/app.js" >/dev/null 2>&1; then
        red "alive.js 下载失败或语法校验未通过，请检查: $app_file_url"
        return 1
    fi
    
    cat > ${keep_path}/.env <<EOF
UUID=${UUID}
CFIP=${CFIP}
CFPORT=${CFPORT}
SUB_TOKEN=${SUB_TOKEN}
UPLOAD_URL=${UPLOAD_URL}
TELEGRAM_CHAT_ID=${CHAT_ID}
TELEGRAM_BOT_TOKEN=${BOT_TOKEN}
ARGO_DOMAIN=${ARGO_DOMAIN}
ARGO_AUTH=$([[ -z "$ARGO_AUTH" ]] && echo "" || ([[ "$ARGO_AUTH" =~ ^\{.* ]] && echo "'$ARGO_AUTH'" || echo "$ARGO_AUTH"))
ARGO_PROTOCOL=${ARGO_PROTOCOL}
XHTTP_PATH=${XHTTP_PATH}
ADMIN_TOKEN=${ADMIN_TOKEN}
XRAY_REPO=${XRAY_REPO}
CF_REPO=${CF_REPO}
ALIVE_URL=${ALIVE_URL}
INDEX_URL=${INDEX_URL}
RESTART_SCRIPT_URL=${RESTART_SCRIPT_URL}
RESTART_SCRIPT_SHA256=${RESTART_SCRIPT_SHA256}
EOF
    chmod 600 "${keep_path}/.env"
    devil www add ${USERNAME}.${CURRENT_DOMAIN} php > /dev/null 2>&1
    index_url="$INDEX_URL"
    [ -f "${FILE_PATH}/index.html" ] || $COMMAND "${FILE_PATH}/index.html" "$index_url"
    ln -fs /usr/local/bin/node18 ~/bin/node > /dev/null 2>&1
    ln -fs /usr/local/bin/npm18 ~/bin/npm > /dev/null 2>&1
    mkdir -p ~/.npm-global
    npm config set prefix '~/.npm-global'
    grep -qF 'export PATH=~/.npm-global/bin:~/bin:$PATH' $HOME/.bash_profile 2>/dev/null || echo 'export PATH=~/.npm-global/bin:~/bin:$PATH' >> $HOME/.bash_profile
    source $HOME/.bash_profile
    rm -rf $HOME/.npmrc > /dev/null 2>&1
    cd ${keep_path} && npm install dotenv axios --silent > /dev/null 2>&1
    rm $HOME/domains/keep.${USERNAME}.${CURRENT_DOMAIN}/public_nodejs/public/index.html > /dev/null 2>&1
    devil www restart keep.${USERNAME}.${CURRENT_DOMAIN} > /dev/null 2>&1
    if curl -skL "http://keep.${USERNAME}.${CURRENT_DOMAIN}/${USERNAME}" | grep -q "running"; then
        green "\n全自动保活服务安装成功\n"
	      green "所有服务都运行正常,全自动保活任务添加成功\n\n"
        purple "访问 http://keep.${USERNAME}.${CURRENT_DOMAIN}/stop?token=${ADMIN_TOKEN} 结束进程\n"
        purple "访问 http://keep.${USERNAME}.${CURRENT_DOMAIN}/list?token=${ADMIN_TOKEN} 全部进程列表（/stop /list /restart 需带 token）\n"
        yellow "访问 http://keep.${USERNAME}.${CURRENT_DOMAIN}/${USERNAME} 调起保活程序   备用保活路径: /run  /go  /start\n"
        purple "访问 http://keep.${USERNAME}.${CURRENT_DOMAIN}/status 查看进程状态\n\n"
        if [[ -n "$CHAT_ID" && -n "$BOT_TOKEN" ]]; then
            green "Telegram 通知已生效（CHAT_ID: ${CHAT_ID}）\n\n"
        else
            purple "如需开启 Telegram 通知，请在脚本中添加以下变量后重新运行：\n"
            yellow "CHAT_ID 和 BOT_TOKEN\n"
        fi
    else
        red "\n全自动保活服务安装失败,存在未运行的进程\n访问 ${yellow}http://keep.${USERNAME}.${CURRENT_DOMAIN}/status ${red}检查,建议执行以下命令后重装: \n\ndevil www del ${USERNAME}.${CURRENT_DOMAIN}\ndevil www del keep.${USERNAME}.${CURRENT_DOMAIN}\nrm -rf $HOME/domains/*\n\n${re}"
    fi
}

generate_links() {
  argodomain=$(get_argodomain)
  if [[ -z "$argodomain" ]]; then
    rm -rf config.json
    red "未能获取 Argo 域名（quick tunnel 尚未就绪，或 ARGO_DOMAIN 为空），请稍后重新执行脚本"
    exit 1
  fi
  echo -e "\e[1;32mArgoDomain: \e[1;35m${argodomain}\e[0m"
  echo -e "\e[1;32mArgo Protocol: \e[1;35m${ARGO_PROTOCOL}\e[0m"
  echo -e "\e[1;32mXHTTP Path: \e[1;35m/${XHTTP_PATH}\e[0m\n"
  sleep 1
  get_name() { if [ "$HOSTNAME" = "s1.ct8.pl" ]; then SERVER="CT8"; else SERVER=$(echo "$HOSTNAME" | cut -d '.' -f 1); fi; echo "$SERVER"; }
  NAME=$(get_name)-${USERNAME}

  cat > ${FILE_PATH}/${SUB_TOKEN}.log <<EOF
vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${argodomain}&fp=chrome&type=xhttp&host=${argodomain}&path=%2F${XHTTP_PATH}&mode=auto&alpn=h2#${NAME}-H2-Argo
vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${argodomain}&fp=chrome&type=xhttp&host=${argodomain}&path=%2F${XHTTP_PATH}&mode=auto&alpn=h3#${NAME}-H3-Argo
EOF

  cat ${FILE_PATH}/${SUB_TOKEN}.log
  green "\n订阅连接: https://${USERNAME}.${CURRENT_DOMAIN}/${SUB_TOKEN}.log \n" 
  green "节点说明："
  yellow "  1. H2-Argo  →  alpn=h2（更稳）"
  yellow "  2. H3-Argo  →  alpn=h3（客户端到 CF 边缘走 HTTP/3，与隧道协议 ${ARGO_PROTOCOL} 无关，需客户端网络放行 UDP）\n"
  if [[ -z "$ARGO_AUTH" ]]; then
    yellow "注意：当前为 quick tunnel（trycloudflare 临时域名），每次重启域名都会变化，已导入的节点会失效，需重新拉取订阅。长期使用请配置 ARGO_DOMAIN + ARGO_AUTH 固定隧道。\n"
  fi
  rm -rf config.json fake_useragent_0.2.0.json ${WORKDIR}/boot.log ${WORKDIR}/tunnel.json ${WORKDIR}/tunnel.yml 
  install_keepalive
  if [[ -n "$CHAT_ID" && -n "$BOT_TOKEN" ]]; then
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
      -d chat_id="${CHAT_ID}" \
      --data-urlencode text="✅ ${NAME} XHTTP+Argo(${ARGO_PROTOCOL}) 服务已重新部署完成$([[ -z "$ARGO_AUTH" ]] && printf '\n当前 quick tunnel 域名: %s（重启后会变化）' "$argodomain")" >/dev/null 2>&1
  fi
}
generate_links
