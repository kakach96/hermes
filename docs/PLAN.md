# 赫尔墨斯计划 · 路线图与技术决策记录

> 单一事实来源：项目处于哪个 Phase、每个 Phase 的验收标准、踩过的坑，都记在这里。
> 本文件状态：Phase 1 已完成骨架，等待用户验证。

## 总目标

自嗨性质，但每个选型对标业界天花板。核心诉求：

1. 深度体会 BEAM Actor 模型（状态内聚、无锁、轻量进程）
2. 打通"接入 → 总线 → 存储 → 加密 → 客户端"完整链路
3. 每个选型都能说清"为什么它比 X 好"

## 技术决策记录（ADR 式摘要）

| 决策点 | 选定 | 为什么不选别的（一句话理由） |
| --- | --- | --- |
| 接入层语言 | Erlang/OTP + Gleam | Actor 是一等公民；Gleam 给类型安全，Erlang 生态兜底 |
| QoS | QoS1 + Bloom Filter 幂等 | QoS2 的两次握手代价换不来聊天场景的收益，幂等在业务层做 |
| 多端同步 | 收件箱模型 + 每设备游标 | 按设备拉取，天然支持离线补投，参考 Telegram |
| 大房间 fanout | 树状分发 | 线性 fanout O(N) 会打爆单进程邮箱，参考 Discord Manifold |
| 消息总线 | NATS JetStream | 比 Kafka 轻量一个数量级，比 RabbitMQ 的流能力更贴 IM 离线补投 |
| 存储引擎 | fjall（纯 Rust LSM sidecar，经 Erlang port 接入） | v1 决策：替代 RocksDB——纯 Rust 免 NIF 编译（cmake/MSVC/rebar3 地狱），API 形态同为 LSM KV；RocksDB 路线保留在 ADR 档案里 |
| 桌面壳 | Tauri 直接依赖 core（v0 无 UniFFI） | src-tauri 是 Rust，path 依赖 hermes-core 即可；UniFFI 待 iOS/Android 出现时再引入 |
| E2E 加密 | libsignal（官方 Rust 库） | 禁止自研加密协议；ProVerif 形式化验证放 Phase 6 |
| 客户端 | Rust 核心 + UniFFI | 一套核心逻辑喂 SwiftUI / Compose，视图层纯声明式 |
| retained | 仅在线状态 | 聊天记录走存储层，不塞 retained，参考 MQTT 最佳实践 |

## 冲刺模式（2026-11-11 策略变更）

> 原策略：严格按 Phase 串行，每个模块打磨完再进下一个。
> 新策略：**所有模块先各做一个 v0 版本，端到端跑通再回头加深。**

v0 端到端验收目标：两个 Tauri 客户端经 WebSocket 连 server，房间互聊，
消息落 NATS JetStream 持久化，fjall 存历史，离线重连按设备游标补投，
core 内置 libsignal 会话（加密里程碑见 M6）。

| 里程碑 | 内容 | 状态 |
| --- | --- | --- |
| M1 | 目录迁移 monorepo（server/infra/proto/core/storage/clients/tools） | ✅ 已迁入 server/，冒烟通过 |
| M2 | infra：nats-server 单二进制 + 配置，JetStream 就绪 | ✅ v2.15.3，文件存储已验证 |
| M3 | server：最小 NATS 客户端（FFI）+ 会话 Actor + JetStream 离线补投 | ✅ 含 WS 会话，e2e 全绿（含跨重启历史重放） |
| M4 | storage：fjall sidecar（Erlang port 行协议）+ server store 驱动 | ✅ 游标/成员名单持久化，sidecar 崩溃重启数据仍在，10 测试全绿 |
| M5 | core + Tauri：WS 连接、游标补投、Bloom 幂等、双实例聊天 | ✅ GUI 单实例全链路实测通过（入房/补投/发送），node e2e 覆盖双实例 |
| M6 | crypto：libsignal 会话建立 + 端到端密文 | ⬜ |

v0 明确**不做**（留给第二轮）：树状 fanout、QUIC、UniFFI、iOS/Android 视图、
ProVerif、RocksDB。任何文档冲突以本表为准。

### 原路线图（存档，仍按模块为第二轮的深化顺序）

### Phase 1：Gleam Actor 聊天室 ✅（已通过本机验证：gleam 1.19.2 / OTP 29.1.2）

覆盖：`spawn / send / receive / call / monitor / selector / named_subject / static_supervisor`。

