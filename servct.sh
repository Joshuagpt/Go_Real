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
export UUID=${UUID:-$(uuidgen -r)}
export SUB_PATH=${SUB_PATH:-${UUID:0:8}}
if [[ "$HOSTNAME" =~ ct8 ]]; then CURRENT_DOMAIN="ct8.pl"; elif [[ "$HOSTNAME" =~ hostuno ]]; then CURRENT_DOMAIN="useruno.com"; else CURRENT_DOMAIN="serv00.net"; fi
command -v curl &>/dev/null && COMMAND="curl -so" || command -v wget &>/dev/null && COMMAND="wget -qO" || { red "Error: neither curl nor wget found, please install one of them." >&2; exit 1; }
WORKDIR="$HOME/domains/${USERNAME}.${CURRENT_DOMAIN}/public_nodejs"

# VLESS-WS-Argo 只需要一个本地 TCP 端口给 Argo 隧道用，不需要额外的 UDP 端口
check_port () {
port_list=$(devil port list)
tcp_ports=$(echo "$port_list" | grep -c "tcp")
if [[ $tcp_ports -ne 1 ]]; then
    red "端口规则不符合要求，正在调整..."
    if [[ $tcp_ports -gt 1 ]]; then
        tcp_to_delete=$((tcp_ports - 1))
        echo "$port_list" | awk '/tcp/ {print $1, $2}' | head -n $tcp_to_delete | while read port type; do
            devil port del $type $port >/dev/null 2>&1
            green "已删除TCP端口: $port"
        done
    fi

    if [[ $tcp_ports -lt 1 ]]; then
        while true; do
            tcp_port=$(shuf -i 10000-65535 -n 1)
            result=$(devil port add tcp $tcp_port 2>&1)
            if [[ $result == *"Ok"* ]]; then
                green "已添加TCP端口: $tcp_port"
                break
            else
                yellow "端口 $tcp_port 不可用，尝试其他端口..."
            fi
        done
    fi
    green "端口已调整完成,将断开ssh连接,请重新连接shh重新执行脚本"
    quick_command
    devil binexec on >/dev/null 2>&1
    kill -9 $(ps -o ppid= -p $$) >/dev/null 2>&1
else
    tcp_port=$(echo "$port_list" | awk '/tcp/ {print $1}')
fi
purple "vless-ws-argo使用的tcp端口为: $tcp_port"
export ARGO_PORT=$tcp_port
}

install_vless() {
bash -c 'ps aux | grep $(whoami) | grep -v "sshd\|bash\|grep" | awk "{print \$2}" | xargs -r kill -9 >/dev/null 2>&1' >/dev/null 2>&1
echo -e "${yellow}本脚本仅安装单协议${purple}vless-ws-tls(argo)${re}"
reading "\n确定继续安装吗？(直接回车即确认安装)【y/n】: " choice
  case "${choice:-y}" in
    [Yy]|"")
    	clear
        check_port
        argo_configure
        install_service
      ;;
    [Nn]) exit 0 ;;
    *) red "无效的选择，请输入y或n" && menu ;;
  esac
}

uninstall_vless() {
  reading "\n确定要卸载吗？【y/n】: " choice
    case "$choice" in
        [Yy])
	          bash -c 'ps aux | grep $(whoami) | grep -v "sshd\|bash\|grep" | awk "{print \$2}" | xargs -r kill -9 >/dev/null 2>&1' >/dev/null 2>&1
            remove_keepalive_cron
            devil www del ${USERNAME}.${CURRENT_DOMAIN} 2>/dev/null || true
            rm -rf ${HOME}/domains/${USERNAME}.${CURRENT_DOMAIN} 2>/dev/null || true
            rm -rf "${HOME}/bin/00" >/dev/null 2>&1
            [ -d "${HOME}/bin" ] && [ -z "$(ls -A "${HOME}/bin")" ] && rmdir "${HOME}/bin"
            sed -i '/export PATH="\$HOME\/bin:\$PATH"/d' "${HOME}/.bashrc" >/dev/null 2>&1
            source "${HOME}/.bashrc"
	          clear
       	    green "代理服务已完全卸载"
          ;;
        [Nn]) exit 0 ;;
    	  *) red "无效的选择,请输入y或n" && menu ;;
    esac
}

