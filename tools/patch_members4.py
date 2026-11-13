# -*- coding: utf-8 -*-
import io

P = r"D:\projects\hermes\server\test\hermes_test.gleam"
c = io.open(P, encoding="utf-8").read()

# leave test: Leave 现在先广播 Members 快照再 Notice（顺序：Notice → Members）
old = """  process.send(hall, room.Leave("Alice"))
  let assert Ok(bus.Publish(
    "hermes.presence.t3",
    envelope.Notice("Alice 离开了房间"),
  )) = process.receive(fake_bus, 1000)"""
new = """  process.send(hall, room.Leave("Alice"))
  let assert Ok(bus.Publish(
    "hermes.presence.t3",
    envelope.Notice("Alice 离开了房间"),
  )) = process.receive(fake_bus, 1000)
  // 退房还会广播成员名单快照（成员活水机制）
  let assert Ok(bus.Publish(
    "hermes.presence.t3",
    envelope.Members([]),
  )) = process.receive(fake_bus, 1000)"""
assert old in c, "leave anchor"
c = c.replace(old, new)

io.open(P, "w", encoding="utf-8", newline="\n").write(c)
print("leave test patched")
