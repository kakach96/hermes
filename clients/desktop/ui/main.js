// hermes 桌面端视图逻辑 —— 零业务规则：
// 命令 invoke 进 Rust（→ core），事件 "hermes" 回来只管渲染。
//
// 三段式视图：auth（登录/注册）→ home（大厅：空间/频道）→ chat（聊天）。
// 离开房间回大厅不断连；退出登录才真正断开。

const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

const $ = (id) => document.getElementById(id);
const log = $("log");
let lastSeq = 0;
let connected = false; // WS 活着（登录之后一直为 true，直到断线/退出登录）
let inRoom = false;    // 当前在聊天室里
let myName = "";
let currentSpace = "";
let currentChannel = "";
let selectedSpace = ""; // 大厅里当前点开的空间

// ---------- 主题 ----------

// 默认跟随系统；点 ☀/☾ 手动切换并记住（窗口标题栏一起切）
async function applyTheme(theme) {
  document.documentElement.dataset.theme = theme;
  localStorage.setItem("hermes-theme", theme);
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

// ---------- 视图切换 ----------

function showAuth() {
  $("main").classList.add("hidden");
  $("auth").classList.remove("hidden");
  $("name").focus();
}

function showHome() {
  $("chat").classList.add("hidden");
  $("home").classList.remove("hidden");
  $("room-tag").classList.add("hidden");
  $("leave-item").classList.add("hidden");
  selectedSpace = "";
  $("channel-list-ui").innerHTML = "";
  $("ch-title").textContent = "频道 · 选一个空间";
  invoke("list_spaces").catch(showHint);
}

function showChat() {
  $("home").classList.add("hidden");
  $("chat").classList.remove("hidden");
  $("room-tag").classList.remove("hidden");
  $("leave-item").classList.remove("hidden");
  $("input").focus();
}

function showHint(text, isErr = false) {
  const hint = $("home-hint");
  hint.textContent = text;
  hint.classList.toggle("err-text", isErr);
}

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

// ---------- 大厅渲染 ----------

function renderSpaces(spaces) {
  const ul = $("space-list-ui");
  ul.innerHTML = "";
  for (const s of spaces || []) {
    const li = document.createElement("li");
    li.className = "home-item" + (s.name === selectedSpace ? " selected" : "");
    li.innerHTML = `<span class="item-name"></span><span class="item-sub"></span>`;
    li.querySelector(".item-name").textContent = s.name;
    li.querySelector(".item-sub").textContent = "owner: " + s.owner;
    li.onclick = () => {
      selectedSpace = s.name;
      $("ch-title").textContent = `频道 · ${s.name}`;
      showHint("");
      // 重渲染以刷新选中态，再拉该空间频道
      renderSpaces(spaces);
      invoke("list_channels", { space: s.name }).catch(showHint);
    };
    ul.appendChild(li);
  }
  if (!spaces || spaces.length === 0) {
    const li = document.createElement("li");
    li.className = "home-empty";
    li.textContent = "还没有空间 —— 上面建一个";
    ul.appendChild(li);
  }
}

function renderChannels(space, channels) {
  const ul = $("channel-list-ui");
  ul.innerHTML = "";
  $("ch-title").textContent = `频道 · ${space}`;
  for (const c of channels || []) {
    const li = document.createElement("li");
    li.className = "home-item joinable";
    li.innerHTML = `<span class="item-name"></span><button class="mini enter">进入</button>`;
    li.querySelector(".item-name").textContent = "# " + c;
    li.querySelector(".enter").onclick = () => enterChannel(space, c);
    ul.appendChild(li);
  }
  if (!channels || channels.length === 0) {
    const li = document.createElement("li");
    li.className = "home-empty";
    li.textContent = "这个空间还没有频道";
    ul.appendChild(li);
  }
}

function enterChannel(space, channel) {
  // joined 帧不带空间/频道（server 不知道 UI 上下文），点击时就锁定；
  // cursor 用设备记住的 lastSeq（全局 stream seq，跨频道也不丢消息）
  currentSpace = space;
  currentChannel = channel;
  invoke("join_room", { cursor: lastSeq, space, channel }).catch(showHint);
}

// ---------- 事件桥 ----------

async function startListen() {
  try {
    await listen("hermes", ({ payload: ev }) => {
      document.title = `hermes · ${ev.type}`;
      try {
        handle(ev);
      } catch (e) {
        showHint("渲染错误: " + e.message, true);
      }
    });
  } catch (e) {
    showFatal("事件桥注册失败: " + (e?.message ?? String(e)));
  }
}

function handle(ev) {
  switch (ev.type) {
    case "logged_in":
      myName = ev.name;
      $("user-btn").textContent = ev.name;
      showHome();
      break;
    case "spaces":
      renderSpaces(ev.spaces);
      break;
    case "channel_list":
      if (ev.space === selectedSpace) renderChannels(ev.space, ev.channels);
      break;
    case "space_created":
      showHint(`空间已创建：${ev.name}（你是 owner）`);
      selectedSpace = ev.name;
      invoke("list_spaces").catch(() => {});
      invoke("list_channels", { space: ev.name }).catch(() => {});
      break;
    case "channel_created":
      // 建完直接进，顺滑
      enterChannel(ev.space, ev.name);
      break;
    case "joined":
      renderRoomTag((ev.members || []).length);
      inRoom = true;
      connected = true;
      $("input").disabled = false;
      $("send").disabled = false;
      $("input").focus();
      break;
    case "members_changed":
      renderRoomTag((ev.members || []).length);
      break;
    case "chat":
      addRow(ev.from, ev.text, ev.from === myName);
      if (ev.seq > lastSeq) lastSeq = ev.seq;
      break;
    case "notice":
      if (inRoom) addLine("notice", ev.text);
      break;
    case "room_left":
      inRoom = false;
      $("input").disabled = true;
      $("send").disabled = true;
      showHome();
      break;
    case "error":
      if (inRoom) addLine("err", ev.reason);
      else showHint(ev.reason, true);
      break;
    case "disconnected":
      handleDisconnected();
      break;
    default:
      showHint("未知事件: " + JSON.stringify(ev), true);
  }
}

function handleDisconnected() {
  const wasIn = connected;
  connected = false;
  inRoom = false;
  $("input").disabled = true;
  $("send").disabled = true;
  showAuth();
  if (wasIn) $("auth-error").textContent = "连接断开 —— 消息与游标都记着，重新登录即可";
}

function renderRoomTag(count) {
  const text =
    `${currentSpace}/${currentChannel}` + (count != null ? ` · ${count}人在` : "");
  const tag = $("room-tag");
  tag.textContent = text;
  tag.title = text; // 截断时悬停看全名
}

function showFatal(msg) {
  $("auth-error").textContent = msg;
}

// JS 侧任何未捕获错误都要可见，不许静默
window.addEventListener("unhandledrejection", (e) => {
  const r = e.reason;
  showFatal("错误: " + (r?.message ?? String(r)));
});
window.addEventListener("error", (e) => {
  showFatal("错误: " + e.message);
});

// ---------- 登录 ----------

$("login").onclick = async () => {
  const url = $("url").value.trim();
  const name = $("name").value.trim();
  if (!url || !name) {
    $("auth-error").textContent = "地址和名字都要填";
    return;
  }
  $("auth-error").textContent = "";
  $("login").disabled = true;
  try {
    await invoke("connect", { url });
    await invoke("login", { name });
    // logged_in 事件负责切到大厅
  } catch (e) {
    $("auth-error").textContent = String(e).replace(/^"|"$/g, "");
  } finally {
    $("login").disabled = false;
  }
};

$("name").addEventListener("keydown", (e) => {
  if (e.key === "Enter") $("login").click();
});

// ---------- 大厅操作 ----------

$("btn-new-space").onclick = () => {
  const name = $("new-space").value.trim();
  if (!name) return;
  $("new-space").value = "";
  invoke("create_space", { space: name }).catch(showHint);
};
$("btn-new-channel").onclick = () => {
  if (!selectedSpace) {
    showHint("先在左边选一个空间", true);
    return;
  }
  const name = $("new-channel").value.trim();
  if (!name) return;
  $("new-channel").value = "";
  invoke("create_channel", { space: selectedSpace, channel: name }).catch(showHint);
};

// ---------- 聊天操作 ----------

function sendCurrent() {
  const text = $("input").value.trim();
  if (!text || !inRoom) return;
  invoke("send_message", { text });
  $("input").value = "";
}

$("send").onclick = sendCurrent;
$("input").addEventListener("keydown", (e) => {
  if (e.key === "Enter") sendCurrent();
});

// ---------- 用户菜单 ----------

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
$("leave-item").onclick = () => {
  closeUserMenu();
  if (!inRoom) return;
  invoke("leave_room").catch((e) => addLine("err", "退出失败: " + e));
  // room_left 事件负责回大厅
};
$("logout-item").onclick = () => {
  closeUserMenu();
  invoke("logout").catch(() => {});
  // disconnected 事件负责回登录页
};
document.addEventListener("click", (e) => {
  if (!$("user-menu").classList.contains("hidden")) {
    const inMenu = $("user-menu").contains(e.target);
    const onBtn = $("user-btn").contains(e.target);
    if (!inMenu && !onBtn) closeUserMenu();
  }
});

startListen();
