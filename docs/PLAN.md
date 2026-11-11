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
| 存储 | RocksDB 时序 KV + UUIDv7 | UUIDv7 单调可排序，游标拉取无需索引；LSM 适合写多读少 |
| E2E 加密 | libsignal（官方 Rust 库） | 禁止自研加密协议；ProVerif 形式化验证放 Phase 6 |
| 客户端 | Rust 核心 + UniFFI | 一套核心逻辑喂 SwiftUI / Compose，视图层纯声明式 |
| retained | 仅在线状态 | 聊天记录走存储层，不塞 retained，参考 MQTT 最佳实践 |

## 路线图

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
