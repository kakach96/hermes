// 赫尔墨斯 M7 —— 空间/频道 端到端测试（Node 24 内置 WebSocket）
//
// 场景（全用随机空间名，防跨运行撞车）：
//   1. Alice 加入 space S/channel general（自动建档，首个进入者 = owner）
//   2. Bob 加入同一频道 → 双方 joined，名单 2 人
//   3. Bob 发 msg → Alice 收到（频道即房间，JetStream 路径不变）
//   4. Alice 空间列表 → 含 S（owner Alice）
//   5. Bob 在 S 里建频道 → 拒绝（member 无权）；Alice 建频道 → 成功
//   6. Alice 新建空间 S2 → 成功；频道列表列出 S 下的频道
//   7. join 非法名（带点号）→ error 帧（subject token 安全线）
//
// 用法：node tools/e2e_spaces.mjs   （需要 server 已启动）

const URL = "ws://127.0.0.1:8080/ws";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const S = "e2esp" + crypto.randomUUID().replaceAll("-", "").slice(0, 10);
const S2 = S + "b";

function connect(name, cursor, space, channel) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(URL);
    ws.messages = [];
    ws.onmessage = (e) => {
      const m = JSON.parse(e.data);
      ws.messages.push(m);
      console.log(`[${name}] <- ${e.data}`);
    };
    ws.onopen = () => {
      const join = { type: "join", name, cursor };
      if (space) join.space = space;
      if (channel) join.channel = channel;
      ws.send(JSON.stringify(join));
      resolve(ws);
    };
    ws.onerror = (e) => reject(new Error("连接失败: " + e.message));
  });
}

let failures = 0;
function check(label, cond) {
  console.log(cond ? `PASS ${label}` : `FAIL ${label}`);
  if (!cond) failures++;
}
const sent = (ws, type) => ws.messages.some((m) => m.type === type);

// 1/2. 双人入同一空间频道
const alice = await connect("Alice", 0, S, "general");
await sleep(300);
const bob = await connect("Bob", 0, S, "general");
await sleep(500);
const aliceJoined = alice.messages.find((m) => m.type === "joined");
const bobJoined = bob.messages.find((m) => m.type === "joined");
check("双方收到 joined", aliceJoined && bobJoined);
check("Bob 名单 2 人", bobJoined && bobJoined.members.length === 2);

// 3. 频道即房间：消息路径不变
bob.send(JSON.stringify({ type: "msg", text: "空间频道路径OK", dedup_id: "sp1" }));
await sleep(500);
check("Alice 收到频道消息", alice.messages.some(
  (m) => m.type === "chat" && m.dedup_id === "sp1" && m.seq > 0));

// 4. 空间列表含 S，owner = Alice
alice.send(JSON.stringify({ type: "space_list" }));
await sleep(300);
const spaces = alice.messages.find((m) => m.type === "spaces");
check("空间列表含 S(owner Alice)", spaces &&
  spaces.spaces.some((s) => s.name === S && s.owner === "Alice"));

// 5. 权限：member 建频道被拒，owner 成功
bob.send(JSON.stringify({ type: "channel_create", space: S, channel: "bobchan" }));
await sleep(300);
check("Bob 建频道被拒（member）", bob.messages.some(
  (m) => m.type === "error" && m.code === "channel_forbidden"));
alice.send(JSON.stringify({ type: "channel_create", space: S, channel: "random" }));
await sleep(300);
check("Alice 建频道成功（owner）", alice.messages.some(
  (m) => m.type === "channel_created" && m.name === "random"));

// 6. 管理面：建空间 S2 + 频道列表
alice.send(JSON.stringify({ type: "space_create", space: S2 }));
await sleep(300);
check("建空间 S2 成功", alice.messages.some(
  (m) => m.type === "space_created" && m.name === S2));
alice.send(JSON.stringify({ type: "channel_list", space: S }));
await sleep(300);
const channels = alice.messages.find((m) => m.type === "channels" && m.space === S);
check("频道列表含 general/random", channels &&
  channels.channels.includes("general") && channels.channels.includes("random"));

// 7. 注入防线：空间名带点号（会切 subject token）→ error；用户名宽松合法
const mallory = await connect("bad.name", 0, "bad.space", "general");
await sleep(300);
check("非法空间名被拒", mallory.messages.some((m) => m.type === "error"));
mallory.close();

alice.close();
bob.close();
console.log(failures === 0 ? "== E2E SPACES ALL PASS ==" : `== E2E ${failures} FAILURES ==`);
process.exit(failures === 0 ? 0 : 1);
