//! 认证平面 —— HTTP 客户端（/v1/login | /v1/register）。
//!
//! 与 WS 的分工：登录/注册（含密码）是请求-响应语义，HTTP 天然贴合；
//! 实时消息仍走 WS。认证成功返回带 `?token=` 的 WS 地址——
//! token 是服务端签发的一次性令牌（256-bit CSPRNG），WS 升级时消费，
//! 会话身份由它建立（?name= 直连是 e2e 裸工具的 dev-only 路径）。
//!
//! 错误是稳定码（auth:*）：服务端 HTTP 体带机器 code，本模块透传给
//! UI 层本地化。PBKDF2 等密码学全部在服务端，客户端只搬运。

use serde::{Deserialize, Serialize};

/// 认证结果：WS 地址已带一次性令牌（?token=）
#[derive(Debug, Clone)]
pub struct Auth {
    pub name: String,
    pub ws_url: String,
}

#[derive(Serialize)]
struct AuthBody<'a> {
    name: &'a str,
    password: &'a str,
}

#[derive(Deserialize)]
struct AuthOk {
    #[allow(dead_code)]
    name: String,
    token: String,
}

/// 登录（register=false）或注册（register=true）。
/// base 形如 "http://127.0.0.1:8080"。
pub async fn auth(
    base: &str,
    name: &str,
    password: &str,
    register: bool,
) -> Result<Auth, String> {
    let base = base.trim_end_matches('/');
    let path = if register { "/v1/register" } else { "/v1/login" };
    let url = format!("{base}{path}");

    let client = reqwest::Client::new();
    let resp = client
        .post(&url)
        .json(&AuthBody { name, password })
        .send()
        .await
        .map_err(|e| format!("auth:net: {e}"))?;

    let status = resp.status().as_u16();
    if (200..300).contains(&status) {
        // 2xx：拿一次性令牌，拼 WS 地址
        let ok: AuthOk = resp
            .json()
            .await
            .map_err(|e| format!("auth:net: bad response: {e}"))?;
        return Ok(Auth {
            name: name.to_string(),
            ws_url: build_ws_url(base, &ok.token),
        });
    }

    // 错误体 {code, error}：机器码优先，没码就带状态码
    let body = resp.text().await.unwrap_or_default();
    let code = extract_code(&body);
    match code {
        Some(code) => Err(format!("auth:{code}")),
        None => Err(format!("auth:status{status}: {body}")),
    }
}

/// 从错误体里抽 "code" 字段（服务端 auth 契约错误都带机器码）
fn extract_code(body: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_str(body).ok()?;
    v.get("code")?.as_str().map(|s| s.to_string())
}

/// 认证通过后的 WS 地址：base 的 authority + /ws + ?token=（hex 无需编码）
fn build_ws_url(base: &str, token: &str) -> String {
    let (host, port) = authority_of(base);
    format!("ws://{host}:{port}/ws?token={token}")
}

/// base → (host, port)。"http://127.0.0.1:8080" → ("127.0.0.1", 8080)。
/// authority 里没写端口时用协议缺省（http=80）。
fn authority_of(base: &str) -> (String, u16) {
    let rest = base
        .strip_prefix("http://")
        .or_else(|| base.strip_prefix("https://"))
        .unwrap_or(base);
    let end = rest.find('/').unwrap_or(rest.len());
    let authority = &rest[..end];
    match authority.rsplit_once(':') {
        Some((host, p)) => (host.to_string(), p.parse().unwrap_or(80)),
        None => (authority.to_string(), 80),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn authority_parsing() {
        assert_eq!(
            authority_of("http://127.0.0.1:8080"),
            ("127.0.0.1".into(), 8080)
        );
        assert_eq!(authority_of("http://localhost"), ("localhost".into(), 80));
        assert_eq!(authority_of("http://example.com/sub"), ("example.com".into(), 80));
    }

    #[test]
    fn auth_builds_ws_url_with_token() {
        assert_eq!(
            build_ws_url("http://127.0.0.1:8080", "deadbeef"),
            "ws://127.0.0.1:8080/ws?token=deadbeef"
        );
    }

    #[test]
    fn error_code_extraction() {
        assert_eq!(
            extract_code(r#"{"code":"bad_password","error":"密码错误"}"#),
            Some("bad_password".into())
        );
        assert_eq!(extract_code("not json"), None);
        assert_eq!(extract_code(r#"{"error":"x"}"#), None);
    }
}
