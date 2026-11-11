# 赫尔墨斯计划（Project Hermes）

自嗨性质但每个选型对标业界天花板的 IM 系统：产品级思维、玩具级规模。
目标是打通"接入 → 总线 → 存储 → 加密 → 客户端"完整链路，
深度体会 BEAM Actor 模型（状态内聚、无锁、轻量进程）。

## 技术栈（已定，不要建议更换）

- 接入层：Erlang/OTP，房间 Actor 用 Gleam 编写
- 协议层：WebSocket + Protobuf 起步，后期可升级 QUIC
- 消息总线：NATS JetStream
- 存储层：RocksDB（时序 KV，消息 ID 用 UUIDv7）
- 端到端加密：libsignal（官方 Rust 库，**禁止自研加密协议**）
- 客户端：Rust 核心 + UniFFI，SwiftUI / Compose 纯视图
- 桌面壳：Tauri

## 关键设计约定（不可违背）

- 消息投递 QoS1 + 业务层幂等（Bloom Filter 去重），不用 QoS2
- 多端同步采用收件箱模型：每个设备独立 sequence 游标
- 单个大房间 fanout 考虑树状分发（参考 Discord Manifold）
- 离线消息走 JetStream 持久化 + 上线后按游标拉取补投
- retained 消息仅用于在线状态，不用于聊天记录

## 目录结构

完整目录契约与依赖边界见 **`docs/STRUCTURE.md`**（单一事实来源）。

要点：
- 目标是 monorepo：`server/`（Gleam 接入层）、`core/`（Rust 核心）、
  `clients/`（iOS/Android/desktop 视图层）、`proto/`（协议契约）、`infra/`、`tools/`。
- Phase 1 代码暂平铺在仓库根 `src/`，**Phase 2 开工第 0 步**按
  `docs/STRUCTURE.md` 第六节迁移到 `server/`。
- 硬边界：server 与 core 永不发生代码依赖（只在 proto 契约会师）；
  客户端业务逻辑只存在于 core，视图层零逻辑。

## 常用命令

```sh
gleam run     # 运行主程序（Phase 1：在仓库根执行；迁移后改为 cd server && gleam run）
gleam test    # 行为测试（gleeunit）
gleam format  # 格式化
```

依赖：Erlang/OTP 26+、Gleam 1.x（`gleam` 与 `erl` 在 PATH 中）。
依赖版本锁在 gleam.toml；gleam_otp 当前为 1.x（`Next`/`Builder` 改版后的新 API）。

## 工作规则（给任何 AI agent / 协作者）

1. **路线图推进受控**：当前处于哪个 Phase 看 `docs/PLAN.md`；
   只有用户明确说"下一阶段"才能推进，不要一次性输出全部代码。
2. **每次只聚焦一个模块**，给可运行的最小代码，不给空谈架构图；
   涉及 BEAM/Gleam 时给完整可 `gleam run` 的项目。
3. **写 Gleam/OTP 代码前先核对当前 API**（hexdocs + 源码），
   gleam_otp/glean_erlang 改版频繁，凭记忆写必翻车。
4. **陷阱必须随代码提示**：幂等、游标、compaction 抖动、进程堆积、
   linked spawn 与 trap_exits、selector 与默认 subject、Erlang 原子表等。
5. 选型都要能说清"为什么它比 X 好"；遇到不可违背约定（见上）时不要提出替代方案，
   除非用户主动问。

## 已知陷阱备忘（Phase 1 实测沉淀）

- `actor.start` 是 **linked spawn**：父进程杀子进程时 exit 信号会传回父进程，
  需要主动 `trap_exits(True)`，否则整棵演示进程树当场退场。
- 给 actor 自定义 selector 时，**默认 subject 不会自动注册**，
  必须在 initialiser 里手动 `process.select(subject)` 加回来，
  否则业务消息全部被丢弃（仅告警，不报错）。
- `process.new_name` 绝不能在循环里调用，会烧穿 Erlang 原子表；
  名字应在程序入口创建一次。
- 主动退房要 `demonitor_process`，否则会收到迟到的 `'DOWN'`，
  房间处理 `'DOWN'` 时需兜底吞掉未知 monitor 的通知。
