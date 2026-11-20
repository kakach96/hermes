//! 认证平面 —— HTTP 客户端（/v1/login | /v1/register）。
//!
//! 与 WS 的分工：登录/注册是请求-响应语义，HTTP 天然贴合；
//! 实时消息仍走 WS。认证成功后返回带 `?name=` 的 WS 地址，
//! server 升级时按查询参数建立会话身份（升级即登录）。
//!
//! v0 无密码：名字即账号（服务端 users 建档 + 客户端本地身份密钥）。
//! 密码/令牌留给真要多端同步时引入。

use serde::Serialize;

/// 认证结果：WS 地址已带身份（?name=，percent-encoded）
#[derive(Debug, Clone)]
pub struct Auth {
    pub name: String,
    pub ws_url: String,
}

#[derive(Serialize)]
struct AuthBody<'a> {
    name: &'a str,
}

/// 登录（register=false）或注册（register=true）。
/// base 形如 "http://127.0.0.1:8080"。
pub async fn auth(base: &str, name: &str, register: bool) -> Result<Auth, String> {
    let base = base.trim_end_matches('/');
    let path = if register { "/v1/register" } else { "/v1/login" };
    let url = format!("{base}{path}");

    let client = reqwest::Client::new();
    let resp = client
        .post(&url)
        .json(&AuthBody { name })
        .send()
        .await
        .map_err(|e| format!("auth:net: {e}"))?;

    let status = resp.status().as_u16();
    if status == 409 {
        // 稳定码：UI 层本地化（auth:exists / auth:not_found），核心不掺语言
        return Err("auth:exists".into());
    }
    if status == 401 {
        return Err("auth:not_found".into());
    }
    if !(200..300).contains(&status) {
        let body = resp.text().await.unwrap_or_default();
        return Err(format!("auth:status{status}: {body}"));
    }

    // 2xx：名字落账（HTTP 语义层），WS 地址带上身份
    let ws_url = build_ws_url(base, name);
    Ok(Auth {
        name: name.to_string(),
        ws_url,
    })
}

/// 认证通过后的 WS 地址：base 的 authority + /ws + ?name=（encoded）。
/// 回归注释：曾把 authority（含端口）又拼一遍端口 → ws://host:8080:8080/ws
/// → tungstenite "invalid authority"。
fn build_ws_url(base: &str, name: &str) -> String {
    let (host, port) = authority_of(base);
    format!("ws://{host}:{port}/ws?name={}", urlencode(name))
}

/// base → (host, port)。"http://127.0.0.1:8080" → ("127.0.0.1", 8080)。
/// authority 里没写端口时用协议缺省（http=80）。
fn authority_of(base: &str) -> (String, u16) {
    let rest = base
        .strip_prefix("http://")
        .or_else(|| base.strip_prefix("https://"))
        .unwrap_or(base);
    // 去掉可能的路径尾巴
    let end = rest.find('/').unwrap_or(rest.len());
    let authority = &rest[..end];
    match authority.rsplit_once(':') {
        Some((host, p)) => (host.to_string(), p.parse().unwrap_or(80)),
        None => (authority.to_string(), 80),
    }
}

/// query 值的 percent-encoding（UTF-8；保留 RFC3986 unreserved 字符）
fn urlencode(s: &str) -> String {
    let mut out = String::new();
    for b in s.as_bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn urlencode_keeps_unreserved() {
        assert_eq!(urlencode("kakach"), "kakach");
        assert_eq!(urlencode("a-b_c.d~e"), "a-b_c.d~e");
    }

    #[test]
    fn urlencode_escapes_rest() {
        assert_eq!(urlencode("小 新"), "%E5%B0%8F%20%E6%96%B0");
        assert_eq!(urlencode("a&b=c"), "a%26b%3Dc");
    }

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
    fn auth_builds_ws_url_without_double_port() {
        // 回归：曾把 authority（含端口）又拼一遍端口 → invalid authority
        assert_eq!(
            build_ws_url("http://127.0.0.1:8080", "kakach"),
            "ws://127.0.0.1:8080/ws?name=kakach"
        );
        assert_eq!(
            build_ws_url("http://127.0.0.1:8080/", "小 新"),
            "ws://127.0.0.1:8080/ws?name=%E5%B0%8F%20%E6%96%B0"
        );
    }
}