- [x] 房间 Actor：Join / Msg / Leave / 'DOWN' 四种消息，状态仅一份成员名单
- [x] 客户端 Actor：只收广播、只打印，代替未来的 WebSocket 连接
- [x] 静态监督树：房间为 worker，`actor.named` + `named_subject` 保证重启后通道有效
- [x] monitor 演示：kill 客户端进程 → 房间收 'DOWN' → 广播掉线
- [x] 两个行为测试（Join 回执名单 / 掉线广播）
- [x] 陷阱沉淀：linked spawn + trap_exits、selector 与默认 subject、迟到 'DOWN'、原子表

**验收**：`gleam run` 输出确定性剧本（含 Bob 掉线被清理）；`gleam test` 全绿。

**Phase 1 遗留的开放问题（进入 Phase 2 时带过去）**：

- 房间状态在 supervisor 重启后会丢（成员名单归零）——Phase 2 用 JetStream 做状态外置
- 单房间广播是线性 `list.each`，O(N) —— Phase 4 之后考虑树状分发
- 无 stdin REPL，演示是剧本式的 —— 视需要在 Phase 2 加交互输入

### Phase 2：接 NATS JetStream，补离线消息（未开始）

- **步骤 0：目录迁移** —— 按 `docs/STRUCTURE.md` 第六节把 Phase 1 代码移入
  `server/`，建 `infra/`、`tools/`，同步更新文档（迁移完成后回来勾掉本条）
- NATS 连接进程（actor），房间广播双写：成员收件箱 + JetStream 流
- 离线设备上线后按游标从流里补投
- 开放问题待决：房间/会话状态的 supervisor 重启恢复策略（外置 NATS 还是 store）
- 验收：客户端进程"死掉再复活"能收到期间的所有消息

### Phase 3：RocksDB 落库 + UUIDv7 游标拉取历史（未开始）

- 消息 key 设计：`room:{id}:{uuidv7}` 时序前缀
- compaction 参数建议（避免写放大抖动）
- 环境坑预告：erlang-rocksdb 是 NIF 依赖，gleam 构建会调 rebar3，
  Windows 上需要 MSVC 工具链 + CMake（详见 STRUCTURE.md 第四节）
- 验收：重启整个 VM 后历史消息仍可按游标拉取

### Phase 4：Rust 核心协议层 + UniFFI 客户端绑定（未开始）

- Protobuf 协议定义（Join/Msg/Leave 映射）
- Rust core：连接管理、游标管理、Bloom Filter 幂等
- UniFFI 绑定，SwiftUI / Compose 纯视图

### Phase 5：libsignal 端到端加密（未开始）

- 双棘轮会话建立、多设备 session
- 明文只在 Rust core 内部，UI 层只见密文/明文结果

### Phase 6（可选自嗨）：QUIC 升级 + ProVerif 协议形式化验证（未开始）

## 踩坑记录（持续追加）

