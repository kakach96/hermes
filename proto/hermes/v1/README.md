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
| `msg` | `text` `dedup_id` | 聊天。dedup_id 由客户端生成（幂等钥匙，QoS1 去重用） |
| `leave` | — | 主动退房（会关连接） |

## 服务端 → 客户端（WS 文本帧）

| type | 字段 | 语义 |
| --- | --- | --- |
| `joined` | `members: string[]` | 入房回执：当前成员名单（新成员在前） |
| `chat` | `from` `text` `dedup_id` `seq` | 一条聊天；seq 用于推进本地游标 |
| `notice` | `text` | presence（加入/离开/掉线）。**不重放** |
| `error` | `reason` | 服务端拒绝（v0 仅 attach 失败等致命场景） |

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
