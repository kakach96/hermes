# 赫尔墨斯 · Phase 1

Gleam Actor 聊天室最小骨架：房间 Actor + 客户端 Actor + 静态监督树，
覆盖 `spawn / send / receive / monitor / call / named_subject / supervisor`。

## 运行

需要 Erlang/OTP 26+ 与 Gleam 1.x（`gleam` 与 `erl` 在 PATH 中）。

```sh
gleam run    # 跑主程序，看一场有剧本的聊天室演示
gleam test   # 两个行为测试：Join 回执名单 / 掉线广播
gleam format # 格式化
```

## 结构

| 文件 | 职责 |
| --- | --- |
| `AGENTS.md` | 项目宪法：技术栈、不可违背的设计约定、工作规则、陷阱备忘 |
| `docs/PLAN.md` | 路线图与技术决策记录（单一事实来源，Phase 状态以它为准） |
| `src/hermes/room.gleam` | 房间 Actor：Join / Msg / Leave / 'DOWN'，状态只有成员名单 |
| `src/hermes/client.gleam` | 客户端 Actor：只收广播、只打印，代替未来的 WebSocket 连接 |
| `src/hermes.gleam` | 程序入口：起监督树、搭场景、跑剧本 |

## 看点（对照 BEAM 概念）

- **状态内聚**：房间状态只有一份 `List(Member)`，外界只能用消息触碰它，无锁。
- **同步 call**：`Join` 用 `process.call`，回执是成员名单；不回执就崩溃调用方。
- **monitor**：客户端进程被 `kill` 后，房间收到 Erlang `'DOWN'`，广播掉线通知。
- **监督树**：房间是 supervisor 的 worker，用 `actor.named` 登记进程名；
  `named_subject` 不绑定 pid，房间重启后依旧有效。
- **陷阱**：`actor.start` 是 linked spawn，main 必须 `trap_exits(True)`，
  否则杀掉一个客户端会把 main 一起带走。

## Phase 2 预告

接 NATS JetStream：把 `broadcast` 的目标从"成员收件箱"换成"收件箱 + JetStream 流"，
离线消息按设备游标补投。
