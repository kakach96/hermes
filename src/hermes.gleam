//// 赫尔墨斯 Phase 1：Gleam Actor 聊天室的可运行骨架。
////
//// 运行：gleam run
//// 测试：gleam test

import gleam/erlang/process.{type Pid, type Subject}
import gleam/io
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import hermes/client
import hermes/room

pub fn main() {
  // main 亲手 kill 一个客户端来演示 monitor。不 trap exit 的话，
  // exit 信号会顺着 link 一起带走 main，整场演示当场谢幕。
  process.trap_exits(True)

  // 1. 监督树：supervisor 挂着唯一的房间 worker。
  //    名字在程序入口创建一次；房间崩了重启后，仍用同一个名字登记。
  let room_name = process.new_name("hermes_room")
  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(room.supervised(room_name))
    |> supervisor.start

  // 2. named_subject 是"房间的门牌号"：不绑定具体 pid，重启多少次都有效
  let hall = process.named_subject(room_name)

  // 3. 两个客户端 Actor + main 自己扮演的"主持人"
  let #(_, _) = join_as(hall, "Alice")
  let #(bob_pid, _) = join_as(hall, "Bob")

  // 主持人和客户端一样，也只是"一个有自己的收件箱的进程"，
  // 只不过它的收件箱由 main 进程亲手创建、亲手 receive。
  let operator = process.new_subject()
  room.join(hall, "Operator", process.self(), operator)
  drain(operator, 1) // 消化"Operator 加入了房间"这条自我通知

  // 4. 剧本开始
  process.send(hall, room.Msg(from: "Alice", text: "这个房间是谁建的？"))
  drain(operator, 1)

  process.send(hall, room.Msg(from: "Bob", text: "查无此人，反正在线"))
  drain(operator, 1)

  // 拔掉 Bob 的网线：进程直接被 kill，房间靠 monitor 清理名单
  process.kill(bob_pid)
  drain(operator, 1)

  process.send(hall, room.Leave("Alice"))
  drain(operator, 1)

  io.println("—— Phase 1 演示结束 ——")
}

/// 起一个客户端 Actor 并让它同步入房，返回 (pid, 收件箱)。
fn join_as(
  hall: Subject(room.RoomMsg),
  name: String,
) -> #(Pid, Subject(client.ClientMsg)) {
  let assert Ok(actor.Started(pid, inbox)) = client.start(name)
  room.join(hall, name, pid, inbox)
  #(pid, inbox)
}

/// 主持人视角：等 n 条广播到齐并打印，保证演示输出是确定性的。
/// 每个 Actor 的邮箱是 FIFO，所以同一进程内消息顺序可靠；
/// 不同进程之间的打印交错才是 BEAM 的真实并发面貌。
fn drain(operator: Subject(client.ClientMsg), count: Int) -> Nil {
  case count {
    0 -> Nil
    _ -> {
      case process.receive(operator, 2000) {
        Ok(client.Chat(from, text)) ->
          io.println("[主持人] 看到 " <> from <> " 说：" <> text)
        Ok(client.Notice(text)) ->
          io.println("[主持人] 看到系统通知：" <> text)
        Error(Nil) ->
          io.println("[主持人] 等了 2 秒，什么也没收到（这里不该发生）")
      }
      drain(operator, count - 1)
    }
  }
}
