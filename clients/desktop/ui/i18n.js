// hermes UI i18n —— 中英双语（zh / en）。
//
// 约定（见 docs/CONVENTIONS.md）：
// - 字典键只增不改语义；动态文案一律 t(key, vars)，静态 DOM 用
//   data-i18n / data-i18n-ph / data-i18n-title 声明，切语言统一刷
// - UI 生成的文案在这里；服务端/核心回吐的消息（房间通知、HTTP 文本）
//   本轮不翻译——需要协议层出 message code，已记入 PLAN
// - 语言优先级：localStorage 记忆 > 系统语言；菜单里随时切
//
// 整体包 IIFE：字典与函数不污染全局（顶层 t/setLang 与 main.js 的
// 解构声明撞名会直接 SyntaxError 杀掉整个脚本——实测踩过）。

(() => {
  const HERMES_I18N = {
    zh: {
      "auth.namePh": "你的名字（新名字 = 注册）",
      "auth.signIn": "登录",
      "auth.signUp": "注册",
      "auth.needBoth": "地址和名字都要填",
      "auth.exists": "用户已存在，请改用「登录」",
      "auth.notFound": "用户不存在，请先「注册」",
      "auth.connLost": "连接断开 —— 消息与游标都记着，重新登录即可",

      "home.spaces": "空间",
      "home.channelsPick": "频道 · 选一个空间",
      "home.channelsOf": "频道 · {name}",
      "home.newSpacePh": "新空间名",
      "home.createSpace": "建空间",
      "home.newChannelPh": "新频道名",
      "home.createChannel": "建频道",
      "home.enter": "进入",
      "home.ownerIs": "owner: {name}",
      "home.noSpaces": "还没有空间 —— 上面建一个",
      "home.noChannels": "这个空间还没有频道",
      "home.pickSpaceFirst": "先在左边选一个空间",
      "home.spaceCreated": "空间已创建：{name}（你是 owner）",

      "chat.inputPh": "说点什么…",
      "chat.leaveFail": "退出失败: {e}",
      "room.onlineN": "{n}人在",

      "menu.lang": "语言",
      "menu.theme": "切换主题",
      "menu.leaveRoom": "退出房间",
      "menu.signOut": "退出登录",

      "theme.title": "切换浅色/深色",
      "account.title": "账号菜单",

      "misc.renderErr": "渲染错误: {msg}",
      "misc.bridgeFail": "事件桥注册失败: {msg}",
      "misc.err": "错误: {msg}",
      "misc.unknownEv": "未知事件: {ev}",
    },

    en: {
      "auth.namePh": "Your name (a new name signs you up)",
      "auth.signIn": "Sign in",
      "auth.signUp": "Sign up",
      "auth.needBoth": "Server address and name are both required",
      "auth.exists": "That name is taken — use Sign in",
      "auth.notFound": "No such user — Sign up first",
      "auth.connLost": "Connection lost — your cursor is remembered, sign in again to catch up",

      "home.spaces": "Spaces",
      "home.channelsPick": "Channels · pick a space",
      "home.channelsOf": "Channels · {name}",
      "home.newSpacePh": "New space name",
      "home.createSpace": "Create space",
      "home.newChannelPh": "New channel name",
      "home.createChannel": "Create channel",
      "home.enter": "Enter",
      "home.ownerIs": "owner: {name}",
      "home.noSpaces": "No spaces yet — create one above",
      "home.noChannels": "No channels in this space yet",
      "home.pickSpaceFirst": "Pick a space on the left first",
      "home.spaceCreated": "Space created: {name} (you are the owner)",

      "chat.inputPh": "Say something…",
      "chat.leaveFail": "Leave failed: {e}",
      "room.onlineN": "{n} online",

      "menu.lang": "Language",
      "menu.theme": "Toggle theme",
      "menu.leaveRoom": "Leave room",
      "menu.signOut": "Sign out",

      "theme.title": "Toggle light/dark",
      "account.title": "Account menu",

      "misc.renderErr": "Render error: {msg}",
      "misc.bridgeFail": "Event bridge failed: {msg}",
      "misc.err": "Error: {msg}",
      "misc.unknownEv": "Unknown event: {ev}",
    },
  };

  function detectLang() {
    const saved = localStorage.getItem("hermes-lang");
    if (saved === "zh" || saved === "en") return saved;
    return (navigator.language || "").toLowerCase().startsWith("zh") ? "zh" : "en";
  }

  let lang = detectLang();

  /// 取文案；{var} 插值；缺失键回落 zh 字典再回落键名（开发期显眼）
  function t(key, vars) {
    const dict = HERMES_I18N[lang] || {};
    let s = dict[key] ?? HERMES_I18N.zh[key] ?? key;
    if (vars) {
      for (const [k, v] of Object.entries(vars)) {
        s = s.replaceAll("{" + k + "}", String(v));
      }
    }
    return s;
  }

  /// 刷静态声明（data-i18n*），再让 main.js 重绘动态文案
  function applyI18nStatic() {
    document.documentElement.lang = lang === "zh" ? "zh-CN" : "en";
    for (const el of document.querySelectorAll("[data-i18n]")) {
      el.textContent = t(el.dataset.i18n);
    }
    for (const el of document.querySelectorAll("[data-i18n-ph]")) {
      el.placeholder = t(el.dataset.i18nPh);
    }
    for (const el of document.querySelectorAll("[data-i18n-title]")) {
      el.title = t(el.dataset.i18nTitle);
    }
    if (window.__hermesOnLang) window.__hermesOnLang();
  }

  function setLang(next) {
    lang = next;
    localStorage.setItem("hermes-lang", lang);
    applyI18nStatic();
  }

  // main.js 注册：切语言后重绘主题图标、房间标签、大厅列表等动态文案
  window.__hermesOnLang = undefined;

  applyI18nStatic();
  window.hermesI18n = {
    t,
    setLang,
    cycleLang: () => setLang(lang === "zh" ? "en" : "zh"),
    get lang() {
      return lang;
    },
  };
})();
