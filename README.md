# 赫尔墨斯（Project Hermes）

自嗨性质但每个选型对标业界天花板的 IM 系统：产品级思维、玩具级规模。
打通"接入 → 总线 → 存储 → 加密 → 客户端"完整链路，深度体会 BEAM Actor 模型与 Rust 高性能系统。

[中文](README.md) | [English](README.en.md)

## 架构一瞥

```
Tauri 客户端 ×N ──WebSocket──► server (Gleam/OTP) ──► NATS JetStream（持久化 + 游标重放）
                    │                │
                    │                └─Erlang port─► storage（fjall sidecar：游标/注册表）
                    │
core（Rust）= 客户端唯一逻辑所在（传输/游标/Bloom 幂等/libsignal 加密）
```

- 完整组件图与数据流：[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
- 当前状态与路线图：[`docs/PLAN.md`](docs/PLAN.md)（v0 端到端闭环已达成，M1~M6 全绿）

## 运行

依赖：Erlang/OTP 26+、Gleam 1.x、Rust stable（msvc）、Node 18+（仅客户端构建需要）、rebar3。
（本机工具链不在系统 PATH 时，启动脚本会自动探测并前置。）

Linux/Docker 部署（server + 存储 sidecar + NATS 全容器化，NATS 用官方镜像按 tag 锁版本）：

```sh
docker compose up --build -d
```

Windows 本机开发（一键起停：自动探测端口，已在跑的跳过；进程脱离终端，关终端不影响）：
scripts\hermes.cmd up        # NATS + 存储 sidecar 构建 + server
scripts\hermes.cmd client    # 开一个客户端窗口（再执行一次 = 多开）
scripts\hermes.cmd status    # 端口与进程状态
scripts\hermes.cmd down      # 停 server + NATS

# 手动等价命令（脚本内部细节见 scripts\hermes.ps1）
infra\nats-server.exe -c infra\nats.conf
cd server && gleam run       # ws://127.0.0.1:8080/ws
node tools\e2e_ws.mjs        # 裸 WS 双端冒烟
```

libsignal 为 path 依赖（官方 Rust 实现，shallow clone 到仓库根 `vendor/`，不入库）：

```sh
git clone --depth 1 https://github.com/signalapp/libsignal vendor/libsignal
```

测试：

```sh
cd server && gleam test      # server 行为测试
cd core && cargo test        # core 单元测试（含 crypto 会话往返）
```

> ⚠ 多端开发不要用两个 `npm run tauri dev`：dev 会重编译并覆盖
> `target\debug\*.exe`，第一个实例锁着该文件（os error 5）。
> release 构建一次后多开 exe 才是多开正解（`client` 子命令即此路线）。

## 文档

| 文件 | 内容 |
| --- | --- |
| `AGENTS.md` | 项目宪法：技术栈、设计约定、工作规则、陷阱备忘 |
| `docs/PLAN.md` | 路线图、里程碑状态、ADR 摘要、踩坑记录（单一事实来源） |
| `docs/STRUCTURE.md` | 目录契约与依赖边界 |
| `docs/ARCHITECTURE.md` | 组件结构、运行时数据流、加密流（[English](docs/ARCHITECTURE.en.md)） |
| `docs/CONVENTIONS.md` | 各模块编码规范、提交纪律、红线清单 |
| `proto/hermes/v1/README.md` | v0 线格式（JSON 帧契约） |
