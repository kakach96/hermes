//// 客户端 Actor —— Phase 1 里它代替未来的"一条 WebSocket 连接"。
//// 没有业务状态，收到广播就打印：这是最朴素的 receive 消费者。

import gleam/erlang/process.{type Subject}
import gleam/io
import gleam/otp/actor

pub type ClientMsg {
  /// 一条广播出来的聊天消息
  Chat(from: String, text: String)
  /// 房间状态变化：加入 / 退出 / 掉线
  Notice(text: String)
}

/// 起一个客户端进程。它不持有房间引用 —— 它唯一的身份是自己的收件箱，
/// 房间往收件箱里投消息，它只负责收。
pub fn start(whoami: String) -> actor.StartResult(Subject(ClientMsg)) {
  actor.new(whoami)
  |> actor.on_message(handle)
  |> actor.start
}

fn handle(whoami: String, msg: ClientMsg) -> actor.Next(String, ClientMsg) {
  case msg {
    Chat(from, text) -> {
      io.println("[" <> from <> "] -> " <> whoami <> "：" <> text)
      actor.continue(whoami)
    }
    Notice(text) -> {
      io.println("(房间) -> " <> whoami <> "：" <> text)
      actor.continue(whoami)
    }
  }
}
