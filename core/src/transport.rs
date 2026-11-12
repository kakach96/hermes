//! WebSocket 传输 + 会话状态机。
//!
//! 职责：连接、收发帧、**游标推进**（收到的每条 chat 的 seq 单调推进）、
//! **去重**（Bloom 按收到的 dedup_id 判定；只在收到时登记，
//! 发送时绝不登记 —— 否则会把自己的消息当重复丢掉）。
//! 游标的持久化语义见 proto/hermes/v1/README：重连时由调用方带
//! "最后收到的 seq"，服务端从 seq+1 补投。

use futures_util::{SinkExt, StreamExt};
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;

use crate::codec::{ClientEvent, ClientFrame, ServerFrame};
use crate::idempotency::Bloom;

/// 发送命令的句柄（Clone 安全）
#[derive(Clone)]
pub struct Handle {
    cmd_tx: mpsc::UnboundedSender<ClientFrame>,
}

impl Handle {
    pub fn join(&self, name: String, cursor: u64) {
        let _ = self.cmd_tx.send(ClientFrame::Join { name, cursor });
    }

    pub fn send_text(&self, text: String) {
        let dedup_id = uuid::Uuid::new_v4().to_string();
        let _ = self.cmd_tx.send(ClientFrame::Msg { text, dedup_id });
    }

    pub fn leave(&self) {
        let _ = self.cmd_tx.send(ClientFrame::Leave);
    }
}

/// 建立 WS 连接并起会话任务。事件经 mpsc 交给渲染层桥（如 Tauri emit）。
pub async fn connect(
    url: &str,
) -> Result<(Handle, mpsc::UnboundedReceiver<ClientEvent>), String> {
    let (ws, _resp) = tokio_tungstenite::connect_async(url)
        .await
        .map_err(|e| format!("连接失败: {e}"))?;

    let (mut sink, mut stream) = ws.split();
    let (cmd_tx, mut cmd_rx) = mpsc::unbounded_channel::<ClientFrame>();
    let (ev_tx, ev_rx) = mpsc::unbounded_channel::<ClientEvent>();

    tokio::spawn(async move {
        // 会话状态：游标 + 去重过滤器（1Mbit ≈ 128KB）
        let mut cursor: u64 = 0;
        let mut seen = Bloom::new(1 << 20);
        let mut joined = false;

        loop {
            tokio::select! {
                cmd = cmd_rx.recv() => {
                    let Some(frame) = cmd else { break };
                    if matches!(frame, ClientFrame::Leave) {
                        let _ = sink.send(Message::text(frame.to_json())).await;
                        let _ = ev_tx.send(ClientEvent::Disconnected);
                        break;
                    }
                    // 未入房时自动 join（首次连接即入房）
                    if !joined {
                        if let ClientFrame::Msg { text, dedup_id } = &frame {
                            // 迟到的发送在 join 完成前不会发生（UI 顺序保证）；
                            // 保险起见丢弃而不是乱序
                            let _ = (text, dedup_id);
                            continue;
                        }
                        joined = true;
                    }
                    if sink.send(Message::text(frame.to_json())).await.is_err() {
                        let _ = ev_tx.send(ClientEvent::Disconnected);
                        break;
                    }
                }
                msg = stream.next() => {
                    let Some(msg) = msg else {
                        let _ = ev_tx.send(ClientEvent::Disconnected);
                        break;
                    };
                    let text = match msg {
                        Ok(Message::Text(t)) => t.to_string(),
                        Ok(_) => continue,
                        Err(e) => {
                            let _ = ev_tx.send(ClientEvent::Error { reason: e.to_string() });
                            let _ = ev_tx.send(ClientEvent::Disconnected);
                            break;
                        }
                    };
                    let Some(frame) = ServerFrame::parse(&text) else {
                        continue; // 坏帧丢弃
                    };
                    match frame {
                        ServerFrame::Joined { members } => {
                            let _ = ev_tx.send(ClientEvent::Joined { members });
                        }
                        ServerFrame::Chat { from, text, dedup_id, seq } => {
                            // 幂等：重复投递按 dedup_id 丢弃；
                            // 登记只发生在收到时（见模块注释）
                            if seen.maybe_contains(&dedup_id) {
                                continue;
                            }
                            seen.insert(&dedup_id);
                            if seq > cursor {
                                cursor = seq;
                            }
                            let _ = ev_tx.send(ClientEvent::Chat { from, text, dedup_id, seq });
                        }
                        ServerFrame::Notice { text } => {
                            let _ = ev_tx.send(ClientEvent::Notice { text });
                        }
                        ServerFrame::Error { reason } => {
                            let _ = ev_tx.send(ClientEvent::Error { reason });
                        }
                    }
                }
            }
        }
    });

    Ok((Handle { cmd_tx }, ev_rx))
}
