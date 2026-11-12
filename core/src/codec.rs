//! v0 线上信封：JSON 编解码（serde），字段与 proto/hermes/v1 README 对齐。
//!
//! 客户端 → 服务端：join / msg / leave
//! 服务端 → 客户端：joined / chat / notice / error

use serde::{Deserialize, Serialize};

/// 服务端 → 客户端帧
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerFrame {
    Joined { members: Vec<String> },
    Chat { from: String, text: String, dedup_id: String, seq: u64 },
    Notice { text: String },
    Error { reason: String },
}

/// 客户端 → 服务端帧
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientFrame {
    Join { name: String, cursor: u64 },
    Msg { text: String, dedup_id: String },
    Leave,
}

impl ServerFrame {
    pub fn parse(json: &str) -> Option<ServerFrame> {
        serde_json::from_str(json).ok()
    }
}

impl ClientFrame {
    pub fn to_json(&self) -> String {
        serde_json::to_string(self).expect("client frame serialize")
    }
}

/// 渲染层消费的事件（WS 帧的投影；游标已由 transport 内部消化）
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientEvent {
    Joined { members: Vec<String> },
    Chat { from: String, text: String, dedup_id: String, seq: u64 },
    Notice { text: String },
    Error { reason: String },
    Disconnected,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn server_frame_roundtrip() {
        let json = r#"{"type":"chat","from":"Alice","text":"hi","dedup_id":"d1","seq":7}"#;
        let frame = ServerFrame::parse(json).expect("parse");
        match frame {
            ServerFrame::Chat { from, seq, .. } => {
                assert_eq!(from, "Alice");
                assert_eq!(seq, 7);
            }
            _ => panic!("wrong variant"),
        }
    }

    #[test]
    fn client_frame_field_names() {
        let json = ClientFrame::Join { name: "Bob".into(), cursor: 3 }.to_json();
        assert!(json.contains(r#""type":"join""#));
        assert!(json.contains(r#""cursor":3"#));

        let json = ClientFrame::Msg { text: "hi".into(), dedup_id: "d".into() }.to_json();
        assert!(json.contains(r#""type":"msg""#));
        assert!(json.contains(r#""dedup_id":"d""#));
    }
}
