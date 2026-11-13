//// v0 信封：线上 JSON 的编解码。
////
//// 契约（与 proto/hermes/v1 一一对应，见该目录 README）：
////   chat   = {"type":"chat",   "from", "text", "dedup_id"}
////   notice = {"type":"notice", "text"}
//// dedup_id 由客户端生成，是 QoS1 幂等去重的钥匙。

import gleam/bit_array
import gleam/dynamic/decode
import gleam/json

pub type Envelope {
  Chat(from: String, text: String, dedup_id: String)
  Notice(text: String)
  /// 成员名单快照（走 presence 通道，不进流）：入房/退房时广播
  Members(list: List(String))
  /// 端到端加密消息：server 只做不透明转发，永远看不到明文。
  /// to 是目标成员名；所有订阅者都会收到，只有 to 本人才解密处理。
  Enc(to: String, from: String, body: String, dedup_id: String)
}

pub fn encode(envelope: Envelope) -> String {
  case envelope {
    Chat(from, text, dedup_id) ->
      json.object([
        #("type", json.string("chat")),
        #("from", json.string(from)),
        #("text", json.string(text)),
        #("dedup_id", json.string(dedup_id)),
      ])
    Notice(text) ->
      json.object([
        #("type", json.string("notice")),
        #("text", json.string(text)),
      ])
    Members(list) ->
      json.object([
        #("type", json.string("members")),
        #("members", json.array(list, json.string)),
      ])
    Enc(to, from, body, dedup_id) ->
      json.object([
        #("type", json.string("enc")),
        #("to", json.string(to)),
        #("from", json.string(from)),
        #("body", json.string(body)),
        #("dedup_id", json.string(dedup_id)),
      ])
  }
  |> json.to_string
}

/// 从 NATS 载荷（字节）解出信封。解析失败交给调用方处理：
/// v0 策略是静默丢弃坏帧 —— 聊天场景宁丢一帧不崩一房。
pub fn decode_payload(payload: BitArray) -> Result(Envelope, String) {
  case bit_array.to_string(payload) {
    Ok(text) -> decode_text(text)
    Error(Nil) -> Error("payload 不是合法 UTF-8")
  }
}

fn decode_text(text: String) -> Result(Envelope, String) {
  let decoder = {
    use kind <- decode.field("type", decode.string)
    case kind {
      "chat" -> {
        use from <- decode.field("from", decode.string)
        use text <- decode.field("text", decode.string)
        use dedup_id <- decode.field("dedup_id", decode.string)
        decode.success(Chat(from, text, dedup_id))
      }
      "notice" -> {
        use text <- decode.field("text", decode.string)
        decode.success(Notice(text))
      }
      "members" -> {
        use members <- decode.field("members", decode.list(decode.string))
        decode.success(Members(members))
      }
      "enc" -> {
        use to <- decode.field("to", decode.string)
        use from <- decode.field("from", decode.string)
        use body <- decode.field("body", decode.string)
        use dedup_id <- decode.field("dedup_id", decode.string)
        decode.success(Enc(to, from, body, dedup_id))
      }
      _ -> decode.failure(Chat("", "", ""), "unknown envelope type")
    }
  }
  case json.parse(from: text, using: decoder) {
    Ok(envelope) -> Ok(envelope)
    Error(_) -> Error("无法解析信封 JSON")
  }
}
