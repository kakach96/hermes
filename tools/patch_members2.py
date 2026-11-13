# -*- coding: utf-8 -*-
import io

# room.gleam: publish Members snapshot on presence subject after Join/Leave
P = r"D:\projects\hermes\server\src\hermes\room.gleam"
c = io.open(P, encoding="utf-8").read()

old_join = """    Join(name, reply_to) -> {
      let members = [name, ..state.members]
      // presence 走非持久订阅，不进 JetStream（重放时不会收到陈旧通知）
      bus.publish(state.bus, state.presence_subject, envelope.Notice(
        name <> " 加入了房间",
      ))
      persist(state, members)
      process.send(reply_to, members)
      actor.continue(State(..state, members: members))
    }"""
new_join = """    Join(name, reply_to) -> {
      let members = [name, ..state.members]
      // presence 走非持久订阅，不进 JetStream（重放时不会收到陈旧通知）
      bus.publish(state.bus, state.presence_subject, envelope.Notice(
        name <> " 加入了房间",
      ))
      // 成员名单快照广播：后来者加入时，先来者的名单也要更新（否则
      // 先来者发消息只会发给入房时刻的成员 —— 名单漂移的坑）
      bus.publish(state.bus, state.presence_subject, envelope.Members(
        members,
      ))
      persist(state, members)
      process.send(reply_to, members)
      actor.continue(State(..state, members: members))
    }"""
assert old_join in c, "join anchor"
c = c.replace(old_join, new_join)

old_leave = """    Leave(name) -> {
      let members = list.filter(state.members, fn(m) { m != name })
      bus.publish(state.bus, state.presence_subject, envelope.Notice(
        name <> " 离开了房间",
      ))
      persist(state, members)
      actor.continue(State(..state, members: members))
    }"""
new_leave = """    Leave(name) -> {
      let members = list.filter(state.members, fn(m) { m != name })
      bus.publish(state.bus, state.presence_subject, envelope.Notice(
        name <> " 离开了房间",
      ))
      bus.publish(state.bus, state.presence_subject, envelope.Members(
        members,
      ))
      persist(state, members)
      actor.continue(State(..state, members: members))
    }"""
assert old_leave in c, "leave anchor"
c = c.replace(old_leave, new_leave)

io.open(P, "w", encoding="utf-8", newline="\n").write(c)
print("room patched")

# session.gleam: deliver handles Members envelope -> forward members frame
P2 = r"D:\projects\hermes\server\src\hermes\session.gleam"
c2 = io.open(P2, encoding="utf-8").read()

old_d = """    Ok(envelope.Notice(text)) -> {
      let _ = mist.send_text_frame(conn, notice_json(text))
      mist.continue(state)
    }
    // 坏帧/控制帧：丢弃（presence 走 core 订阅 seq=0，不更新游标）
    Error(_) -> mist.continue(state)
  }
}"""
new_d = """    Ok(envelope.Notice(text)) -> {
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
}"""
assert old_d in c2, "session deliver anchor"
c2 = c2.replace(old_d, new_d)

old_fn = """fn error_json(reason: String) -> String {"""
new_fn = """fn members_json(members: List(String)) -> String {
  json.object([
    #("type", json.string("members")),
    #("members", json.array(members, json.string)),
  ])
  |> json.to_string
}

fn error_json(reason: String) -> String {"""
assert old_fn in c2, "members_json anchor"
c2 = c2.replace(old_fn, new_fn)

io.open(P2, "w", encoding="utf-8", newline="\n").write(c2)
print("session patched")
