//// WebSocket 监听：/ws 升级为会话，/v1/* 走 HTTP 平面（见 api.gleam），
//// 其他路径 404。main 里把这里的 Builder 交给 mist.supervised 作为监督树 child。

import gleam/erlang/process.{type Subject}
import gleam/http/request
import mist

import hermes/api
import hermes/bus
import hermes/registry
import hermes/rooms
import hermes/session
import hermes/store

pub fn listener(
  port: Int,
  bus: Subject(bus.BusMsg),
  rooms: Subject(rooms.RoomsMsg),
  storage: store.Store,
  registry: Subject(registry.RegistryMsg),
) -> mist.Builder(mist.Connection, mist.ResponseData) {
  let handler = fn(req: request.Request(mist.Connection)) {
    case request.path_segments(req) {
      ["ws"] -> session.upgrade(req, bus, rooms, storage, registry)
      // 非 WS 路径走 HTTP 平面（/v1/*）；未命中回 404
      _ ->
        case api.handle(req, storage) {
          Ok(resp) -> resp
          Error(Nil) -> api.not_found()
        }
    }
  }

  mist.new(handler)
  |> mist.bind("0.0.0.0")
  |> mist.port(port)
}