| Phase | 坑 | 处置 |
| --- | --- | --- |
| 1 | `actor.start` 是 linked spawn，kill 子进程会带走父进程 | 父进程 `trap_exits(True)` |
| 1 | 自定义 selector 后默认 subject 不自动注册 | initialiser 里手动 `process.select(subject)` |
| 1 | 迟到的 'DOWN'（demonitor 前已投递） | 处理时兜底吞掉未知 monitor |
| 1 | `process.new_name` 动态调用烧原子表 | 入口创建一次，传引用下去 |
| 1 | Gleam 内层闭包参数不继承外层返回类型标注（`fn(x: A) -> fn(B) -> C` 中内层 `x` 类型未知） | 给内层闭包参数显式标注类型 |
| 1 | `_` 前缀绑定名只能当丢弃 pattern，不能在表达式位置引用 | 需要引用的绑定用正常名字 |
| 1 | 测试进程结束后残留 client actor 打印触发 `device has terminated` crash report | 无害噪音；actor 应在测试结束前显式停掉（低优先级） |
| M3 | gen_tcp socket 的 controlling process 是调用方，spawn 的连接进程收不到 `{tcp,...}` | 建连后立即 `controlling_process` 交接；passive 建连 + `go` 握手消除 INFO 先到的竞态 |
| M3 | NATS CONNECT 帧必须带 `CONNECT ` 前缀，裸 JSON = `-ERR Unknown Protocol Operation` 且连接悄悄死掉（无日志） | 协议帧逐字对齐；-ERR 视为致命快速失败 |
| M3 | JetStream push consumer 投递的 MSG subject 是**消息原始 subject**（房间），不是 deliver_subject；路由必须按订阅 sid | FFI 按 sid 路由，OnMsg 传 (inbox, 原始 subject, reply, payload) |
| M3 | NATS 2.15（API level 5，Strict）拒绝裸 ConsumerConfig：要包一层 `{stream_name, config}`；ephemeral consumer 默认闲置 5s 即删；`inactive_threshold` 要纳秒 int 不接受字符串 | 显式包层 + inactive_threshold 1800e9 ns；API 响应里的 error 字段必须检查（bus 曾把错误响应当成功） |
| M3 | `by_start_sequence` 的 `opt_start_seq` 是包含起点 | 游标契约定义为"下一条要收的 seq"，重放传 cursor+1 |
| M3 | shell 里 Start-Process 拉起的 NATS 会在 shell 会话结束时被作业对象收割 | 用 WMI `Win32_Process Create` 真脱离父进程 |
| M3 | presence 每会话各挂一个 NATS sub → 每次发布投递 N 份副本，路由字典按 subject 键互相覆盖，最后入房的会话收到 N 遍 | 同一 presence subject 全局只挂一个 sub，bus 内部按 token 名单扇出 |
| M4 | fjall 2 的 `Keyspace::open` 收 `Config` 不是字符串路径 | `fjall::Keyspace::open(fjall::Config::new(dir))` |
| M4 | Erlang port `{packet, 4}` 帧格式必须两侧严格对齐（大端 u32 长度 + 载荷） | Rust 侧手写 framing，天然对齐 |
| M4 | port 的 owner 是打开它的进程；sidecar 崩溃 → exit 信号带走 owner → 监督树重启重建 port，fjall 落盘数据自动恢复 | 崩溃即恢复，测试覆盖 |
| M4 | `catch` 在 OTP 29 已弃用 | 之后统一换 `try ... catch ... end`（低优先级警告） |
| M5 | `tauri-build` 在 Windows 必须有 `icons/icon.ico`（bundle.active=false 也逃不掉，它是资源编译不是打包） | `tools/gen_icon.py` 纯 struct 手写 ICO（BMP 路径，BGR 字节序、高度翻倍、自底向上） |
| M5 | Tauri 异步命令里 `tokio::spawn` 可用（tauri 自带 tokio runtime），但 src-tauri 需显式依赖 tokio（sync feature 足够） | 显式加依赖 |
| M5 | 去重过滤器只在**收到**时登记 dedup_id；发送时登记会把自己的消息当重复丢掉 | transport.rs 注释 |
| M5 | Tauri v2 权限系统：前端 `event.listen` 需要能力声明，没有 capabilities 文件时默认拒绝（且报错对象没有 message，界面只会显示 "undefined"） | 写 `src-tauri/capabilities/default.json` 授 `core:default`；错误显示一律 `String(e)` 全字串化 |
| M5 | 【全局】`erlang:unique_integer` 是 per-VM 计数器：任何跨 VM 的唯一性场景（NATS subject、测试数据目录）都会撞号。实际撞了三次：consumer inbox 跨 VM 串消息（服务器实例间也会！）、request-reply 回执串线、测试数据目录跨运行残留 | 唯一性一律用 `unique_inbox`：每调用 48bit crypto 随机 + unique_integer 兜底；这条规则进 AGENTS 备忘 |
| M5 | 双端多开不能用两个 `tauri dev`：第二个 dev 要覆盖 `target\debug\*.exe`，而第一个实例锁着该文件（os error 5） | release 构建一次后直接多开 exe；README 已写明 |
| M6 | cargo 的 git 依赖会全量 fetch 仓库历史：signalapp/libsignal 这类多语言 monorepo（数 GB）在慢网络下假死（还叠加 package cache 锁互相等待） | 本地 shallow clone vendor 到仓库外（`git clone --depth 1`），Cargo.toml 用 path 依赖；crates.io 同名 `libsignal-protocol` 是社区旧 C 绑定（要 cmake），勿用 |
| M6 | libsignal（官方 Rust）的 store 方法是 `async_trait(?Send)` → 返回 !Send future，进不了 `tokio::spawn` 的任务 | crypto 独立线程 + 每次调用 `now_or_never()` 同步驱动（这些 future 从不真正挂起，官方测试同款） |
| M6 | libsignal 许可证 AGPL-3.0（强传染） | 自嗨项目无碍；若未来分发闭源客户端需替换实现或独立进程隔离 |
