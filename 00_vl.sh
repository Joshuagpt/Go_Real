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
export UUID=${UUID:-$(echo -n "$USERNAME+$HOSTNAME" | md5sum | head -c 32 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')}
export NEZHA_SERVER=${NEZHA_SERVER:-''}   
export NEZHA_PORT=${NEZHA_PORT:-''}    
export NEZHA_KEY=${NEZHA_KEY:-''}           
export ARGO_DOMAIN=${ARGO_DOMAIN:-''}       
export ARGO_AUTH=${ARGO_AUTH:-''}           
export CFIP=${CFIP:-'ali.ztyawc.de'}      
export CFPORT=${CFPORT:-'443'}               
export SUB_TOKEN=${SUB_TOKEN:-${UUID:0:8}}
export CHAT_ID=${CHAT_ID:-''} 
export BOT_TOKEN=${BOT_TOKEN:-''} 
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
rm -rf "$WORKDIR" "$FILE_PATH" && mkdir -p "$WORKDIR" "$FILE_PATH" && chmod 777 "$WORKDIR" "$FILE_PATH" >/dev/null 2>&1
bash -c 'ps aux | grep $(whoami) | grep -v "sshd\|bash\|grep" | awk "{print \$2}" | xargs -r kill -9 >/dev/null 2>&1' >/dev/null 2>&1
command -v curl &>/dev/null && COMMAND="curl -so" || command -v wget &>/dev/null && COMMAND="wget -qO" || { red "Error: neither curl nor wget found, please install one of them." >&2; exit 1; }

check_port () {
  clear
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
  purple "vless-argo使用tcp端口: $tcp_port1"
}
check_port

argo_configure() {
  if [[ -z $ARGO_AUTH || -z $ARGO_DOMAIN ]]; then
    green "ARGO_DOMAIN or ARGO_AUTH is empty,use quick tunnel"
    return
  fi

  if [[ $ARGO_AUTH =~ TunnelSecret ]]; then
    echo $ARGO_AUTH > tunnel.json
    cat > tunnel.yml << EOF
tunnel: $(cut -d\" -f12 <<< "$ARGO_AUTH")
credentials-file: tunnel.json
protocol: http2

ingress:
  - hostname: $ARGO_DOMAIN
    service: http://localhost:$PORT
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
  else
    yellow "当前使用的是token,请在cloudflare后台设置隧道端口为${purple}${PORT}${re}"
  fi
}
argo_configure
wait

ARCH=$(uname -m) && DOWNLOAD_DIR="." && mkdir -p "$DOWNLOAD_DIR" && FILE_INFO=()
if [ "$ARCH" == "arm" ] || [ "$ARCH" == "arm64" ] || [ "$ARCH" == "aarch64" ]; then
    BASE_URL="https://github.com/eooce/test/releases/download/freebsd-arm64"
elif [ "$ARCH" == "amd64" ] || [ "$ARCH" == "x86_64" ] || [ "$ARCH" == "x86" ]; then
    BASE_URL="https://github.com/eooce/test/releases/download/freebsd"
else
    echo "Unsupported architecture: $ARCH"
    exit 1
fi
FILE_INFO=("$BASE_URL/web web" "$BASE_URL/server bot")
if [ -n "$NEZHA_PORT" ]; then
    FILE_INFO+=("$BASE_URL/npm npm")
else
    FILE_INFO+=("$BASE_URL/v1 php")
    NEZHA_TLS=$(case "${NEZHA_SERVER##*:}" in 443|8443|2096|2087|2083|2053) echo -n tls;; *) echo -n false;; esac)
    cat > "${WORKDIR}/config.yaml" << EOF
client_secret: ${NEZHA_KEY}
debug: false
disable_auto_update: true
disable_command_execute: false
disable_force_update: true
disable_nat: false
disable_send_query: false
gpu: false
insecure_tls: false
ip_report_period: 1800
report_delay: 1
server: ${NEZHA_SERVER}
skip_connection_count: false
skip_procs_count: false
temperature: false
tls: ${NEZHA_TLS}
use_gitee_to_upgrade: false
use_ipv6_country_code: false
uuid: ${UUID}
EOF
fi
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
        curl -L -sS -o "$NEW_FILENAME" "$URL"
        green "Downloading $NEW_FILENAME"
    fi
    chmod +x "$NEW_FILENAME"
    FILE_MAP[$(echo "$entry" | cut -d ' ' -f 2)]="$NEW_FILENAME"
done
wait

generate_config() {
  
  cat > config.json << EOF
{
    "log":{
        "access":"/dev/null",
        "error":"/dev/null",
        "loglevel":"none"
    },
    "inbounds":[
        {
          "tag":"vless-ws",
          "port": ${PORT},
          "listen": "0.0.0.0",
          "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "${UUID}",
                        "flow": ""
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "ws",
                "wsSettings": {
                    "path": "/vless-argo"
                }
            }
        }
    ],
    "dns":{
        "servers":[
            "https+local://8.8.8.8/dns-query"
        ]
    },
    "outbounds": [
        {
          "protocol": "freedom",
          "tag": "direct"
          },
        {
          "protocol": "blackhole",
          "tag": "blocked"
        }
    ] 
}
EOF
}
generate_config
wait

