//// 赫尔墨斯 v0 —— server 入口。
////
//// M3（冲刺版）：监督树 = bus（NATS JetStream）+ 房间 + WebSocket 监听。
//// 当前先起 bus 与房间；WS 会话 Actor 在下一步接入。

import gleam/erlang/process
import gleam/io
import gleam/otp/static_supervisor as supervisor
import hermes/bus
import hermes/room

pub fn main() {
  let bus_name = process.new_name("hermes_bus")
  let lobby_name = process.new_name("hermes_room_lobby")

  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(
      bus.supervised(bus_name, "127.0.0.1", 4222, "hermes_chat", "hermes.rooms."),
    )
    |> supervisor.add(
      room.supervised(
        lobby_name,
        "hermes.rooms.lobby",
        "hermes.presence.lobby",
        process.named_subject(bus_name),
      ),
    )
    |> supervisor.start

  io.println("hermes server ready（bus: NATS JetStream, room: lobby）")
  process.sleep_forever()
}