reset_system() {
reading "\n确定重置系统吗吗？【y/n】: " choice
  case "$choice" in
    [Yy]) yellow "\n初始化系统中,请稍后...\n"
          bash -c 'ps aux | grep $(whoami) | grep -v "sshd\|bash\|grep" | awk "{print \$2}" | xargs -r kill -9 >/dev/null 2>&1' >/dev/null 2>&1
          remove_keepalive_cron
          find "${HOME}" -mindepth 1 ! -name "domains" ! -name "mail" ! -name "repo" ! -name "backups" -exec rm -rf {} + > /dev/null 2>&1
          devil www list | awk 'NF>=2 && $1 ~ /\./ {print $1}' | while read -r domain; do devil www del "$domain"; done
          rm -rf $HOME/domains/* > /dev/null 2>&1
          green "\n初始化系统完成!\n"
         ;;
       *) menu ;;
  esac
}

argo_configure() {
  reading "是否需要使用固定argo隧道？(直接回车将使用临时隧道)【y/n】: " argo_choice
  [[ -z $argo_choice ]] && return
  [[ "$argo_choice" != "y" && "$argo_choice" != "Y" && "$argo_choice" != "n" && "$argo_choice" != "N" ]] && { red "无效的选择, 请输入y或n"; return; }
  if [[ "$argo_choice" == "y" || "$argo_choice" == "Y" ]]; then
      reading "请输入argo固定隧道域名: " ARGO_DOMAIN
      green "你的argo固定隧道域名为: $ARGO_DOMAIN"
      reading "请输入argo固定隧道密钥（Json或Token）: " ARGO_AUTH
      green "你的argo固定隧道密钥为: $ARGO_AUTH"
  else
      green "ARGO隧道变量未设置，将使用临时隧道"
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
    service: http://localhost:$ARGO_PORT
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
  else
    yellow "\n当前使用的是token,请在cloudflare里设置隧道端口为${purple}${ARGO_PORT}${re}"
  fi
}

setup_keepalive_cron() {
  local cron_tag="# vless_argo_keepalive"
  local cron_line="*/10 * * * * curl -s -o /dev/null -m 10 https://${USERNAME}.${CURRENT_DOMAIN} >/dev/null 2>&1 ${cron_tag}"
  (crontab -l 2>/dev/null | grep -vF "${cron_tag}"; echo "${cron_line}") | crontab -
  green "已添加保活定时任务(每10分钟访问一次自身域名)"
}

remove_keepalive_cron() {
  local cron_tag="# vless_argo_keepalive"
  crontab -l 2>/dev/null | grep -vF "${cron_tag}" | crontab -
}

