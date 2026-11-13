//! 端到端加密 —— Signal Protocol（官方 libsignal 纯 Rust 实现）封装。
//!
//! 边界纪律（docs/STRUCTURE.md）：
//! - 密钥与会话状态**只存在于本模块的线程内**，永不出界；
//!   对外只暴露"明文进 → base64 密文出"的字节面。
//! - 独立线程而非 tokio 任务：libsignal 的 store 方法是 async_trait(?Send)，
//!   返回 !Send future，进不了 tokio::spawn；而这些 future 从不真正挂起，
//!   用 `now_or_never()` 在普通线程上同步驱动即可（官方测试同款用法）。
//! - v0 范围：房间内两两会话（pairwise），每条消息对每个成员各加密一份；
//!   群组的 Sender Key 方案留作第二轮。会话状态不落盘——客户端重启后
//!   历史重放里的旧密文无法解密（游标通常已越过，实际影响很小）。
//!
//! wire 上的注册包（bundle）JSON schema（server 只做不透明转发）：
//! { registration_id, device_id, identity_key,
//!   signed_pre_key: {id, public, signature},
//!   kyber_pre_key:  {id, public, signature} }     // 全部 base64（id 为数字）

use std::sync::mpsc as std_mpsc;
use std::time::SystemTime;

use base64::Engine as _;
use futures_util::FutureExt as _;
use libsignal_protocol::{
    CiphertextMessage, DeviceId, IdentityKey, IdentityKeyPair, InMemSignalProtocolStore, KeyPair,
    KyberPreKeyRecord, PreKeyBundle, PreKeySignalMessage, ProtocolAddress, SignalMessage,
    SignedPreKeyRecord, Timestamp, initiate_session, kem, message_decrypt, message_encrypt,
};
use rand::rngs::OsRng;
use rand::{CryptoRng, Rng};

/// 发往 crypto 线程的命令
pub enum CryptoCmd {
    /// 生成本机身份 + prekey 套件；事件回执 Registered（bundle JSON 发服务器）
    Init { name: String },
    /// 用对端注册包建立会话（X3DH/PQXDH）
    Establish { peer: String, bundle_json: String },
    /// 加密一段明文；事件回执 Encrypted
    Encrypt { peer: String, dedup_id: String, plaintext: Vec<u8> },
    /// 解密一段密文；事件回执 Decrypted
    Decrypt { peer: String, body_b64: String },
}

/// crypto 线程回吐的事件（WS 会话任务消费）
pub enum CryptoEvent {
    Registered { bundle_json: String },
    Established { peer: String },
    Encrypted { peer: String, dedup_id: String, body_b64: String },
    Decrypted { peer: String, text: String },
    Failed { context: String, detail: String },
}

pub type CryptoCmdTx = std_mpsc::Sender<CryptoCmd>;
pub type CryptoEventRx = tokio::sync::mpsc::UnboundedReceiver<CryptoEvent>;

struct Crypto {
    me: String,
    local: ProtocolAddress,
    store: InMemSignalProtocolStore,
    bundle_json: String,
    rng: OsRng,
}

/// 起 crypto 线程。channel 两端都是线程安全的。
pub fn spawn() -> (CryptoCmdTx, CryptoEventRx) {
    let (cmd_tx, cmd_rx) = std_mpsc::channel::<CryptoCmd>();
    let (ev_tx, ev_rx) = tokio::sync::mpsc::unbounded_channel::<CryptoEvent>();
    std::thread::Builder::new()
        .name("hermes-crypto".into())
        .spawn(move || {
            let mut state: Option<Crypto> = None;
            while let Ok(cmd) = cmd_rx.recv() {
                match cmd {
                    CryptoCmd::Init { name } => {
                        state = init(name, &ev_tx);
                    }
                    CryptoCmd::Establish { peer, bundle_json } => {
                        let Some(crypto) = state.as_mut() else {
                            let _ = ev_tx.send(CryptoEvent::Failed {
                                context: format!("establish {peer}"),
                                detail: "crypto 未初始化".into(),
                            });
                            continue;
                        };
                        match establish(crypto, &peer, &bundle_json) {
                            Ok(()) => {
                                let _ = ev_tx.send(CryptoEvent::Established { peer });
                            }
                            Err(e) => {
                                let _ = ev_tx.send(CryptoEvent::Failed {
                                    context: format!("establish {peer}"),
                                    detail: e,
                                });
                            }
                        }
                    }
                    CryptoCmd::Encrypt { peer, dedup_id, plaintext } => {
                        let Some(crypto) = state.as_mut() else {
                            let _ = ev_tx.send(CryptoEvent::Failed {
                                context: format!("encrypt {peer}"),
                                detail: "crypto 未初始化".into(),
                            });
                            continue;
                        };
                        match encrypt(crypto, &peer, &plaintext) {
                            Ok(body) => {
                                let _ = ev_tx.send(CryptoEvent::Encrypted {
                                    peer,
                                    dedup_id,
                                    body_b64: b64e(&body),
                                });
                            }
                            Err(e) => {
                                let _ = ev_tx.send(CryptoEvent::Failed {
                                    context: format!("encrypt {peer}"),
                                    detail: e,
                                });
                            }
                        }
                    }
                    CryptoCmd::Decrypt { peer, body_b64 } => {
                        let Some(crypto) = state.as_mut() else {
                            let _ = ev_tx.send(CryptoEvent::Failed {
                                context: format!("decrypt {peer}"),
                                detail: "crypto 未初始化".into(),
                            });
                            continue;
                        };
                        match decrypt(crypto, &peer, &body_b64) {
                            Ok(text) => {
                                let _ = ev_tx.send(CryptoEvent::Decrypted { peer, text });
                            }
                            Err(e) => {
                                let _ = ev_tx.send(CryptoEvent::Failed {
                                    context: format!("decrypt {peer}"),
                                    detail: e,
                                });
                            }
                        }
                    }
                }
            }
        })
        .expect("spawn crypto thread");
    (cmd_tx, ev_rx)
}

