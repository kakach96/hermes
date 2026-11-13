# -*- coding: utf-8 -*-
import io

P = r"D:\projects\hermes\server\test\hermes_test.gleam"
c = io.open(P, encoding="utf-8").read()

old = """  let assert Ok(bus.Publish(
    "hermes.presence.t3",
    envelope.Notice("Alice 加入了房间"),
  )) = process.receive(fake_bus, 1000)

  process.send(hall, room.Leave("Alice"))"""
new = """  let assert Ok(bus.Publish(
    "hermes.presence.t3",
    envelope.Notice("Alice 加入了房间"),
  )) = process.receive(fake_bus, 1000)
  // Join 还会广播成员名单快照（成员活水机制），先排空
  let assert Ok(bus.Publish(
    "hermes.presence.t3",
    envelope.Members(["Alice"]),
  )) = process.receive(fake_bus, 1000)

  process.send(hall, room.Leave("Alice"))"""
assert old in c, "anchor"
c = c.replace(old, new)

io.open(P, "w", encoding="utf-8", newline="\n").write(c)
print("drain added")