write_app_js() {
  cat > "$1" <<'JSEOF'
#!/usr/bin/env node

const fs = require('fs');
const path = require('path');
const os = require('os');
const http = require('http');
const crypto = require('crypto');
const axios = require('axios');
const koffi = require('koffi');
const { execSync } = require('child_process');

try { require('dotenv').config(); } catch { /* ignore if dotenv unavailable */ }

// ======================== 环境变量定义 ========================
const YT_WARPOUT     = process.env.YT_WARPOUT     || false;      // 设置为true时强制使用warp出站访问youtube
const FILE_PATH      = process.env.FILE_PATH      || '.npm';     // sub.txt订阅文件路径
const SUB_PATH       = process.env.SUB_PATH       || 'sub';      // 订阅sub路径，默认为sub
const UUID           = process.env.UUID           || '68aa231f-703e-4547-967e-12ed0b36420f'; // UUID
const ARGO_DOMAIN    = process.env.ARGO_DOMAIN    || '';         // argo固定隧道域名,留空即使用临时隧道
const ARGO_AUTH      = process.env.ARGO_AUTH      || '';         // argo固定隧道token或json,留空即使用临时隧道
const ARGO_PORT      = Number(process.env.ARGO_PORT) || 8001;    // argo固定隧道端口(本地vless-ws监听端口)
const CFIP           = process.env.CFIP           || 'saas.sin.fan'; // 优选域名或优选IP
const CFPORT         = Number(process.env.CFPORT) || 443;        // 优选域名或优选IP对应端口
const PORT           = Number(process.env.PORT)   || 3000;       // http订阅端口
const NAME           = process.env.NAME           || '';         // 节点名称
const DISABLE_ARGO   = process.env.DISABLE_ARGO   || false;      // 设置为true时禁用argo
const GLOBAL_WARP    = process.env.GLOBAL_WARP     || false;     // 设置为true时全部出站流量走WARP，否则仅netflix/youtube走WARP
// ==============================================================

const ROOT = process.cwd();
const runtimeFilePath = path.resolve(ROOT, FILE_PATH);
const libraryDir = runtimeFilePath;
const singBoxConfigPath = path.resolve(runtimeFilePath, 'config.json');
const bootLogPath = path.resolve(runtimeFilePath, 'boot.log');
const subPath = path.resolve(runtimeFilePath, 'sub.txt');
const listPath = path.resolve(runtimeFilePath, 'list.txt');
const warpConfigPath = path.resolve(runtimeFilePath, 'warp.json'); // 独立WARP身份持久化文件，注册一次后复用
const subscribePath = '/' + SUB_PATH.replace(/^\//, '');

const arch = (() => {
  const a = os.arch().toLowerCase();
  if (a === 'arm64' || a === 'aarch64') return 'arm64';
  return 'amd64';
})();

// ======================== 文件清理 ========================

const pathsToDelete = ['boot.log', 'list.txt', 'config.json', 'tunnel.json', 'tunnel.yml'];
function cleanupOldFiles() {
  pathsToDelete.forEach(file => {
    const filePath = path.join(FILE_PATH, file);
    fs.unlink(filePath, () => {});
  });
  const tmpDir = path.resolve(ROOT, '.tmp');
  if (fs.existsSync(tmpDir)) {
    try { fs.rmSync(tmpDir, { recursive: true, force: true }); } catch (e) { }
  }
}

function cleanupFiles(options = {}) {
  const keepFiles = new Set(['warp.json']); // WARP身份文件任何时候都不清理，避免重复注册触发限流
  if (options.keepSub) keepFiles.add('sub.txt');
  if (fs.existsSync(runtimeFilePath)) {
    try {
      const files = fs.readdirSync(runtimeFilePath);
      for (const file of files) {
        if (keepFiles.has(file)) continue;
        const filePath = path.resolve(runtimeFilePath, file);
        try {
          const stat = fs.statSync(filePath);
          if (stat.isDirectory()) {
            fs.rmSync(filePath, { recursive: true, force: true });
          } else {
            fs.unlinkSync(filePath);
          }
        } catch (e) { /* skip locked/in-use files */ }
      }
    } catch (e) {
      console.error('Cleanup failed:', e.message);
    }
  }
  const tmpDir = path.resolve(ROOT, '.tmp');
  if (fs.existsSync(tmpDir)) {
    try { fs.rmSync(tmpDir, { recursive: true, force: true }); } catch (e) { }
  }
}

function clearConsole() {
  process.stdout.write('\x1Bc');
}

// ======================== WARP 身份注册 ========================
// 基于 wgcf 同款接口 (api.cloudflareclient.com/v0a884/reg) 独立注册一个 WARP 身份，
// 而不是使用写死/共享的 WireGuard 密钥。注册结果落盘到 warp.json，之后每次启动优先复用，
// 避免频繁注册触发 Cloudflare 风控/限流。

const WARP_REG_URL = 'https://api.cloudflareclient.com/v0a884/reg';
const WARP_API_HEADERS = {
  'User-Agent': 'okhttp/3.12.1',
  'CF-Client-Version': 'a-6.10-2158',
  'Content-Type': 'application/json;charset=UTF-8'
};

// 生成一对 X25519 (Curve25519) 密钥，转成 WireGuard 使用的原始 32 字节 base64 格式。
// Node 的 crypto 模块只能导出 DER 编码，WireGuard 需要的是裸的 32 字节 key，
// 因此从 DER 结构中截取末尾 32 字节（X25519 DER 编码固定为该结构）。
function generateWireguardKeyPair() {
  const { publicKey, privateKey } = crypto.generateKeyPairSync('x25519', {
    publicKeyEncoding: { type: 'spki', format: 'der' },
    privateKeyEncoding: { type: 'pkcs8', format: 'der' }
  });
  const rawPrivateKey = privateKey.subarray(privateKey.length - 32);
  const rawPublicKey = publicKey.subarray(publicKey.length - 32);
  return {
    privateKey: Buffer.from(rawPrivateKey).toString('base64'),
    publicKey: Buffer.from(rawPublicKey).toString('base64')
  };
}

// 调用 Cloudflare 注册接口，拿到属于自己的 client_id(reserved)、分配的内网地址、以及对端公钥
async function registerWarp() {
  const { privateKey, publicKey } = generateWireguardKeyPair();

  const resp = await axios.post(WARP_REG_URL, {
    key: publicKey,
    install_id: '',
    fcm_token: '',
    tos: new Date().toISOString(),
    type: 'PC',
    model: 'PC',
    locale: 'en_US'
  }, {
    headers: WARP_API_HEADERS,
    timeout: 10000
  });

  const data = resp.data;
  if (!data || !data.config || !data.config.peers || !data.config.peers[0]) {
    throw new Error('WARP注册接口返回数据格式异常');
  }

  const cfg = data.config;
  const peer = cfg.peers[0];

  // client_id 是 base64 编码的 3 字节数据，即 reserved 字段
  const reserved = Array.from(Buffer.from(cfg.client_id, 'base64'));

  // peer.endpoint.host 形如 "engage.cloudflareclient.com:2408" 或 "162.159.192.1:2408"
  let endpointHost = 'engage.cloudflareclient.com';
  let endpointPort = 2408;
  if (peer.endpoint && peer.endpoint.host) {
    const idx = peer.endpoint.host.lastIndexOf(':');
    if (idx !== -1) {
      endpointHost = peer.endpoint.host.slice(0, idx);
      endpointPort = Number(peer.endpoint.host.slice(idx + 1)) || 2408;
    } else {
      endpointHost = peer.endpoint.host;
    }
  }

  return {
    private_key: privateKey,
    public_key: peer.public_key,
    endpoint_host: endpointHost,
    endpoint_port: endpointPort,
    address_v4: cfg.interface && cfg.interface.addresses ? cfg.interface.addresses.v4 : null,
    address_v6: cfg.interface && cfg.interface.addresses ? cfg.interface.addresses.v6 : null,
    reserved,
    account_id: data.id || null,
    registered_at: new Date().toISOString()
  };
}

// 校验本地 warp.json 内容是否完整可用
function isValidWarpConfig(cfg) {
  return !!(cfg && cfg.private_key && cfg.public_key && cfg.endpoint_host &&
    Array.isArray(cfg.reserved) && cfg.reserved.length === 3 && cfg.address_v4);
}

// 启动时调用：本地有有效 warp.json 就直接复用；没有则注册一次并保存；注册失败则返回 null（由上层降级为纯 direct）
async function getOrCreateWarpIdentity() {
  try {
    if (fs.existsSync(warpConfigPath)) {
      const cfg = JSON.parse(fs.readFileSync(warpConfigPath, 'utf8'));
      if (isValidWarpConfig(cfg)) {
        console.log('WARP: 检测到本地 warp.json，复用已注册身份');
        return cfg;
      }
      console.log('WARP: 本地 warp.json 内容不完整，将重新注册');
    }
  } catch (e) {
    console.log('WARP: 读取 warp.json 失败(' + e.message + ')，将重新注册');
  }

  try {
    console.log('WARP: 未找到可用身份，正在向 Cloudflare 注册新的 WARP 身份...');
    const cfg = await registerWarp();
    fs.writeFileSync(warpConfigPath, JSON.stringify(cfg, null, 2));
    console.log('WARP: 注册成功，已保存到 warp.json，后续将直接复用');
    return cfg;
  } catch (e) {
    console.error('WARP: 注册失败(' + e.message + ')，本次运行将禁用 WARP，自动降级为纯 direct 出站');
    return null;
  }
}

// ======================== Argo 隧道配置 ========================

function argoType() {
  if (DISABLE_ARGO === 'true' || DISABLE_ARGO === true) {
    console.log("DISABLE_ARGO is set to true, disable argo tunnel");
    return;
  }
  if (!ARGO_AUTH || !ARGO_DOMAIN) {
    console.log("ARGO_DOMAIN or ARGO_AUTH variable is empty, use quick tunnel");
    return;
  }
  if (ARGO_AUTH.includes('TunnelSecret')) {
    fs.writeFileSync(path.join(FILE_PATH, 'tunnel.json'), ARGO_AUTH);
    const tunnelYaml = `
  tunnel: ${ARGO_AUTH.split('"')[11]}
  credentials-file: ${path.join(FILE_PATH, 'tunnel.json')}
  protocol: http2
  
  ingress:
    - hostname: ${ARGO_DOMAIN}
      service: http://localhost:${ARGO_PORT}
      originRequest:
        noTLSVerify: true
    - service: http_status:404
  `;
    fs.writeFileSync(path.join(FILE_PATH, 'tunnel.yml'), tunnelYaml);
  } else {
    console.log(`Using token connect to tunnel, please set ${ARGO_PORT} in cloudflare`);
  }
}

// ======================== 下载库文件 ========================

async function sha256Matches(filePath, expected) {
  if (!expected) return true;
  const actual = await sha256(filePath);
  return actual.toLowerCase() === expected.toLowerCase();
}

function sha256(filePath) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256');
    const stream = fs.createReadStream(filePath);
    stream.on('data', chunk => hash.update(chunk));
    stream.on('end', () => resolve(hash.digest('hex')));
    stream.on('error', reject);
  });
}

