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
//!
//! 注意：libsignal 依赖 rand 0.9.4 的 trait 体系 —— RNG 必须用同一大版本
//! 的 `StdRng`（`OsRng` 在跨版本 trait 下不实现 CryptoRng，官方坑）。

use std::sync::mpsc as std_mpsc;
use std::time::SystemTime;

use base64::Engine as _;
use futures_util::FutureExt as _;
use libsignal_protocol::{
    CiphertextMessage, DeviceId, GenericSignedPreKey as _, IdentityKey, IdentityKeyPair,
    IdentityKeyStore as _, InMemSignalProtocolStore, KeyPair, KyberPreKeyStore as _,
    KyberPreKeyRecord, PreKeyBundle, PreKeySignalMessage, ProtocolAddress,
    SessionStore as _, SignalMessage, SignalProtocolError, SignedPreKeyRecord,
    SignedPreKeyStore as _, Timestamp, initiate_session, kem, message_decrypt,
    message_encrypt,
};
use rand::rngs::StdRng;
use rand::{Rng as _, SeedableRng as _};

/// 内部错误：统一把 libsignal 的错误族转成字符串。
/// （InvalidDeviceId 是 libsignal_core 私有模块的类型，只能闭包处理）
#[derive(Debug)]
struct CryptoError(String);

impl From<SignalProtocolError> for CryptoError {
    fn from(e: SignalProtocolError) -> Self {
        CryptoError(e.to_string())
    }
}

impl From<libsignal_core::curve::CurveError> for CryptoError {
    fn from(e: libsignal_core::curve::CurveError) -> Self {
        CryptoError(e.to_string())
    }
}

impl From<String> for CryptoError {
    fn from(e: String) -> Self {
        CryptoError(e)
    }
}

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
#[derive(Debug)]
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
    local: ProtocolAddress,
    store: InMemSignalProtocolStore,
}

/// 起 crypto 线程。channel 两端都是线程安全的。
pub fn spawn(keys_dir: String) -> (CryptoCmdTx, CryptoEventRx) {
    let (cmd_tx, cmd_rx) = std_mpsc::channel::<CryptoCmd>();
    let (ev_tx, ev_rx) = tokio::sync::mpsc::unbounded_channel::<CryptoEvent>();
    std::thread::Builder::new()
        .name("hermes-crypto".into())
        .spawn(move || {
            let mut state: Option<Crypto> = None;
            while let Ok(cmd) = cmd_rx.recv() {
                // Init 必须在 state 守卫之前处理：它就是用来创建 state 的
                if let CryptoCmd::Init { name } = cmd {
                    state = init(name, &keys_dir, &ev_tx);
                    continue;
                }
                let Some(crypto) = state.as_mut() else {
                    let _ = ev_tx.send(CryptoEvent::Failed {
                        context: "crypto".into(),
                        detail: "尚未初始化（先 Init）".into(),
                    });
                    continue;
                };
                let event = match cmd {
                    CryptoCmd::Establish { peer, bundle_json } =>
                        match establish(crypto, &peer, &bundle_json) {
                            Ok(()) => CryptoEvent::Established { peer },
                            Err(e) => CryptoEvent::Failed {
                                context: format!("establish {peer}"),
                                detail: e.0,
                            },
                        },
                    CryptoCmd::Encrypt { peer, dedup_id, plaintext } =>
                        match encrypt(crypto, &peer, &plaintext) {
                            Ok(body) => CryptoEvent::Encrypted {
                                peer,
                                dedup_id,
                                body_b64: b64e(&body),
                            },
                            Err(e) => CryptoEvent::Failed {
                                context: format!("encrypt {peer}"),
                                detail: e.0,
                            },
                        },
                    CryptoCmd::Decrypt { peer, body_b64 } =>
                        match decrypt(crypto, &peer, &body_b64) {
                            Ok(text) => CryptoEvent::Decrypted { peer, text },
                            Err(e) => CryptoEvent::Failed {
                                context: format!("decrypt {peer}"),
                                detail: e.0,
                            },
                        },
                    // Init 已在上面处理
                    CryptoCmd::Init { .. } => unreachable!(),
                };
                let _ = ev_tx.send(event);
            }
        })
        .expect("spawn crypto thread");
    (cmd_tx, ev_rx)
}