if [ -e "$(basename ${FILE_MAP[web]})" ]; then
    nohup ./"$(basename ${FILE_MAP[web]})" -c config.json >/dev/null 2>&1 &
    sleep 2
    pgrep -x "$(basename ${FILE_MAP[web]})" > /dev/null && green "$(basename ${FILE_MAP[web]}) is running" || { red "$(basename ${FILE_MAP[web]}) is not running, restarting..."; pkill -x "$(basename ${FILE_MAP[web]})" && nohup ./"$(basename ${FILE_MAP[web]})" -c config.json >/dev/null 2>&1 & sleep 2; purple "$(basename ${FILE_MAP[web]}) restarted"; }
fi

if [ -e "$(basename ${FILE_MAP[bot]})" ]; then
    if [[ $ARGO_AUTH =~ ^[A-Z0-9a-z=]{120,250}$ ]]; then
      args="tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token ${ARGO_AUTH}"
    elif [[ $ARGO_AUTH =~ TunnelSecret ]]; then
      args="tunnel --edge-ip-version auto --config tunnel.yml run"
    else
      args="tunnel --edge-ip-version auto --no-autoupdate --protocol http2 --logfile "${WORKDIR}/boot.log" --loglevel info --url http://localhost:$PORT"
    fi
    nohup ./"$(basename ${FILE_MAP[bot]})" $args >/dev/null 2>&1 &
    sleep 2
    pgrep -x "$(basename ${FILE_MAP[bot]})" > /dev/null && green "$(basename ${FILE_MAP[bot]}) is running" || { red "$(basename ${FILE_MAP[bot]}) is not running, restarting..."; pkill -x "$(basename ${FILE_MAP[bot]})" && nohup ./"$(basename ${FILE_MAP[bot]})" "${args}" >/dev/null 2>&1 & sleep 2; purple "$(basename ${FILE_MAP[bot]}) restarted"; }
fi

