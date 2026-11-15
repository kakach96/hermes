//// WebSocket 监听：/ws 升级为会话，其他路径 404。
//// main 里把这里的 Builder 交给 mist.supervised 作为监督树 child。

import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/http/response
import mist

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
      ["ws"] ->
        session.upgrade(req, bus, rooms, storage, registry)
      _ ->
        response.new(404)
        |> response.set_header("content-type", "text/plain")
        |> response.set_body(mist.Bytes(bytes_tree.from_string("not found")))
    }
  }

  mist.new(handler)
  |> mist.bind("0.0.0.0")
  |> mist.port(port)
}
