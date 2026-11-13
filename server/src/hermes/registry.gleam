//// prekey 注册表 —— 端到端加密的"目录服务"。
////
//// 每个用户把自己的 Signal 注册包（bundle JSON）登记在这里，
//// 别人要跟 TA 建会话时来取。server 只存不透明的 JSON 字符串，
//// 既不解密也不签名 —— 私钥永远只在客户端 crypto 线程里。
////
//// v0 简化：内存字典，server 重启后丢失；客户端每次入房都会重新
//// 注册，所以几秒内自愈。persist 到 sidecar 是第二轮的事。

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Subject}
import gleam/otp/actor
import gleam/otp/supervision

pub type RegistryMsg {
  /// 登记自己的注册包（同名覆盖 —— 每次连接都会刷一次）
  Register(name: String, bundle_json: String)
  /// 取某人的注册包；没有登记（从未上线/离线超时清除）回 None
  Fetch(name: String, reply_to: Subject(Result(String, Nil)))
}

type State {
  State(bundles: Dict(String, String))
}

pub fn supervised(
  name: Name(RegistryMsg),
) -> supervision.ChildSpecification(Subject(RegistryMsg)) {
  supervision.worker(fn() { start(name) })
}

pub fn start(name: Name(RegistryMsg)) -> actor.StartResult(Subject(RegistryMsg)) {
  actor.new(State(bundles: dict.new()))
  |> actor.named(name)
  |> actor.on_message(handle)
  |> actor.start
}

fn handle(state: State, msg: RegistryMsg) -> actor.Next(State, RegistryMsg) {
  case msg {
    Register(name, bundle_json) -> {
      actor.continue(State(bundles: dict.insert(state.bundles, name, bundle_json)))
    }

    Fetch(name, reply_to) -> {
      let found = dict.get(state.bundles, name)
      process.send(reply_to, found)
      actor.continue(state)
    }
  }
}

// ---------- API ----------

pub fn register(
  registry: Subject(RegistryMsg),
  name: String,
  bundle_json: String,
) -> Nil {
  process.send(registry, Register(name, bundle_json))
}

pub fn fetch(
  registry: Subject(RegistryMsg),
  name: String,
) -> Result(String, Nil) {
  process.call(registry, 1000, Fetch(name, _))
}
