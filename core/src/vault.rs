//! 静态加密（P0-2）——密钥与会话文件的 AEAD 信封。
//!
//! 设计：
//! - KEK 从**登录密码**派生（Argon2id，64 MiB / t=3 / p=1）——UX 零新增，
//!   登录本来就要输密码；密码本身永不落盘
//! - AEAD = AES-256-GCM（RustCrypto `aes-gcm`，标准原语，不自研）
//! - 信封格式（JSON，与既有文件风格一致）：
//!   `{"v":1,"kdf":"argon2id","salt","nonce","ct"}` —— salt 不是秘密，
//!   存信封里供下次登录重派生
//! - **透明迁移**：老明文文件（keys_*/sessions_* 预 P0-2 产物）在下次
//!   登录时被识别（无信封标记）→ 加密重写
//!
//! 全部密码学是业界标准实现；宪法"禁自研加密协议"约束的是协议层，
//! 这里连原语都是现成的。

use aes_gcm::aead::generic_array::GenericArray;
use aes_gcm::aead::Aead;
use aes_gcm::{Aes256Gcm, KeyInit};
use base64::Engine as _;
use rand::rngs::StdRng;
use rand::{Rng, SeedableRng};

/// 派生密钥容器（32 字节 AES-256 key）
pub struct Vault {
    key: [u8; 32],
}

pub const SALT_LEN: usize = 16;
const NONCE_LEN: usize = 12;

// Argon2id 工作参数：64 MiB / t=3 / p=1（RFC 9106 推荐档位）
const ARGON2_M_KIB: u32 = 65536;
const ARGON2_T: u32 = 3;
const ARGON2_P: u32 = 1;

fn b64e(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

fn b64d(s: &str) -> Result<Vec<u8>, String> {
    base64::engine::general_purpose::STANDARD
        .decode(s)
        .map_err(|e| format!("base64 解码失败: {e}"))
}

impl Vault {
    /// 从密码 + salt 派生 KEK。salt 不是秘密（存信封）。
    pub fn derive(password: &str, salt: &[u8]) -> Result<Vault, String> {
        let params = argon2::Params::new(ARGON2_M_KIB, ARGON2_T, ARGON2_P, Some(32))
            .map_err(|e| format!("argon2 参数: {e}"))?;
        let a2 = argon2::Argon2::new(
            argon2::Algorithm::Argon2id,
            argon2::Version::V0x13,
            params,
        );
        let mut key = [0u8; 32];
        a2.hash_password_into(password.as_bytes(), salt, &mut key)
            .map_err(|e| format!("argon2 派生失败: {e}"))?;
        Ok(Vault { key })
    }

    /// 明文 → 信封 JSON 文本（salt 随信封存——不是秘密，供下次登录重派生）
    pub fn seal_json(&self, salt: &[u8], plaintext: &str) -> Result<String, String> {
        let mut rng = StdRng::from_os_rng();
        let nonce: [u8; NONCE_LEN] = rng.random();
        let cipher = Aes256Gcm::new(GenericArray::from_slice(&self.key));
        let ct = cipher
            .encrypt(
                GenericArray::from_slice(&nonce),
                plaintext.as_bytes(),
            )
            .map_err(|_| "AES-GCM 加密失败".to_string())?;
        let envelope = serde_json::json!({
            "v": 1,
            "kdf": "argon2id",
            "salt": b64e(salt),
            "nonce": b64e(&nonce),
            "ct": b64e(&ct),
        });
        Ok(envelope.to_string())
    }

    /// 信封 JSON → 明文字节。
    /// Ok(None) = 不是信封（**老明文文件**，调用方走迁移路径）；
    /// Err = 是信封但解不开（密钥不匹配 / 数据损坏）。
    pub fn open_json(&self, text: &str) -> Result<Option<Vec<u8>>, String> {
        let v: serde_json::Value =
            serde_json::from_str(text).map_err(|e| format!("信封 JSON 解析失败: {e}"))?;
        let is_envelope = v.get("v").is_some() && v.get("kdf").is_some() && v.get("ct").is_some();
        if !is_envelope {
            return Ok(None);
        }
        let nonce = b64d(
            v.get("nonce")
                .and_then(|x| x.as_str())
                .ok_or("信封缺 nonce")?,
        )?;
        let ct = b64d(v.get("ct").and_then(|x| x.as_str()).ok_or("信封缺 ct")?)?;
        if nonce.len() != NONCE_LEN {
            return Err("nonce 长度异常".into());
        }
        let cipher = Aes256Gcm::new(GenericArray::from_slice(&self.key));
        let pt = cipher
            .decrypt(GenericArray::from_slice(&nonce), ct.as_ref())
            .map_err(|_| "解密失败（密码不对或文件损坏）".to_string())?;
        Ok(Some(pt))
    }

    /// 信封 JSON 文本 → 明文（丢弃 salt 字段的便捷封装）
    pub fn open_json_string(&self, text: &str) -> Result<Option<String>, String> {
        match self.open_json(text)? {
            None => Ok(None),
            Some(bytes) => String::from_utf8(bytes)
                .map(Some)
                .map_err(|_| "解密结果不是 UTF-8".to_string()),
        }
    }
}

/// CSPRNG salt（每个账号一个；首次建档时生成，存进信封）
pub fn gen_salt() -> [u8; SALT_LEN] {
    let mut rng = StdRng::from_os_rng();
    rng.random()
}

/// 从信封文本里抽 salt（登录重派生用；返回 None = 不是信封）
pub fn salt_of(text: &str) -> Option<Vec<u8>> {
    let v: serde_json::Value = serde_json::from_str(text).ok()?;
    let s = v.get("salt")?.as_str()?;
    b64d(s).ok().into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn seal_open_roundtrip() {
        let salt = gen_salt();
        let vault = Vault::derive("correct horse", &salt).unwrap();
        let envelope = vault.seal_json(&salt, "{\"secret\":1}").unwrap();
        assert!(envelope.contains("\"kdf\":\"argon2id\""));
        let opened = vault.open_json_string(&envelope).unwrap().expect("envelope");
        assert_eq!(opened, "{\"secret\":1}");
    }

    #[test]
    fn wrong_key_fails() {
        let salt = gen_salt();
        let a = Vault::derive("password-a", &salt).unwrap();
        let b = Vault::derive("password-b", &salt).unwrap();
        let envelope = a.seal_json(&salt, "data").unwrap();
        assert!(b.open_json(&envelope).is_err());
    }

    #[test]
    fn legacy_plaintext_detected() {
        let salt = gen_salt();
        let vault = Vault::derive("pw", &salt).unwrap();
        // 老明文文件：不是信封 → Ok(None)（迁移路径）
        assert!(vault.open_json("{\"created_ms\":123}").unwrap().is_none());
        // 垃圾文本同样落 None（宽松：交给上层按明文解析失败处理）
        assert!(vault.open_json("not json at all").is_err());
    }

    #[test]
    fn salt_roundtrip_through_envelope() {
        let salt = gen_salt();
        let vault = Vault::derive("pw", &salt).unwrap();
        let envelope = vault.seal_json(&salt, "x").unwrap();
        assert_eq!(salt_of(&envelope).unwrap(), salt.to_vec());
    }
}
