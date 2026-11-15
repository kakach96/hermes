//// rooms（动态房间管理器）测试：惰性 spawn、同 key 复用、消息透传。
//// 假总线技巧同 hermes_test：房间只会 process.send 到总线 Subject，
//// 测试进程持有 Subject 即可收到 Publish —— 全程不依赖 NATS。

import gleam/erlang/process
import gleam/otp/actor
import gleam/string
import gleeunit
import hermes/bus
import hermes/envelope
import hermes/ffi
import hermes/room
import hermes/rooms

pub fn main() {
  gleeunit.main()
}

fn unique_id() -> String {
  ffi.unique_inbox("")
}

pub fn lazy_spawn_and_reuse_test() {
  let fake_bus = process.new_subject()
  let rooms_name = process.new_name("rooms_test")
  let assert Ok(actor.Started(_pid, manager)) = rooms.start(rooms_name, fake_bus)

  let space = "s_" <> unique_id()
  let assert Ok(room_a) = rooms.room_of(manager, space, "general")
  // 同 key 再取 = 复用同一个房间（不是新 spawn）
  let assert Ok(room_b) = rooms.room_of(manager, space, "general")
  let assert True = room_a == room_b
  // 不同频道 = 不同房间
  let assert Ok(room_c) = rooms.room_of(manager, space, "random")
  let assert False = room_a == room_c
  Nil
}

pub fn room_delivers_message_test() {
  let fake_bus = process.new_subject()
  let rooms_name = process.new_name("rooms_test2")
  let assert Ok(actor.Started(_pid, manager)) = rooms.start(rooms_name, fake_bus)

  let space = "s_" <> unique_id()
  let assert Ok(hall) = rooms.room_of(manager, space, "general")

  let reply = process.new_subject()
  process.send(hall, room.Join("alice", reply))
  let assert Ok(["alice"]) = process.receive(reply, 1000)
  process.send(hall, room.Msg("alice", "hello", "dedup-1"))

  // Join 广播两帧 presence（Notice + Members 快照），排空后 chat 才落房间 subject
  let assert Ok(bus.Publish(_presence, envelope.Notice(_))) =
    process.receive(fake_bus, 1000)
  let assert Ok(bus.Publish(_presence2, envelope.Members(_))) =
    process.receive(fake_bus, 1000)
  let assert Ok(bus.Publish(subject, envelope.Chat("alice", "hello", "dedup-1"))) =
    process.receive(fake_bus, 1000)
  let assert True = string.contains(subject, space)
  Nil
}

pub fn room_subject_encodes_hierarchy_test() {
  let fake_bus = process.new_subject()
  let rooms_name = process.new_name("rooms_test3")
  let assert Ok(actor.Started(_pid, manager)) = rooms.start(rooms_name, fake_bus)

  let space = "s_" <> unique_id()
  let assert Ok(hall) = rooms.room_of(manager, space, "general")
  process.send(hall, room.Join("bob", process.new_subject()))
  let assert Ok(bus.Publish(subject, envelope.Notice(_))) =
    process.receive(fake_bus, 1000)
  // hermes.presence.<space>.<channel> —— 层级可读且可按空间通配订阅
  let assert True =
    string.starts_with(subject, "hermes.presence." <> space <> ".general.")
    || subject == "hermes.presence." <> space <> ".general"
  Nil
}
