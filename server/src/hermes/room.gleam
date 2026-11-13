//// 房间 Actor —— v0 冲刺版。
////
//// 与 Phase 1 的关键区别：房间不再直接 fanout 给成员收件箱，
//// 广播统一发往 NATS（聊天进 JetStream 流，presence 走非持久 core 订阅）。
//// 状态只剩一份成员名单，用于 join 回执和 presence 文案。
//// 未来大房间树状分发时，只需把这里换成 fanout.gleam，bus 接口不变。

import gleam/dynamic/decode
import gleam/erlang/process.{type Name, type Subject}
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/otp/supervision

import hermes/bus
import hermes/envelope
import hermes/store

pub type RoomMsg {
  /// 入房：同步 call，回执当前成员名单（新成员在前）
  Join(name: String, reply_to: Subject(List(String)))
  /// 聊天消息：发布到房间 subject，经 JetStream fanout 给所有会话
  Msg(from: String, text: String, dedup_id: String)
  /// 端到端密文：对每个成员各一份，server 原样转发（不进来的看不懂）
  Enc(to: String, from: String, body: String, dedup_id: String)
  /// 主动退房
  Leave(name: String)
}

type State {
  State(
    members: List(String),
    chat_subject: String,
    presence_subject: String,
    bus: Subject(bus.BusMsg),
    /// v0 的状态外置：成员名单持久化到 fjall sidecar（测试传 None 跳过）
    storage: Option(store.Store),
  )
}

pub fn supervised(
  name: Name(RoomMsg),
  chat_subject: String,
  presence_subject: String,
  bus: Subject(bus.BusMsg),
  storage: Option(store.Store),
) -> supervision.ChildSpecification(process.Subject(RoomMsg)) {
  supervision.worker(fn() {
    start(name, chat_subject, presence_subject, bus, storage)
  })
}

pub fn start(
  name: Name(RoomMsg),
  chat_subject: String,
  presence_subject: String,
  bus: Subject(bus.BusMsg),
  storage: Option(store.Store),
) -> actor.StartResult(process.Subject(RoomMsg)) {
  actor.new_with_initialiser(5000, fn(subject) {
    // 成员名单从 sidecar 恢复 —— 房间崩了重启不再变幽灵房
    let members = case storage {
      option.Some(s) ->
        case store.get(s, members_key(chat_subject)) {
          Ok(option.Some(text)) ->
            case json.parse(from: text, using: decode.list(decode.string)) {
              Ok(list) -> list
              Error(_) -> []
            }
          _ -> []
        }
      option.None -> []
    }

    let selector = process.new_selector() |> process.select(subject)
    let initialised =
      actor.initialised(State(
        members: members,
        chat_subject: chat_subject,
        presence_subject: presence_subject,
        bus: bus,
        storage: storage,
      ))
      |> actor.selecting(selector)
      |> actor.returning(subject)

    Ok(initialised)
  })
  |> actor.named(name)
  |> actor.on_message(handle)
  |> actor.start
}

fn handle(state: State, msg: RoomMsg) -> actor.Next(State, RoomMsg) {
  case msg {
    Join(name, reply_to) -> {
      let members = [name, ..state.members]
      // presence 走非持久订阅，不进 JetStream（重放时不会收到陈旧通知）
      bus.publish(state.bus, state.presence_subject, envelope.Notice(
        name <> " 加入了房间",
      ))
      // 成员名单快照广播：后来者加入时，先来者的名单也要更新（否则
      // 先来者发消息只会发给入房时刻的成员 —— 名单漂移的坑）
      bus.publish(state.bus, state.presence_subject, envelope.Members(
        members,
      ))
      persist(state, members)
      process.send(reply_to, members)
      actor.continue(State(..state, members: members))
    }

    Msg(from, text, dedup_id) -> {
      bus.publish(state.bus, state.chat_subject, envelope.Chat(
        from,
        text,
        dedup_id,
      ))
      actor.continue(state)
    }

    Enc(to, from, body, dedup_id) -> {
      bus.publish(state.bus, state.chat_subject, envelope.Enc(
        to,
        from,
        body,
        dedup_id,
      ))
      actor.continue(state)
    }

    Leave(name) -> {
      let members = list.filter(state.members, fn(m) { m != name })
      bus.publish(state.bus, state.presence_subject, envelope.Notice(
        name <> " 离开了房间",
      ))
      bus.publish(state.bus, state.presence_subject, envelope.Members(
        members,
      ))
      persist(state, members)
      actor.continue(State(..state, members: members))
    }
  }
}

fn persist(state: State, members: List(String)) -> Nil {
  case state.storage {
    option.Some(s) ->
      store.put_async(
        s,
        members_key(state.chat_subject),
        json.array(members, json.string) |> json.to_string,
      )
    option.None -> Nil
  }
}

fn members_key(chat_subject: String) -> String {
  "members:" <> chat_subject
}

// ---------- 客户端 API ----------

pub fn join(
  room: Subject(RoomMsg),
  name: String,
) -> List(String) {
  process.call(room, 1000, fn(reply: Subject(List(String))) {
    Join(name, reply)
  })
}

pub fn send_message(
  room: Subject(RoomMsg),
  from: String,
  text: String,
  dedup_id: String,
) -> Nil {
  process.send(room, Msg(from, text, dedup_id))
}

pub fn send_enc(
  room: Subject(RoomMsg),
  to: String,
  from: String,
  body: String,
  dedup_id: String,
) -> Nil {
  process.send(room, Enc(to, from, body, dedup_id))
}

pub fn leave(room: Subject(RoomMsg), name: String) -> Nil {
  process.send(room, Leave(name))
}
