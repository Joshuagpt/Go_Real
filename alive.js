const http = require('http');
const { execSync } = require('child_process');
const axios = require('axios');
const fs = require('fs');
const os = require('os');
const path = require('path');
require('dotenv').config();

const SUB_TOKEN = process.env.SUB_TOKEN;
const API_SUB_URL = process.env.UPLOAD_URL;
const TELEGRAM_CHAT_ID = process.env.TELEGRAM_CHAT_ID;
const TELEGRAM_BOT_TOKEN = process.env.TELEGRAM_BOT_TOKEN;
const HOSTNAME = os.hostname();
const USERNAME = os.userInfo().username.toLowerCase();

// 重启脚本地址（你的VLESS一键脚本）
const RESTART_SCRIPT_URL = 'https://raw.githubusercontent.com/Joshuagpt/Go_Real/main/00_vl.sh';
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

if (process.env.NEZHA_SERVER && process.env.NEZHA_PORT && process.env.NEZHA_KEY) {
  services.push({ name: 'nezha', match: /-s .+:\d+ -p .+/ });
  console.log(new Date().toISOString() + ' - Nezha 服务已启用。');
} else if (process.env.NEZHA_SERVER && process.env.NEZHA_KEY) {
  services.push({
    name: 'nezha',
    match: `-c ${os.homedir()}/domains/${USERNAME}.${CURRENT_DOMAIN}/logs/config.yaml`
  });
  console.log(new Date().toISOString() + ' - Nezha 服务已启用（使用配置文件模式）。');
} else {
  console.log(new Date().toISOString() + ' - Nezha 服务未启用，缺少必要的环境变量。');
}

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

async function downloadAndRunRestartScript() {
  try {
    const res = await axios.get(RESTART_SCRIPT_URL);
    fs.writeFileSync(SCRIPT_PATH, res.data, { mode: 0o755 });

    // 读取 .env 并导出环境变量
    let envContent = '';
    try {
      envContent = fs.readFileSync('.env', 'utf8');
    } catch (e) {}

    const exportCmds = envContent
      .split('\n')
      .filter(line => line.trim() && !line.startsWith('#'))
      .map(line => `export ${line}`)
      .join(' && ');

    console.log(new Date().toISOString() + ' - Running restart script for all services.');
    execSync(`${exportCmds} && bash ${SCRIPT_PATH}`, { stdio: 'inherit' });
    fs.unlinkSync(SCRIPT_PATH);
    return true;
  } catch (err) {
    console.error(new Date().toISOString() + ' - Failed to run restart script: ' + err.message);
    await sendTelegramMessage(`❌ 重启脚本执行失败\n\n账户: ${USERNAME}\n服务器: ${HOSTNAME}\n错误详情: ${err.message}`);
    return false;
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
    monitorInterval = setInterval(monitorServices, 120000); // 2分钟检查一次
  }
}

function getProcessList() {
  try {
    return execSync('ps aux').toString();
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

async function addUrl() {
  try {
    const res = await axios.post('https://keep.gvrander.eu.org/add-url', { url: START_URL }, {
      headers: { 'Content-Type': 'application/json' }
    });
    console.log('添加 URL 结果: ' + JSON.stringify(res.data));
    sendTelegramMessage(`✅ 全自动保活任务添加成功\n\n账户: ${USERNAME}\n服务器: ${HOSTNAME}\n调起进程: ${START_URL}\n\n重启进程: ${RESTART_URL}\n进程列表: ${LIST_URL}\n\n进程状态: ${STATUS_URL}`);
  } catch (err) {
    console.error('添加 URL 失败: ' + err.message);
    sendTelegramMessage(`❌ 全自动保活任务添加失败\n\n账户: ${USERNAME}\n服务器: ${HOSTNAME}\n保活URL: ${START_URL}\n错误信息: ${err.message}`);
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
  if (req.url === '/') {
    startMonitoring();
    res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end('Hello world!\n');
  } else if (['/run', `/${USERNAME}`, '/go', '/start'].includes(req.url)) {
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
  } else if (req.url === '/stop') {
    stopProcess('config.json');
    stopProcess('tunnel --edge-ip-version');
    res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end('所有相关进程已停止');
  } else if (req.url === '/list') {
    const list = getProcessList();
    res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end(list || 'Failed to get process list.');
  } else if (req.url === '/status') {
    let status = {};
    for (const svc of services) {
      status[svc.name] = isProcessRunning(svc.match) ? 'running' : 'stopped';
    }
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify(status, null, 2));
  } else if (req.url === '/restart') {
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
  addUrl();
  uploadSuburl();
});
