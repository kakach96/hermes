//// fjall 存储 sidecar 集成测试 —— 需要 storage/target/release/hermes-storage.exe
//// 已构建（cargo build --release）。exe 不在时自动跳过。
//// 每个 test 用独立数据目录，互不污染。

import gleam/erlang/process
import gleam/option
import gleam/otp/actor
import gleeunit
import hermes/bus
import hermes/envelope
import hermes/ffi
import hermes/room
import hermes/store

pub fn main() {
  gleeunit.main()
}

// 数据目录必须用全局随机：erlang:unique_integer 是 per-VM 计数器，
// 每次运行都从同样的数字开始 → 目录跨运行撞车，残留上一轮的 members
// 数据会被房间恢复出来（血泪教训，见 PLAN 踩坑表）
fn unique_id() -> String {
  ffi.unique_inbox("")
}

/// store.start 失败（多半是 exe 未构建）时跳过测试而不是报红
fn try_start(
  name: process.Name(store.StoreMsg),
  data_dir: String,
) -> Result(actor.Started(store.Store), actor.StartError) {
  let result = store.start(name, store.sidecar_exe, data_dir)
  case result {
    Error(_) ->
      println(
        "跳过 storage 测试（exe 未构建或启动失败）；先 cd storage && cargo build --release",
      )
    Ok(_) -> Nil
  }
  result
}

pub fn put_get_delete_roundtrip_test() {
  let dir = store.data_dir <> "/t_" <> unique_id()
  let name = process.new_name("store_test")
  case try_start(name, dir) {
    Ok(actor.Started(_pid, _)) -> {
      let hall = process.named_subject(name)

      let assert Ok(Nil) = store.put(hall, "hello", "世界")
      let assert Ok(option.Some("世界")) = store.get(hall, "hello")

      let assert Ok(Nil) = store.delete(hall, "hello")
      let assert Ok(option.None) = store.get(hall, "hello")

      // put_async 也应生效（fire-and-forget，稍等一下）
      store.put_async(hall, "async", "yes")
      process.sleep(100)
      let assert Ok(option.Some("yes")) = store.get(hall, "async")
      Nil
    }
    Error(_) -> Nil
  }
}

pub fn survives_sidecar_restart_test() {
  // 数据目录持久化：sidecar（连同 port）被杀重启后，数据仍在
  let dir = store.data_dir <> "/t_" <> unique_id()
  let name = process.new_name("store_restart_test")
  case try_start(name, dir) {
    Ok(actor.Started(pid, _)) -> {
      let hall = process.named_subject(name)
      let assert Ok(Nil) = store.put(hall, "persist", "fjall")

      process.trap_exits(True)
      process.kill(pid)
      process.sleep(100)

      let assert Ok(actor.Started(_pid2, _)) =
        store.start(name, store.sidecar_exe, dir)
      let hall2 = process.named_subject(name)
      let assert Ok(option.Some("fjall")) = store.get(hall2, "persist")
      Nil
    }
    Error(_) -> Nil
  }
}


@external(erlang, "gleam@io", "println")
fn println(text: String) -> Nil
