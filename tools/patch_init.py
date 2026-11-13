# -*- coding: utf-8 -*-
# Splice: replace fn init() { ... } (first occurrence, to first bare "}")
# with the persistence-enabled version. ASCII-safe file IO.
import io, re, sys

P = r"D:\projects\hermes\core\src\crypto.rs"
c = io.open(P, encoding="utf-8").read()
c = c.replace("\r\n", "\n")
lines = c.split("\n")

start = end = -1
for i, line in enumerate(lines):
    if line.startswith("fn init("):
        start = i
        break
for i in range(start + 1, len(lines)):
    if lines[i] == "}":
        end = i
        break
print("init: lines", start + 1, "..", end + 1, "of", len(lines))
assert start > 0 and end > start

new_init = u'''// Same name = same identity: load persisted key material when present,
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
            let material = match load_key_material(name, keys_dir) {
                Some(m) => m,
                None => {
                    let m = generate_material()?;
                    save_key_material(name, keys_dir, &m)?;
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
            "private": b64e(&m.kyber.private_key.serialize()),
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
        Some(KeyPair::from_public_and_private(
            &b64d(x["public"].as_str()?),
            &b64d(x["private"].as_str()?),
        ))
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
        ),
        kyber_sig: b64d(v["kyber_pre_key"]["signature"].as_str()?),
    })
}'''

merged = "\n".join(lines[:start]) + "\n" + new_init + "\n" + "\n".join(lines[end + 1 :])
io.open(P, "w", encoding="utf-8", newline="\n").write(merged)
print("done, new size", len(merged))
