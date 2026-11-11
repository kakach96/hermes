import gleam/erlang/process
import gleam/otp/actor
import gleeunit
import hermes/client
import hermes/room

pub fn main() {
  gleeunit.main()
}

// Join 是同步 call，回执应是当前成员名单（新成员排最前）
pub fn join_reports_members_test() {
  let name = process.new_name("test_room")
  let assert Ok(_) = room.start(name)
  let hall = process.named_subject(name)

  let assert Ok(actor.Started(alice_pid, alice_inbox)) = client.start("Alice")
  let assert ["Alice"] = room.join(hall, "Alice", alice_pid, alice_inbox)

  let assert Ok(actor.Started(bob_pid, bob_inbox)) = client.start("Bob")
  let assert ["Bob", "Alice"] = room.join(hall, "Bob", bob_pid, bob_inbox)
}

// 客户端进程被 kill 后，房间应通过 monitor 广播掉线通知
pub fn dead_member_broadcasts_down_test() {
  // 同 main：杀掉被 link 的客户端进程时，防止 exit 信号带走测试进程
  process.trap_exits(True)

  let name = process.new_name("test_room_down")
  let assert Ok(_) = room.start(name)
  let hall = process.named_subject(name)

  let operator = process.new_subject()
  room.join(hall, "Operator", process.self(), operator)

  let assert Ok(actor.Started(guest_pid, _guest_inbox)) = client.start("Guest")
  let assert ["Guest", "Operator"] = room.join(hall, "Guest", guest_pid, _guest_inbox)

  // 入房通知先到
  let assert Ok(client.Notice("Guest 加入了房间")) =
    process.receive(operator, 2000)

  process.kill(guest_pid)

  // 房间靠 monitor 感知死亡并广播
  let assert Ok(client.Notice("Guest 掉线了，被请出房间")) =
    process.receive(operator, 2000)
}
