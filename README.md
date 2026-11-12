# 赫尔墨斯（Project Hermes）

自嗨性质但每个选型对标业界天花板的 IM 系统：产品级思维、玩具级规模。
打通"接入 → 总线 → 存储 → 加密 → 客户端"完整链路。

## 当前状态：冲刺模式（v0 端到端）

所有模块先各做一个能跑的版本，里程碑 M1~M6 见 `docs/PLAN.md`。

```
Tauri 客户端 ×2 ──WebSocket──► server (Gleam) ──► NATS JetStream（持久化）
                                   │
                                   └─Erlang port─► storage（fjall sidecar）
core（Rust）= 客户端唯一逻辑所在；libsignal 加密在 core 内
```

- [x] M1 目录迁移 monorepo
- [x] M2 NATS v2.15.3 单二进制 + JetStream 就绪
- [ ] M3 server：WS 监听 + 会话 Actor + NATS 客户端 + 离线补投
- [ ] M4 storage：fjall sidecar（Erlang port 行协议）
- [ ] M5 core + Tauri：双实例聊天
- [ ] M6 libsignal 端到端加密

## 运行

需要：Erlang/OTP 29、Gleam 1.19（`D:\programs` 下，已入 PATH）、Rust (msvc)、Node 24、rebar3。

```sh
# 0. 构建 fjall 存储 sidecar（首次）
cd storage && cargo build --release && cd ..

# 1. 起 NATS（仓库根）
infra\nats-server.exe -c infra\nats.conf

# 2. 起服务器
cd server && gleam run        # ws://127.0.0.1:8080/ws

# 3. 起两个终端端到端冒烟（裸 WS 客户端）
node tools\e2e_ws.mjs

# 4. Tauri 客户端 ×2
#    构建一次 release（首次约几分钟），之后直接多开 exe：
cd clients\desktop
npm run tauri build -- --no-bundle
start src-tauri\target\release\hermes-desktop.exe
start src-tauri\target\release\hermes-desktop.exe

#    ⚠ 双端不要用两个 `npm run tauri dev`：dev 会重新编译并覆盖
#    target\debug\hermes-desktop.exe，而第一个实例正锁着这个文件
#    （Windows os error 5 拒绝访问）。dev 只用于开发单实例。
```

## 文档

| 文件 | 内容 |
| --- | --- |
| `AGENTS.md` | 项目宪法：技术栈、设计约定、工作规则、陷阱备忘 |
| `docs/PLAN.md` | 路线图、里程碑、ADR 摘要、踩坑记录（单一事实来源） |
| `docs/STRUCTURE.md` | 目录契约与依赖边界 |
