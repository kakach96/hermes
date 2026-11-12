//// 房间 Actor 的纯逻辑测试 —— 不依赖 NATS。
////
//// 技巧：房间只会 process.send 到总线 Subject，所以"假总线"就是
//// 一个由测试进程自己拥有的 Subject，房间发来的 Publish 消息
//// 直接落在测试进程的信箱里，用 receive 就能检查。

import gleam/erlang/process
import gleeunit
import hermes/bus
import hermes/envelope
import hermes/room

pub fn main() {
  gleeunit.main()
}

pub fn join_and_presence_test() {
  let fake_bus = process.new_subject()
  let room_name = process.new_name("test_room")
  let assert Ok(_) =
    room.start(room_name, "hermes.rooms.t1", "hermes.presence.t1", fake_bus)
  let hall = process.named_subject(room_name)

  let reply = process.new_subject()
  process.send(hall, room.Join("Alice", reply))
  let assert Ok(["Alice"]) = process.receive(reply, 1000)

  // 房间应向 presence subject 发布加入通知
  let assert Ok(
    bus.Publish("hermes.presence.t1", envelope.Notice("Alice 加入了房间")),
  ) = process.receive(fake_bus, 1000)
}

pub fn msg_publishes_chat_envelope_test() {
  let fake_bus = process.new_subject()
  let room_name = process.new_name("test_room_msg")
  let assert Ok(_) =
    room.start(room_name, "hermes.rooms.t2", "hermes.presence.t2", fake_bus)
  let hall = process.named_subject(room_name)

  room.send_message(hall, "Alice", "你好", "dedup-1")

  let assert Ok(bus.Publish(
    "hermes.rooms.t2",
    envelope.Chat("Alice", "你好", "dedup-1"),
  )) = process.receive(fake_bus, 1000)
}

pub fn leave_updates_members_test() {
  let fake_bus = process.new_subject()
  let room_name = process.new_name("test_room_leave")
  let assert Ok(_) =
    room.start(room_name, "hermes.rooms.t3", "hermes.presence.t3", fake_bus)
  let hall = process.named_subject(room_name)

  let reply = process.new_subject()
  process.send(hall, room.Join("Alice", reply))
  let assert Ok(["Alice"]) = process.receive(reply, 1000)
  let assert Ok(bus.Publish(
    "hermes.presence.t3",
    envelope.Notice("Alice 加入了房间"),
  )) = process.receive(fake_bus, 1000)

  process.send(hall, room.Leave("Alice"))
  let assert Ok(bus.Publish(
    "hermes.presence.t3",
    envelope.Notice("Alice 离开了房间"),
  )) = process.receive(fake_bus, 1000)

  // Bob 入房时名单不应再包含已离开的 Alice
  process.send(hall, room.Join("Bob", reply))
  let assert Ok(["Bob"]) = process.receive(reply, 1000)
}
