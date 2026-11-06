const http = require('http');
const crypto = require('crypto');
const { execSync } = require('child_process');
const axios = require('axios');
const fs = require('fs');
const os = require('os');
const path = require('path');
const dotenv = require('dotenv');

const ENV_FILE = path.join(__dirname, '.env');
dotenv.config({ path: ENV_FILE });

const SUB_TOKEN = process.env.SUB_TOKEN;
// 管理接口（/list /stop /restart）令牌：优先 ADMIN_TOKEN，未设置时沿用 SUB_TOKEN
const ADMIN_TOKEN = process.env.ADMIN_TOKEN || SUB_TOKEN || '';
const API_SUB_URL = process.env.UPLOAD_URL;
const TELEGRAM_CHAT_ID = process.env.TELEGRAM_CHAT_ID;
const TELEGRAM_BOT_TOKEN = process.env.TELEGRAM_BOT_TOKEN;
const HOSTNAME = os.hostname();
const USERNAME = os.userInfo().username.toLowerCase();

// 重启脚本：保活的对象是 00_vl_xhttp.sh。可用环境变量 RESTART_SCRIPT_URL 覆盖（例如固定到某个 commit），
// 并可用 RESTART_SCRIPT_SHA256 钉住内容，校验不一致则拒绝执行
const RESTART_SCRIPT_URL = process.env.RESTART_SCRIPT_URL || 'https://raw.githubusercontent.com/Joshuagpt/Go_Real/main/00_vl_xhttp.sh';
const RESTART_SCRIPT_SHA256 = (process.env.RESTART_SCRIPT_SHA256 || '').trim().toLowerCase();
const SCRIPT_PATH = path.join(os.homedir(), 'vl_restart.sh');

let CURRENT_DOMAIN;
if (/ct8/.test(HOSTNAME)) {
  CURRENT_DOMAIN = 'ct8.pl';
} else if (/hostuno/.test(HOSTNAME)) {
  CURRENT_DOMAIN = 'useruno.com';
} else {
  CURRENT_DOMAIN = 'serv00.net';
}

const RESTART_URL = `http://keep.${USERNAME}.${CURRENT_DOMAIN}/restart`;
const START_URL = `http://keep.${USERNAME}.${CURRENT_DOMAIN}/${USERNAME}`;
const LIST_URL = `http://keep.${USERNAME}.${CURRENT_DOMAIN}/list`;
const STATUS_URL = `http://keep.${USERNAME}.${CURRENT_DOMAIN}/status`;
const SUB_URL = `https://${USERNAME}.${CURRENT_DOMAIN}/${SUB_TOKEN}.log`;

const services = [
  { name: 'xray', match: /-c config\.json/ },
  { name: 'argo', match: /tunnel --edge-ip-version/ }
];

function isProcessRunning(match) {
  try {
    const output = execSync('ps aux').toString();
    if (typeof match === 'string') {
      return output.includes(match);
    } else if (match instanceof RegExp) {
      return match.test(output);
    }
    return false;
  } catch (err) {
    console.error(new Date().toISOString() + ' - Failed to check process: ' + err.message);
    return false;
  }
}

