//! WebSocket 传输 + 会话状态机。
//!
//! 职责：连接、收发帧、**游标推进**（收到的每条消息的 seq 单调推进）、
//! **去重**（Bloom 按收到的 dedup_id 判定；只在收到时登记，见下）、
//! **端到端加密编排**（M6）：入房后对名单成员懒建 Signal 会话，
//! 发送走"加密→enc 帧"，接收走"enc 帧→解密→还原成 Chat 事件"。
//!
//! 分层红利：UI 见到的 `ClientEvent` 形状与明文时代完全一致——
//! 加密是 transport 与 crypto 之间的事，视图层无感知。
//!
//! 去重细节：登记只发生在**收到**时。发送时登记会把自己的消息
//! 当重复丢掉。

use std::collections::{HashMap, HashSet};
use std::sync::mpsc as std_mpsc;

use futures_util::{SinkExt, StreamExt};
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;

use crate::codec::{ClientEvent, ClientFrame, ServerFrame};
use crate::crypto::{self, CryptoCmd, CryptoEvent};
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

/// 建立 WS 连接并起会话任务（内含 crypto 线程的编排逻辑）。
/// 事件经 mpsc 交给渲染层桥（如 Tauri emit）。
pub async fn connect(
    url: &str,
) -> Result<(Handle, mpsc::UnboundedReceiver<ClientEvent>), String> {
    let (ws, _resp) = tokio_tungstenite::connect_async(url)
        .await
        .map_err(|e| format!("连接失败: {e}"))?;

    // crypto 线程：明文/密文转换全部发生在那条线程里，密钥不出界
    let (crypto_tx, mut crypto_rx) = crypto::spawn();

    let (mut sink, mut stream) = ws.split();
    let (cmd_tx, mut cmd_rx) = mpsc::unbounded_channel::<ClientFrame>();
    let (ev_tx, ev_rx) = mpsc::unbounded_channel::<ClientEvent>();

    tokio::spawn(async move {
        // ---- 会话状态 ----
        let mut cursor: u64 = 0;
        let mut seen = Bloom::new(1 << 20);
        let mut joined = false;
        let mut me = String::new();
        let mut members: Vec<String> = Vec::new();
        let mut established: HashSet<String> = HashSet::new();
        // 已发出 prekey_fetch、尚无结果的成员（防止重复刷请求）
        let mut fetching: HashSet<String> = HashSet::new();
        // 懒建会话期间的待发队列：peer -> [(dedup_id, text)]
        let mut pending: HashMap<String, Vec<(String, String)>> = HashMap::new();

        loop {
            tokio::select! {
                // ---- 用户命令 ----
                cmd = cmd_rx.recv() => {
                    let Some(frame) = cmd else { break };
                    match frame {
                        ClientFrame::Leave => {
                            let _ = sink.send(Message::text(frame.to_json())).await;
                            let _ = ev_tx.send(ClientEvent::Disconnected);
                            break;
                        }
                        ClientFrame::Join { name, cursor: c } => {
                            // 先构造帧再移交 name，避免移动冲突
                            let join_frame = ClientFrame::Join { name: name.clone(), cursor: c }.to_json();
                            joined = true;
                            cursor = c;
                            me = name.clone();
                            // crypto 初始化：生成身份与 prekey 套件（带名字建地址）
                            let _ = crypto_tx.send(CryptoCmd::Init { name });
                            if sink.send(Message::text(join_frame)).await.is_err() {
                                let _ = ev_tx.send(ClientEvent::Disconnected);
                                break;
                            }
                        }
                        ClientFrame::Msg { text, dedup_id } => {
                            if !joined { continue; }
                            dispatch_outgoing(
                                &text, &dedup_id, &members, &mut established,
                                &mut fetching, &mut pending, &crypto_tx, &mut sink,
                            )
                            .await;
                        }
                        // 这两类只从内部事件路径产生，不该出现在用户命令里
                        other => {
                            let _ = sink.send(Message::text(other.to_json())).await;
                        }
                    }
                }

                // ---- crypto 线程回吐的事件 ----
                Some(ev) = crypto_rx.recv() => {
                    match ev {
                        CryptoEvent::Registered { bundle_json } => {
                            let _ = sink.send(Message::text(
                                ClientFrame::PrekeyRegister { bundle: bundle_json }.to_json(),
                            )).await;
                        }
                        CryptoEvent::Established { peer } => {
                            established.insert(peer.clone());
                            fetching.remove(&peer);
                            // 冲掉懒建期间排队的明文
                            if let Some(queue) = pending.remove(&peer) {
                                for (dedup_id, text) in queue {
                                    let _ = crypto_tx.send(CryptoCmd::Encrypt {
                                        peer: peer.clone(),
                                        dedup_id,
                                        plaintext: text.into_bytes(),
                                    });
                                }
                            }
                        }
                        CryptoEvent::Encrypted { peer, dedup_id, body_b64 } => {
                            let frame = ClientFrame::Enc {
                                to: peer,
                                body: body_b64,
                                dedup_id,
                            };
                            let _ = sink.send(Message::text(frame.to_json())).await;
                        }
                        CryptoEvent::Decrypted { peer, text } => {
                            let seq = cursor;
                            let _ = ev_tx.send(ClientEvent::Chat {
                                from: peer,
                                text,
                                dedup_id: String::new(),
                                seq,
                            });
                        }
                        CryptoEvent::Failed { context, detail } => {
                            let _ = ev_tx.send(ClientEvent::Notice {
                                text: format!("加密 {context}：{detail}"),
                            });
                        }
                    }
                }

                // ---- 服务端帧 ----
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
                        ServerFrame::Joined { members: list } => {
                            members = list.clone();
                            let _ = ev_tx.send(ClientEvent::Joined { members: list });
                            // 对名单里其他成员懒建加密会话；自己不 fetch——
                            // 自己的注册包此刻可能还没落账，必然撞空，留到首次发送时懒建
                            for peer in members.iter() {
                                if peer == &me { continue; }
                                if !established.contains(peer) && !fetching.contains(peer) {
                                    fetching.insert(peer.clone());
                                    let _ = sink.send(Message::text(
                                        ClientFrame::PrekeyFetch { for_name: peer.clone() }
                                            .to_json(),
                                    )).await;
                                }
                            }
                        }
                        ServerFrame::PrekeyBundle { for_name, bundle } => {
                            fetching.remove(&for_name);
                            if bundle.is_empty() {
                                // 保留待发队列：下次发送会重新 fetch（对方可能随后上线）
                                let _ = ev_tx.send(ClientEvent::Notice {
                                    text: format!("暂无法与 {for_name} 建立加密会话（对方不在线），消息已暂存"),
                                });
                            } else {
                                let _ = crypto_tx.send(CryptoCmd::Establish {
                                    peer: for_name,
                                    bundle_json: bundle,
                                });
                            }
                        }
                        ServerFrame::Chat { from, text, dedup_id, seq } => {
                            // 明文 legacy 路径（node e2e 等工具用）
                            if seen.maybe_contains(&dedup_id) {
                                continue;
                            }
                            seen.insert(&dedup_id);
                            if seq > cursor { cursor = seq; }
                            let _ = ev_tx.send(ClientEvent::Chat { from, text, dedup_id, seq });
                        }
                        ServerFrame::Enc { from, body, dedup_id: _, seq } => {
                            // 自己的消息也会被加密回声（自会话），统一解密路径
                            if seq > cursor { cursor = seq; }
                            let _ = crypto_tx.send(CryptoCmd::Decrypt {
                                peer: from.clone(),
                                body_b64: body,
                            });
                            let _ = from;
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

/// 一条待发消息 → 对名单里每个成员走"已建会话则加密 / 未建则排队并取注册包"
async fn dispatch_outgoing(
    text: &str,
    dedup_id: &str,
    members: &[String],
    established: &mut HashSet<String>,
    fetching: &mut HashSet<String>,
    pending: &mut HashMap<String, Vec<(String, String)>>,
    crypto_tx: &std_mpsc::Sender<CryptoCmd>,
    sink: &mut (impl SinkExt<Message> + Unpin),
) {
    for peer in members {
        let peer = peer.clone();
        if established.contains(&peer) {
            let _ = crypto_tx.send(CryptoCmd::Encrypt {
                peer,
                dedup_id: dedup_id.to_string(),
                plaintext: text.as_bytes().to_vec(),
            });
        } else {
            let queue = pending.entry(peer.clone()).or_default();
            queue.push((dedup_id.to_string(), text.to_string()));
            // 首次排队才发 fetch；fetch 已在途时不重复刷
            if !fetching.contains(&peer) {
                fetching.insert(peer.clone());
                let frame = ClientFrame::PrekeyFetch { for_name: peer }.to_json();
                let _ = sink.send(Message::text(frame)).await;
            }
        }
    }
}
