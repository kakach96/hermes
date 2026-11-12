// hermes 桌面端视图逻辑 —— 零业务规则：
// 命令 invoke 进 Rust（→ core），事件 "hermes" 回来只管渲染。

const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

const $ = (id) => document.getElementById(id);
const log = $("log");
let lastSeq = 0;
let connected = false;
let myName = "";

// ---------- 主题 ----------

// 默认跟随系统；点 ☀/☾ 手动切换并记住（窗口标题栏一起切）
async function applyTheme(theme) {
  document.documentElement.dataset.theme = theme;
  localStorage.setItem("hermes-theme", theme);
  $("theme").textContent = theme === "light" ? "☾" : "☀";
  try {
    await window.__TAURI__.window.getCurrentWindow().setTheme(theme);
  } catch {
    // 权限缺失时只切页面不切标题栏，可接受
  }
}

applyTheme(
  localStorage.getItem("hermes-theme") ??
    (matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark"),
);

$("theme").onclick = () => {
  applyTheme(document.documentElement.dataset.theme === "light" ? "dark" : "light");
};

// ---------- 渲染 ----------

function now() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, "0");
  return `${p(d.getHours())}:${p(d.getMinutes())}`;
}

function scrollBottom() {
  log.scrollTop = log.scrollHeight;
}

function addRow(who, text, self = false) {
  const row = document.createElement("div");
  row.className = "row" + (self ? " self" : "");
  row.innerHTML = `
    <div class="meta"><span class="who">${escape(who)}</span><span>${now()}</span></div>
    <div class="body"></div>`;
  row.querySelector(".body").textContent = text;
  log.appendChild(row);
  scrollBottom();
}

function addLine(cls, text) {
  const line = document.createElement("div");
  line.className = cls;
  line.textContent = text;
  log.appendChild(line);
  scrollBottom();
}

// 极简转义（meta 里只放名字；正文一律 textContent）
function escape(s) {
  return s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
}

// ---------- 事件桥 ----------

async function startListen() {
  try {
    await listen("hermes", ({ payload: ev }) => {
      // 诊断：标题栏显示最后收到的事件类型（桥活了没一眼可见）
      document.title = `hermes · ${ev.type}`;
      try {
        handle(ev);
      } catch (e) {
        addLine("err", "渲染错误: " + e.message);
      }
    });
  } catch (e) {
    showFatal("事件桥注册失败: " + (e?.message ?? String(e)));
  }
}

function handle(ev) {
  switch (ev.type) {
    case "joined":
      addLine("notice", `已进入房间 · ${(ev.members || []).length} 人在线`);
      connected = true;
      $("input").disabled = false;
      $("send").disabled = false;
      $("input").focus();
      break;
    case "chat":
      addRow(ev.from, ev.text, ev.from === myName);
      if (ev.seq > lastSeq) lastSeq = ev.seq;
      break;
    case "notice":
      addLine("notice", ev.text);
      break;
    case "error":
      addLine("err", ev.reason);
      break;
    case "disconnected":
      connected = false;
      $("input").disabled = true;
      $("send").disabled = true;
      addLine("err", "连接断开 —— 消息已按游标记住，重新进入即可补上");
      setTimeout(() => {
        $("chat").classList.add("hidden");
        $("join").classList.remove("hidden");
        $("name").value = myName;
        $("name").focus();
      }, 1200);
      break;
    default:
      addLine("err", "未知事件: " + JSON.stringify(ev));
  }
}

function showFatal(msg) {
  $("join-error").textContent = msg;
  const line = document.createElement("div");
  line.className = "err";
  line.textContent = msg;
  document.body.appendChild(line);
}

// JS 侧任何未捕获错误都要可见，不许静默
window.addEventListener("unhandledrejection", (e) => {
  const r = e.reason;
  showFatal("错误: " + (r?.message ?? String(r)));
});
window.addEventListener("error", (e) => {
  showFatal("错误: " + (e.message ?? String(e)));
});

// ---------- 交互 ----------

$("connect").onclick = async () => {
  const url = $("url").value.trim();
  const name = $("name").value.trim();
  if (!url || !name) {
    $("join-error").textContent = "地址和名字都要填";
    return;
  }
  $("join-error").textContent = "";
  $("connect").disabled = true;
  try {
    // cursor 用设备记住的 lastSeq（重连补投的钥匙）
    await invoke("connect", { url, name, cursor: lastSeq });
    myName = name;
    log.innerHTML = "";
    $("join").classList.add("hidden");
    $("chat").classList.remove("hidden");
    $("me").textContent = name;
    // 3 秒内没等到 joined = 桥有问题，明确说出来而不是干等
    setTimeout(() => {
      if (!connected) {
        addLine("err", "3 秒未收到入房回执 —— 检查 server 是否在跑");
      }
    }, 3000);
  } catch (e) {
    $("join-error").textContent = String(e).replace(/^"|"$/g, "");
  } finally {
    $("connect").disabled = false;
  }
};

$("name").addEventListener("keydown", (e) => {
  if (e.key === "Enter") $("connect").click();
});

function sendCurrent() {
  const text = $("input").value.trim();
  if (!text || !connected) return;
  invoke("send_message", { text });
  $("input").value = "";
}

$("send").onclick = sendCurrent;
$("input").addEventListener("keydown", (e) => {
  if (e.key === "Enter") sendCurrent();
});

startListen();