async function downloadLibrary(url, fileName, expectedSha256) {
  const target = path.resolve(libraryDir, fileName);
  if (fs.existsSync(target) && await sha256Matches(target, expectedSha256)) {
    console.log(`Using cached native library: ${target}`);
    return target;
  }
  await fs.promises.mkdir(libraryDir, { recursive: true });
  const tmp = path.resolve(libraryDir, `${fileName}.download`);
  const writer = fs.createWriteStream(tmp);
  console.log(`Downloading ${url} -> ${target}`);
  const response = await axios.get(url, { responseType: 'stream', timeout: 3 * 60 * 1000 });
  if (response.status < 200 || response.status >= 300) {
    throw new Error(`Failed to download ${url}: HTTP ${response.status}`);
  }
  response.data.pipe(writer);
  await new Promise((resolve, reject) => writer.on('finish', resolve).on('error', reject));
  if (!(await sha256Matches(tmp, expectedSha256))) {
    throw new Error(`SHA-256 mismatch for ${tmp}`);
  }
  await fs.promises.rename(tmp, target);
  return target;
}

// ======================== Koffi 服务管理 ========================

function createService(name, libraryPath, startSymbol, stopSymbol, payload) {
  const lib = koffi.load(libraryPath);
  const startFn = lib.func(`int ${startSymbol}(str)`);
  const stopFn = lib.func(`int ${stopSymbol}()`);
  return {
    name,
    start: () => {
      startFn.async(payload || '', (err, code) => {
        if (err) {
          console.error(`${name} native service failed: ${err.message}`);
        } else if (code !== 0) {
          console.warn(`${name} native service exited with code ${code}`);
        }
      });
    },
    stop: () => new Promise((resolve, reject) => {
      try {
        stopFn.async((err, code) => {
          if (err) return reject(err);
          resolve(code);
        });
      } catch (error) {
        resolve(-1);
      }
    })
  };
}

