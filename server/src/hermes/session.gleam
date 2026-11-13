//// 会话 —— 一个 WebSocket 进程（mist 的 WS handler 即 Actor）。
////
//// 为什么不单独起一个 session Actor：mist 的 websocket 进程本身就是
//// "每连接一个进程"，状态（设备游标、consumer inbox、身份）内聚在
//// handler 的 state 里，bus 的投递通过 selector 以 Custom 消息进入，
//// 客户端命令走 Text 帧 —— 两个方向的收件箱天然合并，少一层桥接。
////
//// v0 线上协议（JSON，字段与 proto/hermes/v1 一一映射）：
////   客户端→服务端: {"type":"join","name","cursor"} | {"type":"msg","text","dedup_id"} | {"type":"leave"}
////   服务端→客户端: {"type":"joined","members"} | {"type":"chat","from","text","dedup_id","seq"} | {"type":"notice","text"}
////
//// 游标语义：客户端报"最后收到的 seq"，服务端从 cursor+1 起补投
//// （JetStream by_start_sequence 的起点是包含的，见 bus.attach 注释）。

import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/option
import mist

import hermes/bus
import hermes/envelope
import hermes/registry
import hermes/room
import hermes/store

pub type State {
  State(
    bus: Subject(bus.BusMsg),
    room: Subject(room.RoomMsg),
    store: store.Store,
    registry: Subject(registry.RegistryMsg),
    room_subject: String,
    presence_subject: String,
    /// 入房身份；"" = 尚未入房
    name: String,
    /// JetStream consumer 的退订 token
    chat_token: String,
    /// presence 扇出名单的退订 token
    presence_token: String,
    /// 本设备的游标 key（cursor:<room>:<name>）
    cursor_key: String,
    /// 已收到的最大 stream seq —— 设备游标的真身
    cursor: Int,
    /// 服务端→客户端投递通道（本进程拥有的 Subject）
    ws_subject: Subject(bus.Delivered),
  )
}

type ClientCmd {
  JoinMsg(name: String, cursor: Int)
  ChatMsg(text: String, dedup_id: String)
  LeaveMsg
  /// 登记 Signal 注册包（bundle 是 JSON 字符串，server 不透明存储）
  PrekeyRegisterMsg(bundle: String)
  /// 取某人的注册包 → 回 prekey_bundle 帧（空 bundle = 对方无登记）
  PrekeyFetchMsg(for_name: String)
  /// 端到端密文：server 原样转发进房间流，只有 to 本人解密
  EncMsg(to: String, body: String, dedup_id: String)
}

/// 把 HTTP 请求升级为 WebSocket 会话。
pub fn upgrade(
  req: request.Request(mist.Connection),
  bus: Subject(bus.BusMsg),
  room: Subject(room.RoomMsg),
  storage: store.Store,
  registry: Subject(registry.RegistryMsg),
  room_subject: String,
  presence_subject: String,
) -> response.Response(mist.ResponseData) {
  mist.websocket(
    request: req,
    on_init: fn(_ws_conn) {
      let ws_subject = process.new_subject()
      let state =
        State(
          bus: bus,
          room: room,
          store: storage,
          registry: registry,
          room_subject: room_subject,
          presence_subject: presence_subject,
          name: "",
          chat_token: "",
          presence_token: "",
          cursor_key: "",
          cursor: 0,
          ws_subject: ws_subject,
        )
      let selector =
        process.new_selector()
        |> process.select(ws_subject)
      #(state, option.Some(selector))
    },
    handler: handle,
    on_close: close,
  )
}

fn handle(
  state: State,
  msg: mist.WebsocketMessage(bus.Delivered),
  conn: mist.WebsocketConnection,
) -> mist.Next(State, bus.Delivered) {
  case msg {
    mist.Text(text) -> handle_text(state, text, conn)
    mist.Custom(bus.Delivered(seq, payload)) -> deliver(state, seq, payload, conn)
    // v0 不用二进制帧；异常关闭交给 mist 处理
    mist.Binary(_) -> mist.continue(state)
    mist.Closed -> mist.stop()
    mist.Shutdown -> mist.stop()
  }
}

// ---------- 客户端命令 ----------

