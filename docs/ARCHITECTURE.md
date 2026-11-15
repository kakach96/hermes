# 赫尔墨斯 · 架构（v0）

> 本文描述 v0 端到端闭环的组件结构与运行时数据流。
> 目录契约见 `docs/STRUCTURE.md`，路线图与状态见 `docs/PLAN.md`。
> English: [docs/ARCHITECTURE.en.md](ARCHITECTURE.en.md)

## 一、总览

```
 ┌─────────────────────────────────────────────────────────────────┐
 │                            clients                              │
 │        desktop (Tauri)      ·      ios/android (round 2)        │
 │                pure views — zero business logic                 │
 └───────────────────────────────┬─────────────────────────────────┘
                                 │ Rust API (v0) / UniFFI (round 2)
 ┌───────────────────────────────▼─────────────────────────────────┐
 │                         core (Rust)                             │
 │    transport · codec · sync(cursor) · idempotency(Bloom)         │
 │                  crypto — libsignal（X3DH/PQXDH                 │
 │                  + 双棘轮），密钥永不越出 core                   │
 └──────────────┬───────────────────────────────────┬──────────────┘
                │ WebSocket（JSON，v0）             │
                │ （QUIC + protobuf，第二轮）        │
 ┌──────────────▼───────────────────────────────────▼──────────────┐
 │                  server（Gleam on Erlang/OTP）                  │
 │    ws (mist) · session · rooms(动态) · room · meta · bus        │
 │           E2E 密文的不透明转发者 —— 只见密文                      │
 └───────┬─────────────────────────────────────────┬───────────────┘
         │ NATS 协议                               │ Erlang port（stdio，JSON 行）
 ┌───────▼────────────────────┐        ┌───────────▼─────────────────────┐
 │   NATS JetStream（infra）  │        │  storage sidecar（Rust, fjall） │
 │   hermes_chat 流：         │        │  设备游标、prekey 注册表        │
 │   聊天持久化 + 游标重放     │        │  （被 server 监督，可崩溃重启） │
 │   presence：非持久订阅     │        └─────────────────────────────────┘
 └────────────────────────────┘
```

一句话：**视图层（Tauri）零逻辑 → 逻辑全在 core → server 只做会话/路由/持久化编排 →
NATS JetStream 承担持久化与重放 → fjall sidecar 承担游标等状态外置。**

## 二、组件职责

| 组件 | 语言 | 职责 | 明确不做 |
| --- | --- | --- | --- |
| `clients/desktop` | Tauri (JS + Rust 壳) | 渲染、事件转发 | 任何业务/加密逻辑 |
| `core` | Rust | WS 传输、编解码、每设备游标、Bloom 幂等、libsignal 加密 | 不理解 server 内部实现 |
| `server` | Gleam/Erlang | WS 接入、会话 Actor、房间 Actor、NATS 收发、prekey 注册表、port 驱动 | 解密（永远只见密文） |
| `storage` | Rust (fjall) | 状态外置 sidecar：get/put 行协议 | 不开网络端口 |
| `infra` | NATS v2.15.3 | JetStream 持久化流 + presence 瞬时通道 | 版本不浮动 |

## 三、运行时数据流

### 1. 入房与成员活水

```
client ──join{name, cursor, space?, channel?}──► session
         ├─ 名字校验：用户名宽松；space/channel 必须 subject-token 安全
         ├─ 元数据建档（fjall meta 域）：user_touch / 空间自动建档（首进者=owner）
         │   / 频道自动建档 / 成员资格登记（members partition，持久）
         ├─ rooms 管理器：按 <space>.<channel> 惰性 spawn 房间 Actor
         └─ room.Join
              ├─ 名单去重置顶（roster = 连接生命周期，不持久化）
              ├─ presence: Notice("xx 加入了房间")
              ├─ presence: Members(快照)   ← 名单活水
              └─ 返回当前名单
```

- 成员资格 = 连接生命周期：服务重启/会话断开即离开，**名册从不落盘**。
- 每次加入/退房都向 presence 通道广播 `Members` 快照，先来者的加密目标集合实时更新。

### 2. 加密消息（唯一消息路径，`msg` 帧仅为 legacy 调试保留）

```
core:
  明文 ──► 对名单内每个 peer：
             未建会话 ──► prekey_fetch ──► X3DH/PQXDH 建会话
             双棘轮加密 ──► enc{to, body, dedup_id}
server:
  enc ──► room ──► NATS hermes.rooms.<room>（JetStream hermes_chat 流持久化）
       ──► fanout 给房间内所有订阅者（只有 to 本人解密，其余丢弃）
storage:
  每设备游标 put_async（fjall sidecar）
```

- server 对 `body` 是不透明字符串，**协议上不存在服务端解密路径**。
- 自回显：自己发的消息在 core 本地即时上屏，不走加密自发自收。

### 3. 离线补投（收件箱模型）

```
重连 join{cursor} ──► session 以 by_start_sequence(cursor+1) 起 JetStream
                      ordered consumer ──► 重放期间只吃 enc/chat ──► 追上后转实时
```

- 游标语义：`cursor` = 该设备最后完整消费的 seq；**补投从 cursor+1 开始**（inclusive opt_start_seq）。
- 每设备独立游标，多端互不干扰。

### 4. 幂等（QoS1 的业务层兜底）

- `dedup_id` 由发送端生成（UUID），随消息走全链路。
- core 侧 Bloom Filter 窗口去重：QoS1 重复投递在业务层折叠，不用 QoS2。

## 四、加密流（pairwise，v0）

| 帧 | 方向 | 语义 |
| --- | --- | --- |
| `prekey_register{bundle}` | C→S | 本机身份/签名 prekey/Kyber prekey 注册；bundle 由 server 原样存储 |
| `prekey_fetch{for}` | C→S | 取对方 bundle；回帧 `prekey_bundle`，空 = 对方无登记 |
| `enc{to, body, dedup_id}` | C→S→C | 密文信封，server 不透明转发 |

- 算法：官方 libsignal Rust 实现，X3DH/PQXDH + 双棘轮；**禁止自研加密协议**（宪法）。
- 身份密钥跨重启持久化（同名 = 永远同一身份），明文 JSON 落盘（v0 边界，静态加密在第二轮）。
- 会话（ratchet）状态不持久化：离线期间的旧密文补投后可能落在重放窗口外而解不开（v0 已知边界）。

## 五、关键语义约束（变更需走 ADR）

1. **QoS1 + 业务幂等**，不用 QoS2。
2. **收件箱模型**：每设备独立 sequence 游标，补投从 cursor+1。
3. **roster = 连接生命周期**，不持久化；持久化的只有身份与游标。
4. **presence 非持久订阅**，不进 JetStream（重放不会收到陈旧通知）。
5. **retained 仅用于在线状态**，不用于聊天记录。
6. **server 与 core 永不代码依赖**，只在 proto 契约会师。
7. **成员资格（持久）≠ 在线名册（瞬态）**：空间成员与角色落 fjall
   （members/perms partition）；"谁此刻在线"永远只在房间 Actor 内存。
8. **space/channel 名必须 subject-token 安全**（`[a-z0-9_-]{1,32}`）；
   用户名不进 NATS subject，宽松校验。

## 六、v0 已知边界（第二轮候选）

密钥静态加密 · 会话状态持久化 · Sender Key 群组加密 · 树状 fanout（Discord Manifold
思路）· Protobuf + QUIC · UniFFI + iOS/Android · ProVerif 形式化验证。
