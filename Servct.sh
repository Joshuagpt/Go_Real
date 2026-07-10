#!/bin/bash
# ===================================================================
# 统一运行时组件一键部署脚本 —— 共享主机管理专版
# 平台: 仅支持 Serv00/CT8 共享主机环境 (devil 管理)
# 生命周期: install(安装) / re(自适应重装) / update(更新核心) / de(清理卸载) / status(状态审查)
# 保活机制: 内部 crontab 周期巡检 + 运行时访问触发自愈机制
# ===================================================================

# 兜底确保 Bash 环境自举
if [ -z "$BASH_VERSION" ]; then
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    else
        echo "Error: This script requires a bash environment." >&2
        exit 1
    fi
fi

re="\033[0m"
red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }
export LC_ALL=C

# ---------------------------------------------------------------
# 动作指令解析
# ---------------------------------------------------------------
ACTION="${1:-install}"
case "$ACTION" in
    install|re|update|de|status) ;;
    *) red "未知动作: ${ACTION} (支持: install, re, update, status, de)"; exit 1 ;;
esac

# 基础下载工具预检
HAVE_CURL=0; command -v curl >/dev/null 2>&1 && HAVE_CURL=1
HAVE_WGET=0; command -v wget >/dev/null 2>&1 && HAVE_WGET=1
if [ "$HAVE_CURL" = 0 ] && [ "$HAVE_WGET" = 0 ]; then
    red "Error: 缺少必要网络下载组件 (curl 或 wget)，请先安装其中之一"
    exit 1
fi

IS_TTY=0; [ -t 1 ] && IS_TTY=1

# ---------------------------------------------------------------
# 通用健壮性工具闭包
# ---------------------------------------------------------------
fetch_with_retry() {
    local url="$1" out="$2" attempt=0 max_attempts=3
    while [ $attempt -lt $max_attempts ]; do
        attempt=$((attempt + 1))
        if [ "$HAVE_CURL" = 1 ]; then
            if [ "$IS_TTY" = 1 ]; then
                curl -fL --progress-bar --connect-timeout 10 --max-time 120 --retry 2 --retry-delay 2 -o "$out" "$url" && return 0
            else
                curl -fL -sS --connect-timeout 10 --max-time 120 --retry 2 --retry-delay 2 -o "$out" "$url" && return 0
            fi
        else
            if [ "$IS_TTY" = 1 ]; then
                wget -T 10 -t 1 -O "$out" "$url" && return 0
            else
                wget -q -T 10 -t 1 -O "$out" "$url" && return 0
            fi
        fi
        yellow "下载延迟或失败 (第 ${attempt} 次尝试): ${url}，2秒后重试..."
        sleep 2
    done
    red "下载在重试 ${max_attempts} 次后仍然失败: ${url}"
    return 1
}

