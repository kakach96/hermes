//// HTTP 平面 —— 认证与只读目录的 REST 端点。
////
//// mist 本身就是 HTTP 服务器（WS 升级跑在 HTTP 上），这里把非 WS 路径
//// 变成正式 API。与 WS 的分工：
////   HTTP：登录/注册（请求-响应语义天然贴合）+ 只读目录
////   WS：实时消息 + 会话态（?name= 查询参数即身份，升级即登录）
////
//// v0 无密码：名字 + 本地身份密钥即账号（宪法禁止自研加密，
//// 密码哈希/令牌留给真要多端同步时引入）。
////
//// 端点：
////   POST /v1/register {name} -> 201 {name} | 409 用户已存在
////   POST /v1/login    {name} -> 200 {name} | 401 用户不存在
////   GET  /v1/spaces          -> 200 [{name,owner}]
////   GET  /v1/spaces/:s/channels -> 200 {space, channels}

import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import mist

import hermes/meta
import hermes/store.{type Store}

/// WS 升级之外的所有路径都进这里。返回 None 表示未命中（调用方回 404）。
pub fn handle(
  req: Request(mist.Connection),
  storage: Store,
) -> Result(Response(mist.ResponseData), Nil) {
  case req.method, request.path_segments(req) {
    http.Post, ["v1", "register"] -> auth_endpoint(req, storage, True)
    http.Post, ["v1", "login"] -> auth_endpoint(req, storage, False)
    http.Get, ["v1", "spaces"] -> {
      let body = case meta.space_list(storage) {
        Ok(pairs) ->
          json.object([
            #(
              "spaces",
              json.array(pairs, fn(pair) {
                let #(name, owner) = pair
                json.object([
                  #("name", json.string(name)),
                  #("owner", json.string(owner)),
                ])
              }),
            ),
          ])
        Error(reason) -> error_body(reason)
      }
      Ok(ok_json(body))
    }
    http.Get, ["v1", "spaces", space, "channels"] -> {
      let body = case meta.channel_list(storage, space) {
        Ok(names) ->
          json.object([
            #("space", json.string(space)),
            #("channels", json.array(names, json.string)),
          ])
        Error(reason) -> error_body(reason)
      }
      Ok(ok_json(body))
    }
    _, _ -> Error(Nil)
  }
}

/// 登录/注册共用：解析 body {name}，按 register 开关分派语义。
fn auth_endpoint(
  req: Request(mist.Connection),
  storage: Store,
  register: Bool,
) -> Result(Response(mist.ResponseData), Nil) {
  case read_credentials(req) {
    Error(_) -> Ok(bad_request_code("bad_request", "body 不是合法 {name, password}"))
    Ok(#(name, password)) ->
      case meta.check_user(name) {
        Error(reason) -> Ok(bad_request_code("bad_name", reason))
        Ok(_) -> {
          let result = case register {
            // 注册：新建账号或认领无密码老账号（首次设密码）
            True -> meta.user_register(storage, name, password)
            // 登录：密码校验
            False -> meta.user_check_password(storage, name, password)
          }
          case result {
            Ok(Nil) ->
              // 成功 = 签发一次性 WS 令牌（HTTP 认证平面与 WS 身份的桥）
              case meta.issue_token(storage, name) {
                Ok(token) -> {
                  let status = case register {
                    True -> 201
                    False -> 200
                  }
                  Ok(
                    response.new(status)
                    |> response.set_header("content-type", "application/json")
                    |> response.set_body(
                      mist.Bytes(body_tree(
                        json.object([
                          #("name", json.string(name)),
                          #("token", json.string(token)),
                        ]),
                      )),
                    ),
                  )
                }
                Error(reason) -> Ok(json_error(500, reason))
              }
            Error(reason) -> {
              // 机器码 → 客户端本地化；人读文本兜底
              let #(status, code, text) = auth_error_parts(register, reason)
              Ok(json_code_error(status, code, text))
            }
          }
        }
      }
  }
}

/// 后端错误 → (HTTP 状态, 机器码, 人读文本)。
/// 机器码是 wire 契约（UI 按 code 本地化），文本只是调试兜底。
fn auth_error_parts(register: Bool, reason: String) -> #(Int, String, String) {
  case register {
    True ->
      case reason {
        "密码长度需在 8~128 位之间" -> #(400, "weak_password", reason)
        "用户已存在" <> _ -> #(409, "exists", reason)
        _ -> #(400, "register_failed", reason)
      }
    False ->
      case reason {
        "用户不存在" <> _ -> #(401, "not_found", reason)
        "NO_PASSWORD" -> #(401, "no_password", "该账号未设密码")
        "BAD_PASSWORD" -> #(401, "bad_password", "密码错误")
        _ -> #(401, "login_failed", reason)
      }
  }
}

// ---------- 内部 ----------

fn read_credentials(req: Request(mist.Connection)) -> Result(#(String, String), Nil) {
  case mist.read_body(req, 64_000) {
    Error(_) -> Error(Nil)
    Ok(req2) ->
      case bit_array.to_string(req2.body) {
        Error(Nil) -> Error(Nil)
        Ok(text) ->
          case json.parse(from: text, using: credentials_decoder()) {
            Ok(pair) -> Ok(pair)
            Error(_) -> Error(Nil)
          }
      }
  }
}

fn credentials_decoder() -> decode.Decoder(#(String, String)) {
  use name <- decode.field("name", decode.string)
  use password <- decode.field("password", decode.string)
  decode.success(#(name, password))
}

fn body_tree(j: json.Json) -> bytes_tree.BytesTree {
  json.to_string(j) |> bytes_tree.from_string
}

fn ok_json(j: json.Json) -> Response(mist.ResponseData) {
  response.new(200)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(body_tree(j)))
}

fn json_error(status: Int, reason: String) -> Response(mist.ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(body_tree(error_body(reason))))
}

/// auth 契约错误体：{code（机器码，UI 本地化）, error（人读兜底）}
fn json_code_error(status: Int, code: String, text: String) -> Response(mist.ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(
    mist.Bytes(body_tree(json.object([
      #("code", json.string(code)),
      #("error", json.string(text)),
    ]))),
  )
}

fn bad_request_code(code: String, text: String) -> Response(mist.ResponseData) {
  json_code_error(400, code, text)
}

fn error_body(reason: String) -> json.Json {
  json.object([#("error", json.string(reason))])
}

/// 供 ws.gleam 的 404 兜底复用
pub fn not_found() -> Response(mist.ResponseData) {
  response.new(404)
  |> response.set_header("content-type", "text/plain")
  |> response.set_body(mist.Bytes(bytes_tree.from_string("not found")))
}