// ======================== sing-box 配置生成 ========================

const WARP_OUTBOUND_TAG = 'warp-auto';

function generateSingBoxConfig(warpConfig) {
  const inbounds = [];

  // VLESS+WS inbound (for argo reverse proxy)
  inbounds.push({
    type: 'vless',
    tag: 'vless-ws-in',
    listen: '::',
    listen_port: ARGO_PORT,
    users: [{ uuid: UUID }],
    transport: {
      type: 'ws',
      path: '/vless-argo',
      early_data_header_name: 'Sec-WebSocket-Protocol'
    }
  });

  const endpoints = [];
  const outbounds = [{ type: 'direct', tag: 'direct' }];
  const warpAvailable = isValidWarpConfig(warpConfig);

  if (warpAvailable) {
    // 使用注册得到的真实WARP身份（而非写死的密钥）
    const address = [`${warpConfig.address_v4}/32`];
    if (warpConfig.address_v6) address.push(`${warpConfig.address_v6}/128`);

    endpoints.push({
      type: 'wireguard',
      tag: 'wireguard-out',
      mtu: 1280,
      address,
      private_key: warpConfig.private_key,
      peers: [{
        address: warpConfig.endpoint_host,
        port: warpConfig.endpoint_port,
        public_key: warpConfig.public_key,
        allowed_ips: ['0.0.0.0/0', '::/0'],
        reserved: warpConfig.reserved
      }]
    });

    outbounds.push({
      type: 'urltest',
      tag: WARP_OUTBOUND_TAG,
      outbounds: ['wireguard-out', 'direct'],
      url: 'https://www.gstatic.com/generate_204',
      interval: '2m',
      tolerance: 100
    });
  } else {
    console.log('WARP身份不可用，跳过wireguard出站配置，所有分流规则自动禁用，出站全部走direct');
  }

  const remoteRuleSet = (tag, url) => ({
    tag,
    type: 'remote',
    format: 'binary',
    url
  });

  let route;

  if (GLOBAL_WARP === true || GLOBAL_WARP === 'true') {
    if (warpAvailable) {
      // 全局WARP：所有出站流量默认走warpOutboundTag（内部会自动探测WARP是否可用，不可用则回落到direct）
      console.log('GLOBAL_WARP已启用，所有出站流量将默认走WARP（带自动故障转移）');
      route = {
        default_http_client: 'http-client-direct',
        final: WARP_OUTBOUND_TAG
      };
    } else {
      console.log('GLOBAL_WARP已启用，但WARP身份不可用，自动降级为全部direct出站');
      route = {
        default_http_client: 'http-client-direct',
        final: 'direct'
      };
    }
  } else if (!warpAvailable) {
    // 无可用WARP身份：不生成任何分流规则，全部走direct
    route = {
      default_http_client: 'http-client-direct',
      final: 'direct'
    };
  } else {
    const ruleSet = [
      remoteRuleSet('netflix', 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/netflix.srs')
    ];
    const wireguardRuleSets = ['netflix'];

    // YouTube WARP 出站检测
    let needYoutubeWarp = YT_WARPOUT === true || YT_WARPOUT === 'true';
    if (!needYoutubeWarp) {
      try {
        const youtubeTest = execSync('curl -o /dev/null -m 2 -s -w "%{http_code}" https://www.youtube.com', { encoding: 'utf8' }).trim();
        needYoutubeWarp = youtubeTest !== '200';
      } catch (curlError) {
        if (curlError.output && curlError.output[1]) {
          const test = curlError.output[1].toString().trim();
          needYoutubeWarp = test !== '200';
        } else {
          needYoutubeWarp = true;
        }
      }
    }
    if (needYoutubeWarp) {
      ruleSet.push(remoteRuleSet('youtube', 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/youtube.srs'));
      wireguardRuleSets.push('youtube');
      console.log('Add YouTube outbound rule');
    }

    route = {
      default_http_client: 'http-client-direct',
      rule_set: ruleSet,
      rules: [{ rule_set: wireguardRuleSets, outbound: WARP_OUTBOUND_TAG }],
      final: 'direct'
    };
  }

  return {
    log: { disabled: true, level: 'error', timestamp: true },
    http_clients: [{ tag: 'http-client-direct' }],
    inbounds,
    endpoints,
    outbounds,
    route
  };
}

// ======================== Cloudflared Payload ========================

function cloudflaredPayload() {
  if (DISABLE_ARGO === 'true' || DISABLE_ARGO === true) return null;
  if (ARGO_AUTH && ARGO_DOMAIN) {
    if (ARGO_AUTH.match(/^[A-Z0-9a-z=]{120,250}$/)) {
      return JSON.stringify({
        args: ['tunnel', '--edge-ip-version', 'auto', '--no-autoupdate', '--protocol', 'http2', 'run', '--token', ARGO_AUTH]
      });
    } else if (ARGO_AUTH.match(/TunnelSecret/)) {
      return JSON.stringify({
        args: ['tunnel', '--edge-ip-version', 'auto', '--config', path.join(FILE_PATH, 'tunnel.yml'), 'run']
      });
    }
  }
  // Quick tunnel
  return JSON.stringify({
    args: [
      'tunnel', '--edge-ip-version', 'auto', '--no-autoupdate',
      '--protocol', 'http2', '--logfile', bootLogPath,
      '--loglevel', 'info', '--url', `http://localhost:${ARGO_PORT}`
    ]
  });
}

function singBoxPayload() {
  return JSON.stringify({ config: singBoxConfigPath, workingDir: '.', disableColor: true });
}

// ======================== 隧道域名检测 ========================

function waitForQuickTunnelDomain(logPath, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      if (fs.existsSync(logPath)) {
        const content = fs.readFileSync(logPath, 'utf8');
        const matches = [...content.matchAll(/https:\/\/([A-Za-z0-9.-]+\.trycloudflare\.com)/g)];
        if (matches.length > 0) {
          return matches[matches.length - 1][1];
        }
      }
    } catch (e) { /* file may not exist yet */ }
    const remaining = deadline - Date.now();
    if (remaining <= 0) break;
    const sleepMs = Math.min(1000, remaining);
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, sleepMs);
  }
  return null;
}

