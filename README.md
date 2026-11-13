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

需要：Erlang/OTP 29、Gleam 1.19（`D:\programs` 下）、Rust (msvc)、Node 24、rebar3。

```sh
# 一键起停（自动探测端口，已在跑的跳过；进程脱离终端，关终端不影响）
scripts\hermes.cmd up        # NATS + 存储 sidecar 构建 + server
scripts\hermes.cmd client    # 开一个客户端窗口（再执行一次 = 双端）
scripts\hermes.cmd status    # 端口与进程状态
scripts\hermes.cmd down      # 停 server + NATS

# 手动等价命令（脚本内部细节见 scripts\hermes.ps1）
infra\nats-server.exe -c infra\nats.conf
cd server && gleam run       # ws://127.0.0.1:8080/ws
node tools\e2e_ws.mjs        # 裸 WS 双端冒烟

# ⚠ 双端开发不要用两个 `npm run tauri dev`：dev 会重编译并覆盖
#   target\debug\*.exe，第一个实例锁着该文件（os error 5）。
#   release 构建一次后多开 exe 才是多开正解（client 子命令即此路线）。
```

## 文档

| 文件 | 内容 |
| --- | --- |
| `AGENTS.md` | 项目宪法：技术栈、设计约定、工作规则、陷阱备忘 |
| `docs/PLAN.md` | 路线图、里程碑、ADR 摘要、踩坑记录（单一事实来源） |
| `docs/STRUCTURE.md` | 目录契约与依赖边界 |
