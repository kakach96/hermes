//// 房间 Actor —— 赫尔墨斯 Phase 1 的核心。
////
//// 三条设计原则，也是 BEAM 的常态：
//// 1. 唯一可变状态是一份成员名单，外界只能用消息触碰它（状态内聚，天然无锁）；
//// 2. 客户端进程挂掉时，房间靠 monitor 收到 Erlang 'DOWN'，广播通知其余成员；
//// 3. 房间用进程名登记。崩溃被 supervisor 重启后，外界手里的通道依旧有效。

import gleam/erlang/process.{type Monitor, type Name, type Pid, type Subject}
import gleam/list
import gleam/otp/actor
import gleam/otp/supervision

import hermes/client.{type ClientMsg}

/// 房间能理解的所有消息。这就是房间的全部对外 API。
pub type RoomMsg {
  /// 入房申请：名字、自己的 pid（供房间 monitor）、收件箱、回执通道。
  /// Join 是同步 call，回执是当前成员名单（新成员在前）。
  Join(
    name: String,
    pid: Pid,
    inbox: Subject(ClientMsg),
    reply_to: Subject(List(String)),
  )
  /// 一条要广播的聊天消息。广播的"协议"很朴素：改消息体而不是改收件人。
  Msg(from: String, text: String)
  /// 主动退房
  Leave(name: String)
  /// Erlang 'DOWN'：被 monitor 的客户端进程死了
  MemberDown(down: process.Down)
}

/// 房间状态：一份成员名单。monitor 是死亡通知的凭据，退房时要凭它解除。
type Member {
  Member(name: String, pid: Pid, inbox: Subject(ClientMsg), monitor: Monitor)
}

/// 在程序入口创建一次的名字。房间重启后重新登记同一个名字，
/// named_subject 对外界永远有效 —— 这是"监督树 + 命名进程"的经典搭配。
/// 绝不要在循环里调用 new_name，它会烧 Erlang 原子表。
pub fn supervised(
  name: Name(RoomMsg),
) -> supervision.ChildSpecification(Subject(RoomMsg)) {
  supervision.worker(fn() { start(name) })
}

/// 启动房间。可直接调用（测试用），也可作为 supervisor 的 worker。
pub fn start(name: Name(RoomMsg)) -> actor.StartResult(Subject(RoomMsg)) {
  actor.new_with_initialiser(5000, fn(subject) {
    // 房间要收两类消息：业务消息（走 subject）和客户端死亡通知（走 monitor）。
    // 给了自定义 selector 之后，默认 subject 不会自动注册，必须手动加回来，
    // 否则房间收不到任何聊天消息，只收得到 'DOWN'。
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_monitors(fn(down) { MemberDown(down) })

    let initialised =
      actor.initialised([])
      |> actor.selecting(selector)
      |> actor.returning(subject)

    Ok(initialised)
  })
  |> actor.named(name)
  |> actor.on_message(handle)
  |> actor.start
}

/// 消息处理：一次只处理一条，顺序执行 —— 这就是"每个 Actor 一个邮箱、
/// 状态只在单进程里流转"的含义，不需要任何锁。
fn handle(
  members: List(Member),
  msg: RoomMsg,
) -> actor.Next(List(Member), RoomMsg) {
  case msg {
    Join(name, pid, inbox, reply_to) -> {
      // monitor 必须由房间进程自己发起，'DOWN' 才会投进房间的信箱
      let monitor = process.monitor(pid)
      let members = [Member(name, pid, inbox, monitor), ..members]
      // 广播放在登记之后，新成员也能听到自己的入房通知
      broadcast(members, client.Notice(name <> " 加入了房间"))
      process.send(reply_to, list.map(members, fn(member) { member.name }))
      actor.continue(members)
    }

    Msg(from, text) -> {
      broadcast(members, client.Chat(from, text))
      actor.continue(members)
    }

    Leave(name) -> {
      case take_member(members, by_name(name)) {
        Ok(#(member, rest)) -> {
          // 主动退房要主动解除 monitor，否则稍后会收到一封迟到的 'DOWN'
          process.demonitor_process(member.monitor)
          broadcast(rest, client.Notice(name <> " 离开了房间"))
          actor.continue(rest)
        }
        Error(Nil) -> actor.continue(members)
      }
    }

    MemberDown(down) -> {
      case take_member(members, by_monitor(down.monitor)) {
        Ok(#(member, rest)) -> {
          broadcast(rest, client.Notice(member.name <> " 掉线了，被请出房间"))
          actor.continue(rest)
        }
        // 已经退房的成员的迟到 'DOWN'，直接吞掉
        Error(Nil) -> actor.continue(members)
      }
    }
  }
}

// ---------- 内部工具 ----------

fn broadcast(members: List(Member), what: ClientMsg) -> Nil {
  list.each(members, fn(member) { process.send(member.inbox, what) })
}

fn by_name(name: String) -> fn(Member) -> Bool {
  fn(member: Member) { member.name == name }
}

fn by_monitor(monitor: Monitor) -> fn(Member) -> Bool {
  fn(member: Member) { member.monitor == monitor }
}

/// 从名单里摘出一个成员，返回它和剩下的名单。
fn take_member(
  members: List(Member),
  matches: fn(Member) -> Bool,
) -> Result(#(Member, List(Member)), Nil) {
  case members {
    [] -> Error(Nil)
    [first, ..rest] ->
      case matches(first) {
        True -> Ok(#(first, rest))
        False ->
          case take_member(rest, matches) {
            Ok(#(found, remainder)) -> Ok(#(found, [first, ..remainder]))
            Error(Nil) -> Error(Nil)
          }
      }
  }
}

// ---------- 客户端 API ----------

/// 同步入房：发起 call，等房间回执成员名单。1000ms 内没回执就崩溃调用方，
/// call 语义就是这样：宁可崩溃重试，也不能拿着一个假的"已加入"继续跑。
pub fn join(
  hall: Subject(RoomMsg),
  name: String,
  pid: Pid,
  inbox: Subject(ClientMsg),
) -> List(String) {
  process.call(hall, 1000, fn(reply: Subject(List(String))) {
    Join(name, pid, inbox, reply)
  })
}