function isAuthorized(req, url) {
  if (!ADMIN_TOKEN) return false;
  const given = url.searchParams.get('token') || req.headers['x-admin-token'] || '';
  const a = Buffer.from(String(given));
  const b = Buffer.from(ADMIN_TOKEN);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

// 防止定时检查与 HTTP 触发同时重启
let restarting = false;

async function downloadAndRunRestartScript() {
  if (restarting) {
    console.log(new Date().toISOString() + ' - Restart already in progress, skipping.');
    return false;
  }
  restarting = true;
  try {
    const res = await axios.get(RESTART_SCRIPT_URL, { responseType: 'arraybuffer', timeout: 30000 });
    const buf = Buffer.from(res.data);
    if (buf.length < 200 || buf.slice(0, 2).toString() !== '#!') {
      throw new Error('下载内容不是有效的 shell 脚本: ' + RESTART_SCRIPT_URL);
    }
    if (RESTART_SCRIPT_SHA256) {
      const got = crypto.createHash('sha256').update(buf).digest('hex');
      if (got !== RESTART_SCRIPT_SHA256) {
        throw new Error(`重启脚本 SHA256 校验失败 (期望 ${RESTART_SCRIPT_SHA256}, 实际 ${got})`);
      }
    }
    fs.writeFileSync(SCRIPT_PATH, buf, { mode: 0o700 });

    // 重新读取 .env，保证拿到最新配置；以环境变量方式传给脚本，避免拼接 shell 命令
    let envVars = {};
    try {
      envVars = dotenv.parse(fs.readFileSync(ENV_FILE, 'utf8'));
    } catch (e) {}

    console.log(new Date().toISOString() + ' - Running restart script for all services.');
    execSync(`bash ${SCRIPT_PATH}`, {
      stdio: 'inherit',
      // KEEPALIVE_RESTART=1 告知脚本：由保活进程触发，不要杀掉或重装保活服务自身
      env: { ...process.env, ...envVars, KEEPALIVE_RESTART: '1' }
    });
    return true;
  } catch (err) {
    console.error(new Date().toISOString() + ' - Failed to run restart script: ' + err.message);
    await sendTelegramMessage(`❌ 重启脚本执行失败\n\n账户: ${USERNAME}\n服务器: ${HOSTNAME}\n错误详情: ${err.message}`);
    return false;
  } finally {
    try { fs.unlinkSync(SCRIPT_PATH); } catch (e) {}
    restarting = false;
  }
}

async function sendTelegramMessage(text) {
  if (!TELEGRAM_CHAT_ID && !TELEGRAM_BOT_TOKEN) {
    console.warn(new Date().toISOString() + ' - Telegram credentials not configured.');
    return;
  }
  try {
    if (TELEGRAM_CHAT_ID && TELEGRAM_BOT_TOKEN) {
      await axios.post(`https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage`, {
        chat_id: TELEGRAM_CHAT_ID,
        text: text,
        parse_mode: 'HTML',
        disable_web_page_preview: true
      });
    }
  } catch (err) {
    console.error(new Date().toISOString() + ' - Failed to send Telegram message: ' + err.message);
  }
}

async function monitorServices() {
  if (restarting) return;
  let allRunning = true;
  for (const svc of services) {
    if (!isProcessRunning(svc.match)) {
      console.log(new Date().toISOString() + ` - ${svc.name} is not running.`);
      await sendTelegramMessage(`⚠️ Serv00服务离线通知\n\n${svc.name} 服务离线\n\n账户: ${USERNAME}\n服务器: ${HOSTNAME}`);
      allRunning = false;
      break;
    }
  }

  if (!allRunning) {
    const success = await downloadAndRunRestartScript();
    if (success) {
      console.log(new Date().toISOString() + ' - Services restart script executed successfully, checking START_URL...');
      try {
        const res = await axios.get(START_URL, {
          httpsAgent: new (require('https').Agent)({ rejectUnauthorized: false }),
          timeout: 10000
        });
        if (res.data.includes('running')) {
          await sendTelegramMessage(`✅ 所有服务已成功重启!\n\n账户: ${USERNAME}\n服务器: ${HOSTNAME}\n进程状态: ${STATUS_URL}`);
        } else {
          await sendTelegramMessage(`❌ Serv00服务重启失败\n账户: ${USERNAME}\n服务器: ${HOSTNAME}\n请手动尝试开启：${START_URL}`);
        }
      } catch (err) {
        await sendTelegramMessage(`❌ 检查服务状态失败\n账户: ${USERNAME}\n服务器: ${HOSTNAME}\n错误信息: ${err.message}`);
      }
    } else {
      await sendTelegramMessage(`❌ Serv00服务重启失败\n账户: ${USERNAME}\n服务器: ${HOSTNAME}\n请手动检查服务状态。`);
    }
  }
}

let monitorInterval = null;
function startMonitoring() {
  if (!monitorInterval) {
    console.log(new Date().toISOString() + ' - Starting monitoring services.');
    monitorInterval = setInterval(monitorServices, 120000);
  }
}

function getProcessList() {
  try {
    // 进程命令行里可能带 cloudflared 的 --token，输出前打码
    return execSync('ps aux').toString().replace(/(--token\s+)\S+/g, '$1***');
  } catch (err) {
    console.error(new Date().toISOString() + ' - Failed to get process list: ' + err.message);
    return null;
  }
}

function stopProcess(keyword) {
  try {
    const output = execSync('ps aux').toString();
    const lines = output.split('\n');
    for (const line of lines) {
      if (line.includes(keyword)) {
        const pid = line.trim().split(/\s+/)[1];
        execSync(`kill -9 ${pid}`);
        console.log(new Date().toISOString() + ` - Stopped process with PID: ${pid}`);
      }
    }
    return true;
  } catch (err) {
    console.error(new Date().toISOString() + ' - Failed to stop process: ' + err.message);
    return false;
  }
}

async function uploadSuburl() {
  if (API_SUB_URL) {
    const url = API_SUB_URL + '/api/add-subscriptions';
    const data = { subscription: [SUB_URL] };
    axios.post(url, data, { headers: { 'Content-Type': 'application/json' } })
      .then(res => console.log('Request successful:', res.status))
      .catch(err => console.error('Error making request:', err.message));
  }
}

const server = http.createServer(async (req, res) => {
  let url;
  try {
    url = new URL(req.url, 'http://localhost');
  } catch (e) {
    res.writeHead(400);
    res.end('Bad Request');
    return;
  }
  const pathname = url.pathname;

  // 需要鉴权的管理接口
  if (['/stop', '/list', '/restart'].includes(pathname) && !isAuthorized(req, url)) {
    res.writeHead(403, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end('Forbidden');
    return;
  }

  if (pathname === '/') {
    startMonitoring();
    res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end('Hello world!\n');
  } else if (['/run', `/${USERNAME}`, '/go', '/start'].includes(pathname)) {
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    let allRunning = true;
    for (const svc of services) {
      if (!isProcessRunning(svc.match)) {
        allRunning = false;
        break;
      }
    }
    if (allRunning) {
      res.end(JSON.stringify({ status: 'running', message: '所有服务都正在运行' }, null, 2));
    } else {
      res.end(`正在启动进程中,访问 http://keep.${USERNAME}.${CURRENT_DOMAIN}/${USERNAME}`);
      await downloadAndRunRestartScript();
    }
  } else if (pathname === '/stop') {
    stopProcess('config.json');
    stopProcess('tunnel --edge-ip-version');
    res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end('所有相关进程已停止');
  } else if (pathname === '/list') {
    const list = getProcessList();
    res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end(list || 'Failed to get process list.');
  } else if (pathname === '/status') {
    let status = {};
    for (const svc of services) {
      status[svc.name] = isProcessRunning(svc.match) ? 'running' : 'stopped';
    }
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify(status, null, 2));
  } else if (pathname === '/restart') {
    res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end(`服务重启成功,20秒后访问并刷新 http://keep.${USERNAME}.${CURRENT_DOMAIN}/status 查看进程是否都是running状态`);
    await downloadAndRunRestartScript();
  } else {
    res.writeHead(404);
    res.end('Not Found');
  }
});

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => {
  console.log(new Date().toISOString() + ` - Keepalive server running on port ${PORT}`);
  startMonitoring();
  uploadSuburl();
});
