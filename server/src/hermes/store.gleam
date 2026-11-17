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
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/otp/supervision

import hermes/ffi

/// sidecar 可执行文件默认路径（相对 server/ 工作目录）。
/// Docker/Linux 部署用 HERMES_STORAGE_EXE 覆盖（无 .exe 后缀）。
pub const sidecar_exe = "../storage/target/release/hermes-storage.exe"

/// 数据目录默认（相对 server/ 工作目录）。部署用 HERMES_DATA_DIR 覆盖。
pub const data_dir = "../storage-data"

/// 部署覆盖：环境变量优先，编译期默认兜底
pub fn resolve_sidecar_exe() -> String {
  case ffi.getenv("HERMES_STORAGE_EXE") {
    Ok(path) -> path
    Error(Nil) -> sidecar_exe
  }
}

pub fn resolve_data_dir() -> String {
  case ffi.getenv("HERMES_DATA_DIR") {
    Ok(dir) -> dir
    Error(Nil) -> data_dir
  }
}

pub type StorePort

pub type Store =
  Subject(StoreMsg)

pub type StoreMsg {
  Get(key: String, reply_to: Subject(Result(Option(String), String)))
  Put(key: String, value: String, reply_to: Subject(Result(Nil, String)))
  /// fire-and-forget 写入（游标推进这类高频低价值更新用）
  PutAsync(key: String, value: String)
  Delete(key: String, reply_to: Subject(Result(Nil, String)))
  /// 指定 partition 的读写（元数据域：users/spaces/channels/members/perms）
  KsGet(
    ks: String,
    key: String,
    reply_to: Subject(Result(Option(String), String)),
  )
  KsPut(
    ks: String,
    key: String,
    value: String,
    reply_to: Subject(Result(Nil, String)),
  )
  KsDelete(ks: String, key: String, reply_to: Subject(Result(Nil, String)))
  /// 前缀扫描（列空间/频道/成员）；key 升序返回
  KsList(
    ks: String,
    prefix: String,
    reply_to: Subject(Result(List(#(String, String)), String)),
  )
}

pub type StoreState {
  StoreState(port: StorePort)
}

type Resp {
  RespOk(found: Bool, value: String)
  RespError(error: String)
}

pub fn supervised(name: Name(StoreMsg)) -> supervision.ChildSpecification(Store) {
  supervision.worker(fn() {
    start(name, resolve_sidecar_exe(), resolve_data_dir())
  })
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
      let resp = case call_port(state.port, encode_get(key, option.None)) {
        Ok(payload) -> parse(payload, has_found: True)
        Error(reason) -> Error(reason)
      }
      process.send(reply_to, to_option(resp))
      actor.continue(state)
    }

    Put(key, value, reply_to) -> {
      let resp =
        case call_port(state.port, encode_put(key, value, option.None)) {
          Ok(payload) -> parse(payload, has_found: False) |> to_nil
          Error(reason) -> Error(reason)
        }
      process.send(reply_to, resp)
      actor.continue(state)
    }

    PutAsync(key, value) -> {
      // 崩了也不阻塞主流程：写不进去顶多重连时多补几条
      let _ = call_port(state.port, encode_put(key, value, option.None))
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

    KsGet(ks, key, reply_to) -> {
      let resp = case call_port(state.port, encode_get(key, option.Some(ks))) {
        Ok(payload) -> parse(payload, has_found: True)
        Error(reason) -> Error(reason)
      }
      process.send(reply_to, to_option(resp))
      actor.continue(state)
    }

    KsPut(ks, key, value, reply_to) -> {
      let resp =
        case call_port(state.port, encode_put(key, value, option.Some(ks))) {
          Ok(payload) -> parse(payload, has_found: False) |> to_nil
          Error(reason) -> Error(reason)
        }
      process.send(reply_to, resp)
      actor.continue(state)
    }

    KsDelete(ks, key, reply_to) -> {
      let resp =
        case call_port(state.port, encode_delete_with(key, option.Some(ks))) {
          Ok(payload) -> parse(payload, has_found: False) |> to_nil
          Error(reason) -> Error(reason)
        }
      process.send(reply_to, resp)
      actor.continue(state)
    }

    KsList(ks, prefix, reply_to) -> {
      let resp = case call_port(state.port, encode_list(ks, prefix)) {
        Ok(payload) -> parse_items(payload)
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

/// 指定 partition 读写（元数据域）。ks 必须是 sidecar 白名单之一。
pub fn ks_get(
  store: Store,
  ks: String,
  key: String,
) -> Result(Option(String), String) {
  process.call(store, 5000, KsGet(ks, key, _))
}

pub fn ks_put(
  store: Store,
  ks: String,
  key: String,
  value: String,
) -> Result(Nil, String) {
  process.call(store, 5000, KsPut(ks, key, value, _))
}

pub fn ks_delete(store: Store, ks: String, key: String) -> Result(Nil, String) {
  process.call(store, 5000, KsDelete(ks, key, _))
}

/// 前缀扫描，key 升序。空 prefix = 全量列出。
pub fn ks_list(
  store: Store,
  ks: String,
  prefix: String,
) -> Result(List(#(String, String)), String) {
  process.call(store, 5000, KsList(ks, prefix, _))
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

fn encode_get(key: String, ks: Option(String)) -> BitArray {
  encode_ks(
    [
      #("op", json.string("get")),
      #("key", json.string(key)),
    ],
    ks,
  )
}

fn encode_put(key: String, value: String, ks: Option(String)) -> BitArray {
  encode_ks(
    [
      #("op", json.string("put")),
      #("key", json.string(key)),
      #("value", json.string(value)),
    ],
    ks,
  )
}

fn encode_delete(key: String) -> BitArray {
  encode_delete_with(key, option.None)
}

fn encode_delete_with(key: String, ks: Option(String)) -> BitArray {
  encode_ks(
    [
      #("op", json.string("delete")),
      #("key", json.string(key)),
    ],
    ks,
  )
}

fn encode_list(ks: String, prefix: String) -> BitArray {
  json.object([
    #("op", json.string("list")),
    #("ks", json.string(ks)),
    #("prefix", json.string(prefix)),
  ])
  |> json.to_string
  |> bit_array.from_string
}

/// 无 ks 字段 = sidecar 缺省 "kv"（游标等 v0 数据）
fn encode_ks(fields: List(#(String, Json)), ks: Option(String)) -> BitArray {
  let fields = case ks {
    option.Some(ks) -> list.append(fields, [#("ks", json.string(ks))])
    option.None -> fields
  }
  json.object(fields)
  |> json.to_string
  |> bit_array.from_string
}

type Item {
  Item(key: String, value: String)
}

fn parse_items(payload: BitArray) -> Result(List(#(String, String)), String) {
  let decoder = {
    use ok <- decode.field("ok", decode.bool)
    case ok {
      False -> {
        use error <- decode.field("error", decode.string)
        decode.success(Error(error))
      }
      True -> {
        use items <- decode.field(
          "items",
          decode.list(item_decoder()),
        )
        decode.success(Ok(items))
      }
    }
  }
  case bit_array.to_string(payload) {
    Error(Nil) -> Error("sidecar 应答不是 UTF-8")
    Ok(text) ->
      case json.parse(from: text, using: decoder) {
        Ok(Ok(items)) ->
          Ok(
            items
            |> list.map(fn(item) {
              let Item(key, value) = item
              #(key, value)
            }),
          )
        Ok(Error(reason)) -> Error(reason)
        Error(_) -> Error("sidecar 应答 JSON 无法解析")
      }
  }
}

fn item_decoder() -> decode.Decoder(Item) {
  use key <- decode.field("key", decode.string)
  use value <- decode.field("value", decode.string)
  decode.success(Item(key, value))
}

// ---------- Erlang FFI ----------

@external(erlang, "hermes_store_ffi", "open")
fn open_port(exe: String, data_dir: String) -> Result(StorePort, String)

@external(erlang, "hermes_store_ffi", "call")
fn call_port(port: StorePort, request: BitArray) -> Result(BitArray, String)