// ---------- 操作实现（async 签名保留 libsignal 的形态，同步驱动） ----------

/// 每次操作独立 OS 熵种子的 StdRng（临时密钥的熵源必须来自 OS）
fn fresh_rng() -> StdRng {
    StdRng::from_os_rng()
}

fn device_id() -> Result<DeviceId, CryptoError> {
    DeviceId::new(1).map_err(|_| CryptoError("invalid device id".into()))
}

// Same name = same identity: load persisted key material when present,
// otherwise generate and persist. Signal's real semantics: identity is
// stable across restarts, so old sessions keep working after rejoin.
// v0 stores keys as plain JSON (toy-grade); at-rest encryption is round 2.
fn init(
    name: String,
    keys_dir: &str,
    ev: &tokio::sync::mpsc::UnboundedSender<CryptoEvent>,
) -> Option<Crypto> {
    let result: Option<Result<(InMemSignalProtocolStore, ProtocolAddress, String), CryptoError>> =
        (|| async {
            let device = device_id()?;
            let material = match load_key_material(&name, keys_dir) {
                Some(m) => m,
                None => {
                    let m = generate_material()?;
                    save_key_material(&name, keys_dir, &m)?;
                    m
                }
            };

            let identity_pair = IdentityKeyPair::from(material.identity.clone());
            let identity_key = *identity_pair.identity_key();
            let mut store = InMemSignalProtocolStore::new(identity_pair, material.registration_id)?;

            store
                .save_signed_pre_key(
                    material.signed_id.into(),
                    &SignedPreKeyRecord::new(
                        material.signed_id.into(),
                        Timestamp::from_epoch_millis(now_ms()),
                        &material.signed,
                        &material.signed_sig,
                    ),
                )
                .await?;
            store
                .save_kyber_pre_key(
                    material.kyber_id.into(),
                    &KyberPreKeyRecord::new(
                        material.kyber_id.into(),
                        Timestamp::from_epoch_millis(now_ms()),
                        &material.kyber,
                        &material.kyber_sig,
                    ),
                )
                .await?;

            let bundle = PreKeyBundle::new(
                material.registration_id,
                device,
                None, // v0: no one-time EC prekeys (matches official last-resort usage)
                material.signed_id.into(),
                material.signed.public_key,
                material.signed_sig.clone(),
                material.kyber_id.into(),
                material.kyber.public_key,
                material.kyber_sig.clone(),
                identity_key,
            )?;

            let local = ProtocolAddress::new(name.clone(), device);
            let bundle_json = bundle_json_of(&bundle)?;
            Ok((store, local, bundle_json))
        })()
        .now_or_never();

    match result {
        Some(Ok((store, local, bundle_json))) => {
            let _ = ev.send(CryptoEvent::Registered { bundle_json: bundle_json.clone() });
            Some(Crypto { local, store })
        }
        Some(Err(e)) => {
            let _ = ev.send(CryptoEvent::Failed { context: "init".into(), detail: e.0 });
            None
        }
        None => {
            let _ = ev.send(CryptoEvent::Failed {
                context: "init".into(),
                detail: "now_or_never hang".into(),
            });
            None
        }
    }
}

// ---------- key material persistence ----------

struct KeyMaterial {
    registration_id: u32,
    identity: KeyPair,
    signed_id: u32,
    signed: KeyPair,
    signed_sig: Vec<u8>,
    kyber_id: u32,
    kyber: kem::KeyPair,
    kyber_sig: Vec<u8>,
}

