// hermes 桌面端视图逻辑 —— 零业务规则：
// 命令 invoke 进 Rust（→ core），事件 "hermes" 回来只管渲染。

const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

const $ = (id) => document.getElementById(id);
const log = $("log");
let lastSeq = 0;
let connected = false;
let myName = "";
let leaving = false;
let currentSpace = "lobby";
let currentChannel = "general";

function backToJoin() {
  $("chat").classList.add("hidden");
  $("join").classList.remove("hidden");
  $("name").value = myName;
  $("name").focus();
}

// ---------- 主题 ----------

// 默认跟随系统；点 ☀/☾ 手动切换并记住（窗口标题栏一起切）
async function applyTheme(theme) {
  document.documentElement.dataset.theme = theme;
  localStorage.setItem("hermes-theme", theme);
  // 两处入口同步：入房卡片的固定按钮 + 聊天视图的用户菜单项
  const icon = theme === "light" ? "☾" : "☀";
  $("theme").textContent = icon;
  $("theme-item").textContent = `${icon} 切换主题`;
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

function renderRoomTag(count) {
  const text =
    `${currentSpace}/${currentChannel}` + (count != null ? ` · ${count}人在` : "");
  const tag = $("room-tag");
  tag.textContent = text;
  tag.title = text; // 截断时悬停看全名
}

function handle(ev) {
  switch (ev.type) {
    case "joined":
      addLine("notice", `已进入房间 · ${(ev.members || []).length} 人在线`);
      renderRoomTag((ev.members || []).length);
      connected = true;
      $("input").disabled = false;
      $("send").disabled = false;
      $("input").focus();
      break;
    case "members_changed":
      // 名单活水：实时人数跟随 presence 快照，不再停在入房那一刻
      renderRoomTag((ev.members || []).length);
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
      if (leaving) {
        // 主动退出：安静回退到入房卡片（游标与消息都已记住）
        leaving = false;
        backToJoin();
        break;
      }
      addLine("err", "连接断开 —— 消息已按游标记住，重新进入即可补上");
      setTimeout(backToJoin, 1200);
      break;
    // 空间/频道元数据事件：渲染 + 填充 datalist 建议
  case "space_list": {
    const dl = $("space-list");
    dl.innerHTML = "";
    const names = (ev.spaces || []).map((s) => s.name);
    for (const s of ev.spaces || []) {
      const opt = document.createElement("option");
      opt.value = s.name;
      opt.label = "owner: " + s.owner;
      dl.appendChild(opt);
    }
    addLine("notice", `空间 ${names.length} 个：${names.join(" · ") || "（空）"}`);
    break;
  }
  case "space_created":
    addLine("notice", `空间已创建：${ev.name}（你是 owner）`);
    break;
  case "channel_list": {
    const dl = $("channel-list");
    dl.innerHTML = "";
    for (const c of ev.channels || []) {
      const opt = document.createElement("option");
      opt.value = c;
      dl.appendChild(opt);
    }
    addLine("notice", `${ev.space} 的频道：${(ev.channels || []).join(" · ") || "（空）"}`);
    break;
  }
  case "channel_created":
    addLine("notice", `频道已创建：${ev.space}/${ev.name}`);
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
  // 日志先清再连：事件桥可能在 invoke 返回前就开始推帧
  //（后清会把刚到的 joined/通知一起抹掉——第三窗口"消息凭空消失"的坑）
  log.innerHTML = "";
  // 空间/频道在点击时就锁定：joined 事件可能抢在 invoke 返回前到达
  currentSpace = $("space").value.trim() || "lobby";
  currentChannel = $("channel").value.trim() || "general";
  try {
    // cursor 用设备记住的 lastSeq（重连补投的钥匙）；
    // 空间/频道随 join 下发（不存在则服务端自动建档，首进者即 owner）
    await invoke("connect", {
      url,
      name,
      cursor: lastSeq,
      space: $("space").value.trim(),
      channel: $("channel").value.trim(),
    });
    myName = name;
    $("user-btn").textContent = name;
    log.innerHTML = "";
    $("join").classList.add("hidden");
    $("chat").classList.remove("hidden");
    $("user-btn").textContent = name;    // 3 秒内没等到 joined = 桥有问题，明确说出来而不是干等
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

// ---- 空间/频道管理（聊天视图内；结果走事件回流渲染到 log）----
// 管理目标 = 当前所在空间；新名字共用 #new-name 输入框
// （manage 行在 #chat 内，未入房不可见；再加 connected 双保险）
$("btn-space-list").onclick = () => {
  if (connected) invoke("list_spaces");
};
$("btn-channel-list").onclick = () => {
  if (connected) invoke("list_channels", { space: currentSpace });
};
$("btn-space-create").onclick = () => {
  if (!connected) return;
  const name = $("new-name").value.trim();
  if (!name) return;
  $("new-name").value = "";
  invoke("create_space", { space: name });
};
$("btn-channel-create").onclick = () => {
  if (!connected) return;
  const name = $("new-name").value.trim();
  if (!name) return;
  $("new-name").value = "";
  invoke("create_channel", { space: currentSpace, channel: name });
};

function sendCurrent() {
  const text = $("input").value.trim();
  if (!text || !connected) return;
  invoke("send_message", { text });
  $("input").value = "";
}

// 退出房间：主动走 leave 帧（server 会清名册），游标两边都记着，
// 重进（哪怕换空间/频道）都不丢消息。入口在用户名弹窗里。
$("leave-item").onclick = () => {
  closeUserMenu();
  if (!connected) return;
  leaving = true;
  invoke("disconnect").catch((e) => {
    leaving = false;
    addLine("err", "退出失败: " + e);
  });
};

// ---- 用户名弹窗 ----
function closeUserMenu() {
  $("user-menu").classList.add("hidden");
}
$("user-btn").onclick = (e) => {
  e.stopPropagation();
  $("user-menu").classList.toggle("hidden");
};
$("theme-item").onclick = () => {
  applyTheme(document.documentElement.dataset.theme === "light" ? "dark" : "light");
};
// 点弹窗外任意处关闭
document.addEventListener("click", (e) => {
  if (!$("user-menu").classList.contains("hidden")) {
    const inMenu = $("user-menu").contains(e.target);
    const onBtn = $("user-btn").contains(e.target);
    if (!inMenu && !onBtn) closeUserMenu();
  }
});

$("send").onclick = sendCurrent;
$("input").addEventListener("keydown", (e) => {
  if (e.key === "Enter") sendCurrent();
});

startListen();