if [ -n "$NEZHA_SERVER" ] && [ -n "$NEZHA_PORT" ] && [ -n "$NEZHA_KEY" ]; then
    if [ -e "$(basename ${FILE_MAP[npm]})" ]; then
    tlsPorts=("443" "8443" "2096" "2087" "2083" "2053")
      [[ "${tlsPorts[*]}" =~ "${NEZHA_PORT}" ]] && NEZHA_TLS="--tls" || NEZHA_TLS=""
      export TMPDIR=$(pwd)
      nohup ./"$(basename ${FILE_MAP[npm]})" -s ${NEZHA_SERVER}:${NEZHA_PORT} -p ${NEZHA_KEY} ${NEZHA_TLS} >/dev/null 2>&1 &
      sleep 2
      pgrep -x "$(basename ${FILE_MAP[npm]})" > /dev/null && green "$(basename ${FILE_MAP[npm]}) is running" || { red "$(basename ${FILE_MAP[npm]})" is not running, restarting..."; pkill -f "$(basename ${FILE_MAP[npm]})" && nohup ./"$(basename ${FILE_MAP[npm]})" -s ${NEZHA_SERVER}:${NEZHA_PORT} -p ${NEZHA_KEY} ${NEZHA_TLS} >/dev/null 2>&1 & sleep 2; purple "$(basename ${FILE_MAP[npm]}) restarted"; }
    fi
elif [ -n "$NEZHA_SERVER" ] && [ -n "$NEZHA_KEY" ]; then
    if [ -e "$(basename ${FILE_MAP[php]})" ]; then
      nohup ./"$(basename ${FILE_MAP[php]})" -c "${WORKDIR}/config.yaml" >/dev/null 2>&1 &
      sleep 2
      pgrep -x "$(basename ${FILE_MAP[php]})" > /dev/null && green "$(basename ${FILE_MAP[php]}) is running\e[0m" || { red "$(basename ${FILE_MAP[php]}) is not running, restarting..."; pkill -x "$(basename ${FILE_MAP[php]})" && nohup ./"$(basename ${FILE_MAP[php]})" -s -c "${WORKDIR}/config.yaml" >/dev/null 2>&1 & sleep 2; purple "$(basename ${FILE_MAP[php]}) restarted"; }
    fi
else
    purple "NEZHA variable is empty, skipping running"
fi
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
    purple "正在安装保活服务中,请稍等......"
    devil www del keep.${USERNAME}.${CURRENT_DOMAIN} > /dev/null 2>&1
    devil www add keep.${USERNAME}.${CURRENT_DOMAIN} nodejs /usr/local/bin/node18 > /dev/null 2>&1
    keep_path="$HOME/domains/keep.${USERNAME}.${CURRENT_DOMAIN}/public_nodejs"
    [ -d "$keep_path" ] || mkdir -p "$keep_path"
    app_file_url="https://xray.ssss.nyc.mn/vmess.js"
    $COMMAND "${keep_path}/app.js" "$app_file_url"
    
    cat > ${keep_path}/.env <<EOF
UUID=${UUID}
CFIP=${CFIP}
CFPORT=${CFPORT}
SUB_TOKEN=${SUB_TOKEN}
UPLOAD_URL=${UPLOAD_URL}
TELEGRAM_CHAT_ID=${CHAT_ID}
TELEGRAM_BOT_TOKEN=${BOT_TOKEN}
NEZHA_SERVER=${NEZHA_SERVER}
NEZHA_PORT=${NEZHA_PORT}
NEZHA_KEY=${NEZHA_KEY}
ARGO_DOMAIN=${ARGO_DOMAIN}
ARGO_AUTH=$([[ -z "$ARGO_AUTH" ]] && echo "" || ([[ "$ARGO_AUTH" =~ ^\{.* ]] && echo "'$ARGO_AUTH'" || echo "$ARGO_AUTH"))
EOF
    devil www add ${USERNAME}.${CURRENT_DOMAIN} php > /dev/null 2>&1
    index_url="https://github.com/eooce/Sing-box/releases/download/00/index.html"
    [ -f "${FILE_PATH}/index.html" ] || $COMMAND "${FILE_PATH}/index.html" "$index_url"
    ln -fs /usr/local/bin/node18 ~/bin/node > /dev/null 2>&1
    ln -fs /usr/local/bin/npm18 ~/bin/npm > /dev/null 2>&1
    mkdir -p ~/.npm-global
    npm config set prefix '~/.npm-global'
    echo 'export PATH=~/.npm-global/bin:~/bin:$PATH' >> $HOME/.bash_profile && source $HOME/.bash_profile
    rm -rf $HOME/.npmrc > /dev/null 2>&1
    cd ${keep_path} && npm install dotenv axios --silent > /dev/null 2>&1
    rm $HOME/domains/keep.${USERNAME}.${CURRENT_DOMAIN}/public_nodejs/public/index.html > /dev/null 2>&1
    devil www restart keep.${USERNAME}.${CURRENT_DOMAIN} > /dev/null 2>&1
    if curl -skL "http://keep.${USERNAME}.${CURRENT_DOMAIN}/${USERNAME}" | grep -q "running"; then
        green "\n全自动保活服务安装成功\n"
	      green "所有服务都运行正常,全自动保活任务添加成功\n\n"
        purple "访问 http://keep.${USERNAME}.${CURRENT_DOMAIN}/stop 结束进程\n"
        purple "访问 http://keep.${USERNAME}.${CURRENT_DOMAIN}/list 全部进程列表\n"
        yellow "访问 http://keep.${USERNAME}.${CURRENT_DOMAIN}/${USERNAME} 调起保活程序   备用保活路径: /run  /go  /start\n"
        purple "访问 http://keep.${USERNAME}.${CURRENT_DOMAIN}/status 查看进程状态\n\n"
        purple "如果需要TG通知,在${yellow}https://t.me/laowang_serv00_bot${re}${purple}获取CHAT_ID,并带CHAT_ID环境变量运行${re}\n\n"
    else
        red "\n全自动保活服务安装失败,存在未运行的进程\n访问 ${yellow}http://keep.${USERNAME}.${CURRENT_DOMAIN}/status ${red}检查,建议执行以下命令后重装: \n\ndevil www del ${USERNAME}.${CURRENT_DOMAIN}\ndevil www del keep.${USERNAME}.${CURRENT_DOMAIN}\nrm -rf $HOME/domains/*\n\n${re}"
    fi
}

generate_links() {
  argodomain=$(get_argodomain)
  echo -e "\e[1;32mArgoDomain: \e[1;35m${argodomain}\e[0m\n"
  sleep 1
  get_name() { if [ "$HOSTNAME" = "s1.ct8.pl" ]; then SERVER="CT8"; else SERVER=$(echo "$HOSTNAME" | cut -d '.' -f 1); fi; echo "$SERVER"; }
  NAME=$(get_name)-vless-argo-${USERNAME}
  cat > ${FILE_PATH}/${SUB_TOKEN}_vless.log <<EOF
vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${argodomain}&type=ws&host=${argodomain}&path=%2Fvless-argo%3Fed%3D2560#${NAME}
EOF
  cat ${FILE_PATH}/${SUB_TOKEN}_vless.log
  green "\n订阅连接: https://${USERNAME}.${CURRENT_DOMAIN}/${SUB_TOKEN}_vless.log 适用于V2ranN/Nekobox/Karing/小火箭/sterisand/Loon 等\n" 
  rm -rf config.json fake_useragent_0.2.0.json ${WORKDIR}/boot.log ${WORKDIR}/tunnel.json ${WORKDIR}/tunnel.yml 
  install_keepalive
}
generate_links