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
        .map_err(|e| format!("HTTP 请求失败: {e}"))?;

    let status = resp.status().as_u16();
    if status == 409 {
        return Err("用户已存在，请改用「登录」".into());
    }
    if status == 401 {
        return Err("用户不存在，请先「注册」".into());
    }
    if !(200..300).contains(&status) {
        let body = resp.text().await.unwrap_or_default();
        return Err(format!("HTTP {status}: {body}"));
    }

    // 2xx：名字落账（HTTP 语义层），WS 地址带上身份
    let ws_url = format!(
        "{}://{}:{}/ws?name={}",
        ws_scheme(base),
        host_of(base),
        port_of(base, 80),
        urlencode(name),
    );
    Ok(Auth {
        name: name.to_string(),
        ws_url,
    })
}

fn ws_scheme(base: &str) -> &str {
    // v0 端点都是 http://，直接映射
    "ws"
}

fn host_of(base: &str) -> &str {
    let rest = base
        .strip_prefix("http://")
        .or_else(|| base.strip_prefix("https://"))
        .unwrap_or(base);
    // 去掉可能的路径尾巴
    let end = rest.find('/').unwrap_or(rest.len());
    &rest[..end]
}

fn port_of(base: &str, default: u16) -> u16 {
    let host = host_of(base);
    match host.rsplit_once(':') {
        Some((_, p)) => p.parse().unwrap_or(default),
        None => default,
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
    fn host_and_port_parsing() {
        assert_eq!(host_of("http://127.0.0.1:8080"), "127.0.0.1:8080");
        assert_eq!(port_of("http://127.0.0.1:8080", 80), 8080);
        assert_eq!(port_of("http://localhost", 80), 80);
        assert_eq!(host_of("http://example.com/sub"), "example.com");
    }
}
