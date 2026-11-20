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

use crate::codec::{ClientEvent, ClientFrame, ServerFrame, DEFAULT_CHANNEL, DEFAULT_SPACE};
use crate::crypto::{self, CryptoCmd, CryptoEvent};
use crate::idempotency::Bloom;

/// 发送命令的句柄（Clone 安全）
#[derive(Clone)]
pub struct Handle {
    cmd_tx: mpsc::UnboundedSender<ClientFrame>,
}

impl Handle {
    /// 登录：确定身份（密钥/注册包随后就位），不进任何房间。
    pub fn login(&self, name: String) {
        let _ = self.cmd_tx.send(ClientFrame::Login { name });
    }

    /// 入房。space/channel 传空串则用 wire 缺省（lobby/general）。
    /// 须先 login（裸 WS 工具直接 join 时由 server 隐式登录兜底）。
    pub fn join(&self, name: String, cursor: u64, space: String, channel: String) {
        let space = if space.is_empty() { DEFAULT_SPACE.into() } else { space };
        let channel = if channel.is_empty() { DEFAULT_CHANNEL.into() } else { channel };
        let _ = self.cmd_tx.send(ClientFrame::Join { name, cursor, space, channel });
    }

    /// 离开房间，保持连接与登录态（回大厅）。
    pub fn leave_room(&self) {
        let _ = self.cmd_tx.send(ClientFrame::Leave);
    }

    /// 断开连接（退出登录）。
    pub fn logout(&self) {
        let _ = self.cmd_tx.send(ClientFrame::Logout);
    }

    /// 建空间（创建者 = owner）。需已登录（server 端校验）。
    pub fn create_space(&self, space: String) {
        let _ = self.cmd_tx.send(ClientFrame::SpaceCreate { space });
    }

    pub fn list_spaces(&self) {
        let _ = self.cmd_tx.send(ClientFrame::SpaceList);
    }

    /// 建频道（需空间 owner/admin —— server 端校验）。
    pub fn create_channel(&self, space: String, channel: String) {
        let _ = self.cmd_tx.send(ClientFrame::ChannelCreate { space, channel });
    }

