//// meta（元数据域：users/spaces/channels/members/perms）集成测试。
//// 依赖 sidecar exe（同 store_test）；exe 不在时自动跳过。
//// 所有实体名带全局随机后缀 —— 跨 VM/跨运行防撞车（宪法级教训）。

import gleam/option
import gleam/string
import gleam/otp/actor
import gleam/erlang/process
import gleeunit
import hermes/ffi
import hermes/meta
import hermes/store

pub fn main() {
  gleeunit.main()
}

fn unique_id() -> String {
  // unique_inbox 出大写十六进制 —— 名字校验只收小写，转掉
  string.lowercase(ffi.unique_inbox(""))
}

fn try_start(
  name: process.Name(store.StoreMsg),
  data_dir: String,
) -> Result(actor.Started(store.Store), actor.StartError) {
  let result = store.start(name, store.sidecar_exe, data_dir)
  case result {
    Error(_) ->
      println("跳过 meta 测试（sidecar 未构建）；先 cd storage && cargo build --release")
    Ok(_) -> Nil
  }
  result
}

pub fn space_create_list_test() {
  let dir = store.data_dir <> "/t_" <> unique_id()
  let name = process.new_name("meta_space_test")
  case try_start(name, dir) {
    Ok(actor.Started(_pid, _)) -> {
      let hall = process.named_subject(name)
      let space = "s_" <> unique_id()
      let other = "s_" <> unique_id()

      let assert Ok(Nil) = meta.space_create(hall, space, "alice")
      // 重复建 = 拒绝（幂等保护）
      let assert Error(_) = meta.space_create(hall, space, "bob")
      // 非法名 = 拒绝（subject token 安全线）
      let assert Error(_) = meta.space_create(hall, "with.dot", "alice")

      let assert Ok(spaces) = meta.space_list(hall)
      let assert True =
        contains_pair(spaces, space, "alice")
      // 另一个空间也进去（list 是全量）
      let assert Ok(Nil) = meta.space_create(hall, other, "carol")
      let assert Ok(spaces2) = meta.space_list(hall)
      let assert True = contains_pair(spaces2, other, "carol")
      Nil
    }
    Error(_) -> Nil
  }
}

pub fn channel_list_and_permission_test() {
  let dir = store.data_dir <> "/t_" <> unique_id()
  let name = process.new_name("meta_channel_test")
  case try_start(name, dir) {
    Ok(actor.Started(_pid, _)) -> {
      let hall = process.named_subject(name)
      let space = "s_" <> unique_id()

      let assert Ok(Nil) = meta.space_create(hall, space, "owner")
      let assert Ok(Nil) = meta.perm_set(hall, space, "owner", "owner")
      let assert Ok(Nil) = meta.member_upsert(hall, space, "owner", "owner")

      // 频道创建 + 前缀列出
      let assert Ok(Nil) = meta.channel_create(hall, space, "general")
      let assert Ok(Nil) = meta.channel_create(hall, space, "random")
      let assert Error(_) = meta.channel_create(hall, space, "general")
      let assert Ok(channels) = meta.channel_list(hall, space)
      let assert True = contains(channels, "general")
      let assert True = contains(channels, "random")

      // 权限：owner/admin 可建，普通成员不行
      let assert Ok(True) = meta.can_create_channel(hall, space, "owner")
      let assert Ok(Nil) = meta.perm_set(hall, space, "admin1", "admin")
      let assert Ok(True) = meta.can_create_channel(hall, space, "admin1")
      let assert Ok(Nil) = meta.perm_set(hall, space, "pleb", "member")
      let assert Ok(False) = meta.can_create_channel(hall, space, "pleb")
      let assert Ok(option.None) = meta.perm_get(hall, space, "stranger")

      // 成员资格（持久）
      let assert Ok(Nil) = meta.member_upsert(hall, space, "pleb", "member")
      // 幂等：重复登记不覆盖首条（joined_ms 语义）
      let assert Ok(Nil) = meta.member_upsert(hall, space, "pleb", "member")
      let assert Ok(members) = meta.member_list(hall, space)
      let assert True = contains_pair(members, "pleb", "member")
      Nil
    }
    Error(_) -> Nil
  }
}

pub fn name_validation_test() {
  let assert True = meta.valid_name("lobby")
  let assert True = meta.valid_name("a-b_c9")
  let assert False = meta.valid_name("with.dot")
  // NATS 通配符与空 token 全是注入面
  let assert False = meta.valid_name("with*star")
  let assert False = meta.valid_name("with>gt")
  let assert False = meta.valid_name("中文名")
  let assert False = meta.valid_name("")
  let assert False = meta.valid_name("a-very-long-name-that-exceeds-the-32-char-limit")
  Nil
}

// ---------- helpers ----------

fn contains(haystack: List(String), needle: String) -> Bool {
  case haystack {
    [] -> False
    [head, ..tail] -> head == needle || contains(tail, needle)
  }
}

fn contains_pair(
  haystack: List(#(String, String)),
  key: String,
  value: String,
) -> Bool {
  case haystack {
    [] -> False
    [#(k, v), ..tail] -> k == key && v == value || contains_pair(tail, key, value)
  }
}

@external(erlang, "gleam@io", "println")
fn println(text: String) -> Nil
