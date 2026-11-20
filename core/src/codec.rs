//! v0 线上信封：JSON 编解码（serde），字段与 proto/hermes/v1 README 对齐。
//!
//! 客户端 → 服务端：join / msg / leave / prekey / enc
//!              + 空间/频道管理（M7）：space_create / space_list /
//!                channel_create / channel_list
//! 服务端 → 客户端：joined / chat / enc / notice / members / error
//!              + spaces / space_created / channels / channel_created

use serde::{Deserialize, Serialize};

/// 空间条目（space_list 的元素）
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct SpaceEntry {
    pub name: String,
    pub owner: String,
}

/// 服务端 → 客户端帧
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerFrame {
    /// 入房回执：members = 当前在线（presence 显示）；targets = 空间持久成员
    /// （加密分发目标——离线成员也永远有一份密文留在流里，重进按游标补投）
    Joined { members: Vec<String>, targets: Vec<String> },
    Chat { from: String, text: String, dedup_id: String, seq: u64 },
    /// 发给本人的端到端密文（server 已按 to 过滤；base64 密文）
    Enc { from: String, body: String, dedup_id: String, seq: u64 },
    Notice { text: String },
    Error { reason: String },
    /// 成员名单快照（presence 通道广播，加入/退房时更新）
    Members { members: Vec<String> },
    /// prekey_fetch 的回执；bundle 为空 = 对方无登记（不在线）
    PrekeyBundle {
        #[serde(rename = "for")]
        for_name: String,
        bundle: String,
    },
    /// 登录回执（大厅页的入场券）
    LoggedIn { name: String },
    /// 空间列表（name/owner 对）
    Spaces { spaces: Vec<SpaceEntry> },
    SpaceCreated { name: String },
    /// 某空间的频道列表
    Channels { space: String, channels: Vec<String> },
    ChannelCreated { space: String, name: String },
}

/// 客户端 → 服务端帧
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientFrame {
    /// 登录：只确定身份（user_touch），不入房。大厅页的目录/建频道靠它放行
    Login { name: String },
    /// space/channel 为空时 transport 填 wire 缺省（lobby/general）；
    /// node e2e 工具不发 login 直接 join 时由 server 隐式登录兜底
    Join { name: String, cursor: u64, space: String, channel: String },
    Msg { text: String, dedup_id: String },
    /// 离开房间但保持连接（回大厅页）；Logout 才是真断开
    Leave,
    /// 本地命令：关掉 WS（不发帧，server 靠连接关闭清理）
    Logout,
    /// 登记 Signal 注册包（JSON 字符串，server 不透明存储）
    PrekeyRegister { bundle: String },
    /// 取某人的注册包（wire 字段名是 "for"，serde 需显式改名）
    PrekeyFetch {
        #[serde(rename = "for")]
        for_name: String,
    },
    /// 端到端密文（发给某成员）
    Enc { to: String, body: String, dedup_id: String },
    SpaceCreate { space: String },
    SpaceList,
    ChannelCreate { space: String, channel: String },
    ChannelList { space: String },
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
    /// 登录成功（大厅页入场）
    LoggedIn { name: String },
    /// 已离开房间（保持连接）——视图层回大厅
    RoomLeft,
    /// 在线名单变化（presence 快照活水）——视图层用它刷新实时人数
    MembersChanged { members: Vec<String> },
    /// 空间/频道目录（视图层管展示，core 不缓存）
    SpaceList { spaces: Vec<SpaceEntry> },
    SpaceCreated { name: String },
    ChannelList { space: String, channels: Vec<String> },
    ChannelCreated { space: String, name: String },
}

/// wire 缺省：join 不带 space/channel 时落点（server 端同样有缺省）
pub const DEFAULT_SPACE: &str = "lobby";
pub const DEFAULT_CHANNEL: &str = "general";

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
        let json = ClientFrame::Join {
            name: "Bob".into(),
            cursor: 3,
            space: "lobby".into(),
            channel: "general".into(),
        }
        .to_json();
        assert!(json.contains(r#""type":"join""#));
        assert!(json.contains(r#""cursor":3"#));
        assert!(json.contains(r#""space":"lobby""#));

        let json = ClientFrame::Msg { text: "hi".into(), dedup_id: "d".into() }.to_json();
        assert!(json.contains(r#""type":"msg""#));
        assert!(json.contains(r#""dedup_id":"d""#));
    }

    #[test]
    fn joined_frame_carries_targets() {
        let json = r#"{"type":"joined","members":["Alice"],"targets":["Alice","Bob"]}"#;
        let frame = ServerFrame::parse(json).expect("parse");
        match frame {
            ServerFrame::Joined { members, targets } => {
                assert_eq!(members, vec!["Alice".to_string()]);
                assert_eq!(targets, vec!["Alice".to_string(), "Bob".to_string()]);
            }
            _ => panic!("wrong variant"),
        }
    }
    #[test]
    fn spaces_frame_roundtrip() {
        let json = r#"{"type":"spaces","spaces":[{"name":"lobby","owner":"a"},{"name":"dev","owner":"b"}]}"#;
        let frame = ServerFrame::parse(json).expect("parse");
        match frame {
            ServerFrame::Spaces { spaces } => {
                assert_eq!(spaces.len(), 2);
                assert_eq!(spaces[1].owner, "b");
            }
            _ => panic!("wrong variant"),
        }
    }

    #[test]
    fn space_mgmt_frames() {
        let json = ClientFrame::ChannelCreate { space: "lobby".into(), channel: "random".into() }.to_json();
        assert!(json.contains(r#""type":"channel_create""#));

        let frame = ServerFrame::parse(r#"{"type":"channel_created","space":"lobby","name":"random"}"#)
            .expect("parse");
        match frame {
            ServerFrame::ChannelCreated { space, name } => {
                assert_eq!(space, "lobby");
                assert_eq!(name, "random");
            }
            _ => panic!("wrong variant"),
        }
    }
}