    pub fn list_channels(&self, space: String) {
        let _ = self.cmd_tx.send(ClientFrame::ChannelList { space });
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
/// name：HTTP 平面（http::auth）认证过的身份；WS URL 已带 ?token=，
/// server 升级即登录。空串 = 未登录（裸工具 join 隐式登录兜底）。
/// password：登录密码——只用于派生静态加密 KEK（Argon2id），不落盘。
pub async fn connect(
    url: &str,
    keys_dir: &str,
    name: &str,
    password: &str,
) -> Result<(Handle, mpsc::UnboundedReceiver<ClientEvent>), String> {
    let (ws, _resp) = tokio_tungstenite::connect_async(url)
        .await
        .map_err(|e| format!("连接失败: {e}"))?;

    // crypto 线程：明文/密文转换全部发生在那条线程里，密钥不出界
    let (crypto_tx, mut crypto_rx) = crypto::spawn(keys_dir.to_string(), password.to_string());
    // HTTP 认证过的身份：立刻初始化密钥套件（Registered → 自动 prekey_register）
    let name = name.to_string();
    if !name.is_empty() {
        let _ = crypto_tx.send(CryptoCmd::Init { name: name.clone() });
    }

    let (mut sink, mut stream) = ws.split();
    let (cmd_tx, mut cmd_rx) = mpsc::unbounded_channel::<ClientFrame>();
    let (ev_tx, ev_rx) = mpsc::unbounded_channel::<ClientEvent>();

    tokio::spawn(async move {
        // ---- 会话状态 ----
        let mut cursor: u64 = 0;
        let mut seen = Bloom::new(1 << 20);
        let mut joined = false;
        let mut me = String::new();
        let mut crypto_inited = !name.is_empty();
        let mut members: Vec<String> = Vec::new();
        // 加密目标：空间持久成员（joined.targets），离线成员也在内
        let mut targets: Vec<String> = Vec::new();
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
                        // 真断开：不发帧，直接掉线（server 靠连接关闭清理）。
                        // 必须先推 Disconnected——loop break 是静默的，
                        // 否则 UI 永远停在当前视图（"退出登录没反应"的根因）
                        ClientFrame::Logout => {
                            let _ = ev_tx.send(ClientEvent::Disconnected);
                            break;
                        }
                        ClientFrame::Leave => {
                            // 离房不断连：回大厅，加密目标名单清空重建
                            if joined {
                                let _ = sink.send(Message::text(ClientFrame::Leave.to_json())).await;
                                joined = false;
                                members.clear();
                                targets.clear();
                                fetching.clear();
                                pending.clear();
                                let _ = ev_tx.send(ClientEvent::RoomLeft);
                            }
                        }
                        ClientFrame::Login { name } => {
                            me = name.clone();
                            if !crypto_inited {
                                crypto_inited = true;
                                // crypto 初始化：加载/生成本名身份与 prekey 套件
                                let _ = crypto_tx.send(CryptoCmd::Init { name });
                            }
                            if sink
                                .send(Message::text(ClientFrame::Login { name: me.clone() }.to_json()))
                                .await
                                .is_err()
                            {
                                let _ = ev_tx.send(ClientEvent::Disconnected);
                                break;
                            }
                        }
                        ClientFrame::Join { name, cursor: c, space, channel } => {
                            // GUI 已登录（URL 带 ?name=，me 由 join 帧补上）；
                            // 裸工具 join 即隐式登录。crypto 只允许初始化一次——
                            // 重复 Init 会重置 ratchet 会话（会话状态不持久化）
                            if me.is_empty() {
                                me = name.clone();
                            }
                            if !crypto_inited {
                                crypto_inited = true;
                                let _ = crypto_tx.send(CryptoCmd::Init { name: me.clone() });
                            }
                            let join_frame = ClientFrame::Join {
                                name: me.clone(),
                                cursor: c,
                                space,
                                channel,
                            }
                            .to_json();
                            joined = true;
                            cursor = c;
                            // 换房间：旧名单作废（joined 帧会重建）
                            members.clear();
                            fetching.clear();
                            pending.clear();
                            if sink.send(Message::text(join_frame)).await.is_err() {
                                let _ = ev_tx.send(ClientEvent::Disconnected);
                                break;
                            }
                        }
                        ClientFrame::Msg { text, dedup_id } => {
                            if !joined { continue; }
                            // 自己的消息本地即时回显（不经过加密自发自收——
                            // 自会话是 Signal 里最拧巴的路径，v0 直接绕开）
                            let _ = ev_tx.send(ClientEvent::Chat {
                                from: me.clone(),
                                text: text.clone(),
                                dedup_id: dedup_id.clone(),
                                seq: cursor,
                            });
                            dispatch_outgoing(
                                &text, &dedup_id, &targets, &me, &mut established,
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
                            // 码化（P0-3）：crypto 失败不再拼中文句子上 wire，
                            // UI 按 context 分类本地化
                            let _ = ev_tx.send(ClientEvent::Notice {
                                text: None,
                                code: Some("crypto.failed".into()),
                                name: Some(format!("{context}|{detail}")),
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
                            let _ = ev_tx.send(ClientEvent::Error {
                                reason: e.to_string(),
                                code: None,
                            });
                            let _ = ev_tx.send(ClientEvent::Disconnected);
                            break;
                        }
                    };
                    let Some(frame) = ServerFrame::parse(&text) else {
                        continue; // 坏帧丢弃
                    };
                    match frame {
                        ServerFrame::Joined { members: list, targets: t } => {
                            // 显示名单（presence）与加密目标（持久成员）分家：
                            // members 只管 UI 计数，targets 驱动加密分发与懒建
                            members = list.clone();
                            targets = t;
                            let _ = ev_tx.send(ClientEvent::Joined { members: list });
                            // 对目标名单里的成员懒建加密会话（含离线成员——
                            // 发送方要给不在场的人也留一份密文）；
                            // 自己不 fetch——自己的注册包此刻可能还没落账
                            for peer in targets.iter() {
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
                                // 离线成员：静默。pending 队列保留，对方上线后的
                                // 下一次发送重新 fetch → establish → 冲掉全部暂存。
                                // "暂存"是收件箱模型的默认行为，逐个提示只是噪音
                                //（在线状态展示留给房间成员列表，见 PLAN P1）
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
                        ServerFrame::Members { members: list } => {
                            // 名单活水：更新加密目标集合 + 推给视图层刷新实时人数
                            members = list.clone();
                            let _ = ev_tx.send(ClientEvent::MembersChanged {
                                members: list,
                            });
                        }
                        ServerFrame::LoggedIn { name } => {
                            let _ = ev_tx.send(ClientEvent::LoggedIn { name });
                        }
                        ServerFrame::Notice { text, code, name } => {
                            // 码化通知透传（UI 本地化）；老 text 帧原样
                            let _ = ev_tx.send(ClientEvent::Notice { text, code, name });
                        }
                        ServerFrame::Error { reason, code } => {
                            let _ = ev_tx.send(ClientEvent::Error { reason, code });
                        }
                        // ---- 空间/频道目录：直接投影给视图层 ----
                        ServerFrame::Spaces { spaces } => {
                            let _ = ev_tx.send(ClientEvent::SpaceList { spaces });
                        }
                        ServerFrame::SpaceCreated { name } => {
                            let _ = ev_tx.send(ClientEvent::SpaceCreated { name });
                        }
                        ServerFrame::Channels { space, channels } => {
                            let _ = ev_tx.send(ClientEvent::ChannelList { space, channels });
                        }
                        ServerFrame::ChannelCreated { space, name } => {
                            let _ = ev_tx.send(ClientEvent::ChannelCreated { space, name });
                        }
                    }
                }
            }
        }
    });

    Ok((Handle { cmd_tx }, ev_rx))
}

/// 一条待发消息 → 对**持久成员目标集**里每个成员走"已建会话则加密 / 未建则
/// 排队并取注册包"。离线成员也在目标集里——他们的那份密文先落流，
/// 上线后按游标补投（收件箱模型的 pairwise 实现）。
async fn dispatch_outgoing(
    text: &str,
    dedup_id: &str,
    targets: &[String],
    me: &str,
    established: &mut HashSet<String>,
    fetching: &mut HashSet<String>,
    pending: &mut HashMap<String, Vec<(String, String)>>,
    crypto_tx: &std_mpsc::Sender<CryptoCmd>,
    sink: &mut (impl SinkExt<Message> + Unpin),
) {
    for peer in targets {
        let peer = peer.clone();
        if peer == me {
            continue; // 自己的消息不走加密分发（本地已回显）
        }
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
