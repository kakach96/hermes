# 赫尔墨斯 v0 协议契约

> v0 线格式为 JSON（字段名与最终 protobuf 一一映射，见 *.proto）。
> 第二轮换 Protobuf 时只换编码，字段语义不变。
> 本目录的 .proto 是契约事实来源；下表是 v0 JSON 编码。

## 载体

- 客户端 ↔ server：**双平面**。认证与只读目录走 HTTP（`/v1/*`，见下），
  实时消息走 WebSocket 文本帧 `ws://host:8080/ws?name=<用户名>`
  （`?name=` 即会话身份，升级即登录并回 `logged_in` 帧；不带则未登录）
- server 内部 ↔ NATS：`hermes.rooms.<space>.<channel>` 聊天（进 JetStream 流
  `hermes_chat`，流订 `hermes.rooms.>` 前缀），`hermes.presence.<space>.<channel>`
  在线通知（不进流）。v1 单房间 = space 缺省（见 M7 一节）
- 房间 subject 里流转的信封 **不带 seq**：seq 存在于 JetStream 投递的
  `$JS.ACK` 回执中（第 6 个点分段），由 bus 解出后加到 WS 帧上

## HTTP 平面（M8，认证 + 只读目录）

| 方法与路径 | body | 语义 |
| --- | --- | --- |
| `POST /v1/register` | `{name}` | 注册：201 `{name}`；已存在 409；非法名 400 |
| `POST /v1/login` | `{name}` | 登录：200 `{name}`；不存在 401 |
| `GET /v1/spaces` | — | 200 `{spaces:[{name,owner}]}` |
| `GET /v1/spaces/:space/channels` | — | 200 `{space, channels:[]}` |

- v0 无密码：名字即账号（服务端 users 建档 + 客户端本地身份密钥持久化）；
  密码/令牌留给多端同步阶段
- `login` WS 帧仍保留（裸工具兼容路径），GUI 走 HTTP 认证后连 WS 不再发它

## 客户端 → 服务端（WS 文本帧）

| type | 字段 | 语义 |
| --- | --- | --- |
| `join` | `name?` `cursor` `space?` `channel?` | 入房。cursor = 该设备最后收到的 stream seq（新设备传 0）。space/channel 可选，缺省 `lobby`/`general`；不存在时自动建档（首个进入者 = 空间 owner）。name 可选：GUI 登录后不传（用会话身份）；裸 WS 工具带 name 直接 join = 隐式登录兜底 |
| `msg` | `text` `dedup_id` | **legacy 明文**聊天（工具/测试用；GUI 走 enc） |
| `leave` | — | 离开房间回大厅。**不断开连接**，登录态保留；真正断开直接关 WS（server 靠连接关闭清理） |
| `prekey_register` | `bundle` | 登记 Signal 注册包（bundle 为 JSON 字符串，server 不透明存储，同名覆盖） |
| `prekey_fetch` | `for` | 取某人的注册包 → 回 `prekey_bundle` 帧（空 bundle = 对方无登记） |
| `enc` | `to` `body` `dedup_id` | 端到端密文：server 原样转发进房间流，只有 `to` 本人能解密 |
| `login` | `name` | 登录：确定身份并建档（幂等），**不入房**。`space_list`/`space_create`/`channel_create`/`channel_list` 只要求已登录（大厅页能力） |
| `space_create` | `space` | 建空间（创建者 = owner）。需已入房（任意空间） |
| `space_list` | — | 列全部空间 |
| `channel_create` | `space` `channel` | 建频道。**需该空间 owner/admin**（v0 权限模型） |
| `channel_list` | `space` | 列某空间的频道 |

## 服务端 → 客户端（WS 文本帧）