safe_rm() {
    if [ -z "$RUNTIME_DIR" ] || [ -z "$WORKDIR" ] || [ -z "$FILE_PATH" ] || [ -z "$HOME" ]; then
        red "safe_rm: 关键目录路径存在空变量，拒绝执行危险的通配符删除！"
        return 1
    fi
    local target
    for target in "$@"; do
        case "$target" in
            "$RUNTIME_DIR"|"$RUNTIME_DIR"/*|"$WORKDIR"|"$WORKDIR"/*|"$FILE_PATH"|"$FILE_PATH"/*)
                rm -rf -- "$target"
                ;;
            *)
                yellow "safe_rm: 目标路径 [${target:-空}] 不在沙箱白名单内，已拒绝安全擦除"
                ;;
        esac
    done
}

graceful_kill_pidfile() {
    local pidfile="$1" pid i
    [ -f "$pidfile" ] || return 0
    pid=$(cat "$pidfile" 2>/dev/null)
    [ -z "$pid" ] && return 0
    if kill -0 "$pid" >/dev/null 2>&1; then
        kill "$pid" >/dev/null 2>&1
        for i in 1 2 3 4 5; do
            kill -0 "$pid" >/dev/null 2>&1 || break
            sleep 0.5
        done
        kill -0 "$pid" >/dev/null 2>&1 && kill -9 "$pid" >/dev/null 2>&1
    fi
    rm -f "$pidfile"
}

# ---------------------------------------------------------------
# 平台探测与统一中性路径拓扑规划
# ---------------------------------------------------------------
if ! command -v devil >/dev/null 2>&1; then
    red "环境异常: 未能检测到核心管理套件 devil 命令，此脚本仅支持在 Serv00/CT8 平台部署"
    exit 1
fi

HOSTNAME=$(hostname)
USERNAME=$(whoami | tr '[:upper:]' '[:lower:]')

if [[ "$HOSTNAME" =~ ct8 ]]; then
    CURRENT_DOMAIN="ct8.pl"
elif [[ "$HOSTNAME" =~ hostuno ]]; then
    CURRENT_DOMAIN="useruno.com"
else
    CURRENT_DOMAIN="serv00.net"
fi

# 统一路径与中性抽象变量定义 [满足要求 1 与 4]
WORKDIR="${HOME}/domains/${USERNAME}.${CURRENT_DOMAIN}/logs"
FILE_PATH="${HOME}/domains/${USERNAME}.${CURRENT_DOMAIN}/public_html"
RUNTIME_DIR="${HOME}/.local/share/runtime"
STATE_FILE="${RUNTIME_DIR}/.service.env"

# 统一映射的运行时参数与中性配置文件 [满足要求 2 与 3]
EXEC_ENGINE="${RUNTIME_DIR}/engine"
EXEC_DAEMON="${RUNTIME_DIR}/daemon"
CONF_SERVICE="${RUNTIME_DIR}/service.json"
CONF_RUNTIME="${RUNTIME_DIR}/runtime.json"
CONF_CREDENTIAL="${RUNTIME_DIR}/credential.json"
CONF_TUNNEL="${RUNTIME_DIR}/service.yml"
HEALTH_SCRIPT="${RUNTIME_DIR}/monitor.sh"
HEALTH_STATE="${RUNTIME_DIR}/.monitor.state"
PID_ENGINE="${RUNTIME_DIR}/engine.pid"
PID_DAEMON="${RUNTIME_DIR}/daemon.pid"

# ---------------------------------------------------------------
# 状态持久化与状态读取
# ---------------------------------------------------------------
load_state() {
    [ -f "$STATE_FILE" ] || return 0
    # shellcheck disable=SC1090
    source "$STATE_FILE"
}

save_state() {
    mkdir -p "$RUNTIME_DIR"
    cat > "$STATE_FILE" <<EOF
SAVED_UUID=$(printf '%q' "$UUID")
SAVED_PORT=$(printf '%q' "$PORT")
SAVED_ARGO_DOMAIN=$(printf '%q' "$ARGO_DOMAIN")
SAVED_ARGO_AUTH=$(printf '%q' "$ARGO_AUTH")
SAVED_CFIP=$(printf '%q' "$CFIP")
SAVED_CFPORT=$(printf '%q' "$CFPORT")
SAVED_SUB_TOKEN=$(printf '%q' "$SUB_TOKEN")
SAVED_TG_TOKEN=$(printf '%q' "$TG_TOKEN")
SAVED_TG_ID=$(printf '%q' "$TG_ID")
SAVED_WORKDIR=$(printf '%q' "$WORKDIR")
SAVED_FILE_PATH=$(printf '%q' "$FILE_PATH")
SAVED_WARP=$(printf '%q' "$WARP")
EOF
    chmod 600 "$STATE_FILE" >/dev/null 2>&1
}

# ---------------------------------------------------------------
# 定时任务精确调度清理
# ---------------------------------------------------------------
HEALTH_MARK="runtime_health"

remove_healthcheck_schedule() {
    if command -v crontab >/dev/null 2>&1; then
        ( crontab -l 2>/dev/null | grep -v "$HEALTH_MARK" ) | crontab - 2>/dev/null
    fi
}

# ---------------------------------------------------------------
# 彻底清理与完全卸载模式
# ---------------------------------------------------------------
do_uninstall() {
    purple "正在执行全面清理与卸载任务..."
    remove_healthcheck_schedule
    purple "已稳妥移除周期健康检查计划任务"

    graceful_kill_pidfile "$PID_ENGINE"
    graceful_kill_pidfile "$PID_DAEMON"
    pkill -f "$EXEC_ENGINE" >/dev/null 2>&1
    pkill -f "$EXEC_DAEMON" >/dev/null 2>&1

    devil www del "${USERNAME}.${CURRENT_DOMAIN}" >/dev/null 2>&1
    devil www del "keep.${USERNAME}.${CURRENT_DOMAIN}" >/dev/null 2>&1

    safe_rm "$WORKDIR" "$FILE_PATH" "$RUNTIME_DIR"

    green "所有相关程序资产、私有状态缓存、公共网卡映射及中性配置已彻底移除。"
    green "卸载完成！"
}

if [ "$ACTION" = "de" ]; then
    do_uninstall
    exit 0
fi

# 状态恢复演化
if [ "$ACTION" = "re" ] || [ "$ACTION" = "update" ] || [ "$ACTION" = "status" ]; then
    load_state
fi
[ "$ACTION" = "update" ] && FORCE_REDOWNLOAD=1

# ---------------------------------------------------------------
# 字符串格式化安全过滤与变量预置
# ---------------------------------------------------------------
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

sed_repl_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//&/\\&}"
    s="${s//|/\\|}"
    printf '%s' "$s"
}

export UUID=${UUID:-${SAVED_UUID:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo -n "$USERNAME+$HOSTNAME" | md5sum | head -c 32 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')}}
if ! [[ "$UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    red "UUID 参数校验失败 (非标准 UUID 格式): $UUID"
    exit 1
fi

export ARGO_DOMAIN=${ARGO_DOMAIN:-${SAVED_ARGO_DOMAIN:-''}}
if [ -n "$ARGO_DOMAIN" ] && ! [[ "$ARGO_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]; then
    red "ARGO_DOMAIN 参数校验失败 (非合法域名结构): $ARGO_DOMAIN"
    exit 1
fi

export ARGO_AUTH=${ARGO_AUTH:-${SAVED_ARGO_AUTH:-''}}
export CFIP=${CFIP:-${SAVED_CFIP:-'saas.sin.fan'}}
export CFPORT=${CFPORT:-${SAVED_CFPORT:-'443'}}
export SUB_TOKEN=${SUB_TOKEN:-${SAVED_SUB_TOKEN:-${UUID:0:8}}}
export TG_TOKEN=${TG_TOKEN:-${SAVED_TG_TOKEN:-''}}
export TG_ID=${TG_ID:-${SAVED_TG_ID:-''}}

if [ "$WARP" = "1" ]; then
    export WARP=1
else
    export WARP=0
fi

# ---------------------------------------------------------------
# 审查模式下的中性回显
# ---------------------------------------------------------------
do_status() {
    echo "===================== 容器运行状态及配置审查 ====================="
    if [ ! -f "$STATE_FILE" ]; then
        yellow "未检测到现有部署记录，当前输出将退回默认演算状态。"
    fi
    echo "运行时标识 (UUID)  : ${UUID}"
    echo "本地服务端口 (PORT): ${SAVED_PORT:-<尚未指派>}"
    echo "映射边界域名       : ${ARGO_DOMAIN:-<未配置, 当前采用 Quick 模式分发>}"
    echo "网段中介网关 (CFIP): ${CFIP}:${CFPORT}"
    if [ -n "$TG_TOKEN" ] && [ -n "$TG_ID" ]; then
        green "主动心跳监控       : 已注册活跃 (TG_ID=${TG_ID})"
    else
        echo "主动心跳监控       : 未配置"
    fi
    if [ "$SAVED_WARP" = "1" ]; then
        [ -f "$CONF_RUNTIME" ] && green "辅助出站中继 (WARP): 活跃已就绪" || yellow "辅助出站中继 (WARP): 已申明但缺少凭据"
    else
        echo "辅助出站中继 (WARP): 未启用"
    fi
    echo "---------------------------------------------------------------"
    local name exec_file pid_file
    for name in engine daemon; do
        if [ "$name" = "engine" ]; then pid_file="$PID_ENGINE"; else pid_file="$PID_DAEMON"; fi
        if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file" 2>/dev/null)" >/dev/null 2>&1; then
            green "子组件 [${name}] : 运行中 (PID: $(cat "$pid_file"))"
        else
            red "子组件 [${name}] : 已停止"
        fi
    done
    if [ -f "${FILE_PATH}/${SAVED_SUB_TOKEN:-$SUB_TOKEN}_sync.php" ]; then
        echo "中性配置同步分发口: https://${USERNAME}.${CURRENT_DOMAIN}/${SAVED_SUB_TOKEN:-$SUB_TOKEN}_sync.php"
    fi
    echo "==============================================================="
}

if [ "$ACTION" = "status" ]; then
    do_status
    exit 0
fi

purple "确认执行平台无误: Serv00/CT8 抽象网格隔离层"

STEP_NUM=0
step() {
    STEP_NUM=$((STEP_NUM + 1))
    purple "\n[步骤 ${STEP_NUM}] $1"
}

# ---------------------------------------------------------------
# 环境初始化与安全擦除
# ---------------------------------------------------------------
graceful_kill_pidfile "$PID_ENGINE"
graceful_kill_pidfile "$PID_DAEMON"
safe_rm "$WORKDIR" "$FILE_PATH"
mkdir -p "$WORKDIR" "$FILE_PATH" "$RUNTIME_DIR"
chmod 755 "$WORKDIR" "$FILE_PATH" >/dev/null 2>&1

# ---------------------------------------------------------------
# 独占性 TCP 通讯端口指派
# ---------------------------------------------------------------
check_port() {
  if { [ "$ACTION" = "re" ] || [ "$ACTION" = "update" ]; } && [ -n "$SAVED_PORT" ]; then
      export PORT="$SAVED_PORT"
      purple "承袭上轮既定分配端口: $PORT"
      return
  fi
  clear
  purple "正在轮询并分析宿主机可用端口组..."
  local port_list tcp_ports udp_ports udp_port_to_delete tcp_port result tcp_port1
  port_list=$(devil port list)
  tcp_ports=$(echo "$port_list" | grep -c "tcp")
  udp_ports=$(echo "$port_list" | grep -c "udp")

  if [[ $tcp_ports -lt 1 ]]; then
      red "检测到 TCP 端口配额耗尽，正在自动腾挪低频 UDP 通道配额..."
      if [[ $udp_ports -ge 3 ]]; then
          if [ "$ALLOW_PORT_ADJUST" != "1" ]; then
              red "需要清理一个闲置 UDP 端口以转换配额。请确认无误后添加 ALLOW_PORT_ADJUST=1 变量再次运行此程序。"
              exit 1
          fi
          udp_port_to_delete=$(echo "$port_list" | awk '/udp/ {print $1}' | head -n 1)
          yellow "系统将在 5 秒后强制回收并剥离 UDP 端口: $udp_port_to_delete"
          sleep 5
          devil port del udp $udp_port_to_delete
          green "UDP 端口配额注销成功: $udp_port_to_delete"
      else
          red "UDP 配额基数过低，无法自动闪转腾挪，请登录主控面板手动调拨端口配额！"
          exit 1
      fi
      while true; do
          tcp_port=$(shuf -i 10000-65535 -n 1)
          result=$(devil port add tcp $tcp_port 2>&1)
          if [[ $result == *"Ok"* ]]; then
              green "TCP 基础资源创建成功，分配端口: $tcp_port"
              tcp_port1=$tcp_port
              break
          fi
      done
      devil binexec on >/dev/null 2>&1
      red "端口配额架构转换成功！共享内存隔离需要重置父会话，将在 5 秒后切断当前连接。请重新连接 SSH 并运行本脚本完成安装。"
      sleep 5
      kill -9 $(ps -o ppid= -p $$) >/dev/null 2>&1
  else
      tcp_port1=$(echo "$port_list" | awk '/tcp/ {print $1}' | sed -n '1p')
  fi
  export PORT=$tcp_port1
  purple "组件本地通信映射至端口: $PORT"
}

step "分析分配专有通信信道"
check_port

# ---------------------------------------------------------------
# 边界网关拓扑结构映射
# ---------------------------------------------------------------
detect_argo_mode() {
    if [[ -z $ARGO_AUTH || -z $ARGO_DOMAIN ]]; then
        ARGO_MODE="quick"
    elif [[ $ARGO_AUTH =~ TunnelSecret ]]; then
        ARGO_MODE="tunnelsecret"
    elif [[ $ARGO_AUTH =~ ^[A-Za-z0-9=]{120,250}$ ]]; then
        ARGO_MODE="token"
    else
        red "未知的授权令牌流格式 (非标准 Token 或 JSON 凭证)，请审查 ARGO_AUTH 输入！"
        exit 1
    fi
}

argo_configure() {
  detect_argo_mode
  if [ "$ARGO_MODE" = "quick" ]; then
    green "未配置边界证书与自定义网卡，将启用临时通道 (Quick 模式)"
    return
  fi

  if [ "$ARGO_MODE" = "tunnelsecret" ]; then
    echo "$ARGO_AUTH" > "$CONF_CREDENTIAL"
    local TUNNEL_ID=""
    if command -v python3 >/dev/null 2>&1; then
        TUNNEL_ID=$(python3 -c "import json; print(json.load(open('$CONF_CREDENTIAL'))['TunnelID'])" 2>/dev/null)
    fi
    if [ -z "$TUNNEL_ID" ]; then
        TUNNEL_ID=$(sed -n 's/.*"TunnelID"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONF_CREDENTIAL" 2>/dev/null)
    fi
    if [ -z "$TUNNEL_ID" ]; then
        red "无法从解密缓冲区解析出 TunnelID 关键字段，授权不完整。"
        exit 1
    fi

    cat > "$CONF_TUNNEL" << EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${CONF_CREDENTIAL}
protocol: http2

ingress:
  - hostname: $ARGO_DOMAIN
    service: http://localhost:$PORT
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
  else
    yellow "当前已应用全局 Token 令牌模式，请确保外部平台转发指向本地服务通信端口: ${PORT}"
  fi
}

step "拓扑映射边缘网关策略"
argo_configure

# ---------------------------------------------------------------
# 核心驱动与守护程序资源拉取
# ---------------------------------------------------------------
download_binaries() {
  local ARCH=$(uname -m)
  cd "$RUNTIME_DIR" || exit 1

  local BASE_URL="https://github.com/Joshuagpt/Go_Real/releases/download/v1"
  local WEB_ASSET BOT_ASSET
  if [[ "$ARCH" =~ ^(arm|arm64|aarch64)$ ]]; then
      WEB_ASSET="runtime-arm64"
      BOT_ASSET="serv-arm64"
  else
      WEB_ASSET="runtime"
      BOT_ASSET="serv"
  fi

  if [ -x "$EXEC_ENGINE" ] && [ "$FORCE_REDOWNLOAD" != "1" ]; then
      green "核心驱动模块 [engine] 状态良好，已忽略重复拉取"
  else
      purple "正在检索并拉取服务核心内核驱动 [engine]..."
      fetch_with_retry "${BASE_URL}/${WEB_ASSET}" "$EXEC_ENGINE" || exit 1
      chmod +x "$EXEC_ENGINE"
  fi

  if [ -x "$EXEC_DAEMON" ] && [ "$FORCE_REDOWNLOAD" != "1" ]; then
      green "边缘守卫守护进程 [daemon] 状态良好，已忽略重复拉取"
  else
      purple "正在检索并拉取边缘网关服务守护线程 [daemon]..."
      fetch_with_retry "${BASE_URL}/${BOT_ASSET}" "$EXEC_DAEMON" || exit 1
      chmod +x "$EXEC_DAEMON"
  fi
}

step "校验并组装驱动与守护线程资产"
download_binaries

# ---------------------------------------------------------------
# 辅助出站中继能力预检 (WARP)
# ---------------------------------------------------------------
check_warp_supported() {
    [ "$WARP" = "1" ] || return 0

    purple "正在检验核心驱动是否包含 WireGuard 中继组件特性..."
    local test_conf="${RUNTIME_DIR}/.probe.json" probe_out
    cat > "$test_conf" <<'EOF'
{
  "outbounds": [
    {
      "protocol": "wireguard",
      "tag": "warp-probe",
      "settings": {
        "secretKey": "wIol6i8Wl4Wp+i6PXVXwZBoTr6Ez2FZ3+Rjez7cvvV0=",
        "address": ["172.16.0.2/32"],
        "peers": [
          { "publicKey": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=", "endpoint": "162.159.192.1:2408" }
        ]
      }
    }
  ]
}
EOF
    probe_out=$("$EXEC_ENGINE" -test -c "$test_conf" 2>&1)
    rm -f "$test_conf"

    if echo "$probe_out" | grep -qiE "unknown (outbound )?protocol|not registered|invalid protocol|unknown config"; then
        red "警告: 当前核心驱动未包含内置中继协议栈，自动将其优雅挂起，降级至标准出站形态"
        export WARP=0
        return 1
    fi
    if echo "$probe_out" | grep -qiE "flag provided but not defined|unknown (flag|command)|no such (flag|command)"; then
        red "警告: 核心指令不支持断言校验，出于运行稳定性考量已自动切断中继链路，保障主干线平稳"
        export WARP=0
        return 1
    fi
    green "协议栈特性完整度校验成功！准备测试底层网络层对外界通信端点的直接吞吐率"
}

step "核心特性边界能力检测"
check_warp_supported

# ---------------------------------------------------------------
# 全自动出站中继流控注册 (WARP)
# ---------------------------------------------------------------
warp_register() {
    [ "$WARP" = "1" ] || return 0

    if [ -f "$CONF_RUNTIME" ]; then
        purple "加载现有路由中继凭据缓存，实现资源重用: ${CONF_RUNTIME}"
        return 0
    fi

    purple "当前未检测到活跃的路由中继凭据，正在发起远程云端节点安全握手注册..."

    if ! command -v openssl >/dev/null 2>&1; then
        red "本地 openssl 缺失，无法完成对等体密钥非对称混淆，中继链路强制降级直连"
        export WARP=0; return 1
    fi

    local py_bin=""
    command -v python3 >/dev/null 2>&1 && py_bin="python3"
    if [ -z "$py_bin" ]; then
        red "本地缺少必要高阶解析环境 Python，无法捕获响应报文，中继链路降级"
        export WARP=0; return 1
    fi

    local tmpdir priv_pem priv_key_b64 pub_key_b64
    tmpdir=$(mktemp -d 2>/dev/null || echo "${RUNTIME_DIR}/.reg_tmp")
    mkdir -p "$tmpdir"
    priv_pem="${tmpdir}/priv.pem"
    openssl genpkey -algorithm X25519 -out "$priv_pem" >/dev/null 2>&1
    if [ ! -s "$priv_pem" ]; then
        red "openssl 底层架构不兼容 X25519 特征演化，注册中断"
        rm -rf "$tmpdir"; export WARP=0; return 1
    fi
    priv_key_b64=$(openssl pkey -in "$priv_pem" -outform DER 2>/dev/null | tail -c 32 | base64 | tr -d '\n')
    pub_key_b64=$(openssl pkey -in "$priv_pem" -pubout -outform DER 2>/dev/null | tail -c 32 | base64 | tr -d '\n')
    rm -rf "$tmpdir"
    if [ -z "$priv_key_b64" ] || [ -z "$pub_key_b64" ]; then
        red "对称序列流密钥二次提取出现空数据，中继优雅降级"
        export WARP=0; return 1
    fi

    local reg_resp="${RUNTIME_DIR}/.reg_resp.json" tos_ts body
    tos_ts=$(date -u +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || echo "2026-01-01T00:00:00.000Z")
    body=$(printf '{"key":"%s","tos":"%s","type":"PC","model":"PC","locale":"en_US"}' "$pub_key_b64" "$tos_ts")

    if [ "$HAVE_CURL" = 1 ]; then
        curl -fsSL -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
            -H "Content-Type: application/json" \
            -H "User-Agent: okhttp/3.12.1" \
            -d "$body" -o "$reg_resp" >/dev/null 2>&1
    else
        wget -q --method=POST --header="Content-Type: application/json" \
            --header="User-Agent: okhttp/3.12.1" \
            --body-data="$body" -O "$reg_resp" "https://api.cloudflareclient.com/v0a2158/reg" >/dev/null 2>&1
    fi

    if [ ! -s "$reg_resp" ]; then
        red "向边界服务握手注册未收到回包，可能因网络拦截或UDP受限，中继优雅降级"
        rm -f "$reg_resp"; export WARP=0; return 1
    fi

    local w_id w_token w_ip
    w_id=$($py_bin -c "import json; print(json.load(open('$reg_resp'))['id'])" 2>/dev/null)
    w_token=$($py_bin -c "import json; print(json.load(open('$reg_resp'))['token'])" 2>/dev/null)
    w_ip=$($py_bin -c "import json; print(json.load(open('$reg_resp'))['config']['interface']['addresses']['v4'])" 2>/dev/null)
    rm -f "$reg_resp"

    if [ -z "$w_id" ] || [ -z "$w_token" ]; then
        red "边界服务注册报文提取数据不完整，令牌失效，中继关闭"
        export WARP=0; return 1
    fi

    # 统一命名为中性 runtime.json 配置文件 [满足要求 2]
    cat > "$CONF_RUNTIME" << EOF
{
  "private_key": "${priv_key_b64}",
  "local_address": "${w_ip:-172.16.0.2/32}",
  "peer_public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
  "endpoint": "162.159.192.1:2408",
  "id": "${w_id}",
  "token": "${w_token}"
}
EOF
    chmod 600 "$CONF_RUNTIME"
    green "路由中继凭据生成并就绪，成功缓存至中性运行时配置文件: ${CONF_RUNTIME}"
}

step "协商并注册云端中继对等体凭证"
warp_register

# ---------------------------------------------------------------
# 中继多端口高可用联通性穿透测试
# ---------------------------------------------------------------
warp_live_test() {
    [ "$WARP" = "1" ] || return 0

    purple "正在开始对本地中继链路的高可用端点及多端口进行联通性穿透测试..."
    local w_priv w_addr w_pub w_endpoint
    w_priv=$(python3 -c "import json; print(json.load(open('$CONF_RUNTIME'))['private_key'])" 2>/dev/null)
    w_addr=$(python3 -c "import json; print(json.load(open('$CONF_RUNTIME'))['local_address'])" 2>/dev/null)
    w_pub=$(python3 -c "import json; print(json.load(open('$CONF_RUNTIME'))['peer_public_key'])" 2>/dev/null)

    local endpoint_host="162.159.192.1"
    local ports_to_try=(2408 500 4500 1701 880)
    local try_port probe_port=19835 test_conf="${RUNTIME_DIR}/.live_probe.json"
    local trace_out="" success=0 WARP_ENDPOINT=""

    for try_port in "${ports_to_try[@]}"; do
        purple "探测中继远端候选端口: ${endpoint_host}:${try_port} ..."
        cat > "$test_conf" << EOF
{
  "log": { "loglevel": "none" },
  "inbounds": [ { "port": ${probe_port}, "listen": "127.0.0.1", "protocol": "http", "settings": {} } ],
  "outbounds": [
    {
      "protocol": "wireguard",
      "tag": "warp-out",
      "settings": {
        "secretKey": "${w_priv}",
        "address": ["${w_addr}"],
        "peers": [ { "publicKey": "${w_pub}", "endpoint": "${endpoint_host}:${try_port}" } ]
      }
    }
  ],
  "routing": { "rules": [ { "type": "field", "outboundTag": "warp-out", "network": "tcp,udp" } ] }
}
EOF
        # 统一规范的后台调试启动形态 [满足要求 3]
        "$EXEC_ENGINE" -c "$test_conf" >/dev/null 2>&1 &
        local test_pid=$!
        echo "$test_pid" > "${RUNTIME_DIR}/.test.pid"

        local waited=0 is_listen=0
        while [ $waited -lt 10 ]; do
            if sockstat -4l -p "$probe_port" >/dev/null 2>&1 || netstat -an | grep -q "127.0.0.1.${probe_port}.*LISTEN"; then
                is_listen=1; break
            fi
            sleep 0.5
            waited=$((waited + 1))
        done

        if [ "$is_listen" = 1 ]; then
            if [ "$HAVE_CURL" = 1 ]; then
                trace_out=$(curl -s -m 6 -x "http://127.0.0.1:${probe_port}" "https://www.cloudflare.com/cdn-cgi/trace" 2>/dev/null)
            else
                trace_out=$(http_proxy="http://127.0.0.1:${probe_port}" https_proxy="http://127.0.0.1:${probe_port}" wget -qO- -T 6 "https://www.cloudflare.com/cdn-cgi/trace" 2>/dev/null)
            fi
        fi

        kill -9 "$test_pid" >/dev/null 2>&1
        rm -f "${RUNTIME_DIR}/.test.pid"

        if echo "$trace_out" | grep -q "warp=on"; then
            green "中继穿透成功！回包已带有 warp=on 标识，端口 ${try_port} 建立高可用握手"
            WARP_ENDPOINT="${endpoint_host}:${try_port}"
            success=1
            break
        fi
        yellow "远端端口 ${try_port} 通信受限，无响应或未成功建立对等体，继续轮询..."
    done

    rm -f "$test_conf"

    if [ "$success" = 1 ]; then
        python3 -c "import json; d=json.load(open('$CONF_RUNTIME')); d['endpoint']='${WARP_ENDPOINT}'; json.dump(d,open('$CONF_RUNTIME','w'))" 2>/dev/null
        return 0
    else
        red "警告: 经遍历所有可用中继公共中转端口，当前底层网络均无法实现正常 UDP 回流握手，已强制将其回退至纯直连网络形态。"
        export WARP=0
        return 1
    fi
}

step "中继多通道高可用穿透性评测"
warp_live_test

# ---------------------------------------------------------------
# 中性核心配置矩阵动态拼装
# ---------------------------------------------------------------
generate_config() {
    local uuid_json
    uuid_json=$(json_escape "$UUID")
    local warp_outbound="" warp_routing=""

    if [ "$WARP" = "1" ] && [ -f "$CONF_RUNTIME" ]; then
        local w_priv w_addr w_endpoint
        w_priv=$(python3 -c "import json; print(json.load(open('$CONF_RUNTIME'))['private_key'])" 2>/dev/null)
        w_addr=$(python3 -c "import json; print(json.load(open('$CONF_RUNTIME'))['local_address'])" 2>/dev/null)
        w_endpoint=$(python3 -c "import json; print(json.load(open('$CONF_RUNTIME'))['endpoint'])" 2>/dev/null)

        if [ -n "$w_priv" ] && [ -n "$w_addr" ] && [ -n "$w_endpoint" ]; then
            warp_outbound=", { \"protocol\": \"wireguard\", \"tag\": \"warp-out\", \"settings\": { \"secretKey\": \"${w_priv}\", \"address\": [\"${w_addr}\"], \"peers\": [ { \"publicKey\": \"bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=\", \"endpoint\": \"${w_endpoint}\" } ] }, \"streamSettings\": { \"sockopt\": { \"mark\": 0, \"tcpFastOpen\": true } } }"
            warp_routing=", \"routing\": { \"rules\": [ { \"type\": \"field\", \"outboundTag\": \"warp-out\", \"network\": \"tcp,udp\" } ] }"
        fi
    fi

    # 统一命名为中性 service.json 配置文件 [满足要求 2]
    cat > "$CONF_SERVICE" << EOF
{
  "log": {
    "access": "/dev/null",
    "error": "/dev/null",
    "loglevel": "none"
  },
  "inbounds": [
    {
      "tag": "vless-ws",
      "port": ${PORT},
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "${uuid_json}", "level": 0 }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/data-sync?ed=2560"
        }
      }
    }
  ],
  "dns": {
    "servers": [
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
    }${warp_outbound}
  ]${warp_routing}
}
EOF
}

step "动态装配中性核心服务配置文件"
generate_config

# ---------------------------------------------------------------
# 后台进程隔离级拉起与控制 [完全统一启动参数形式，满足要求 3]
# ---------------------------------------------------------------
start_services() {
    cd "$RUNTIME_DIR" || exit 1

    # 1. 统一形式拉起网络核心引擎驱动
    nohup "$EXEC_ENGINE" -c "$CONF_SERVICE" >/dev/null 2>&1 &
    echo $! > "$PID_ENGINE"

    # 2. 统一形式拉起网关边缘守卫线程
    local ARGO_LOG="${WORKDIR}/argo.log"
    rm -f "$ARGO_LOG"

    if [ "$ARGO_MODE" = "tunnelsecret" ]; then
        nohup "$EXEC_DAEMON" tunnel --config "$CONF_TUNNEL" run >/dev/null 2>&1 &
        echo $! > "$PID_DAEMON"
    elif [ "$ARGO_MODE" = "token" ]; then
        nohup "$EXEC_DAEMON" tunnel --no-autoupdate run --token "$ARGO_AUTH" >/dev/null 2>&1 &
        echo $! > "$PID_DAEMON"
    else
        # Quick 模式：将边缘网关日志引入私有 logs 沙箱，用于心跳脚本做域名提取
        nohup "$EXEC_DAEMON" tunnel --url "http://localhost:$PORT" --no-autoupdate > "$ARGO_LOG" 2>&1 &
        echo $! > "$PID_DAEMON"
    fi

    sleep 1.5
}

step "统一隔离状态引导核心子进程后台轮转"
start_services

# ---------------------------------------------------------------
# 构建高可用中性巡检守护脚本 (monitor.sh)
# ---------------------------------------------------------------
install_healthcheck() {
    # 动态构建全中性、参数自解耦的 monitor.sh
    cat > "$HEALTH_SCRIPT" << 'EOF'
#!/bin/bash
export LC_ALL=C

# 加载全局环境参数快照
SCRIPT_DIR=$(dirname "$0")
STATE_ENV="${SCRIPT_DIR}/.service.env"
[ -f "$STATE_ENV" ] && source "$STATE_ENV"

PID_ENG="${SCRIPT_DIR}/engine.pid"
PID_DAE="${SCRIPT_DIR}/daemon.pid"
EXE_ENG="${SCRIPT_DIR}/engine"
EXE_DAE="${SCRIPT_DIR}/daemon"
CFG_SER="${SCRIPT_DIR}/service.json"
CFG_TUN="${SCRIPT_DIR}/service.yml"
LOG_ARG="${SAVED_WORKDIR}/argo.log"
TXT_LNK="${SAVED_WORKDIR}/current_link.txt"

check_and_heal() {
    local label="$1" pid_file="$2" exec_cmd="$3"
    local alive=0
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" >/dev/null 2>&1; then
            alive=1
        fi
    fi
    if [ "$alive" = "0" ]; then
        eval "$exec_cmd"
        return 1
    fi
    return 0
}

# 统一自愈引导命令流 [满足要求 3]
CMD_ENG="nohup \"$EXE_ENG\" -c \"$CFG_SER\" >/dev/null 2>&1 & echo \$! > \"$PID_ENG\""

if [ -z "$SAVED_ARGO_AUTH" ] || [ -z "$SAVED_ARGO_DOMAIN" ]; then
    CMD_DAE="nohup \"$EXE_DAE\" tunnel --url \"http://localhost:\$SAVED_PORT\" --no-autoupdate > \"$LOG_ARG\" 2>&1 & echo \$! > \"$PID_DAE\""
elif [[ $SAVED_ARGO_AUTH =~ TunnelSecret ]]; then
    CMD_DAE="nohup \"$EXE_DAE\" tunnel --config \"$CFG_TUN\" run >/dev/null 2>&1 & echo \$! > \"$PID_DAE\""
else
    CMD_DAE="nohup \"$EXE_DAE\" tunnel --no-autoupdate run --token \"$SAVED_ARGO_AUTH\" >/dev/null 2>&1 & echo \$! > \"$PID_DAE\""
fi

heal_eng=0
heal_dae=0
check_and_heal "engine" "$PID_ENG" "$CMD_ENG" || heal_eng=1
check_and_heal "daemon" "$PID_DAE" "$CMD_DAE" || heal_dae=1

# Quick 随机域名高可用轮换捕获
if [ -z "$SAVED_ARGO_AUTH" ] || [ -z "$SAVED_ARGO_DOMAIN" ]; then
    local current_host=""
    if [ -f "$LOG_ARG" ]; then
        current_host=$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$LOG_ARG" | head -n 1 | sed 's|https://||')
    fi
    if [ -n "$current_host" ]; then
        local new_link="vless://${SAVED_UUID}@${SAVED_CFIP}:${SAVED_CFPORT}?encryption=none&security=tls&type=ws&host=${current_host}&path=%2Fdata-sync%3Fed%3D2560&sni=${SAVED_CFIP}#${USERNAME}_serv00"
        echo "$new_link" > "$TXT_LNK"
    fi
fi

# 告警流水线介入
if [ -n "$SAVED_TG_TOKEN" ] && [ -n "$SAVED_TG_ID" ]; then
    if [ $heal_eng = 1 ] || [ $heal_dae = 1 ]; then
        local msg="[告警通知] 位于宿主机 $(hostname) 上的运行时中性通信组件发生突发中断。内部高可用巡检机制已自动介入完成异常分支自愈引导。"
        curl -s -X POST "https://api.telegram.org/bot${SAVED_TG_TOKEN}/sendMessage" -d "chat_id=${SAVED_TG_ID}" -d "text=${msg}" >/dev/null 2>&1
    fi
fi
EOF
    chmod +x "$HEALTH_SCRIPT"

    # 清理并精准注册中性计划任务
    remove_healthcheck_schedule
    if command -v crontab >/dev/null 2>&1; then
        (crontab -l 2>/dev/null; echo "*/10 * * * * bash $HEALTH_SCRIPT >/dev/null 2>&1 #$HEALTH_MARK") | crontab - 2>/dev/null
    fi
}

