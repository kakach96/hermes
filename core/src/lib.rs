//! 赫尔墨斯 v0 —— 客户端唯一有逻辑的地方。
//!
//! 分层（对应 docs/STRUCTURE.md 的依赖边界）：
//! - `codec`：v0 JSON 信封（与 proto/hermes/v1 README 一一对应）
//! - `idempotency`：Bloom Filter 去重（QoS1 + 业务幂等的客户端半边）
//! - `transport`：WebSocket 客户端 + 会话状态机（游标在会话内推进）
//!
//! 边界纪律：crypto（M6）与本地 store 不出现在对外 API 签名里；
//! 密钥与明文永远不越过这条线。

pub mod codec;
pub mod crypto;
pub mod idempotency;
pub mod transport;

pub use codec::{ClientEvent, ClientFrame, ServerFrame};
pub use transport::{connect, Handle};