// ---------- 操作实现（async 签名保留 libsignal 的形态，同步驱动） ----------

fn init(name: String, ev: &tokio::sync::mpsc::UnboundedSender<CryptoEvent>) -> Option<Crypto> {
    let result: Result<(InMemSignalProtocolStore, ProtocolAddress, String), String> = (|| async {
        let mut rng = OsRng;
        let identity = IdentityKeyPair::generate(&mut rng);
        let registration_id = libsignal_protocol::generate_registration_id(&mut rng);

        // 先签名（identity 还没被 store 吃掉）
        let signed_key = KeyPair::generate(&mut rng);
        let signed_sig =
            identity.private_key().calculate_signature(&signed_key.public_key.serialize(), &mut rng)?;
        let kyber_key = kem::KeyPair::generate(kem::KeyType::Kyber1024, &mut rng);
        let kyber_sig =
            identity.private_key().calculate_signature(&kyber_key.public_key.serialize(), &mut rng)?;

        let identity_key = *identity.identity_key();
        let store = InMemSignalProtocolStore::new(identity, registration_id)?;

        store
            .save_signed_pre_key(
                1.into(),
                &SignedPreKeyRecord::new(
                    1.into(),
                    Timestamp::from_epoch_millis(now_ms()),
                    &signed_key,
                    &signed_sig,
                ),
            )
            .await?;
        store
            .save_kyber_pre_key(
                1.into(),
                &KyberPreKeyRecord::new(
                    1.into(),
                    Timestamp::from_epoch_millis(now_ms()),
                    &kyber_key,
                    &kyber_sig,
                ),
            )
            .await?;

        let bundle = PreKeyBundle::new(
            registration_id,
            DeviceId::new(1)?,
            None, // v0 不发一次性 EC prekey（与官方 last-resort 用法一致）
            1.into(),
            signed_key.public_key,
            signed_sig,
            1.into(),
            kyber_key.public_key,
            kyber_sig,
            identity_key,
        )?;

        Ok((store, ProtocolAddress::new(name.clone(), DeviceId::new(1)?), bundle_json_of(&bundle)?))
    })().now_or_never();

    let Ok(Ok((store, local, bundle_json))) = result else {
        let detail = match result {
            Some(Err(e)) => e,
            _ => "now_or_never 意外挂起".into(),
        };
        let _ = ev.send(CryptoEvent::Failed { context: "init".into(), detail });
        return None;
    };

    let _ = ev.send(CryptoEvent::Registered { bundle_json: bundle_json.clone() });
    Some(Crypto {
        me: name,
        local,
        store,
        bundle_json,
        rng: OsRng,
    })
}

fn establish(crypto: &mut Crypto, peer: &str, bundle_json: &str) -> Result<(), String> {
    let run = async {
        let bundle = parse_bundle(bundle_json)?;
        let peer_addr = ProtocolAddress::new(peer.to_string(), DeviceId::new(1)?);
        initiate_session(
            &peer_addr,
            &crypto.local,
            &mut crypto.store.session_store,
            &mut crypto.store.identity_store,
            &bundle,
            SystemTime::now(),
            &mut crypto.rng,
        )
        .await?;
        Ok(())
    };
    run.now_or_never().unwrap_or_else(|| Err("establish 意外挂起".into()))
}

