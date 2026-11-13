# -*- coding: utf-8 -*-
import io

# 1. room.gleam: Join 去重 + 移除名册持久化（成员资格 = 连接生命周期）
P = r"D:\projects\hermes\server\src\hermes\room.gleam"
c = io.open(P, encoding="utf-8").read()

old_join = """    Join(name, reply_to) -> {
      let members = [name, ..state.members]"""
new_join = """    Join(name, reply_to) -> {
      // 重进房间 = 移到队首（去重）；名册是活水，不 persist
      let others = list.filter(state.members, fn(m) { m != name })
      let members = [name, ..others]"""
assert old_join in c, "join anchor"
c = c.replace(old_join, new_join)

old_persist_join = """      persist(state, members)
      process.send(reply_to, members)"""
new_persist_join = """      process.send(reply_to, members)"""
assert old_persist_join in c, "persist join anchor"
c = c.replace(old_persist_join, new_persist_join)

old_persist_leave = """      persist(state, members)
      actor.continue(State(..state, members: members))
    }
  }
}"""
new_persist_leave = """      actor.continue(State(..state, members: members))
    }
  }
}"""
assert old_persist_leave in c, "persist leave anchor"
c = c.replace(old_persist_leave, new_persist_leave)

# 移除 persist 函数与 storage 字段
old_persist_fn = """fn persist(state: State, members: List(String)) -> Nil {
  case state.storage {
    option.Some(s) ->
      store.put_async(
        s,
        members_key(state.chat_subject),
        json.array(members, json.string) |> json.to_string,
      )
    option.None -> Nil
  }
}

fn members_key(chat_subject: String) -> String {
  "members:" <> chat_subject
}

"""
assert old_persist_fn in c, "persist fn anchor"
c = c.replace(old_persist_fn, "")

# storage 字段与相关 import 保留会报 unused —— 一并清掉
c = c.replace("""type State {
  State(
    members: List(String),
    chat_subject: String,
    presence_subject: String,
    bus: Subject(bus.BusMsg),
    /// v0 的状态外置：成员名单持久化到 fjall sidecar（测试传 None 跳过）
    storage: Option(store.Store),
  )
}""", """type State {
  State(
    members: List(String),
    chat_subject: String,
    presence_subject: String,
    bus: Subject(bus.BusMsg),
  )
}""")

c = c.replace("""pub fn supervised(
  name: Name(RoomMsg),
  chat_subject: String,
  presence_subject: String,
  bus: Subject(bus.BusMsg),
  storage: Option(store.Store),
) -> supervision.ChildSpecification(process.Subject(RoomMsg)) {
  supervision.worker(fn() {
    start(name, chat_subject, presence_subject, bus, storage)
  })
}""", """pub fn supervised(
  name: Name(RoomMsg),
  chat_subject: String,
  presence_subject: String,
  bus: Subject(bus.BusMsg),
) -> supervision.ChildSpecification(process.Subject(RoomMsg)) {
  supervision.worker(fn() {
    start(name, chat_subject, presence_subject, bus)
  })
}""")

c = c.replace("""pub fn start(
  name: Name(RoomMsg),
  chat_subject: String,
  presence_subject: String,
  bus: Subject(bus.BusMsg),
  storage: Option(store.Store),
) -> actor.StartResult(process.Subject(RoomMsg)) {
  actor.new_with_initialiser(5000, fn(subject) {
    // 成员名单从 sidecar 恢复 —— 房间崩了重启不再变幽灵房
    let members = case storage {
      option.Some(s) ->
        case store.get(s, members_key(chat_subject)) {
          Ok(option.Some(text)) ->
            case json.parse(from: text, using: decode.list(decode.string)) {
              Ok(list) -> list
              Error(_) -> []
            }
          _ -> []
        }
      option.None -> []
    }

    let selector = process.new_selector() |> process.select(subject)
    let initialised =
      actor.initialised(State(
        members: members,
        chat_subject: chat_subject,
        presence_subject: presence_subject,
        bus: bus,
        storage: storage,
      ))
      |> actor.selecting(selector)
      |> actor.returning(subject)

    Ok(initialised)
  })
  |> actor.named(name)
  |> actor.on_message(handle)
  |> actor.start
}""", """pub fn start(
  name: Name(RoomMsg),
  chat_subject: String,
  presence_subject: String,
  bus: Subject(bus.BusMsg),
) -> actor.StartResult(process.Subject(RoomMsg)) {
  actor.new(State(
    members: [],
    chat_subject: chat_subject,
    presence_subject: presence_subject,
    bus: bus,
  ))
  |> actor.named(name)
  |> actor.on_message(handle)
  |> actor.start
}""")

# imports 清理
c = c.replace("import gleam/json\n", "")
c = c.replace("import gleam/option.{type Option}\n", "")
c = c.replace("import hermes/store\n", "")

io.open(P, "w", encoding="utf-8", newline="\n").write(c)
print("room patched")

# 2. main.gleam: room.supervised 不再传 storage
P2 = r"D:\projects\hermes\server\src\hermes.gleam"
c2 = io.open(P2, encoding="utf-8").read()
old_main = """    |> supervisor.add(
      room.supervised(
        lobby_name,
        "hermes.rooms.lobby",
        "hermes.presence.lobby",
        bus_subject,
        option.Some(store_subject),
      ),
    )"""
new_main = """    |> supervisor.add(
      room.supervised(
        lobby_name,
        "hermes.rooms.lobby",
        "hermes.presence.lobby",
        bus_subject,
      ),
    )"""
assert old_main in c2, "main anchor"
c2 = c2.replace(old_main, new_main)
c2 = c2.replace("import gleam/option\n", "")
io.open(P2, "w", encoding="utf-8", newline="\n").write(c2)
print("main patched")

# 3. tests: room.start 去掉 option.None 参数
P3 = r"D:\projects\hermes\server\test\hermes_test.gleam"
c3 = io.open(P3, encoding="utf-8").read()
c3 = c3.replace(", fake_bus,\n      option.None,\n    )", ", fake_bus,\n    )")
c3 = c3.replace("import gleam/option\n", "")
io.open(P3, "w", encoding="utf-8", newline="\n").write(c3)
print("tests patched")

# 4. store_test 里的 room.start 调用同步
P4 = r"D:\projects\hermes\server\test\store_test.gleam"
c4 = io.open(P4, encoding="utf-8").read()
c4 = c4.replace("""        room.start(
          room_name,
          "hermes.rooms.p1",
          "hermes.presence.p1",
          fake_bus,
          option.Some(hall_store),
        )""", """        room.start(
          room_name,
          "hermes.rooms.p1",
          "hermes.presence.p1",
          fake_bus,
        )""")
c4 = c4.replace("""        room.start(
          room_name,
          "hermes.rooms.p1",
          "hermes.presence.p1",
          fake_bus,
          option.Some(hall_store),
        )""", """        room.start(
          room_name,
          "hermes.rooms.p1",
          "hermes.presence.p1",
          fake_bus,
        )""")
# room_members_persist_test 已无意义（名册不再持久化）→ 删除
s = c4.find("pub fn room_members_persist_test()")
if s != -1:
    e = c4.find("\n}\n", s)
    c4 = c4[:s] + c4[e+3:]
io.open(P4, "w", encoding="utf-8", newline="\n").write(c4)
print("store_test patched")
