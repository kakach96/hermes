//// bus 与 NATS JetStream 的集成测试 —— 需要 NATS 已启动
//// （infra\nats-server.exe -c infra\nats.conf）。
////
//// 隔离策略：每条测试用 unique suffix 生成自己的房间 subject，
//// consumer 按 subject 过滤，所以多次运行/并发测试互不污染，
//// 也不受流里历史数据影响。

import gleam/erlang/process
import gleam/otp/actor
import hermes/bus
import hermes/envelope
import hermes/ffi

fn unique_suffix() -> String {
  ffi.unique_inbox("")
}

pub fn chat_roundtrip_test() {
  let bus_name = process.new_name("test_bus")
  let assert Ok(actor.Started(_pid, _bus_sub)) =
    bus.start(bus_name, "127.0.0.1", 4222, "hermes_test", "hermes.test.")
  let hall = process.named_subject(bus_name)

  let room = "hermes.test." <> unique_suffix()
  let deliver = process.new_subject()

  // 1. 建消费者（deliver_policy = all）
  let assert Ok(_inbox) = bus.attach(hall, room, 0, deliver)

  // 2. 发布一条聊天
  bus.publish(hall, room, envelope.Chat("Alice", "环回测试", "dedup-1"))

  // 3. 应经 JetStream fanout 回来，且 seq 是 stream 序号
  let assert Ok(bus.Delivered(_seq, payload)) = process.receive(deliver, 5000)
  let assert Ok(envelope.Chat("Alice", "环回测试", "dedup-1")) =
    envelope.decode_payload(payload)
}

pub fn replay_from_seq_test() {
  let bus_name = process.new_name("test_bus_replay")
  let assert Ok(actor.Started(_pid, hall)) =
    bus.start(bus_name, "127.0.0.1", 4222, "hermes_test", "hermes.test.")
  let bus_sub = process.named_subject(bus_name)

  let room = "hermes.test." <> unique_suffix()

  // 先发三条（没有消费者在线 = 离线场景）
  bus.publish(hall, room, envelope.Chat("A", "一", "r1"))
  bus.publish(hall, room, envelope.Chat("A", "二", "r2"))
  bus.publish(hall, room, envelope.Chat("A", "三", "r3"))
  process.sleep(300)

  // 新会话从 seq 0 重放：应恰好收到这三条，顺序 = stream 顺序
  let deliver = process.new_subject()
  let assert Ok(_inbox) = bus.attach(bus_sub, room, 0, deliver)

  let assert Ok(bus.Delivered(s1, p1)) = process.receive(deliver, 5000)
  let assert Ok(envelope.Chat("A", "一", "r1")) = envelope.decode_payload(p1)
  let assert Ok(bus.Delivered(s2, p2)) = process.receive(deliver, 5000)
  let assert Ok(envelope.Chat("A", "二", "r2")) = envelope.decode_payload(p2)
  let assert Ok(bus.Delivered(s3, p3)) = process.receive(deliver, 5000)
  let assert Ok(envelope.Chat("A", "三", "r3")) = envelope.decode_payload(p3)

  // 游标语义：s1 < s2 < s3
  let assert True = s1 < s2
  let assert True = s2 < s3
}

pub fn replay_from_cursor_test() {
  let bus_name = process.new_name("test_bus_cursor")
  let assert Ok(actor.Started(_pid, hall)) =
    bus.start(bus_name, "127.0.0.1", 4222, "hermes_test", "hermes.test.")
  let bus_sub = process.named_subject(bus_name)

  let room = "hermes.test." <> unique_suffix()
  bus.publish(hall, room, envelope.Chat("A", "旧消息", "c1"))
  bus.publish(hall, room, envelope.Chat("A", "新消息", "c2"))
  process.sleep(300)

  // 重放全量拿到第一条的 seq，用它作为"已消费到 c1"的游标
  let deliver = process.new_subject()
  let assert Ok(_inbox) = bus.attach(bus_sub, room, 0, deliver)
  let assert Ok(bus.Delivered(seq_c1, payload_c1)) = process.receive(deliver, 5000)
  let assert Ok(envelope.Chat("A", "旧消息", "c1")) =
    envelope.decode_payload(payload_c1)

  // 从游标之后重放：传"下一条要收的 seq"（游标 + 1，包含起点），
  // 只应收到 c2 —— 这就是设备断线重连的补投
  let deliver2 = process.new_subject()
  let assert Ok(_inbox2) = bus.attach(bus_sub, room, seq_c1 + 1, deliver2)
  let assert Ok(bus.Delivered(_seq, p2)) = process.receive(deliver2, 5000)
  let assert Ok(envelope.Chat("A", "新消息", "c2")) = envelope.decode_payload(p2)
  // 超时收不到第二条，等价于"没有遗漏也没有多给"：
  let assert Error(Nil) = process.receive(deliver2, 500)
}

pub fn presence_not_persisted_test() {
  let bus_name = process.new_name("test_bus_presence")
  let assert Ok(actor.Started(_pid, hall)) =
    bus.start(bus_name, "127.0.0.1", 4222, "hermes_test", "hermes.test.")
  let bus_sub = process.named_subject(bus_name)

  let room = unique_suffix()
  let deliver = process.new_subject()
  let presence_subject = "hermes.presence." <> room
  let assert Ok(_presence_subject) = bus.attach_presence(bus_sub, presence_subject, deliver)

  bus.publish(hall, "hermes.presence." <> room, envelope.Notice("上线"))

  // presence 走 core 订阅：seq 恒为 0
  let assert Ok(bus.Delivered(0, payload)) = process.receive(deliver, 5000)
  let assert Ok(envelope.Notice("上线")) = envelope.decode_payload(payload)
}
