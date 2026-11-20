// 赫尔墨斯 M7.5 —— 登录/大厅 三段式流程端到端测试（Node 24 内置 WebSocket）
//
// 场景（随机空间名防撞车）：
//   1. login{name} → logged_in 回执
//   2. 未入房即可 space_list / space_create / channel_create（大厅能力）
//   3. join 进频道 → msg 往返
//   4. leave → left 回执，连接**保持**：再 space_list 立刻有回应
//   5. 换频道再 join（同连接切频道）
//   6. join 时 name 与登录名不一致 → 拒绝
//
// 用法：node tools/e2e_home.mjs   （需要 server 已启动）

const URL = "ws://127.0.0.1:8080/ws";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const S = "e2home" + crypto.randomUUID().replaceAll("-", "").slice(0, 10);

function open() {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(URL);
    ws.messages = [];
    ws.onmessage = (e) => {
      const m = JSON.parse(e.data);
      ws.messages.push(m);
      console.log(`  <- ${e.data}`);
    };
    ws.onopen = () => resolve(ws);
    ws.onerror = (e) => reject(new Error("连接失败: " + e.message));
  });
}
const send = (ws, obj) => ws.send(JSON.stringify(obj));
const got = (ws, type, pred) => ws.messages.some((m) => m.type === type && (!pred || pred(m)));

let failures = 0;
function check(label, cond) {
  console.log(cond ? `PASS ${label}` : `FAIL ${label}`);
  if (!cond) failures++;
}

// 1. 登录
const ws = await open();
send(ws, { type: "login", name: "Alice" });
await sleep(300);
check("登录回执", got(ws, "logged_in", (m) => m.name === "Alice"));

// 2. 大厅能力（未入房）
send(ws, { type: "space_list" });
await sleep(250);
check("未入房可列空间", got(ws, "spaces"));
send(ws, { type: "space_create", space: S });
await sleep(250);
check("未入房可建空间", got(ws, "space_created", (m) => m.name === S));
send(ws, { type: "channel_create", space: S, channel: "dev" });
await sleep(250);
check("owner 可建频道", got(ws, "channel_created", (m) => m.name === "dev"));

// 3. 入频道 + 消息
send(ws, { type: "join", cursor: 0, space: S, channel: "dev" });
await sleep(400);
check("进入频道", got(ws, "joined"));
send(ws, { type: "msg", text: "大厅流程OK", dedup_id: "h1" });
await sleep(400);
check("频道消息往返", got(ws, "chat", (m) => m.dedup_id === "h1"));

// 4. 离房不断连
send(ws, { type: "leave" });
await sleep(300);
check("离房回执", got(ws, "left"));
const mark = ws.messages.length;
send(ws, { type: "space_list" });
await sleep(300);
check("离房后连接仍在（space_list 有回应）",
  ws.messages.slice(mark).some((m) => m.type === "spaces"));

// 5. 同连接换频道再进
send(ws, { type: "channel_create", space: S, channel: "random" });
await sleep(250);
send(ws, { type: "join", cursor: 0, space: S, channel: "random" });
await sleep(400);
check("换频道再进", got(ws, "joined"));

// 6. 冒名 join 拒绝
send(ws, { type: "join", name: "Mallory", cursor: 0, space: S, channel: "dev" });
await sleep(300);
check("冒名 join 被拒", got(ws, "error", (m) => m.code === "login_identity_conflict"));

// 7. 离房期间的消息：重进同频道后必须补投（GUI 用户的核心场景）
send(ws, { type: "join", cursor: 0, space: S, channel: "dev" });
await sleep(400);
const bob = await open();
send(bob, { type: "login", name: "Bob" });
await sleep(300);
send(bob, { type: "join", cursor: 0, space: S, channel: "dev" });
await sleep(400);
const markLeave = ws.messages.length;
send(ws, { type: "leave" });
await sleep(300);
// Alice 离房期间 Bob 发两条
send(bob, { type: "msg", text: "你不在-1", dedup_id: "away1" });
await sleep(250);
send(bob, { type: "msg", text: "你不在-2", dedup_id: "away2" });
await sleep(400);
// 重进：cursor 传 0，server 用它代存的游标补投
send(ws, { type: "join", cursor: 0, space: S, channel: "dev" });
await sleep(600);
const afterRejoin = ws.messages.slice(markLeave);
check(
  "重进补投离房期间的两条消息",
  afterRejoin.some((m) => m.type === "chat" && m.dedup_id === "away1") &&
    afterRejoin.some((m) => m.type === "chat" && m.dedup_id === "away2"),
);
bob.close();

ws.close();
console.log(failures === 0 ? "== E2E HOME ALL PASS ==" : `== E2E ${failures} FAILURES ==`);
process.exit(failures === 0 ? 0 : 1);
