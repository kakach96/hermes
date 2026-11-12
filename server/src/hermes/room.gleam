//// 房间 Actor —— v0 冲刺版。
////
//// 与 Phase 1 的关键区别：房间不再直接 fanout 给成员收件箱，
//// 广播统一发往 NATS（聊天进 JetStream 流，presence 走非持久 core 订阅）。
//// 状态只剩一份成员名单，用于 join 回执和 presence 文案。
//// 未来大房间树状分发时，只需把这里换成 fanout.gleam，bus 接口不变。

import gleam/erlang/process.{type Name, type Subject}
import gleam/list
import gleam/otp/actor
import gleam/otp/supervision

import hermes/bus
import hermes/envelope

pub type RoomMsg {
  /// 入房：同步 call，回执当前成员名单（新成员在前）
  Join(name: String, reply_to: Subject(List(String)))
  /// 聊天消息：发布到房间 subject，经 JetStream fanout 给所有会话
  Msg(from: String, text: String, dedup_id: String)
  /// 主动退房
  Leave(name: String)
}

type State {
  State(
    members: List(String),
    chat_subject: String,
    presence_subject: String,
    bus: Subject(bus.BusMsg),
  )
}

pub fn supervised(
  name: Name(RoomMsg),
  chat_subject: String,
  presence_subject: String,
  bus: Subject(bus.BusMsg),
) -> supervision.ChildSpecification(process.Subject(RoomMsg)) {
  supervision.worker(fn() {
    start(name, chat_subject, presence_subject, bus)
  })
}

pub fn start(
  name: Name(RoomMsg),
  chat_subject: String,
  presence_subject: String,
  bus: Subject(bus.BusMsg),
) -> actor.StartResult(process.Subject(RoomMsg)) {
  actor.new(State(
    members: [],
    chat_subject: chat_subject,
    presence_subject: presence_subject,
    bus: bus,
  ))
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

    Leave(name) -> {
      let members = list.filter(state.members, fn(m) { m != name })
      bus.publish(state.bus, state.presence_subject, envelope.Notice(
        name <> " 离开了房间",
      ))
      actor.continue(State(..state, members: members))
    }
  }
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

pub fn leave(room: Subject(RoomMsg), name: String) -> Nil {
  process.send(room, Leave(name))
}
