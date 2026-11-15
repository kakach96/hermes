//// 房间管理器 —— 空间/频道时代房间是**按需 lazy spawn** 的。
////
//// 以前整个 server 一个写死的 lobby 房间；现在 join 可能落在任意
//// <space>.<channel> 上，房间 Actor 不能再在监督树里静态枚举。
////
//// 模型（v0 玩具规模刻意简单）：
//// - 管理器是受监督的 worker，持有 Dict(key, room Subject)
//// - GetRoom 命中 → 直接回；未命中 → process.new_name + room.start
////   （linked spawn，房间成为管理器的子进程）
//// - 房间崩溃 → exit 信号带走管理器 → 监督树重启管理器（dict 清空）
////   → 下一个 join 惰性重建。名册本来就是瞬态的（宪法），
////   房间"丢了"唯一的损失是空房间名单，天然自愈
//// - 陷阱备忘：每个频道一个 new_name = 原子表里多一个唯一原子。
////   只发生在"新频道第一次有人进"这一刻（有界、低频），不是热循环；
////   若未来频道量巨大，改用全局 gproc 式按 subject 寻址。

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Subject}
import gleam/otp/actor
import gleam/otp/supervision

import hermes/bus
import hermes/room

pub type RoomsMsg {
  /// 取（或惰性建）某频道的房间 Actor。key = <space>.<channel>
  GetRoom(
    space: String,
    channel: String,
    reply_to: Subject(Result(RoomRef, String)),
  )
}

/// 房间句柄
pub type RoomRef =
  Subject(room.RoomMsg)

type State {
  State(
    /// "<space>.<channel>" -> 房间句柄
    rooms: Dict(String, RoomRef),
    bus: Subject(bus.BusMsg),
  )
}

pub fn supervised(
  name: Name(RoomsMsg),
  bus: Subject(bus.BusMsg),
) -> supervision.ChildSpecification(Subject(RoomsMsg)) {
  supervision.worker(fn() { start(name, bus) })
}

pub fn start(
  name: Name(RoomsMsg),
  bus: Subject(bus.BusMsg),
) -> actor.StartResult(Subject(RoomsMsg)) {
  actor.new(State(rooms: dict.new(), bus: bus))
  |> actor.named(name)
  |> actor.on_message(handle)
  |> actor.start
}

fn handle(state: State, msg: RoomsMsg) -> actor.Next(State, RoomsMsg) {
  case msg {
    GetRoom(space, channel, reply_to) -> {
      let key = space <> "." <> channel
      case dict.get(state.rooms, key) {
        Ok(subject) -> {
          process.send(reply_to, Ok(subject))
          actor.continue(state)
        }
        Error(Nil) -> {
          case spawn_room(state, key) {
            Ok(subject) -> {
              process.send(reply_to, Ok(subject))
              actor.continue(
                State(..state, rooms: dict.insert(state.rooms, key, subject)),
              )
            }
            Error(reason) -> {
              process.send(reply_to, Error(reason))
              actor.continue(state)
            }
          }
        }
      }
    }
  }
}

/// room.start 是 linked spawn：房间成为管理器子进程（见模块头注释）。
fn spawn_room(state: State, key: String) -> Result(RoomRef, String) {
  let name = process.new_name("hermes_room_" <> key)
  case
    room.start(
      name,
      "hermes.rooms." <> key,
      "hermes.presence." <> key,
      state.bus,
    )
  {
    // actor.Started(data) 里的 data 就是 Subject
    Ok(started) -> Ok(started.data)
    // StartError 是 opaque 类型，归一化成字符串（细节进日志无益）
    Error(_) -> Error("房间启动失败: " <> key)
  }
}

// ---------- 客户端 API ----------

/// 取（或惰性建）某频道的房间 Actor。
pub fn room_of(
  rooms: Subject(RoomsMsg),
  space: String,
  channel: String,
) -> Result(RoomRef, String) {
  process.call(rooms, 5000, GetRoom(space, channel, _))
}
