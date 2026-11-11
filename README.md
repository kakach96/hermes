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

需要：Erlang/OTP 29、Gleam 1.19（`D:\programs` 下，已入 PATH）、Rust (msvc)、Node。

```sh
# 1. 起 NATS（仓库根）
infra\nats-server.exe -c infra\nats.conf

# 2. 起服务器
cd server && gleam run

# 3. 起 Tauri 客户端 ×2（M5 完成后）
cd clients\desktop && npm i && npm run tauri dev
```

## 文档

| 文件 | 内容 |
| --- | --- |
| `AGENTS.md` | 项目宪法：技术栈、设计约定、工作规则、陷阱备忘 |
| `docs/PLAN.md` | 路线图、里程碑、ADR 摘要、踩坑记录（单一事实来源） |
| `docs/STRUCTURE.md` | 目录契约与依赖边界 |
