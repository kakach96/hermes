//// 赫尔墨斯 v0 —— server 入口。
////
//// 监督树：bus（NATS JetStream 连接）+ 房间（lobby）+ WebSocket 监听。
//// 每个 WS 连接 = 一个会话进程（见 session.gleam）。
////
//// 启动前 NATS 必须在跑：infra\nats-server.exe -c infra\nats.conf
//// 客户端连接：ws://127.0.0.1:8080/ws

import gleam/erlang/process
import gleam/io
import gleam/option
import gleam/otp/static_supervisor as supervisor
import hermes/bus
import hermes/registry
import hermes/room
import hermes/store
import hermes/ws
import mist

pub fn main() {
  let store_name = process.new_name("hermes_store")
  let bus_name = process.new_name("hermes_bus")
  let registry_name = process.new_name("hermes_registry")
  let lobby_name = process.new_name("hermes_room_lobby")

  let store_subject = process.named_subject(store_name)
  let bus_subject = process.named_subject(bus_name)
  let registry_subject = process.named_subject(registry_name)
  let room_subject = process.named_subject(lobby_name)

  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    // store 先起：bus/room/会话都依赖它
    |> supervisor.add(store.supervised(store_name))
    |> supervisor.add(registry.supervised(registry_name))
    |> supervisor.add(
      bus.supervised(bus_name, "127.0.0.1", 4222, "hermes_chat", "hermes.rooms."),
    )
    |> supervisor.add(
      room.supervised(
        lobby_name,
        "hermes.rooms.lobby",
        "hermes.presence.lobby",
        bus_subject,
        option.Some(store_subject),
      ),
    )
    |> supervisor.add(
      mist.supervised(
        ws.listener(
          8080,
          bus_subject,
          room_subject,
          store_subject,
          registry_subject,
          "hermes.rooms.lobby",
          "hermes.presence.lobby",
        ),
      ),
    )
    |> supervisor.start

  io.println("hermes server ready: ws://127.0.0.1:8080/ws（room: lobby）")
  process.sleep_forever()
}