fn generate_material() -> Result<KeyMaterial, CryptoError> {
    let mut rng = fresh_rng();
    let identity = KeyPair::generate(&mut rng);
    // Signal registration id: an opaque small integer
    let registration_id = rng.random_range(1..0x3FFF);
    let signed = KeyPair::generate(&mut rng);
    let kyber = kem::KeyPair::generate(kem::KeyType::Kyber1024, &mut rng);
    let signer = IdentityKeyPair::from(identity.clone());
    let signed_sig = signer
        .private_key()
        .calculate_signature(&signed.public_key.serialize(), &mut rng)?
        .to_vec();
    let kyber_sig = signer
        .private_key()
        .calculate_signature(&kyber.public_key.serialize(), &mut rng)?
        .to_vec();
    Ok(KeyMaterial {
        registration_id,
        identity,
        signed_id: 1,
        signed,
        signed_sig,
        kyber_id: 1,
        kyber,
        kyber_sig,
    })
}

fn keys_file(keys_dir: &str, name: &str) -> std::path::PathBuf {
    std::path::Path::new(keys_dir).join(format!("keys_{}.json", name))
}

fn save_key_material(name: &str, keys_dir: &str, m: &KeyMaterial) -> Result<(), CryptoError> {
    std::fs::create_dir_all(keys_dir).map_err(|e| CryptoError(e.to_string()))?;
    let json = serde_json::json!({
        "registration_id": m.registration_id,
        "identity": { "public": b64e(&m.identity.public_key.serialize()), "private": b64e(&m.identity.private_key.serialize()) },
        "signed_pre_key": {
            "id": m.signed_id,
            "public": b64e(&m.signed.public_key.serialize()),
            "private": b64e(&m.signed.private_key.serialize()),
            "signature": b64e(&m.signed_sig),
        },
        "kyber_pre_key": {
            "id": m.kyber_id,
            "public": b64e(&m.kyber.public_key.serialize()),
            "private": b64e(&m.kyber.secret_key.serialize()),
            "signature": b64e(&m.kyber_sig),
        },
    });
    std::fs::write(keys_file(keys_dir, name), json.to_string())
        .map_err(|e| CryptoError(e.to_string()))
}

fn load_key_material(name: &str, keys_dir: &str) -> Option<KeyMaterial> {
    let text = std::fs::read_to_string(keys_file(keys_dir, name)).ok()?;
    let v: serde_json::Value = serde_json::from_str(&text).ok()?;
    let pair = |x: &serde_json::Value| -> Option<KeyPair> {
        Some(
            KeyPair::from_public_and_private(
                &b64d(x["public"].as_str()?),
                &b64d(x["private"].as_str()?),
            )
            .ok()?,
        )
    };
    Some(KeyMaterial {
        registration_id: v["registration_id"].as_u64()? as u32,
        identity: pair(&v["identity"])?,
        signed_id: v["signed_pre_key"]["id"].as_u64()? as u32,
        signed: pair(&v["signed_pre_key"])?,
        signed_sig: b64d(v["signed_pre_key"]["signature"].as_str()?),
        kyber_id: v["kyber_pre_key"]["id"].as_u64()? as u32,
        kyber: kem::KeyPair::from_public_and_private(
            &b64d(v["kyber_pre_key"]["public"].as_str()?),
            &b64d(v["kyber_pre_key"]["private"].as_str()?),
        )
        .ok()?,
        kyber_sig: b64d(v["kyber_pre_key"]["signature"].as_str()?),
    })
}

fn establish(crypto: &mut Crypto, peer: &str, bundle_json: &str) -> Result<(), CryptoError> {
    let run = async {
        let bundle = parse_bundle(bundle_json)?;
        let peer_addr = ProtocolAddress::new(peer.to_string(), device_id()?);
        initiate_session(
            &peer_addr,
            &crypto.local,
            &mut crypto.store.session_store,
            &mut crypto.store.identity_store,
            &bundle,
            SystemTime::now(),
            &mut fresh_rng(),
        )
        .await?;
        Ok(())
    };
    run.now_or_never().unwrap_or_else(|| Err(CryptoError("establish 意外挂起".into())))
}