| type | 字段 | 语义 |
| --- | --- | --- |
| `joined` | `members: string[]` `targets: string[]` | 入房回执。members = 当前在线（presence 显示）；targets = **空间持久成员**（加密分发目标——离线成员也永远有一份密文留在流里，重进按游标补投） |
| `chat` | `from` `text` `dedup_id` `seq` | 明文聊天（legacy）；seq 用于推进本地游标 |
| `enc` | `from` `body` `dedup_id` `seq` | 发给本人的密文（server 已按 `to` 过滤） |
| `notice` | `text` | presence（加入/离开/掉线）。**不重放** |
| `error` | `reason` | 服务端拒绝 |
| `prekey_bundle` | `for` `bundle` | prekey_fetch 的回执；空 bundle 表示对方不在线 |
| `members` | `members: string[]` | 成员名单快照（presence 通道广播，加入/退房时更新；加密目标名单的活水） |
| `logged_in` | `name` | 登录成功（大厅页入场券） |
| `left` | — | 已离开房间（连接保持） |
| `spaces` | `spaces: [{name,owner}]` | 空间列表（space_list 的回执） |
| `space_created` | `name` | 空间创建成功（创建者 = owner） |
| `channels` | `space` `channels: string[]` | 某空间的频道列表（channel_list 的回执） |
| `channel_created` | `space` `name` | 频道创建成功 |

## 端到端加密（M6，pairwise）

- 密码学全部在客户端 core 的 crypto 线程里（官方 libsignal 纯 Rust 实现，
  X3DH/PQXDH + 双棘轮）；server 只做注册包目录与密文转发，**永远接触不到明文**
- 建会话流程：入房后对名单里每个成员 `prekey_fetch` → `initiate_session`；
  之后对该成员发消息走 `enc`。名单快照之外的晚到成员由发送方懒建会话补上
- 游标对 `enc` 信封同样推进（重放时 server 仍按 `to` 过滤，幂等性由
  客户端 Bloom dedup 兜底）
- 明确的 v0 限制：群组不走 Sender Key（pairwise，房间大 = O(N) 副本）；
  会话状态不落盘，客户端重启后无法解密重放窗口里的旧密文

## 空间/频道（M7）

- 层级编进 subject：`hermes.rooms.<space>.<channel>` —— JetStream 流
  `hermes.rooms.>` 天然覆盖，无需动流配置；游标 key 也自然按频道隔离
- **成员资格（持久）≠ 在线名册（瞬态）**：fjall 的 members/perms 存"谁属于
  这个空间、什么角色"；"谁此刻在线"仍在房间 Actor 内存里（连接生命周期）
- 名字规则：space/channel 必须是 subject token 安全的 `[a-z0-9_-]{1,32}`
  （点号 = subject token 边界，放任用户输入 = 路由注入）；用户名宽松
  （不进 subject），1~32 字符，中文/大写合法
- v0 开放模型：join 自动建档（空间缺 owner = 首进者；频道自动创建）；
  显式 channel_create 才有 owner/admin 权限门。变更需走 ADR

## 游标语义（收件箱模型）

- seq 是 `hermes_chat` 流的**全局** stream 序号；同一房间内单调
- 断线重连：客户端带 `cursor` 重新 join，server 建消费者从 `cursor + 1` 起补投
  （JetStream `by_start_sequence` 的起点是**包含**的，所以 +1）
- 补投与实时投递走同一个消费者，天然不重不漏；
  客户端仍需按 `dedup_id` 幂等（防御重连竞态与未来多副本投递）

## 消息流向

```
WS(join/msg/leave) → session 进程 → rooms 管理器（按 <space>.<channel> 惰性 spawn）→ room Actor
chat:   room ──PUB──► hermes.rooms.<space>.<channel> ──► JetStream hermes_chat
        session 的 consumer（filter=房间 subject, deliver_subject=_INBOX.*）
        ◄── MSG（subject=原始房间 subject, reply=$JS.ACK...含 seq）──
presence: room ──PUB──► hermes.presence.<space>.<channel> ──► bus 内部扇出到各会话
```