fn handle_text(state: State, text: String, conn: mist.WebsocketConnection) {
  case decode_cmd(text) {
    Error(Nil) -> {
      // 坏命令：v0 直接丢弃（M5 起回 error 帧让客户端感知）
      mist.continue(state)
    }
    Ok(JoinMsg(name, cursor)) -> {
      case state.name {
        "" -> join(state, name, cursor, conn)
        // 重复 join：忽略（客户端 bug 或重放，幂等对待）
        _ -> mist.continue(state)
      }
    }
    Ok(ChatMsg(text, dedup_id)) -> {
      case state.name {
        "" -> mist.continue(state)
        // 未入房不许说话
        _ -> {
          room.send_message(state.room, state.name, text, dedup_id)
          mist.continue(state)
        }
      }
    }
    Ok(LeaveMsg) -> {
      let state = detach_all(state)
      room.leave(state.room, state.name)
      mist.stop()
    }

    Ok(PrekeyRegisterMsg(bundle)) -> {
      case state.name {
        "" -> Nil
        name -> registry.register(state.registry, name, bundle)
      }
      mist.continue(state)
    }

    Ok(PrekeyFetchMsg(for_name)) -> {
      // 没登记就回空 bundle，客户端会得到明确的"对方不在线"事件
      let bundle = case registry.fetch(state.registry, for_name) {
        Ok(b) -> b
        Error(Nil) -> ""
      }
      let _ = mist.send_text_frame(conn, prekey_bundle_json(for_name, bundle))
      mist.continue(state)
    }

    Ok(EncMsg(to, body, dedup_id)) -> {
      case state.name {
        "" -> mist.continue(state)
        name -> {
          room.send_enc(state.room, to, name, body, dedup_id)
          mist.continue(state)
        }
      }
    }
  }
}

fn join(state: State, name: String, cursor: Int, conn) {
  // 游标恢复：客户端报了 cursor 就用客户端的（设备真相在客户端），
  // 没报（=0）就查服务端替它记住的那个
  let cursor_key = "cursor:" <> state.room_subject <> ":" <> name
  let start_cursor = case cursor > 0 {
    True -> cursor
    False ->
      case store.get(state.store, cursor_key) {
        Ok(option.Some(v)) ->
          case int.parse(v) {
            Ok(n) -> n
            Error(Nil) -> 0
          }
        _ -> 0
      }
  }
  let _ = store.put(state.store, cursor_key, int.to_string(start_cursor))

  // 顺序敏感：先挂 presence 订阅，再让房间广播加入通知 —— 自己也能收到
  case bus.attach_presence(state.bus, state.presence_subject, state.ws_subject) {
    Error(reason) -> {
      let _ = mist.send_text_frame(conn, error_json("presence: " <> reason))
      mist.continue(state)
    }
    Ok(presence_token) -> {
      let members = room.join(state.room, name)
      case
        bus.attach(
          state.bus,
          state.room_subject,
          start_cursor + 1,
          state.ws_subject,
        )
      {
        Error(reason) -> {
          bus.detach(state.bus, presence_token)
          room.leave(state.room, name)
          let _ = mist.send_text_frame(conn, error_json("attach: " <> reason))
          mist.continue(state)
        }
        Ok(chat_token) -> {
          let _ = mist.send_text_frame(conn, joined_json(members))
          mist.continue(
            State(
              ..state,
              name: name,
              chat_token: chat_token,
              presence_token: presence_token,
              cursor_key: cursor_key,
              cursor: start_cursor,
            ),
          )
        }
      }
    }
  }
}

fn detach_all(state: State) -> State {
  let state = case state.chat_token {
    "" -> state
    chat_token -> {
      bus.detach(state.bus, chat_token)
      State(..state, chat_token: "")
    }
  }
  case state.presence_token {
    "" -> state
    presence_token -> {
      bus.detach(state.bus, presence_token)
      State(..state, presence_token: "")
    }
  }
}

/// WS 进程关闭（任何原因）：清干净房间里自己的痕迹，
/// 否则成员名单里会躺着一个永远不说话的幽灵。
fn close(state: State) -> Nil {
  case state.name {
    "" -> Nil
    _ -> {
      let _ = detach_all(state)
      room.leave(state.room, state.name)
    }
  }
}

// ---------- 服务端→客户端投递 ----------

