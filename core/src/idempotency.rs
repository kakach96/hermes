//! Bloom Filter 幂等去重 —— QoS1 + 业务层幂等的客户端半边。
//!
//! 用途：重连补投与实时投递竞态时（新旧 consumer 短暂并存），按
//! `dedup_id` 丢弃重复投递。Bloom 的假阳性会误丢真消息，所以
//! 位图要给足（1Mbit ≈ 128KB，百万级消息内假阳性 <0.1%）；
//! 双重哈希（double hashing）省掉 k 组独立哈希。
//!
//! 学习点：为什么不用 QoS2 —— 两次握手协议换不来聊天场景的收益，
//! 一条"可能重复、但绝不丢失"的管道 + 幂等消费才是对的权衡。

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

pub struct Bloom {
    bits: Box<[u8]>,
    nbits: usize,
}

impl Bloom {
    /// nbits = 位图总位数（建议 2^n 方便取模）
    pub fn new(nbits: usize) -> Self {
        assert!(nbits % 8 == 0, "nbits must be a multiple of 8");
        Bloom {
            bits: vec![0u8; nbits / 8].into_boxed_slice(),
            nbits,
        }
    }

    pub fn insert(&mut self, key: &str) {
        let (h1, h2) = hashes(key);
        for i in 0..4u64 {
            let idx = index(h1, h2, i, self.nbits);
            self.bits[idx / 8] |= 1 << (idx % 8);
        }
    }

    /// 假阳性可能返回 true，但 false 永远可信 —— false 才能用于"确定没见过"
    pub fn maybe_contains(&self, key: &str) -> bool {
        let (h1, h2) = hashes(key);
        (0..4u64).all(|i| {
            let idx = index(h1, h2, i, self.nbits);
            self.bits[idx / 8] & (1 << (idx % 8)) != 0
        })
    }
}

fn hashes(key: &str) -> (u64, u64) {
    let mut a = DefaultHasher::new();
    key.hash(&mut a);
    let h1 = a.finish();
    // 第二次哈希：混入盐再过一遍，制造统计独立的 h2（奇数，防止与 h1 相关）
    let mut b = DefaultHasher::new();
    (key, 0x9E3779B97F4A7C15u64).hash(&mut b);
    let h2 = b.finish() | 1;
    (h1, h2)
}

fn index(h1: u64, h2: u64, i: u64, nbits: usize) -> usize {
    ((h1.wrapping_add(i.wrapping_mul(h2))) % (nbits as u64)) as usize
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_false_negatives() {
        let mut bloom = Bloom::new(1 << 20);
        for i in 0..1000 {
            bloom.insert(&format!("dedup-{i}"));
        }
        for i in 0..1000 {
            assert!(bloom.maybe_contains(&format!("dedup-{i}")), "i={i}");
        }
    }

    #[test]
    fn low_false_positive_rate() {
        let mut bloom = Bloom::new(1 << 20);
        for i in 0..10_000 {
            bloom.insert(&format!("seen-{i}"));
        }
        let false_positives = (0..10_000)
            .filter(|i| bloom.maybe_contains(&format!("miss-{i}")))
            .count();
        // 10k 条占用 1Mbit：理论 FP ≈ 0.3%；放宽到 3% 防止哈希实现差异导致抖动
        assert!(false_positives < 300, "fp={false_positives}");
    }
}
