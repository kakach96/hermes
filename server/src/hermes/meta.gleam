//// 元数据域 —— 空间 / 频道 / 用户 / 成员资格 / 权限。
////
//// 全部落 fjall sidecar 的独立 partition（见 storage/src/main.rs 头注释）：
////   users / spaces / channels / members / perms
//// key 约定集中在这里，其他模块不许私拼 key。
////
//// 语义切分（重要）：
//// - members/perms 存的是**持久资格**（谁属于哪个空间、什么角色）
//// - "谁此刻在线"（连接名册）是瞬态的，永远在 room Actor 内存里，
////   成员资格 = 连接生命周期的宪法不变
////
//// 名字规则（NATS subject token 安全）：
////   space / channel / user 名一律 [a-z0-9_-]{1,32}，禁止点号 ——
////   room subject 形如 hermes.rooms.<space>.<channel>，一个点就是一个
////   subject token 边界，放任用户输入等于放任路由注入。

import gleam/erlang/atom.{type Atom}
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string

import gleam/dynamic/decode

import hermes/store.{type Store}

/// NATS subject 里房间的默认落点（wire 缺省值）
pub const default_space = "lobby"

pub const default_channel = "general"

// ---------- 名字校验 ----------

const lowercase = "abcdefghijklmnopqrstuvwxyz"

const digits = "0123456789"

/// [a-z0-9_-]{1,32}：subject token 安全 + 人类可读
pub fn valid_name(name: String) -> Bool {
  let graphemes = string.to_graphemes(name)
  let len = list.length(graphemes)
  case len >= 1 && len <= 32 {
    False -> False
    True ->
      list.all(graphemes, fn(g) {
        string.contains(lowercase, g)
        || string.contains(digits, g)
        || g == "_"
        || g == "-"
      })
  }
}

pub fn check_name(name: String) -> Result(String, String) {
  case valid_name(name) {
    True -> Ok(name)
    False ->
      Error("空间/频道名不合法（只允许小写字母/数字/_/-，1~32 位）: " <> name)
  }
}

/// 用户名走宽松规则：不进 NATS subject（只做成员 key 与 enc 匹配），
/// 大写与中文都合法；只挡空名与超长。
pub fn check_user(name: String) -> Result(String, String) {
  let len = string.length(string.trim(name))
  case len >= 1 && len <= 32 {
    True -> Ok(name)
    False -> Error("用户名不合法（1~32 个字符）: " <> name)
  }
}

// ---------- key 约定（partition 内的裸 key） ----------

pub fn user_key(name: String) -> String {
  name
}

pub fn space_key(space: String) -> String {
  space
}

pub fn channel_key(space: String, channel: String) -> String {
  space <> "." <> channel
}

pub fn member_key(space: String, user: String) -> String {
  space <> "." <> user
}

// ---------- 用户 ----------