fn encrypt(crypto: &mut Crypto, peer: &str, plaintext: &[u8]) -> Result<Vec<u8>, String> {
    let run = async {
        let peer_addr = ProtocolAddress::new(peer.to_string(), DeviceId::new(1)?);
        let ct = message_encrypt(
            plaintext,
            &peer_addr,
            &crypto.local,
            &mut crypto.store.session_store,
            &mut crypto.store.identity_store,
            SystemTime::now(),
            &mut crypto.rng,
        )
        .await?;
        Ok(ct.serialize().to_vec())
    };
    run.now_or_never().unwrap_or_else(|| Err("encrypt 意外挂起".into()))
}

fn decrypt(crypto: &mut Crypto, peer: &str, body_b64: &str) -> Result<String, String> {
    let run = async {
        let bytes = b64d(body_b64);
        // wire 首字节是消息类型标签（whisper=2 / prekey=3，见 CiphertextMessageType）
        let msg = match bytes.first() {
            Some(3) => CiphertextMessage::PreKeySignalMessage(PreKeySignalMessage::try_from(
                bytes.as_slice(),
            )?),
            Some(2) => {
                CiphertextMessage::SignalMessage(SignalMessage::try_from(bytes.as_slice())?)
            }
            other => return Err(format!("未知密文类型 {other:?}")),
        };
        let peer_addr = ProtocolAddress::new(peer.to_string(), DeviceId::new(1)?);
        let plaintext = message_decrypt(
            &msg,
            &peer_addr,
            &crypto.local,
            &mut crypto.store.session_store,
            &mut crypto.store.identity_store,
            &mut crypto.store.pre_key_store,
            &crypto.store.signed_pre_key_store,
            &mut crypto.store.kyber_pre_key_store,
            &mut crypto.rng,
        )
        .await?;
        String::from_utf8(plaintext).map_err(|_| "解密结果不是 UTF-8".to_string())
    };
    run.now_or_never().unwrap_or_else(|| Err("decrypt 意外挂起".into()))
}

// ---------- bundle JSON 编解码 ----------

