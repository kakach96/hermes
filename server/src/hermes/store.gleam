//// fjall 存储 sidecar（hermes-storage.exe）的 Erlang port 驱动 Actor。
////
//// 职责：
//// 1. initialiser 里 spawn sidecar（port 所有者 = 本 Actor），
////    sidecar 崩溃 → exit 信号带走本 Actor → 监督树重启重建 port，
////    fjall 数据在磁盘，天然恢复
//// 2. 提供 get / put / put_async / delete —— v0 存设备游标与房间成员名单，
////    历史消息仍在 JetStream，这里只存"元数据"
////
//// key 约定（见 storage/src/main.rs 头注释）：
////   cursor:<room subject>:<name>  /  members:<room subject>

import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process.{type Name, type Subject}
import gleam/json
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/otp/supervision

/// sidecar 可执行文件（相对 server/ 工作目录）
pub const sidecar_exe = "../storage/target/release/hermes-storage.exe"

/// 数据目录（相对 server/ 工作目录）
pub const data_dir = "../storage-data"

pub type StorePort

pub type Store =
  Subject(StoreMsg)

pub type StoreMsg {
  Get(key: String, reply_to: Subject(Result(Option(String), String)))
  Put(key: String, value: String, reply_to: Subject(Result(Nil, String)))
  /// fire-and-forget 写入（游标推进这类高频低价值更新用）
  PutAsync(key: String, value: String)
  Delete(key: String, reply_to: Subject(Result(Nil, String)))
}

pub type StoreState {
  StoreState(port: StorePort)
}

type Resp {
  RespOk(found: Bool, value: String)
  RespError(error: String)
}

pub fn supervised(name: Name(StoreMsg)) -> supervision.ChildSpecification(Store) {
  supervision.worker(fn() { start(name, sidecar_exe, data_dir) })
}

pub fn start(
  name: Name(StoreMsg),
  exe: String,
  data_dir: String,
) -> actor.StartResult(Store) {
  actor.new_with_initialiser(5000, fn(subject) {
    case open_port(exe, data_dir) {
      Error(reason) -> Error("存储 sidecar 启动失败: " <> reason)
      Ok(port) -> {
        let selector = process.new_selector() |> process.select(subject)
        let initialised =
          actor.initialised(StoreState(port: port))
          |> actor.selecting(selector)
          |> actor.returning(subject)
        Ok(initialised)
      }
    }
  })
  |> actor.named(name)
  |> actor.on_message(handle)
  |> actor.start
}

fn handle(state: StoreState, msg: StoreMsg) -> actor.Next(StoreState, StoreMsg) {
  case msg {
    Get(key, reply_to) -> {
      let resp = case call_port(state.port, encode_get(key)) {
        Ok(payload) -> parse(payload, has_found: True)
        Error(reason) -> Error(reason)
      }
      process.send(reply_to, to_option(resp))
      actor.continue(state)
    }

    Put(key, value, reply_to) -> {
      let resp = case call_port(state.port, encode_put(key, value)) {
        Ok(payload) -> parse(payload, has_found: False) |> to_nil
        Error(reason) -> Error(reason)
      }
      process.send(reply_to, resp)
      actor.continue(state)
    }

    PutAsync(key, value) -> {
      // 崩了也不阻塞主流程：写不进去顶多重连时多补几条
      let _ = call_port(state.port, encode_put(key, value))
      actor.continue(state)
    }

    Delete(key, reply_to) -> {
      let resp = case call_port(state.port, encode_delete(key)) {
        Ok(payload) -> parse(payload, has_found: False) |> to_nil
        Error(reason) -> Error(reason)
      }
      process.send(reply_to, resp)
      actor.continue(state)
    }
  }
}

// ---------- 客户端 API ----------

pub fn get(store: Store, key: String) -> Result(Option(String), String) {
  process.call(store, 5000, Get(key, _))
}

pub fn put(store: Store, key: String, value: String) -> Result(Nil, String) {
  process.call(store, 5000, Put(key, value, _))
}

pub fn put_async(store: Store, key: String, value: String) -> Nil {
  process.send(store, PutAsync(key, value))
}

pub fn delete(store: Store, key: String) -> Result(Nil, String) {
  process.call(store, 5000, Delete(key, _))
}

// ---------- 内部 ----------

fn parse(payload: BitArray, has_found found: Bool) -> Result(Resp, String) {
  case bit_array.to_string(payload) {
    Error(Nil) -> Error("sidecar 应答不是 UTF-8")
    Ok(text) ->
      case json.parse(from: text, using: resp_decoder(found)) {
        Ok(resp) -> Ok(resp)
        Error(_) -> Error("sidecar 应答 JSON 无法解析")
      }
  }
}

fn resp_decoder(has_found: Bool) -> decode.Decoder(Resp) {
  {
    use ok <- decode.field("ok", decode.bool)
    case ok {
      False -> {
        use error <- decode.field("error", decode.string)
        decode.success(RespError(error))
      }
      True ->
        case has_found {
          False -> decode.success(RespOk(False, ""))
          True -> {
            use found <- decode.optional_field("found", False, decode.bool)
            use value <- decode.optional_field("value", "", decode.string)
            decode.success(RespOk(found, value))
          }
        }
    }
  }
}

fn to_option(resp: Result(Resp, String)) -> Result(Option(String), String) {
  case resp {
    Ok(RespOk(True, value)) -> Ok(option.Some(value))
    Ok(RespOk(False, _)) -> Ok(option.None)
    Ok(RespError(error)) -> Error(error)
    Error(reason) -> Error(reason)
  }
}

fn to_nil(resp: Result(Resp, String)) -> Result(Nil, String) {
  case resp {
    Ok(RespOk(_, _)) -> Ok(Nil)
    Ok(RespError(error)) -> Error(error)
    Error(reason) -> Error(reason)
  }
}

fn encode_get(key: String) -> BitArray {
  json.object([
    #("op", json.string("get")),
    #("key", json.string(key)),
  ])
  |> json.to_string
  |> bit_array.from_string
}

fn encode_put(key: String, value: String) -> BitArray {
  json.object([
    #("op", json.string("put")),
    #("key", json.string(key)),
    #("value", json.string(value)),
  ])
  |> json.to_string
  |> bit_array.from_string
}

fn encode_delete(key: String) -> BitArray {
  json.object([
    #("op", json.string("delete")),
    #("key", json.string(key)),
  ])
  |> json.to_string
  |> bit_array.from_string
}

// ---------- Erlang FFI ----------

@external(erlang, "hermes_store_ffi", "open")
fn open_port(exe: String, data_dir: String) -> Result(StorePort, String)

@external(erlang, "hermes_store_ffi", "call")
fn call_port(port: StorePort, request: BitArray) -> Result(BitArray, String)