fn encrypt(crypto: &mut Crypto, peer: &str, plaintext: &[u8]) -> Result<Vec<u8>, CryptoError> {
    let run = async {
        let peer_addr = ProtocolAddress::new(peer.to_string(), device_id()?);
        let ct = message_encrypt(
            plaintext,
            &peer_addr,
            &crypto.local,
            &mut crypto.store.session_store,
            &mut crypto.store.identity_store,
            SystemTime::now(),
            &mut fresh_rng(),
        )
        .await?;
        Ok(ct.serialize().to_vec())
    };
    run.now_or_never().unwrap_or_else(|| Err(CryptoError("encrypt 意外挂起".into())))
}

fn decrypt(crypto: &mut Crypto, peer: &str, body_b64: &str) -> Result<String, CryptoError> {
    let run = async {
        let bytes = b64d(body_b64);
        // 不按首字节魔数分派（新版本的版本打包字节会变），直接尝试解析：
        // PreKey 消息（会话初建）优先，普通 Whisper 消息兜底
        let msg = if let Ok(m) = PreKeySignalMessage::try_from(bytes.as_slice()) {
            CiphertextMessage::PreKeySignalMessage(m)
        } else if let Ok(m) = SignalMessage::try_from(bytes.as_slice()) {
            CiphertextMessage::SignalMessage(m)
        } else {
            return Err(CryptoError(format!(
                "未知密文，长度 {}，前字节 {:?}",
                bytes.len(),
                bytes.first()
            )));
        };
        let peer_addr = ProtocolAddress::new(peer.to_string(), device_id()?);
        let plaintext = message_decrypt(
            &msg,
            &peer_addr,
            &crypto.local,
            &mut crypto.store.session_store,
            &mut crypto.store.identity_store,
            &mut crypto.store.pre_key_store,
            &crypto.store.signed_pre_key_store,
            &mut crypto.store.kyber_pre_key_store,
            &mut fresh_rng(),
        )
        .await?;
        String::from_utf8(plaintext).map_err(|_| CryptoError("解密结果不是 UTF-8".into()))
    };
    run.now_or_never().unwrap_or_else(|| Err(CryptoError("decrypt 意外挂起".into())))
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

fn bundle_json_of(bundle: &PreKeyBundle) -> Result<String, CryptoError> {
    let signed_pub = bundle.signed_pre_key_public()?;
    let kyber_pub = bundle.kyber_pre_key_public()?;
    Ok(serde_json::json!({
        "registration_id": bundle.registration_id()?,
        "device_id": 1,
        "identity_key": b64e(&bundle.identity_key()?.serialize()),
        "signed_pre_key": {
            "id": u32::from(bundle.signed_pre_key_id()?),
            "public": b64e(&signed_pub.serialize()),
            "signature": b64e(&bundle.signed_pre_key_signature()?),
        },
        "kyber_pre_key": {
            "id": u32::from(bundle.kyber_pre_key_id()?),
            "public": b64e(&kyber_pub.serialize()),
            "signature": b64e(&bundle.kyber_pre_key_signature()?),
        },
    })
    .to_string())
}

fn parse_bundle(json: &str) -> Result<PreKeyBundle, CryptoError> {
    let v: serde_json::Value =
        serde_json::from_str(json).map_err(|e| CryptoError(e.to_string()))?;
    let spk = &v["signed_pre_key"];
    let kyber = &v["kyber_pre_key"];
    let id = |x: &serde_json::Value| -> Result<u32, CryptoError> {
        x.as_u64()
            .and_then(|n| u32::try_from(n).ok())
            .ok_or_else(|| CryptoError("id 非法".into()))
    };
    let identity = IdentityKey::new(deserialize_curve_pub(
        v["identity_key"].as_str().unwrap_or_default(),
    )?);
    PreKeyBundle::new(
        v["registration_id"].as_u64().unwrap_or(0) as u32,
        device_id()?,
        None,
        id(&spk["id"])?.into(),
        deserialize_curve_pub(spk["public"].as_str().unwrap_or_default())?,
        b64d(spk["signature"].as_str().unwrap_or_default()),
        id(&kyber["id"])?.into(),
        deserialize_kyber_pub(kyber["public"].as_str().unwrap_or_default())?,
        b64d(kyber["signature"].as_str().unwrap_or_default()),
        identity,
    )
    .map_err(CryptoError::from)
}

fn deserialize_curve_pub(s: &str) -> Result<libsignal_protocol::PublicKey, String> {
    libsignal_protocol::PublicKey::deserialize(&b64d(s)).map_err(|e| e.to_string())
}

fn deserialize_kyber_pub(s: &str) -> Result<kem::PublicKey, String> {
    kem::PublicKey::deserialize(&b64d(s)).map_err(|e| e.to_string())
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

// ---------- 测试：双端回环（对齐官方 session_management/tests.rs 的用法） ----------

#[cfg(test)]
mod tests {
    use super::*;

    /// 建一个对端：身份 + prekey 套件。
    /// 返回 (地址, store, bundle 对象, bundle JSON)。
    async fn make_peer(
        name: &str,
    ) -> (ProtocolAddress, InMemSignalProtocolStore, PreKeyBundle, String) {
        let mut rng = fresh_rng();
        let device = device_id().unwrap();
        let identity = IdentityKeyPair::generate(&mut rng);
        let signed_key = KeyPair::generate(&mut rng);
        let kyber_key = kem::KeyPair::generate(kem::KeyType::Kyber1024, &mut rng);
        let signed_sig = identity
            .private_key()
            .calculate_signature(&signed_key.public_key.serialize(), &mut rng)
            .unwrap()
            .to_vec();
        let kyber_sig = identity
            .private_key()
            .calculate_signature(&kyber_key.public_key.serialize(), &mut rng)
            .unwrap()
            .to_vec();
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
            device,
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
        let addr = ProtocolAddress::new(name.to_string(), device);
        let bundle_json = bundle_json_of(&bundle).unwrap();
        (addr, store, bundle, bundle_json)
    }

    /// 完整回环：Alice 建 X3DH/PQXDH 会话 → 单向 → 双向 → 多轮棘轮。
    /// json=true 时 bundle 经 JSON 编解码链路（wire 形态）。
    async fn run_roundtrip(json: bool) -> Result<(), CryptoError> {
        let (alice_addr, mut alice, _, _alice_bundle_json) = make_peer("alice").await;
        let (bob_addr, mut bob, bob_bundle, bob_bundle_json) = make_peer("bob").await;
        let _ = _alice_bundle_json;

        let bundle = if json {
            assert_eq!(
                bundle_json_of(&parse_bundle(&bob_bundle_json)?)?,
                bob_bundle_json,
                "bundle json roundtrip"
            );
            parse_bundle(&bob_bundle_json)?
        } else {
            bob_bundle
        };

        // Alice 用 Bob 的注册包建会话
        initiate_session(
            &bob_addr,
            &alice_addr,
            &mut alice.session_store,
            &mut alice.identity_store,
            &bundle,
            SystemTime::now(),
            &mut fresh_rng(),
        )
        .await?;

        // Alice → Bob：PreKey 消息（建立 Bob 侧会话）+ 双棘轮首条
        let ct = message_encrypt(
            b"hello-e2e",
            &bob_addr,
            &alice_addr,
            &mut alice.session_store,
            &mut alice.identity_store,
            SystemTime::now(),
            &mut fresh_rng(),
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
            &mut fresh_rng(),
        )
        .await?;
        assert_eq!(pt, b"hello-e2e");

        // Bob → Alice：棘轮已双向
        let ct = message_encrypt(
            b"received",
            &alice_addr,
            &bob_addr,
            &mut bob.session_store,
            &mut bob.identity_store,
            SystemTime::now(),
            &mut fresh_rng(),
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
            &mut fresh_rng(),
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
                &mut bob.session_store,
                &mut bob.identity_store,
                SystemTime::now(),
                &mut fresh_rng(),
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
                &mut fresh_rng(),
            )
            .await?;
            assert_eq!(pt, text.as_bytes());
        }

        // bundle JSON 往返无损
        if json {
            let _ = parse_bundle(&bob_bundle_json)?;
        }

        Ok(())
    }

    #[test]
    fn x3dh_and_double_ratchet_roundtrip_in_memory_bundle() {
        let _ = env_logger::builder().is_test(true).try_init();
        run_roundtrip(false).now_or_never().unwrap().unwrap();
    }

    #[test]
    fn x3dh_and_double_ratchet_roundtrip_via_wire_json() {
        run_roundtrip(true).now_or_never().unwrap().unwrap();
    }

    #[test]
    fn key_serialization_roundtrip() {
        let mut rng = fresh_rng();
        let kp = KeyPair::generate(&mut rng);
        let curve_bytes = kp.public_key.serialize();
        let curve_pk = libsignal_protocol::PublicKey::deserialize(&curve_bytes)
            .expect("curve deserialize");
        assert_eq!(curve_pk.serialize(), curve_bytes, "curve roundtrip");

        let ky = kem::KeyPair::generate(kem::KeyType::Kyber1024, &mut rng);
        let kyber_bytes = ky.public_key.serialize();
        let kyber_pk = kem::PublicKey::deserialize(&kyber_bytes).expect("kyber deserialize");
        assert_eq!(kyber_pk.serialize(), kyber_bytes, "kyber roundtrip");
    }

    /// 线程级集成：两个 crypto 线程实例经命令/事件通道完成
    /// 注册 → 建会话 → 加密 → 解密。守护"Init 被守卫吞掉"一类的回归。
    #[test]
    fn crypto_thread_lifecycle() {
        let keys_dir = std::env::temp_dir().join("hermes-test-keys").to_string_lossy().into_owned();
        let (alice_tx, mut alice_ev) = spawn(keys_dir.clone());
        let (bob_tx, mut bob_ev) = spawn(keys_dir.clone());

        alice_tx.send(CryptoCmd::Init { name: "Alice".into() }).unwrap();
        let registered = alice_ev.blocking_recv().expect("registered event");
        let CryptoEvent::Registered { bundle_json } = registered else {
            panic!("expected Registered, got {registered:?}");
        };

        bob_tx.send(CryptoCmd::Init { name: "Bob".into() }).unwrap();
        let CryptoEvent::Registered { bundle_json: bob_bundle_json } =
            bob_ev.blocking_recv().unwrap()
        else {
            panic!("bob expected Registered");
        };

        // Alice 用 **Bob 的** 注册包建会话（不是自己的！）
        alice_tx
            .send(CryptoCmd::Establish {
                peer: "Bob".into(),
                bundle_json: bob_bundle_json,
            })
            .unwrap();
        let CryptoEvent::Established { peer } = alice_ev.blocking_recv().unwrap() else {
            panic!("alice expected Established");
        };
        assert_eq!(peer, "Bob");

        // 加密 → 解密
        alice_tx
            .send(CryptoCmd::Encrypt {
                peer: "Bob".into(),
                dedup_id: "t1".into(),
                plaintext: b"thread-level".to_vec(),
            })
            .unwrap();
        let CryptoEvent::Encrypted { peer, body_b64, .. } = alice_ev.blocking_recv().unwrap()
        else {
            panic!("alice expected Encrypted");
        };
        assert_eq!(peer, "Bob");

        bob_tx
            .send(CryptoCmd::Decrypt { peer: "Alice".into(), body_b64 })
            .unwrap();
        let ev = bob_ev.blocking_recv().unwrap();
        let CryptoEvent::Decrypted { peer, text } = ev else {
            panic!("bob expected Decrypted, got {ev:?}");
        };
        assert_eq!(peer, "Alice");
        assert_eq!(text, "thread-level");
    }
}