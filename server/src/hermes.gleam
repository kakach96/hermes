//// 赫尔墨斯 v0 —— server 入口。
////
//// 监督树：bus（NATS JetStream 连接）+ 房间管理器 + WebSocket 监听。
//// 房间 Actor 不再静态枚举：join 落在任意 <space>.<channel> 上时由
//// 房间管理器惰性 spawn（见 rooms.gleam）。
////
//// 启动前 NATS 必须在跑：infra\nats-server.exe -c infra\nats.conf
//// 客户端连接：ws://127.0.0.1:8080/ws

import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/otp/static_supervisor as supervisor
import hermes/bus
import hermes/ffi
import hermes/registry
import hermes/rooms
import hermes/store
import hermes/ws
import mist

pub fn main() {
  let store_name = process.new_name("hermes_store")
  let bus_name = process.new_name("hermes_bus")
  let registry_name = process.new_name("hermes_registry")
  let rooms_name = process.new_name("hermes_rooms")

  let store_subject = process.named_subject(store_name)
  let bus_subject = process.named_subject(bus_name)
  let registry_subject = process.named_subject(registry_name)
  let rooms_subject = process.named_subject(rooms_name)

  // NATS 地址：环境变量覆盖（Docker compose 里主机名是 "nats"），缺省本机
  let nats_host = case ffi.getenv("HERMES_NATS_HOST") {
    Ok(host) -> host
    Error(Nil) -> "127.0.0.1"
  }
  let nats_port = case ffi.getenv("HERMES_NATS_PORT") {
    Ok(port) ->
      case int.parse(port) {
        Ok(n) -> n
        Error(Nil) -> 4222
      }
    Error(Nil) -> 4222
  }

  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    // store 先起：bus/房间管理器/会话都依赖它
    |> supervisor.add(store.supervised(store_name))
    |> supervisor.add(registry.supervised(registry_name))
    |> supervisor.add(
      bus.supervised(bus_name, nats_host, nats_port, "hermes_chat", "hermes.rooms."),
    )
    |> supervisor.add(rooms.supervised(rooms_name, bus_subject))
    |> supervisor.add(
      mist.supervised(
        ws.listener(8080, bus_subject, rooms_subject, store_subject, registry_subject),
      ),
    )
    |> supervisor.start

  io.println(
    "hermes server ready: ws://"
    <> nats_host
    <> int.to_string(8080)
    <> "（spaces/channels on, NATS "
    <> nats_host
    <> ":"
    <> int.to_string(nats_port)
    <> "）",
  )
  process.sleep_forever()
}
