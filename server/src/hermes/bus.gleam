//// 总线 Actor —— NATS JetStream 的唯一持有者。
////
//// 职责：
//// 1. 持有唯一的 NATS 连接（Erlang FFI），连接死亡 → 自己退场，监督树重启重建
//// 2. 发布：房间 Actor 把信封 JSON 发到房间 subject
//// 3. 订阅：为每个会话创建 JetStream ephemeral consumer（按房间过滤），
////    消息回执 $JS.ACK 里的 stream seq 就是设备游标的真身
//// 4. presence 走非持久 core 订阅（不进流，重放时不会收到陈旧通知）
////
//// 内部模块：main 与 room/session 只通过 Subject(BusMsg) 交互。

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Subject}
import gleam/int
import gleam/io
import gleam/json.{type Json}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/string

import hermes/envelope.{type Envelope}
import hermes/ffi

/// 从 NATS 投递到会话的消息。seq = JetStream stream 序号（游标）；
/// presence 走 core 订阅，没有 stream seq，恒为 0。
pub type Delivered {
  Delivered(seq: Int, payload: BitArray)
}

pub type BusMsg {
  /// 来自 NATS 连接进程的回调路由（内部）。
  /// inbox = 订阅 subject（路由键）；msg_subject = 消息原始 subject。
  Route(inbox: String, msg_subject: String, reply: String, payload: BitArray)
  /// 发布信封到指定 subject（房间 Actor 用）
  Publish(subject: String, envelope: Envelope)
  /// 为会话建 JetStream consumer：按 room 过滤，from_seq <= 0 表示从头。
  /// 成功回执 consumer 的 inbox subject（会话退房时凭它 Detach）。
  Attach(
    room: String,
    from_seq: Int,
    deliver: Subject(Delivered),
    reply_to: Subject(Result(String, String)),
  )
  /// 为会话建 presence 订阅（非持久）
  AttachPresence(
    room: String,
    deliver: Subject(Delivered),
    reply_to: Subject(Result(String, String)),
  )
  /// 会话退房：UNSUB inbox，ephemeral consumer 随之自动删除
  Detach(subject: String)
  /// NATS 连接死亡（内部）
  ConnDown
}

type Kind {
  /// JetStream 消费者投递（inbox subject）
  Jetstream
  /// 非持久 core 订阅（presence）
  Core
}

type Entry {
  Entry(sid: Int, deliver: Subject(Delivered), kind: Kind)
}

type State {
  State(
    conn: ffi.Conn,
    routes: Dict(String, Entry),
    stream: String,
    room_prefix: String,
  )
}

pub fn supervised(
  name: Name(BusMsg),
  host: String,
  port: Int,
  stream: String,
  room_prefix: String,
) -> supervision.ChildSpecification(Subject(BusMsg)) {
  supervision.worker(fn() { start(name, host, port, stream, room_prefix) })
}

