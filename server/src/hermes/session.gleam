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
import gleam/list
import gleam/option
import gleam/result
import mist

import hermes/bus
import hermes/envelope
import hermes/meta
import hermes/registry
import hermes/room
import hermes/rooms
import hermes/store

pub type State {
  State(
    bus: Subject(bus.BusMsg),
    /// 动态房间管理器：join 时按 <space>.<channel> 取（或惰性建）房间
    rooms: Subject(rooms.RoomsMsg),
    store: store.Store,
    registry: Subject(registry.RegistryMsg),
    /// 入房后填充（"" = 未入房）
    space: String,
    channel: String,
    room_subject: String,
    presence_subject: String,
    /// 入房时由房间管理器惰性解析出；未入房 = None
    room: option.Option(Subject(room.RoomMsg)),
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
  /// 登录：只确定身份（user_touch），不入房。大厅页的元数据操作靠它放行
  LoginMsg(name: String)
  JoinMsg(name: String, cursor: Int, space: String, channel: String)
  ChatMsg(text: String, dedup_id: String)
  /// 离开房间但**保持连接与登录态**（回大厅页）——与断开 WS 是两回事
  LeaveMsg
  /// 登记 Signal 注册包（bundle 是 JSON 字符串，server 不透明存储）
  PrekeyRegisterMsg(bundle: String)
  /// 取某人的注册包 → 回 prekey_bundle 帧（空 bundle = 对方无登记）
  PrekeyFetchMsg(for_name: String)
  /// 端到端密文：server 原样转发进房间流，只有 to 本人解密
  EncMsg(to: String, body: String, dedup_id: String)
  /// 建空间（创建者 = owner）；回 space_created / error
  SpaceCreateMsg(space: String)
  /// 列空间；回 spaces 帧
  SpaceListMsg
  /// 建频道（需 owner/admin）；回 channel_created / error
  ChannelCreateMsg(space: String, channel: String)
  /// 列某空间频道；回 channels 帧
  ChannelListMsg(space: String)
}

/// 把 HTTP 请求升级为 WebSocket 会话。
/// ?name=<用户名> 查询参数即身份：升级即登录（HTTP 平面认证过的客户端
/// 把名字带进来），回 logged_in 帧；不带则保持未登录（裸工具 join 兜底）。
pub fn upgrade(
  req: request.Request(mist.Connection),
  bus: Subject(bus.BusMsg),
  rooms: Subject(rooms.RoomsMsg),
  storage: store.Store,
  registry: Subject(registry.RegistryMsg),
) -> response.Response(mist.ResponseData) {
  let identity = identity_from_query(req)
  let initial_name = case identity {
    // 身份合法性已在 identity_from_query 校验过；这里建档（幂等）
    "" -> ""
    name -> {
      let _ = meta.user_touch(storage, name)
      name
    }
  }
  mist.websocket(
    request: req,
    on_init: fn(ws_conn) {
      let ws_subject = process.new_subject()
      let state =
        State(
          bus: bus,
          rooms: rooms,
          store: storage,
          registry: registry,
          space: "",
          channel: "",
          room_subject: "",
          presence_subject: "",
          room: option.None,
          name: initial_name,
          chat_token: "",
          presence_token: "",
          cursor_key: "",
          cursor: 0,
          ws_subject: ws_subject,
        )
      // 查询参数带来的身份：立刻回执（大厅页无需再发 login 帧）
      case initial_name {
        "" -> Nil
        name -> {
          let _ = mist.send_text_frame(ws_conn, logged_in_json(name))
          Nil
        }
      }
      let selector =
        process.new_selector()
        |> process.select(ws_subject)
      #(state, option.Some(selector))
    },
    handler: handle,
    on_close: close,
  )
}

/// 从升级请求的 ?name= 查询参数取会话身份。
/// 空串/缺参/非法名 = 未登录（裸工具用 join 帧隐式登录兜底）。
fn identity_from_query(req: request.Request(mist.Connection)) -> String {
  case request.get_query(req) {
    Error(_) -> ""
    Ok(pairs) ->
      case find_pair(pairs, "name") {
        Ok(name) ->
          case meta.check_user(name) {
            Ok(_) -> name
            Error(_) -> ""
          }
        Error(Nil) -> ""
      }
  }
}

fn find_pair(pairs: List(#(String, String)), key: String) -> Result(String, Nil) {
  case pairs {
    [] -> Error(Nil)
    [#(k, v), ..rest] ->
      case k == key {
        True -> Ok(v)
        False -> find_pair(rest, key)
      }
  }
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
    Ok(LoginMsg(name)) -> {
      case state.name {
        // 重复登录同一身份：幂等回执
        "" -> login(state, name, conn)
        n if n == name -> {
          let _ = mist.send_text_frame(conn, logged_in_json(n))
          mist.continue(state)
        }
        n -> {
          let _ = mist.send_text_frame(
            conn,
            error_json("本连接已登录为 " <> n <> "，如需换身份请重连"),
          )
          mist.continue(state)
        }
      }
    }
    Ok(JoinMsg(name, cursor, space, channel)) -> {
      // 未登录直接 join（node e2e 工具的老路径）：隐式 login 兜底
      case state.name {
        "" ->
          case meta.check_user(name) {
            Error(reason) -> {
              let _ = mist.send_text_frame(conn, error_json(reason))
              mist.continue(state)
            }
            Ok(_) -> {
              let _ = meta.user_touch(state.store, name)
              join_room(State(..state, name: name), cursor, space, channel, conn)
            }
          }
        // 已登录：帧里的 name 要么为空（GUI 不传），要么必须一致
        n -> {
          case name {
            "" -> join_room(state, cursor, space, channel, conn)
            other if other == n ->
              join_room(state, cursor, space, channel, conn)
            other -> {
              let _ = mist.send_text_frame(
                conn,
                error_json("已登录为 " <> n <> "，不能以 " <> other <> " 入房"),
              )
              mist.continue(state)
            }
          }
        }
      }
    }
    Ok(ChatMsg(text, dedup_id)) -> {
      case state.room {
        option.Some(room_actor) -> {
          room.send_message(room_actor, state.name, text, dedup_id)
          mist.continue(state)
        }
        // 未入房不许说话
        option.None -> mist.continue(state)
      }
    }
    Ok(LeaveMsg) -> {
      // 离开房间 ≠ 断开：回大厅页后连接与登录态都保留
      let state = leave_room(state)
      let _ = mist.send_text_frame(conn, left_json())
      mist.continue(state)
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
      case state.room {
        option.Some(room_actor) ->
          room.send_enc(room_actor, to, state.name, body, dedup_id)
        option.None -> Nil
      }
      mist.continue(state)
    }

    Ok(SpaceCreateMsg(space)) -> {
      case state.name {
        "" -> mist.continue(state)
        name -> space_create(state, space, name, conn)
      }
    }

    Ok(SpaceListMsg) -> {
      case state.name {
        "" -> mist.continue(state)
        _ -> {
          let frame = case meta.space_list(state.store) {
            Ok(pairs) ->
              json.object([
                #("type", json.string("spaces")),
                #(
                  "spaces",
                  json.array(pairs, fn(pair) {
                    let #(name, owner) = pair
                    json.object([
                      #("name", json.string(name)),
                      #("owner", json.string(owner)),
                    ])
                  }),
                ),
              ])
              |> json.to_string
            Error(reason) -> error_json(reason)
          }
          let _ = mist.send_text_frame(conn, frame)
          mist.continue(state)
        }
      }
    }

    Ok(ChannelCreateMsg(space, channel)) -> {
      case state.name {
        "" -> mist.continue(state)
        name -> channel_create(state, space, channel, name, conn)
      }
    }

    Ok(ChannelListMsg(space)) -> {
      let body = case meta.channel_list(state.store, space) {
        Ok(names) ->
          json.object([
            #("type", json.string("channels")),
            #("space", json.string(space)),
            #("channels", json.array(names, json.string)),
          ])
          |> json.to_string
        Error(reason) -> error_json(reason)
      }
      let _ = mist.send_text_frame(conn, body)
      mist.continue(state)
    }
  }
}

// ---------- 空间 / 频道管理 ----------

fn space_create(
  state: State,
  space: String,
  name: String,
  conn,
) -> mist.Next(State, bus.Delivered) {
  case meta.space_create(state.store, space, name) {
    Error(reason) -> {
      let _ = mist.send_text_frame(conn, error_json(reason))
      mist.continue(state)
    }
    Ok(Nil) -> {
      // 建档时的从属写入：owner 角色 + 首个成员资格（失败不阻断，
      // 元数据域的次级记录，下个动作会幂等补上）
      let _ = meta.perm_set(state.store, space, name, "owner")
      let _ = meta.member_upsert(state.store, space, name, "owner")
      let _ = mist.send_text_frame(conn, space_created_json(space))
      mist.continue(state)
    }
  }
}

fn channel_create(
  state: State,
  space: String,
  channel: String,
  name: String,
  conn,
) -> mist.Next(State, bus.Delivered) {
  let result =
    meta.check_name(channel)
    |> result.try(fn(_) { meta.check_name(space) })
    |> result.try(fn(_) {
      case meta.space_exists(state.store, space) {
        Ok(True) -> Ok(Nil)
        Ok(False) -> Error("空间不存在: " <> space)
        Error(reason) -> Error(reason)
      }
    })
    |> result.try(fn(_) {
      case meta.can_create_channel(state.store, space, name) {
        Ok(True) -> Ok(Nil)
        Ok(False) -> Error("无权在 " <> space <> " 建频道（需 owner/admin）")
        Error(reason) -> Error(reason)
      }
    })
    |> result.try(fn(_) { meta.channel_create(state.store, space, channel) })
  case result {
    Error(reason) -> {
      let _ = mist.send_text_frame(conn, error_json(reason))
      mist.continue(state)
    }
    Ok(Nil) -> {
      let _ = mist.send_text_frame(
        conn,
        channel_created_json(space, channel),
      )
      mist.continue(state)
    }
  }
}

fn join_room(
  state: State,
  cursor: Int,
  space: String,
  channel: String,
  conn,
) {
  // 已在房间里先退（大厅页换频道 = 直接点另一个频道进入）
  let state = case state.room {
    option.Some(_) -> leave_room(state)
    option.None -> state
  }
  // 空串归一化：其他客户端显式发空 space/channel 时回落 wire 缺省
  // （GUI 的 core 传输层已做同样归一化，这里是对裸 WS 客户端的兜底）
  let space = case space {
    "" -> meta.default_space
    _ -> space
  }
  let channel = case channel {
    "" -> meta.default_channel
    _ -> channel
  }
  // 空间/频道名过 subject-token 校验（NATS 路由注入防线）；
  // 用户名在 login 阶段已校验（宽松规则，不进 subject）
  case
    meta.check_name(space)
    |> result.try(fn(_) { meta.check_name(channel) })
  {
    Error(reason) -> {
      let _ = mist.send_text_frame(conn, error_json(reason))
      mist.continue(state)
    }
    Ok(_) -> join_ok(state, cursor, space, channel, conn)
  }
}

fn join_ok(
  state: State,
  cursor: Int,
  space: String,
  channel: String,
  conn,
) {
  let name = state.name

  // 开放模型（v0）：空间不存在则自动建档，首个进入者即 owner；
  // 频道不存在则自动建（join 即创建，显式建频道走 channel_create 帧才有权限门）
  case meta.space_exists(state.store, space) {
    Ok(True) -> {
      let _ = meta.member_upsert(state.store, space, name, "member")
      Nil
    }
    Ok(False) -> {
      let _ = meta.space_create(state.store, space, name)
      let _ = meta.perm_set(state.store, space, name, "owner")
      let _ = meta.member_upsert(state.store, space, name, "owner")
      Nil
    }
    Error(_) -> Nil
  }
  let _ =
    meta.channel_exists(state.store, space, channel)
    |> result.try(fn(exists) {
      case exists {
        True -> Ok(Nil)
        False -> meta.channel_create(state.store, space, channel)
      }
    })

  // 房间 subject 直接编码层级：hermes.rooms.<space>.<channel>。
  // JetStream 流订的是 hermes.rooms.> 前缀，天然覆盖所有空间/频道。
  let key = space <> "." <> channel
  let room_subject = "hermes.rooms." <> key
  let presence_subject = "hermes.presence." <> key

  // 游标恢复：客户端报了 cursor 就用客户端的（设备真相在客户端），
  // 没报（=0）就查服务端替它记住的那个
  let cursor_key = "cursor:" <> room_subject <> ":" <> name
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

  case rooms.room_of(state.rooms, space, channel) {
    Error(reason) -> {
      let _ = mist.send_text_frame(conn, error_json(reason))
      mist.continue(state)
    }
    Ok(room_actor) -> {
      // 顺序敏感：先挂 presence 订阅，再让房间广播加入通知 —— 自己也能收到
      case
        bus.attach_presence(state.bus, presence_subject, state.ws_subject)
      {
        Error(reason) -> {
          let _ = mist.send_text_frame(conn, error_json("presence: " <> reason))
          mist.continue(state)
        }
        Ok(presence_token) -> {
          let members = room.join(room_actor, name)
          case
            bus.attach(state.bus, room_subject, start_cursor + 1, state.ws_subject)
          {
            Error(reason) -> {
              bus.detach(state.bus, presence_token)
              room.leave(room_actor, name)
              let _ = mist.send_text_frame(conn, error_json("attach: " <> reason))
              mist.continue(state)
            }
            Ok(chat_token) -> {
              let _ =
                mist.send_text_frame(
                  conn,
                  joined_json(members, durable_targets(state, space, members)),
                )
              mist.continue(
                State(
                  ..state,
                  name: name,
                  space: space,
                  channel: channel,
                  room_subject: room_subject,
                  presence_subject: presence_subject,
                  room: option.Some(room_actor),
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
  }
}

/// 登录：确定身份并建档（幂等），不触碰任何房间状态。
fn login(state: State, name: String, conn) {
  case meta.check_user(name) {
    Error(reason) -> {
      let _ = mist.send_text_frame(conn, error_json(reason))
      mist.continue(state)
    }
    Ok(_) ->
      case meta.user_touch(state.store, name) {
        Error(reason) -> {
          let _ = mist.send_text_frame(conn, error_json(reason))
          mist.continue(state)
        }
        Ok(Nil) -> {
          let _ = mist.send_text_frame(conn, logged_in_json(name))
          mist.continue(State(..state, name: name))
        }
      }
  }
}

/// 离开房间：清订阅与房间关联，**保留登录态**（大厅还要用）。
fn leave_room(state: State) -> State {  let state = detach_all(state)
  case state.room {
    option.Some(room_actor) -> room.leave(room_actor, state.name)
    option.None -> Nil
  }
  State(
    ..state,
    space: "",
    channel: "",
    room_subject: "",
    presence_subject: "",
    room: option.None,
    chat_token: "",
    presence_token: "",
  )
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
      let state = detach_all(state)
      case state.room {
        option.Some(room_actor) -> room.leave(room_actor, state.name)
        option.None -> Nil
      }
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

fn joined_json(members: List(String), targets: List(String)) -> String {
  json.object([
    #("type", json.string("joined")),
    #("members", json.array(members, json.string)),
    #("targets", json.array(targets, json.string)),
  ])
  |> json.to_string
}

/// 加密目标 = 空间**持久成员**（fjall members 域）∪ 当前在线。
/// 这是收件箱模型对 pairwise 加密的自洽解：消息永远给每个空间成员
/// 留一份密文在流里——接收方离线时重进按游标补投即可拿到。
/// 在线名单（members）只负责 presence 显示，不参与加密分发。
fn durable_targets(state: State, space: String, live: List(String)) -> List(String) {
  let durable = case meta.member_list(state.store, space) {
    Ok(pairs) ->
      list.map(pairs, fn(pair) {
        let #(name, _) = pair
        name
      })
    Error(_) -> []
  }
  // live 里可能有 meta 落账延迟的刚进成员：补上（fjall 写是同步完成的，
  // 这里只是防御性兜底）
  list.append(durable, list.filter(live, fn(m) { !list.contains(durable, m) }))
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

fn logged_in_json(name: String) -> String {
  json.object([#("type", json.string("logged_in")), #("name", json.string(name))])
  |> json.to_string
}

fn left_json() -> String {
  json.object([#("type", json.string("left"))]) |> json.to_string
}

fn space_created_json(space: String) -> String {
  json.object([#("type", json.string("space_created")), #("name", json.string(space))])
  |> json.to_string
}

fn channel_created_json(space: String, channel: String) -> String {
  json.object([
    #("type", json.string("channel_created")),
    #("space", json.string(space)),
    #("name", json.string(channel)),
  ])
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
      "login" -> {
        use name <- decode.field("name", decode.string)
        decode.success(LoginMsg(name))
      }
      "join" -> {
        // name 可选：登录后由 server 用会话身份（GUI 不传）；
        // 裸工具直接 join 时带 name 走隐式登录
        use name <- decode.optional_field("name", "", decode.string)
        use cursor <- decode.field("cursor", decode.int)
        // 空间/频道可选：缺省 lobby/general（e2e 工具与旧客户端零改动）
        use space <- decode.optional_field(
          "space",
          meta.default_space,
          decode.string,
        )
        use channel <- decode.optional_field(
          "channel",
          meta.default_channel,
          decode.string,
        )
        decode.success(JoinMsg(name, cursor, space, channel))
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
      "space_create" -> {
        use space <- decode.field("space", decode.string)
        decode.success(SpaceCreateMsg(space))
      }
      "space_list" -> decode.success(SpaceListMsg)
      "channel_create" -> {
        use space <- decode.field("space", decode.string)
        use channel <- decode.field("channel", decode.string)
        decode.success(ChannelCreateMsg(space, channel))
      }
      "channel_list" -> {
        use space <- decode.field("space", decode.string)
        decode.success(ChannelListMsg(space))
      }
      _ -> decode.failure(LeaveMsg, "unknown client command")
    }
  }
  case json.parse(from: text, using: decoder) {
    Ok(cmd) -> Ok(cmd)
    Error(_) -> Error(Nil)
  }
}
