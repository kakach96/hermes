// 赫尔墨斯 v0 —— WebSocket 端到端测试（Node 24 内置 WebSocket 客户端）
//
// 场景：
//   1. Alice / Bob 两个客户端经 WS 连入 lobby
//   2. Alice 发一条消息 → 双方都应经 JetStream 收到（带 seq）
//   3. Alice "断线"（直接关连接）
//   4. Alice 以保存的游标重连 → Bob 再发一条 → Alice 应只收到新的那条
//
// 用法：node tools/e2e_ws.mjs   （需要 server 已启动）

const URL = "ws://127.0.0.1:8080/ws";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function connect(name, cursor) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(URL);
    ws.messages = [];
    ws.onmessage = (e) => {
      const m = JSON.parse(e.data);
      ws.messages.push(m);
      console.log(`[${name}] <- ${e.data}`);
    };
    ws.onopen = () => {
      ws.send(JSON.stringify({ type: "join", name, cursor }));
      resolve(ws);
    };
    ws.onerror = (e) => reject(new Error("连接失败: " + e.message));
  });
}

function latestSeq(ws, dedupId) {
  const chat = ws.messages.filter(
    (m) => m.type === "chat" && m.dedup_id === dedupId,
  );
  return chat.length ? chat[chat.length - 1].seq : 0;
}

let failures = 0;
function check(label, cond) {
  console.log(cond ? `PASS ${label}` : `FAIL ${label}`);
  if (!cond) failures++;
}

const alice = await connect("Alice", 0);
const bob = await connect("Bob", 0);
await sleep(500);

check("双方收到 joined", alice.messages.some((m) => m.type === "joined") &&
  bob.messages.some((m) => m.type === "joined"));
check("Alice 收到加入通知(含自己)", alice.messages.some(
  (m) => m.type === "notice" && m.text.includes("Alice 加入了房间")));

// 消息广播
alice.send(JSON.stringify({ type: "msg", text: "端到端!", dedup_id: "e1" }));
await sleep(500);
check("Bob 收到 e1", bob.messages.some(
  (m) => m.type === "chat" && m.dedup_id === "e1" && m.text === "端到端!"));
const seqE1 = latestSeq(bob, "e1");
check("e1 带 seq", seqE1 > 0);

// Alice 断线（不发 leave，模拟网络闪断）
alice.close();
await sleep(300);

// Bob 在 Alice 离线期间再发一条
bob.send(JSON.stringify({ type: "msg", text: "你断线了", dedup_id: "e2" }));
await sleep(300);

// Alice 按游标重连：应补投 e2（且不重投 e1）
const alice2 = await connect("Alice", seqE1);
await sleep(700);
check("Alice 补投 e2", alice2.messages.some(
  (m) => m.type === "chat" && m.dedup_id === "e2"));
check("Alice 不重投 e1", !alice2.messages.some(
  (m) => m.type === "chat" && m.dedup_id === "e1"));

bob.send(JSON.stringify({ type: "leave" }));
bob.close();

console.log(failures === 0 ? "== E2E ALL PASS ==" : `== E2E ${failures} FAILURES ==`);
process.exit(failures === 0 ? 0 : 1);