pub fn start(
  name: Name(BusMsg),
  host: String,
  port: Int,
  stream: String,
  room_prefix: String,
) -> actor.StartResult(Subject(BusMsg)) {
  actor.new_with_initialiser(10_000, fn(subject) {
    let on_msg = fn(inbox: String, msg_subject: String, reply: String, p: BitArray) {
      process.send(subject, Route(inbox, msg_subject, reply, p))
    }
    case ffi.connect(host, port, on_msg) {
      Error(reason) -> Error("NATS 连接失败: " <> reason)
      Ok(conn) -> {
        ensure_stream(conn, stream, room_prefix)
        let _ = process.monitor(ffi.conn_pid(conn))
        let selector =
          process.new_selector()
          |> process.select(subject)
          |> process.select_monitors(fn(_) { ConnDown })

        let initialised =
          actor.initialised(State(
            conn: conn,
            routes: dict.new(),
            stream: stream,
            room_prefix: room_prefix,
          ))
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

// ---------- 消息处理 ----------

fn handle(state: State, msg: BusMsg) -> actor.Next(State, BusMsg) {
  case msg {
    Publish(subject, envelope) -> {
      let payload = envelope.encode(envelope) |> bit_array.from_string
      ffi.publish(state.conn, subject, payload)
      actor.continue(state)
    }

    Route(inbox, _msg_subject, reply, payload) -> {
      case dict.get(state.routes, inbox) {
        Ok(Entry(_, deliver, Jetstream)) ->
          case parse_stream_seq(reply) {
            Ok(seq) -> process.send(deliver, Delivered(seq, payload))
            // reply 为空 = 控制帧（CREATE 应答等），吞掉
            Error(Nil) -> Nil
          }
        Ok(Entry(_, deliver, Core)) ->
          process.send(deliver, Delivered(0, payload))
        // 无人认领的消息（比如 Detach 与投递赛跑），丢弃
        Error(Nil) -> Nil
      }
      actor.continue(state)
    }

    Attach(room, from_seq, deliver, reply_to) -> {
      let inbox = ffi.unique_inbox("_INBOX.")
      case ffi.subscribe(state.conn, inbox) {
        Error(Nil) -> {
          process.send(reply_to, Error("订阅 inbox 失败"))
          actor.continue(state)
        }
        Ok(sid) -> {
          let cfg =
            consumer_config(state.stream, room, from_seq, inbox)
            |> json.to_string
            |> bit_array.from_string
          case
            ffi.request(
              state.conn,
              "$JS.API.CONSUMER.CREATE." <> state.stream,
              cfg,
              5000,
            )
          {
            Ok(_consumer_info) -> {
              let state =
                State(
                  ..state,
                  routes: dict.insert(
                    state.routes,
                    inbox,
                    Entry(sid, deliver, Jetstream),
                  ),
                )
              process.send(reply_to, Ok(inbox))
              actor.continue(state)
            }
            Error(reason) -> {
              ffi.unsubscribe(state.conn, sid)
              process.send(reply_to, Error("创建 consumer 失败: " <> reason))
              actor.continue(state)
            }
          }
        }
      }
    }

    AttachPresence(room, deliver, reply_to) -> {
      let subject = "hermes.presence." <> room
      case ffi.subscribe(state.conn, subject) {
        Error(Nil) -> {
          process.send(reply_to, Error("订阅 presence 失败"))
          actor.continue(state)
        }
        Ok(sid) -> {
          let state =
            State(
              ..state,
              routes: dict.insert(
                state.routes,
                subject,
                Entry(sid, deliver, Core),
              ),
            )
          process.send(reply_to, Ok(subject))
          actor.continue(state)
        }
      }
    }

    Detach(subject) -> {
      let state = case dict.get(state.routes, subject) {
        Ok(entry) -> {
          ffi.unsubscribe(state.conn, entry.sid)
          State(..state, routes: dict.delete(state.routes, subject))
        }
        Error(Nil) -> state
      }
      actor.continue(state)
    }

    ConnDown -> {
      io.println("(bus) NATS 连接断开，交还监督树重启")
      actor.stop_abnormal("nats connection lost")
    }
  }
}

// ---------- 客户端 API（供 room / session 调用） ----------

pub fn publish(
  bus: Subject(BusMsg),
  subject: String,
  envelope: Envelope,
) -> Nil {
  process.send(bus, Publish(subject, envelope))
}

/// 建消费者并等待就绪。返回 inbox subject，退房时凭它 Detach。
/// from_seq 是**包含**起点：传"下一条要收的 stream seq"，
/// 即设备游标（最后一条已收的 seq）+ 1；从零开始收全量传 0。
pub fn attach(
  bus: Subject(BusMsg),
  room: String,
  from_seq: Int,
  deliver: Subject(Delivered),
) -> Result(String, String) {
  process.call(bus, 8000, Attach(room, from_seq, deliver, _))
}

pub fn attach_presence(
  bus: Subject(BusMsg),
  room: String,
  deliver: Subject(Delivered),
) -> Result(String, String) {
  process.call(bus, 8000, AttachPresence(room, deliver, _))
}

pub fn detach(bus: Subject(BusMsg), subject: String) -> Nil {
  process.send(bus, Detach(subject))
}

// ---------- JetStream 细节 ----------

fn ensure_stream(conn: ffi.Conn, stream: String, room_prefix: String) -> Nil {
  let cfg =
    json.object([
      #("name", json.string(stream)),
      #("subjects", json.array([room_prefix <> ">"], json.string)),
      #("storage", json.string("file")),
      #("retention", json.string("limits")),
    ])
    |> json.to_string
    |> bit_array.from_string
  case
    ffi.request(conn, "$JS.API.STREAM.CREATE." <> stream, cfg, 5000)
  {
    Ok(_info) -> Nil
    // 已存在且配置一致时 NATS 也会成功返回；其他错误先记日志不致命
    Error(reason) -> io.println("(bus) 建流失败: " <> reason)
  }
}

fn consumer_config(stream: String, room: String, from_seq: Int, inbox: String) -> Json {
  // v2.15.3（API level 5，Strict 模式）要求请求体包一层：
  // {"stream_name": ..., "config": {...ConsumerConfig}}
  // 另外该版本 ephemeral consumer 默认闲置 5s 即删，必须显式放宽，
  // 否则安静房间会话会在几分钟内悄悄收不到消息。
  // v0 不配 flow_control / idle_heartbeat：玩具规模下先少动零件。
  // opt_start_seq 只在 by_start_sequence 时有效，全量投递时必须剔除。
  let config = [
    #("filter_subject", json.string(room)),
    #("deliver_subject", json.string(inbox)),
    #("ack_policy", json.string("none")),
    #("deliver_policy", json.string(deliver_policy(from_seq))),
    #("inactive_threshold", json.int(1_800_000_000_000)),
  ]
  let config = case from_seq <= 0 {
    True -> config
    False -> [#("opt_start_seq", json.int(from_seq)), ..config]
  }
  json.object([
    #("stream_name", json.string(stream)),
    #("config", json.object(config)),
  ])
}

fn deliver_policy(from_seq: Int) -> String {
  case from_seq <= 0 {
    True -> "all"
    False -> "by_start_sequence"
  }
}

fn parse_stream_seq(reply: String) -> Result(Int, Nil) {
  // $JS.ACK.<stream>.<consumer>.<delivered>.<sseq>.<dseq>.<ts>.<pending>
  case string.split(reply, ".") {
    ["$JS", "ACK", _stream, _consumer, _delivered, sseq, ..] -> int.parse(sseq)
    _ -> Error(Nil)
  }
}