fn deliver(state: State, seq: Int, payload: BitArray, conn) {
  // 游标推进对任何有效信封都生效（包括发别人的密文——重放时同样会被过滤）
  let state = State(..state, cursor: int.max(state.cursor, seq))
  case envelope.decode_payload(payload) {
    Ok(envelope.Chat(from, text, dedup_id)) -> {
      let _ = mist.send_text_frame(conn, chat_json(seq, from, text, dedup_id))
      // 游标推进：高频低价值写入，fire-and-forget
      store.put_async(state.store, state.cursor_key, int.to_string(seq))
      mist.continue(state)
    }
    // 端到端密文：只转发给收件人本人，server 永远看不到明文
    Ok(envelope.Enc(to, from, body, dedup_id)) -> {
      case to == state.name {
        True -> {
          let _ = mist.send_text_frame(
            conn,
            enc_json(seq, from, body, dedup_id),
          )
          store.put_async(state.store, state.cursor_key, int.to_string(seq))
          mist.continue(state)
        }
        False -> mist.continue(state)
      }
    }
    Ok(envelope.Notice(text)) -> {
      let _ = mist.send_text_frame(conn, notice_json(text))
      mist.continue(state)
    }
    // 成员名单快照：转发给客户端（core 用它更新加密目标名单）
    Ok(envelope.Members(members)) -> {
      let _ = mist.send_text_frame(conn, members_json(members))
      mist.continue(state)
    }
    // 坏帧/控制帧：丢弃（presence 走 core 订阅 seq=0，不更新游标）
    Error(_) -> mist.continue(state)
  }
}

// ---------- 线上 JSON ----------

fn joined_json(members: List(String)) -> String {
  json.object([
    #("type", json.string("joined")),
    #("members", json.array(members, json.string)),
  ])
  |> json.to_string
}

fn chat_json(seq: Int, from: String, text: String, dedup_id: String) -> String {
  json.object([
    #("type", json.string("chat")),
    #("from", json.string(from)),
    #("text", json.string(text)),
    #("dedup_id", json.string(dedup_id)),
    #("seq", json.int(seq)),
  ])
  |> json.to_string
}

fn enc_json(seq: Int, from: String, body: String, dedup_id: String) -> String {
  json.object([
    #("type", json.string("enc")),
    #("from", json.string(from)),
    #("body", json.string(body)),
    #("dedup_id", json.string(dedup_id)),
    #("seq", json.int(seq)),
  ])
  |> json.to_string
}

fn notice_json(text: String) -> String {
  json.object([#("type", json.string("notice")), #("text", json.string(text))])
  |> json.to_string
}

fn members_json(members: List(String)) -> String {
  json.object([
    #("type", json.string("members")),
    #("members", json.array(members, json.string)),
  ])
  |> json.to_string
}

fn error_json(reason: String) -> String {
  json.object([#("type", json.string("error")), #("reason", json.string(reason))])
  |> json.to_string
}

fn prekey_bundle_json(for_name: String, bundle: String) -> String {
  json.object([
    #("type", json.string("prekey_bundle")),
    #("for", json.string(for_name)),
    #("bundle", json.string(bundle)),
  ])
  |> json.to_string
}

// ---------- 客户端命令解码 ----------

fn decode_cmd(text: String) -> Result(ClientCmd, Nil) {
  let decoder = {
    use kind <- decode.field("type", decode.string)
    case kind {
      "join" -> {
        use name <- decode.field("name", decode.string)
        use cursor <- decode.field("cursor", decode.int)
        decode.success(JoinMsg(name, cursor))
      }
      "msg" -> {
        use text <- decode.field("text", decode.string)
        use dedup_id <- decode.field("dedup_id", decode.string)
        decode.success(ChatMsg(text, dedup_id))
      }
      "leave" -> decode.success(LeaveMsg)
      "prekey_register" -> {
        use bundle <- decode.field("bundle", decode.string)
        decode.success(PrekeyRegisterMsg(bundle))
      }
      "prekey_fetch" -> {
        use for_name <- decode.field("for", decode.string)
        decode.success(PrekeyFetchMsg(for_name))
      }
      "enc" -> {
        use to <- decode.field("to", decode.string)
        use body <- decode.field("body", decode.string)
        use dedup_id <- decode.field("dedup_id", decode.string)
        decode.success(EncMsg(to, body, dedup_id))
      }
      _ -> decode.failure(LeaveMsg, "unknown client command")
    }
  }
  case json.parse(from: text, using: decoder) {
    Ok(cmd) -> Ok(cmd)
    Error(_) -> Error(Nil)
  }
}
