//// Erlang FFI（hermes_ffi.erl）的类型安全绑定 —— 最小 NATS 客户端。
////
//// 内部模块：只给 bus.gleam 用，不要在别处 import。

import gleam/erlang/process.{type Pid}

/// NATS 连接（一个连接 = 一个 Erlang 进程，独占 socket）
pub type Conn

/// 建连并发送 CONNECT 帧。on_msg 在连接进程内被调用：
/// fn(route_subject, msg_subject, reply, payload)。
/// route_subject = 订阅时的 subject（JetStream 下是 inbox），
/// msg_subject = 消息的原始 subject（JetStream push 会保留原始房间 subject），
/// reply = 回执 subject（JetStream 下含 $JS.ACK 流序号元数据），
/// payload = 原始字节。
@external(erlang, "hermes_ffi", "connect")
pub fn connect(
  host: String,
  port: Int,
  on_msg: fn(String, String, String, BitArray) -> Nil,
) -> Result(Conn, String)

/// 关闭连接（v0 基本用不到：监督树会重启整个 bus）
@external(erlang, "hermes_ffi", "close")
pub fn close(conn: Conn) -> Nil

/// 连接进程的 pid，供 bus monitor
@external(erlang, "hermes_ffi", "conn_pid")
pub fn conn_pid(conn: Conn) -> Pid

/// 总线型订阅：该 subject 的 MSG 会被路由进 on_msg 回调，返回 sid
@external(erlang, "hermes_ffi", "subscribe")
pub fn subscribe(conn: Conn, subject: String) -> Result(Int, Nil)

@external(erlang, "hermes_ffi", "unsubscribe")
pub fn unsubscribe(conn: Conn, sid: Int) -> Nil

/// fire-and-forget 发布
@external(erlang, "hermes_ffi", "publish")
pub fn publish(conn: Conn, subject: String, payload: BitArray) -> Nil

/// 同步 request-reply（NATS 自带语义），超时返回 Error
@external(erlang, "hermes_ffi", "request")
pub fn request(
  conn: Conn,
  subject: String,
  payload: BitArray,
  timeout_ms: Int,
) -> Result(BitArray, String)

/// 生成唯一字符串（基于 erlang:unique_integer，不烧原子表）
@external(erlang, "hermes_ffi", "unique_inbox")
pub fn unique_inbox(prefix: String) -> String