step "下发分布式高可用主动巡检守护逻辑"
install_healthcheck

# ---------------------------------------------------------------
# 中性静态站点迷彩混淆
# ---------------------------------------------------------------
install_homepage() {
  local homepage="${FILE_PATH}/index.html"
  cat > "$homepage" << 'HTMLEOF'
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Runtime Environment Operational</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #f4f6f9; color: #333; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; }
        .card { background: white; padding: 2.5rem; border-radius: 12px; box-shadow: 0 4px 16px rgba(0,0,0,0.05); text-align: center; max-width: 400px; }
        h1 { color: #2ecc71; margin-top: 0; font-size: 1.8rem; }
        p { color: #666; line-height: 1.5; font-size: 0.95rem; }
        .status { display: inline-block; padding: 0.25rem 0.75rem; background: #e8f8f5; color: #2ecc71; border-radius: 50px; font-weight: 600; font-size: 0.85rem; }
    </style>
</head>
<body>
    <div class="card">
        <h1>Runtime Service</h1>
        <p><span class="status">Active & Stable</span></p>
        <p>The shared microkernel abstraction service layer is running normally. All underlying asynchronous execution cycles are synchronized.</p>
    </div>
</body>
</html>
HTMLEOF
  chmod 644 "$homepage" >/dev/null 2>&1
}

# ---------------------------------------------------------------
# 生成中性同步分发 PHP 页面与入口分发
# ---------------------------------------------------------------
generate_links() {
    local target_host=""
    if [ -n "$ARGO_DOMAIN" ]; then
        target_host="$ARGO_DOMAIN"
    else
        local current_host="" i=0
        for i in {1..6}; do
            if [ -f "${WORKDIR}/argo.log" ]; then
                current_host=$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "${WORKDIR}/argo.log" | head -n 1 | sed 's|https://||')
                [ -n "$current_host" ] && break
            fi
            sleep 1
        done
        target_host="${current_host:-pending.trycloudflare.com}"
    fi

    local LINK="vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&type=ws&host=${target_host}&path=%2Fdata-sync%3Fed%3D2560&sni=${CFIP}#${USERNAME}_serv00"
    local LINK_FILE="${WORKDIR}/current_link.txt"
    echo "$LINK" > "$LINK_FILE"

    # 生成满足中性特征伪装的 PHP 分发页面 [满足要求 2]
    cat > "${FILE_PATH}/${SUB_TOKEN}_sync.php" << 'PHPEOF'
<?php
header('Content-Type: text/plain; charset=utf-8');
$link_file = "REPLACE_WITH_LINK_FILE";
$health_script = "REPLACE_WITH_HEALTH_SCRIPT";
if (file_exists($link_file)) {
    echo file_get_contents($link_file);
}
if (file_exists($health_script)) {
    exec("nohup bash " . escapeshellarg($health_script) . " > /dev/null 2>&1 &");
}
?>
PHPEOF

  local php_tmp="${FILE_PATH}/${SUB_TOKEN}_sync.php.tmp.$$"
  local link_file_esc health_script_esc
  link_file_esc=$(sed_repl_escape "$LINK_FILE")
  health_script_esc=$(sed_repl_escape "$HEALTH_SCRIPT")
  sed \
    -e "s|REPLACE_WITH_LINK_FILE|${link_file_esc}|g" \
    -e "s|REPLACE_WITH_HEALTH_SCRIPT|${health_script_esc}|g" \
    "${FILE_PATH}/${SUB_TOKEN}_sync.php" > "$php_tmp" && mv "$php_tmp" "${FILE_PATH}/${SUB_TOKEN}_sync.php"

  chmod 644 "${FILE_PATH}/${SUB_TOKEN}_sync.php" >/dev/null 2>&1

  install_homepage

  echo -e "\n${green}部署成功！系统资产与过程文件已全部转换为中性混淆隐蔽模式。${re}"
  echo -e "${purple}规范化运行时中性配置同步分发口 (唯一订阅地址):${re}"
  echo "https://${USERNAME}.${CURRENT_DOMAIN}/${SUB_TOKEN}_sync.php"
}

step "构建中性分布式缓存页面与迷彩站点"
generate_links

# 锁定持久化快照
save_state