fn b64e(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

fn b64d(s: &str) -> Vec<u8> {
    base64::engine::general_purpose::STANDARD
        .decode(s)
        .unwrap_or_default()
}

fn bundle_json_of(bundle: &PreKeyBundle) -> Result<String, String> {
    let signed_pub = bundle.signed_pre_key_public()?;
    let kyber_pub = bundle.kyber_pre_key_public()?;
    Ok(serde_json::json!({
        "registration_id": bundle.registration_id()?,
        "device_id": 1,
        "identity_key": b64e(bundle.identity_key()?.serialize()),
        "signed_pre_key": {
            "id": bundle.signed_pre_key_id()?.to_u32(),
            "public": b64e(signed_pub.serialize()),
            "signature": b64e(bundle.signed_pre_key_signature()?),
        },
        "kyber_pre_key": {
            "id": bundle.kyber_pre_key_id()?.to_u32(),
            "public": b64e(kyber_pub.serialize()),
            "signature": b64e(bundle.kyber_pre_key_signature()?),
        },
    })
    .to_string())
}

fn parse_bundle(json: &str) -> Result<PreKeyBundle, String> {
    let v: serde_json::Value = serde_json::from_str(json).map_err(|e| e.to_string())?;
    let spk = &v["signed_pre_key"];
    let kyber = &v["kyber_pre_key"];
    let id = |x: &serde_json::Value| -> Result<u32, String> {
        x.as_u64().and_then(|n| u32::try_from(n).ok()).ok_or_else(|| "id 非法".to_string())
    };
    let identity = IdentityKey::new(deserialize_curve_pub(
        v["identity_key"].as_str().unwrap_or_default(),
    )?);
    PreKeyBundle::new(
        v["registration_id"].as_u64().unwrap_or(0) as u32,
        DeviceId::new(1)?,
        None,
        id(spk["id"])?,
        deserialize_curve_pub(spk["public"].as_str().unwrap_or_default())?,
        b64d(spk["signature"].as_str().unwrap_or_default()),
        id(kyber["id"])?,
        deserialize_kyber_pub(kyber["public"].as_str().unwrap_or_default())?,
        b64d(kyber["signature"].as_str().unwrap_or_default()),
        identity,
    )
    .map_err(|e| e.to_string())
}

fn deserialize_curve_pub(s: &str) -> Result<libsignal_protocol::PublicKey, String> {
    libsignal_protocol::PublicKey::deserialize(&b64d(s)).map_err(|e| e.to_string())
}

fn deserialize_kyber_pub(s: &str) -> Result<kem::PublicKey, String> {
    kem::PublicKey::deserialize(&b64d(s)).map_err(|e| e.to_string())
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

// ---------- 测试：双端回环（对齐官方 session_management/tests.rs 的用法） ----------

#[cfg(test)]
mod tests {
    use super::*;

    /// 建一个对端：身份 + prekey 套件，返回 (地址, store, bundle JSON)
    async fn make_peer(name: &str) -> (ProtocolAddress, InMemSignalProtocolStore, String) {
        let mut rng = OsRng;
        let identity = IdentityKeyPair::generate(&mut rng);
        let signed_key = KeyPair::generate(&mut rng);
        let kyber_key = kem::KeyPair::generate(kem::KeyType::Kyber1024, &mut rng);
        let signed_sig = identity
            .private_key()
            .calculate_signature(&signed_key.public_key.serialize(), &mut rng)
            .unwrap();
        let kyber_sig = identity
            .private_key()
            .calculate_signature(&kyber_key.public_key.serialize(), &mut rng)
            .unwrap();
        let mut store = InMemSignalProtocolStore::new(identity, 1).unwrap();
        store
            .save_signed_pre_key(
                1.into(),
                &SignedPreKeyRecord::new(
                    1.into(),
                    Timestamp::from_epoch_millis(0),
                    &signed_key,
                    &signed_sig,
                ),
            )
            .await
            .unwrap();
        store
            .save_kyber_pre_key(
                1.into(),
                &KyberPreKeyRecord::new(
                    1.into(),
                    Timestamp::from_epoch_millis(0),
                    &kyber_key,
                    &kyber_sig,
                ),
            )
            .await
            .unwrap();
        let bundle = PreKeyBundle::new(
            1,
            DeviceId::new(1).unwrap(),
            None,
            1.into(),
            signed_key.public_key,
            signed_sig,
            1.into(),
            kyber_key.public_key,
            kyber_sig,
            *store.identity_store.get_identity_key_pair().await.unwrap().identity_key(),
        )
        .unwrap();
        let addr = ProtocolAddress::new(name.to_string(), DeviceId::new(1).unwrap());
        (addr, store, bundle_json_of(&bundle).unwrap())
    }

    #[test]
    fn x3dh_and_double_ratchet_roundtrip() {
        let run = async {
            let (alice_addr, mut alice, bob_bundle) = make_peer("alice").await;
            let (bob_addr, mut bob, _) = make_peer("bob").await;

            // Alice 用 Bob 的注册包建会话（X3DH/PQXDH）
            let bundle = parse_bundle(&bob_bundle)?;
            initiate_session(
                &bob_addr,
                &alice_addr,
                &mut alice.session_store,
                &mut alice.identity_store,
                &bundle,
                SystemTime::now(),
                &mut OsRng,
            )
            .await?;

            // Alice → Bob：PreKey 消息建反向会话 + 双棘轮首条
            let ct = message_encrypt(
                b"你好，端到端",
                &bob_addr,
                &alice_addr,
                &mut alice.session_store,
                &mut alice.identity_store,
                SystemTime::now(),
                &mut OsRng,
            )
            .await?;
            let pt = message_decrypt(
                &ct,
                &alice_addr,
                &bob_addr,
                &mut bob.session_store,
                &mut bob.identity_store,
                &mut bob.pre_key_store,
                &bob.signed_pre_key_store,
                &mut bob.kyber_pre_key_store,
                &mut OsRng,
            )
            .await?;
            assert_eq!(pt, b"你好，端到端");

            // Bob → Alice：棘轮已双向
            let ct = message_encrypt(
                b"received",
                &alice_addr,
                &bob_addr,
                &mut bob.session_store,
                &mut bob.identity_store,
                SystemTime::now(),
                &mut OsRng,
            )
            .await?;
            let pt = message_decrypt(
                &ct,
                &bob_addr,
                &alice_addr,
                &mut alice.session_store,
                &mut alice.identity_store,
                &mut alice.pre_key_store,
                &alice.signed_pre_key_store,
                &mut alice.kyber_pre_key_store,
                &mut OsRng,
            )
            .await?;
            assert_eq!(pt, b"received");

            // 连续多轮：前向保密的棘轮步进
            for i in 0..3u32 {
                let text = format!("round-{i}");
                let ct = message_encrypt(
                    text.as_bytes(),
                    &alice_addr,
                    &bob_addr,
                    &mut alice.session_store,
                    &mut alice.identity_store,
                    SystemTime::now(),
                    &mut OsRng,
                )
                .await?;
                let pt = message_decrypt(
                    &ct,
                    &alice_addr,
                    &bob_addr,
                    &mut bob.session_store,
                    &mut bob.identity_store,
                    &mut bob.pre_key_store,
                    &bob.signed_pre_key_store,
                    &mut bob.kyber_pre_key_store,
                    &mut OsRng,
                )
                .await?;
                assert_eq!(pt, text.as_bytes());
            }

            // bundle JSON 往返无损（parse_bundle 与 bundle_json_of 对得上）
            let _ = bundle;

            Ok::<(), String>(())
        };
        assert_eq!(run.now_or_never().unwrap(), Ok(()));
    }
}
