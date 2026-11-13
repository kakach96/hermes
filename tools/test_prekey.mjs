// 服务端 prekey 注册/取回协议验证（绕过 core，裸 WS）
const URL = "ws://127.0.0.1:8080/ws";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function connect(name) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(URL);
    ws.frames = [];
    ws.onmessage = (e) => ws.frames.push(JSON.parse(e.data));
    ws.onopen = () => {
      ws.send(JSON.stringify({ type: "join", name, cursor: 0 }));
      resolve(ws);
    };
    ws.onerror = (e) => reject(new Error("连接失败"));
  });
}

const a = await connect("PkTestA");
await sleep(300);
a.send(JSON.stringify({ type: "prekey_register", bundle: "TEST-BUNDLE-A" }));
await sleep(300);

const b = await connect("PkTestB");
await sleep(300);
b.send(JSON.stringify({ type: "prekey_fetch", for: "PkTestA" }));
await sleep(400);

const got = b.frames.find((m) => m.type === "prekey_bundle");
console.log("prekey_bundle 回执:", JSON.stringify(got));
console.log(got && got.bundle === "TEST-BUNDLE-A" ? "PASS: server 注册/取回 OK" : "FAIL: server 侧问题");
a.close();
b.close();
process.exit(0);
