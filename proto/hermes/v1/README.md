# 赫尔墨斯 v0 协议契约

> v0 线格式为 JSON（字段名与最终 protobuf 一一映射，见 *.proto）。
> 第二轮换 Protobuf 时只换编码，字段语义不变。
> 本目录的 .proto 是契约事实来源；下表是 v0 JSON 编码。

## 载体

- 客户端 ↔ server：WebSocket 文本帧，`ws://host:8080/ws`
- server 内部 ↔ NATS：`hermes.rooms.<room>` 聊天（进 JetStream 流 `hermes_chat`），
  `hermes.presence.<room>` 在线通知（不进流）
- 房间 subject 里流转的信封 **不带 seq**：seq 存在于 JetStream 投递的
  `$JS.ACK` 回执中（第 6 个点分段），由 bus 解出后加到 WS 帧上

## 客户端 → 服务端（WS 文本帧）

| type | 字段 | 语义 |
| --- | --- | --- |
| `join` | `name` `cursor` | 入房。cursor = 该设备最后收到的 stream seq（新设备传 0） |
| `msg` | `text` `dedup_id` | **legacy 明文**聊天（工具/测试用；GUI 走 enc） |
| `leave` | — | 主动退房（会关连接） |
| `prekey_register` | `bundle` | 登记 Signal 注册包（bundle 为 JSON 字符串，server 不透明存储，同名覆盖） |
| `prekey_fetch` | `for` | 取某人的注册包 → 回 `prekey_bundle` 帧（空 bundle = 对方无登记） |
| `enc` | `to` `body` `dedup_id` | 端到端密文：server 原样转发进房间流，只有 `to` 本人能解密 |

## 服务端 → 客户端（WS 文本帧）

| type | 字段 | 语义 |
| --- | --- | --- |
| `joined` | `members: string[]` | 入房回执：当前成员名单（新成员在前） |
| `chat` | `from` `text` `dedup_id` `seq` | 明文聊天（legacy）；seq 用于推进本地游标 |
| `enc` | `from` `body` `dedup_id` `seq` | 发给本人的密文（server 已按 `to` 过滤） |
| `notice` | `text` | presence（加入/离开/掉线）。**不重放** |
| `error` | `reason` | 服务端拒绝 |
| `prekey_bundle` | `for` `bundle` | prekey_fetch 的回执；空 bundle 表示对方不在线 |

## 端到端加密（M6，pairwise）

- 密码学全部在客户端 core 的 crypto 线程里（官方 libsignal 纯 Rust 实现，
  X3DH/PQXDH + 双棘轮）；server 只做注册包目录与密文转发，**永远接触不到明文**
- 建会话流程：入房后对名单里每个成员 `prekey_fetch` → `initiate_session`；
  之后对该成员发消息走 `enc`。名单快照之外的晚到成员由发送方懒建会话补上
- 游标对 `enc` 信封同样推进（重放时 server 仍按 `to` 过滤，幂等性由
  客户端 Bloom dedup 兜底）
- 明确的 v0 限制：群组不走 Sender Key（pairwise，房间大 = O(N) 副本）；
  会话状态不落盘，客户端重启后无法解密重放窗口里的旧密文

## 游标语义（收件箱模型）

- seq 是 `hermes_chat` 流的**全局** stream 序号；同一房间内单调
- 断线重连：客户端带 `cursor` 重新 join，server 建消费者从 `cursor + 1` 起补投
  （JetStream `by_start_sequence` 的起点是**包含**的，所以 +1）
- 补投与实时投递走同一个消费者，天然不重不漏；
  客户端仍需按 `dedup_id` 幂等（防御重连竞态与未来多副本投递）

## 消息流向

```
WS(join/msg/leave) → session 进程 → room Actor
chat:   room ──PUB──► hermes.rooms.lobby ──► JetStream hermes_chat
        session 的 consumer（filter=hermes.rooms.lobby, deliver_subject=_INBOX.*）
        ◄── MSG（subject=原始房间 subject, reply=$JS.ACK...含 seq）──
presence: room ──PUB──► hermes.presence.lobby ──► bus 内部扇出到各会话
```
