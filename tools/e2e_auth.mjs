// 赫尔墨斯 M14 —— HTTP 认证平面（密码 + 一次性令牌）端到端测试
//
// 场景：
//   1. register {name,password} → 201 {name,token}；重复注册 → 409 code=exists
//   2. 弱密码 → 400 code=weak_password
//   3. login 正确密码 → 200 {token}；错误密码 → 401 code=bad_password；
//      不存在用户 → 401 code=not_found
//   4. WS ?token= 升级即登录（回 logged_in）；**同一 token 第二次连接失效**
//   5. ?name= 裸工具路径仍然可用（dev-only，见 proto README）
//
// 用法：node tools/e2e_auth.mjs   （需要 server 已启动）

const BASE = "http://127.0.0.1:8080";
const WS = "ws://127.0.0.1:8080/ws";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const U = "e2pw" + crypto.randomUUID().replaceAll("-", "").slice(0, 8);
const PW = "correct horse battery 9";

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

// 1/2/3. 注册与登录语义（机器码断言）
let r = await post("/v1/register", { name: U, password: PW });
let body = await r.json();
check("注册 → 201 + token", r.status === 201 && typeof body.token === "string");

r = await post("/v1/register", { name: U, password: PW });
body = await r.json();
check("重复注册 → 409 exists", r.status === 409 && body.code === "exists");

r = await post("/v1/register", { name: U + "x", password: "short" });
body = await r.json();
check("弱密码 → 400 weak_password", r.status === 400 && body.code === "weak_password");

r = await post("/v1/login", { name: U, password: PW });
body = await r.json();
check("正确密码 → 200 + token", r.status === 200 && typeof body.token === "string");
const token = body.token;

r = await post("/v1/login", { name: U, password: "wrong password" });
body = await r.json();
check("错误密码 → 401 bad_password", r.status === 401 && body.code === "bad_password");

r = await post("/v1/login", { name: "no-such-user-xz", password: PW });
body = await r.json();
check("不存在用户 → 401 not_found", r.status === 401 && body.code === "not_found");

// 4. 一次性令牌：WS 升级即登录；重放失效
function openWs(url) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    ws.messages = [];
    ws.onmessage = (e) => ws.messages.push(JSON.parse(e.data));
    ws.onopen = () => resolve(ws);
    ws.onerror = (e) => reject(new Error("ws fail: " + e.message));
  });
}
const ws1 = await openWs(`${WS}?token=${token}`);
await sleep(400);
check(
  "?token= 升级回 logged_in",
  ws1.messages.some((m) => m.type === "logged_in" && m.name === U),
);
ws1.close();

// 已消费的 token 不能再用
const ws2 = await openWs(`${WS}?token=${token}`);
await sleep(400);
check("token 一次性（重放无身份）", !ws2.messages.some((m) => m.type === "logged_in"));
ws2.close();

// 5. ?name= 裸工具路径（dev-only）
const ws3 = await openWs(`${WS}?name=${encodeURIComponent(U)}`);
await sleep(400);
check(
  "?name= dev 路径仍可用",
  ws3.messages.some((m) => m.type === "logged_in" && m.name === U),
);
ws3.close();

console.log(failures === 0 ? "== E2E AUTH ALL PASS ==" : `== E2E ${failures} FAILURES ==`);
process.exit(failures === 0 ? 0 : 1);