async function extractDomain() {
  if (DISABLE_ARGO === 'true' || DISABLE_ARGO === true) return null;
  if (ARGO_AUTH && ARGO_DOMAIN) {
    console.log('ARGO_DOMAIN:', ARGO_DOMAIN + '\n');
    return ARGO_DOMAIN;
  }
  // Quick tunnel
  console.log('Waiting for quick tunnel domain in log...');
  let domain = waitForQuickTunnelDomain(bootLogPath, 30000);
  if (!domain) {
    console.log('Quick tunnel domain not found, retrying...');
    try { fs.unlinkSync(bootLogPath); } catch (e) { }
    await new Promise(r => setTimeout(r, 5000));
    domain = waitForQuickTunnelDomain(bootLogPath, 30000);
  }
  if (domain) {
    console.log('ArgoDomain:', domain + '\n');
  } else {
    console.log('ArgoDomain not found');
  }
  return domain;
}

// ======================== ISP 信息 ========================

async function getMetaInfo() {
  try {
    const response1 = await axios.get('https://api.ip.sb/geoip', { headers: { 'User-Agent': 'Mozilla/5.0', timeout: 3000 } });
    if (response1.data && response1.data.country_code && response1.data.isp) {
      return `${response1.data.country_code}-${response1.data.isp}`.replace(/\s+/g, '_');
    }
  } catch (error) {
    try {
      const response2 = await axios.get('http://ip-api.com/json', { headers: { 'User-Agent': 'Mozilla/5.0', timeout: 3000 } });
      if (response2.data && response2.data.status === 'success' && response2.data.countryCode && response2.data.org) {
        return `${response2.data.countryCode}-${response2.data.org}`.replace(/\s+/g, '_');
      }
    } catch (error) { /* backup also failed */ }
  }
  return 'Unknown';
}

// ======================== 节点链接生成 ========================

async function generateLinks(argoDomain) {
  const ISP = await getMetaInfo();
  const nodeName = NAME ? `${NAME}-${ISP}` : ISP;

  await new Promise(r => setTimeout(r, 2000));

  let subTxt = '';

  // VLESS+WS (argo)
  if ((DISABLE_ARGO !== 'true' && DISABLE_ARGO !== true) && argoDomain) {
    const vlessPath = encodeURIComponent('/vless-argo?ed=2560');
    subTxt = `vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${argoDomain}&fp=chrome&type=ws&host=${argoDomain}&path=${vlessPath}#${encodeURIComponent(nodeName)}`;
  }

  // 打印绿色 base64 编码
  console.log('\x1b[32m' + Buffer.from(subTxt).toString('base64') + '\x1b[0m');
  console.log('\n\x1b[35m' + 'Logs will be deleted in 45 seconds, you can copy the above nodes' + '\x1b[0m');

  const subTxtWithNewline = subTxt ? subTxt + '\n' : subTxt;
  fs.writeFileSync(subPath, Buffer.from(subTxtWithNewline).toString('base64'));
  fs.writeFileSync(listPath, subTxtWithNewline, 'utf8');
  console.log(`${FILE_PATH}/sub.txt saved successfully`);

  return subTxtWithNewline;
}