/// 有则跳过（created_ms 是首次出现时间），无则建档。
pub fn user_touch(store: Store, name: String) -> Result(Nil, String) {
  case store.ks_get(store, "users", user_key(name)) {
    Ok(option.Some(_)) -> Ok(Nil)
    Ok(option.None) ->
      store.ks_put(
        store,
        "users",
        user_key(name),
        json.object([#("created_ms", json.int(now_ms()))])
          |> json.to_string,
      )
    Error(reason) -> Error(reason)
  }
}

/// 注册：存在即拒绝（区别于幂等的 user_touch——注册有明确语义）。
pub fn user_exists(store: Store, name: String) -> Result(Bool, String) {
  case store.ks_get(store, "users", user_key(name)) {
    Ok(option.Some(_)) -> Ok(True)
    Ok(option.None) -> Ok(False)
    Error(reason) -> Error(reason)
  }
}

pub fn user_register(store: Store, name: String) -> Result(Nil, String) {
  case user_exists(store, name) {
    Ok(True) -> Error("用户已存在: " <> name)
    Ok(False) -> user_touch(store, name)
    Error(reason) -> Error(reason)
  }
}

// ---------- 空间 ----------

/// 建空间（幂等拒绝重复）。创建者即 owner，写 perms 与 members。
pub fn space_create(
  store: Store,
  space: String,
  owner: String,
) -> Result(Nil, String) {
  use _ <- result.try(check_name(space))
  case store.ks_get(store, "spaces", space_key(space)) {
    Ok(option.Some(_)) -> Error("空间已存在: " <> space)
    Ok(option.None) ->
      store.ks_put(
        store,
        "spaces",
        space_key(space),
        json.object([
          #("name", json.string(space)),
          #("owner", json.string(owner)),
          #("created_ms", json.int(now_ms())),
        ])
        |> json.to_string,
      )
    Error(reason) -> Error(reason)
  }
}

/// 列出全部空间：#(space 名, owner)。key 升序（fjall prefix 迭代序）。
pub fn space_list(store: Store) -> Result(List(#(String, String)), String) {
  case store.ks_list(store, "spaces", "") {
    Ok(items) ->
      items
      |> list.map(fn(item) {
        let #(key, value) = item
        #(key, json_to_string_field(value, "owner"))
      })
      |> Ok
    Error(reason) -> Error(reason)
  }
}

/// 空间是否存在（join 时自动建空间用）
pub fn space_exists(store: Store, space: String) -> Result(Bool, String) {
  case store.ks_get(store, "spaces", space_key(space)) {
    Ok(option.Some(_)) -> Ok(True)
    Ok(option.None) -> Ok(False)
    Error(reason) -> Error(reason)
  }
}

// ---------- 频道 ----------

pub fn channel_create(
  store: Store,
  space: String,
  channel: String,
) -> Result(Nil, String) {
  use _ <- result.try(check_name(channel))
  case store.ks_get(store, "channels", channel_key(space, channel)) {
    Ok(option.Some(_)) -> Error("频道已存在: " <> space <> "/" <> channel)
    Ok(option.None) ->
      store.ks_put(
        store,
        "channels",
        channel_key(space, channel),
        json.object([
          #("space", json.string(space)),
          #("name", json.string(channel)),
          #("created_ms", json.int(now_ms())),
        ])
        |> json.to_string,
      )
    Error(reason) -> Error(reason)
  }
}

pub fn channel_exists(
  store: Store,
  space: String,
  channel: String,
) -> Result(Bool, String) {
  case store.ks_get(store, "channels", channel_key(space, channel)) {
    Ok(option.Some(_)) -> Ok(True)
    Ok(option.None) -> Ok(False)
    Error(reason) -> Error(reason)
  }
}

/// 列某空间下的频道名。key 形如 `<space>.<channel>`，前缀取频道段。
pub fn channel_list(
  store: Store,
  space: String,
) -> Result(List(String), String) {
  let prefix = space <> "."
  case store.ks_list(store, "channels", prefix) {
    Ok(items) ->
      items
      |> list.map(fn(item) {
        let #(key, _) = item
        case string.split_once(key, prefix) {
          Ok(#(_, channel)) -> channel
          Error(Nil) -> key
        }
      })
      |> Ok
    Error(reason) -> Error(reason)
  }
}

// ---------- 成员资格（持久）与角色 ----------

/// 幂等登记：已有记录不覆盖（首次 joined_ms 与首个 role 保留）。
pub fn member_upsert(
  store: Store,
  space: String,
  user: String,
  role: String,
) -> Result(Nil, String) {
  case store.ks_get(store, "members", member_key(space, user)) {
    Ok(option.Some(_)) -> Ok(Nil)
    Ok(option.None) ->
      store.ks_put(
        store,
        "members",
        member_key(space, user),
        json.object([
          #("role", json.string(role)),
          #("joined_ms", json.int(now_ms())),
        ])
        |> json.to_string,
      )
    Error(reason) -> Error(reason)
  }
}

/// 某空间全部成员：#(user, role)
pub fn member_list(
  store: Store,
  space: String,
) -> Result(List(#(String, String)), String) {
  case store.ks_list(store, "members", space <> ".") {
    Ok(items) ->
      items
      |> list.map(fn(item) {
        let #(key, value) = item
        let user = case string.split_once(key, space <> ".") {
          Ok(#(_, u)) -> u
          Error(Nil) -> key
        }
        #(user, json_to_string_field(value, "role"))
      })
      |> Ok
    Error(reason) -> Error(reason)
  }
}

pub fn perm_set(
  store: Store,
  space: String,
  user: String,
  role: String,
) -> Result(Nil, String) {
  store.ks_put(
    store,
    "perms",
    member_key(space, user),
    json.object([#("role", json.string(role))]) |> json.to_string,
  )
}

pub fn perm_get(
  store: Store,
  space: String,
  user: String,
) -> Result(Option(String), String) {
  case store.ks_get(store, "perms", member_key(space, user)) {
    Ok(option.Some(value)) -> Ok(option.Some(json_to_string_field(value, "role")))
    Ok(option.None) -> Ok(option.None)
    Error(reason) -> Error(reason)
  }
}

/// v0 权限模型：建频道需要 owner 或 admin。
pub fn can_create_channel(
  store: Store,
  space: String,
  user: String,
) -> Result(Bool, String) {
  case perm_get(store, space, user) {
    Ok(option.Some("owner")) -> Ok(True)
    Ok(option.Some("admin")) -> Ok(True)
    Ok(option.Some(_)) -> Ok(False)
    Ok(option.None) -> Ok(False)
    Error(reason) -> Error(reason)
  }
}

// ---------- 内部 ----------

fn json_to_string_field(value: String, field: String) -> String {
  case json.parse(from: value, using: decode_string_field(field)) {
    Ok(s) -> s
    Error(_) -> ""
  }
}

fn decode_string_field(field: String) -> decode.Decoder(String) {
  use s <- decode.field(field, decode.string)
  decode.success(s)
}

fn now_ms() -> Int {
  // 毫秒时间戳：跨 VM 无需唯一性，只是建档时间。
  // atom.create 对同一字符串是驻留复用（Erlang 原子按内容 intern），
  // 不会烧原子表——宪法禁的是"每次调用 new_name/unique 字符串"这类。
  os_system_time(atom.create("millisecond"))
}

@external(erlang, "os", "system_time")
fn os_system_time(unit: Atom) -> Int
