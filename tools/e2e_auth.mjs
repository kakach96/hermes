// 赫尔墨斯 M8 —— HTTP 认证平面端到端测试（Node 24 内置 fetch + WebSocket）
//
// 场景：
//   1. POST /v1/register 新名字 → 201；重复注册 → 409
//   2. POST /v1/login 存在 → 200；不存在 → 401
//   3. GET /v1/spaces / /v1/spaces/<s>/channels 只读目录
//   4. WS ?name= 升级即登录（免 login 帧）→ 大厅帧直接可用
//   5. 非法名（超长/空格）→ 400
//
// 用法：node tools/e2e_auth.mjs   （需要 server 已启动）

const BASE = "http://127.0.0.1:8080";
const URL = "ws://127.0.0.1:8080/ws";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const U = "e2auth" + crypto.randomUUID().replaceAll("-", "").slice(0, 8);

let failures = 0;
function check(label, cond) {
  console.log(cond ? `PASS ${label}` : `FAIL ${label}`);
  if (!cond) failures++;
}
const post = (p, body) =>
  fetch(BASE + p, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });

// 1/2. 注册与登录语义
let r = await post("/v1/register", { name: U });
check("注册新用户 → 201", r.status === 201 && (await r.json()).name === U);
r = await post("/v1/register", { name: U });
check("重复注册 → 409", r.status === 409);
r = await post("/v1/login", { name: U });
check("登录存在用户 → 200", r.status === 200);
r = await post("/v1/login", { name: "no-such-user-xz" });
check("登录不存在 → 401", r.status === 401);
r = await post("/v1/register", { name: "x".repeat(33) });
check("超长名 → 400", r.status === 400);
r = await post("/v1/register", { name: "  " });
check("纯空名 → 400", r.status === 400);

// 3. 只读目录
r = await fetch(BASE + "/v1/spaces");
check("GET /v1/spaces → 200", r.status === 200);
const spaces = await r.json();
check("spaces 是数组", Array.isArray(spaces.spaces));
r = await fetch(BASE + "/v1/spaces/lobby/channels");
check("GET channels → 200", r.status === 200);
const chans = await r.json();
check("channels 含字段", Array.isArray(chans.channels));

// 4. WS ?name= 升级即登录（免 login 帧）
const ws = new WebSocket(URL + "?name=" + encodeURIComponent(U));
ws.messages = [];
ws.onmessage = (e) => ws.messages.push(JSON.parse(e.data));
await new Promise((res) => (ws.onopen = res));
await sleep(400);
check("?name= 升级回 logged_in", ws.messages.some(
  (m) => m.type === "logged_in" && m.name === U));
ws.send(JSON.stringify({ type: "space_list" }));
await sleep(300);
check("未 join 即可用大厅帧", ws.messages.some((m) => m.type === "spaces"));
ws.close();

console.log(failures === 0 ? "== E2E AUTH ALL PASS ==" : `== E2E ${failures} FAILURES ==`);
process.exit(failures === 0 ? 0 : 1);