// ======================== HTTP 服务器 ========================

function startHttpServer(subTxt) {
  const server = http.createServer((req, res) => {
    if (req.method !== 'GET') {
      res.statusCode = 405;
      res.end('Method Not Allowed');
      return;
    }
    const url = new URL(req.url, `http://localhost`);
    if (url.pathname === subscribePath) {
      res.setHeader('Content-Type', 'text/plain; charset=utf-8');
      const encodedContent = Buffer.from(subTxt).toString('base64');
      res.end(encodedContent);
    } else if (url.pathname === '/') {
        try {
            const filePath = path.join(__dirname, 'index.html');
            const data = fs.readFileSync(filePath, 'utf8');
            res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
            res.end(data);
        } catch (err) {
            res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
            res.end("Hello world!<br><br>You can access /{SUB_PATH}(Default: /sub) to get your nodes!");
        }
    } else {
      res.statusCode = 404;
      res.end('Not Found');
    }
  });

  server.listen(PORT, '0.0.0.0', () => {
    console.log(`HTTP server is listening on ${PORT}`);
  });

  server.on('error', err => {
    if (err.code === 'EADDRINUSE') {
      console.error(`Port ${PORT} is already in use.`);
    } else {
      console.error('HTTP server error:', err.message);
    }
  });
}

// ======================== 主流程 ========================

async function startServer() {
  // 1. 创建运行目录 + 清理文件
  if (!fs.existsSync(FILE_PATH)) {
    fs.mkdirSync(FILE_PATH);
    console.log(`${FILE_PATH} is created`);
  }
  cleanupOldFiles();

  // 2. 生成 Argo 隧道配置
  argoType();

  // 3. 下载 .so 库文件
  const baseUrl = `https://00.ssss.nyc.mn`;
  const singBoxLib = await downloadLibrary(`${baseUrl}/freebsd-sbx.so`, 'sbx.so');
  let cloudflaredLib = null;

  if (DISABLE_ARGO !== 'true' && DISABLE_ARGO !== true) {
    cloudflaredLib = await downloadLibrary(`${baseUrl}/freebsd-bot.so`, 'bot.so');
  }

  // 4. 获取/注册 WARP 身份（本地已有 warp.json 则直接复用；注册失败则优雅降级，不阻塞服务启动）
  let warpConfig = null;
  try {
    warpConfig = await getOrCreateWarpIdentity();
  } catch (e) {
    console.error('WARP: 获取身份过程出现未捕获异常，禁用WARP并继续启动:', e.message);
    warpConfig = null;
  }

  // 5. 生成 sing-box config.json
  const sbxConfig = generateSingBoxConfig(warpConfig);
  fs.writeFileSync(singBoxConfigPath, JSON.stringify(sbxConfig, null, 2));

  // 6. 启动服务
  const services = [];

  // sing-box
  const singBoxService = createService('sing-box', singBoxLib, 'StartSingBox', 'StopSingBox', singBoxPayload());
  services.push(singBoxService);

  // cloudflared
  let cloudflaredService = null;
  if (cloudflaredLib) {
    const cfPayload = cloudflaredPayload();
    if (cfPayload) {
      cloudflaredService = createService('cloudflared', cloudflaredLib, 'StartCloudflared', 'StopCloudflared', cfPayload);
      services.push(cloudflaredService);
    }
  }

  // 信号监听
  async function stopAll() {
    for (let i = services.length - 1; i >= 0; i--) {
      try { await services[i].stop(); } catch (e) { }
    }
    process.exit(0);
  }
  process.on('SIGINT', stopAll);
  process.on('SIGTERM', stopAll);

  services.forEach(service => service.start());
  await new Promise(r => setTimeout(r, 1000));
  console.log('web is running');
  if (cloudflaredService) console.log('bot is running');

  // 7. 等待并检测隧道域名
  await new Promise(r => setTimeout(r, 5000));
  const argoDomain = await extractDomain();

  // 8. 生成节点链接
  const subTxt = await generateLinks(argoDomain);

  // 9. 启动 HTTP 服务器
  startHttpServer(subTxt);

  setTimeout(() => {
    cleanupFiles({ keepSub: true });
    clearConsole();
    console.log('App is running');
  }, 45000);
}

startServer();
setInterval(() => {}, 1000);
JSEOF
}

install_service () {
    purple "正在安装中,请稍等......"
    devil www del ${USERNAME}.${CURRENT_DOMAIN} > /dev/null 2>&1
    rm -rf $HOME/domains/${USERNAME}.${CURRENT_DOMAIN} > /dev/null 2>&1
    devil www add ${USERNAME}.${CURRENT_DOMAIN} nodejs /usr/local/bin/node24 > /dev/null 2>&1
    [ -d "$WORKDIR" ] || mkdir -p "$WORKDIR"
    write_app_js "${WORKDIR}/app.js"
    $COMMAND "${WORKDIR}/public/index.html" "https://raw.githubusercontent.com/eooce/node-ws/main/index.html" > /dev/null 2>&1
    cat > ${WORKDIR}/.env <<EOF
UUID=${UUID}
SUB_PATH=${SUB_PATH}
ARGO_PORT=${ARGO_PORT}
${ARGO_DOMAIN:+ARGO_DOMAIN=$ARGO_DOMAIN}
${ARGO_AUTH:+ARGO_AUTH=$([[ -z "$ARGO_AUTH" ]] && echo "" || ([[ "$ARGO_AUTH" =~ ^\{.* ]] && echo "'$ARGO_AUTH'" || echo "$ARGO_AUTH"))}
${GLOBAL_WARP:+GLOBAL_WARP=$GLOBAL_WARP}
EOF

  ln -fs /usr/local/bin/node24 ~/bin/node > /dev/null 2>&1
  ln -fs /usr/local/bin/npm24 ~/bin/npm > /dev/null 2>&1
  mkdir -p ~/.npm-global
  npm config set prefix '~/.npm-global'
  echo 'export PATH=~/.npm-global/bin:~/bin:$PATH' >> $HOME/.bash_profile && source $HOME/.bash_profile
  rm -rf $HOME/.npmrc > /dev/null 2>&1
  cd ${WORKDIR} && npm install dotenv axios koffi --silent > /dev/null 2>&1
  devil www restart ${USERNAME}.${CURRENT_DOMAIN} > /dev/null 2>&1
  yellow "服务启动中...."
  sleep 3
  if curl -o /dev/null -m 3 -s -w "%{http_code}" https://${USERNAME}.${CURRENT_DOMAIN} | grep -q "200"; then
      green "服务已启动成功,请先访问 https://${USERNAME}.${CURRENT_DOMAIN}  启动服务，过20秒再访问订阅获取节点"
  else
      red "服务启动失败，请检查端口是否被占用或配置是否正确"
  fi

  TOKEN=$(sed -n 's/^SUB_PATH=\(.*\)/\1/p' $HOME/domains/${USERNAME}.${CURRENT_DOMAIN}/public_nodejs/.env)
  green "\n订阅链接: https://${USERNAME}.${CURRENT_DOMAIN}/${TOKEN}\n节点订阅链接适用于V2rayN/Nekoray/ShadowRocket/karing/Loon/sterisand 等\n"

  setup_keepalive_cron
}

quick_command() {
  COMMAND="00"
  SCRIPT_PATH="$HOME/bin/$COMMAND"
  mkdir -p "$HOME/bin"
  set +H
  printf '#!/bin/bash\n' > "$SCRIPT_PATH"
  echo "bash <(curl -Ls https://raw.githubusercontent.com/eooce/sing-box/main/sb_serv00.sh)" >> "$SCRIPT_PATH"
  chmod +x "$SCRIPT_PATH"
  if [[ ":$PATH:" != *":$HOME/bin:"* ]]; then
      echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.bashrc" 2>/dev/null
      source "$HOME/.bashrc"
  fi
  green "快捷指令00创建成功,下次运行输入00快速进入菜单\n"
}

show_nodes(){
cat ${WORKDIR}/.npm/sub.txt 2>/dev/null
TOKEN=$(sed -n 's/^SUB_PATH=\(.*\)/\1/p' $HOME/domains/${USERNAME}.${CURRENT_DOMAIN}/public_nodejs/.env)
yellow "\n订阅链接: https://${USERNAME}.${CURRENT_DOMAIN}/${TOKEN}\n节点订阅链接适用于V2rayN/Nekoray/ShadowRocket/karing/Loon/sterisand 等\n"
}

menu() {
  clear
  echo ""
  purple "=== Serv00|Ct8|HostUNO VLESS+Argo 安装脚本 ===\n"
  green "1. 安装"
  echo  "==============="
  red "2. 卸载"
  echo  "==============="
  green "3. 查看节点信息"
  echo  "==============="
  yellow "4. 初始化系统"
  echo  "==============="
  red "0. 退出脚本"
  echo "==========="
  reading "请输入选择(0-4): " choice
  echo ""
  case "${choice}" in
      1) install_vless;;
      2) uninstall_vless;;
      3) show_nodes ;;
      4) reset_system ;;
      0) exit 0 ;;
      *) red "无效的选项，请输入 0 到 4" ;;
  esac
}
menu
