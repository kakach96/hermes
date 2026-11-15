//! 赫尔墨斯存储 sidecar —— fjall 多 partition 元数据存储。
//!
//! 被 Erlang port 驱动：stdio 上的 4 字节大端长度帧 + JSON 载荷。
//! 单线程顺序处理（调用方 store Actor 本来就是顺序的）。
//!
//! 协议（请求/应答都是 JSON）：
//!   {"op":"put","key":...,"value":...,"ks":"users"}   -> {"ok":true}
//!   {"op":"get","key":...,"ks":"users"}               -> {"ok":true,"found":true,"value":...} | {"ok":true,"found":false}
//!   {"op":"delete","key":...,"ks":"users"}            -> {"ok":true}
//!   {"op":"list","ks":"channels","prefix":"lobby."}   -> {"ok":true,"items":[{"key":..,"value":..},..]}
//!   错误一律 {"ok":false,"error":...}
//!
//! ks 缺省 = "kv"。partition 集合是**固定白名单**（启动时全部打开），
//! 不接受从 wire 动态建 partition（防滥用 + 数量有界）。
//!
//! partition 布局（server 侧约定，见 server/src/hermes/meta.gleam）：
//!   kv       cursor:<房间 subject>:<name>   -> 设备游标（stream seq 十进制字符串）
//!   users    <name>                         -> {"created_ms":..}
//!   spaces   <space>                        -> {"name":..,"owner":..,"created_ms":..}
//!   channels <space>.<channel>              -> {"space":..,"name":..,"created_ms":..}
//!   members  <space>.<user>                 -> {"role":..,"joined_ms":..}（持久成员资格）
//!   perms    <space>.<user>                 -> {"role":"owner|admin|member"}
//!
//! 持久的是"资格"（谁属于哪个空间/频道），瞬态的"谁在线"在房间 Actor 内存里
//! （成员资格 = 连接生命周期的宪法不变）。历史消息仍在 JetStream 流里。

use std::io::{Read, Write};
use std::collections::HashMap;

/// 固定 partition 白名单：kv = 兼容 v0 的杂项（游标），其余为元数据域
const PARTITIONS: [&str; 6] = ["kv", "users", "spaces", "channels", "members", "perms"];

fn main() {
    let dir = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "./storage-data".into());

    let keyspace = match fjall::Keyspace::open(fjall::Config::new(dir)) {
        Ok(ks) => ks,
        Err(e) => {
            eprintln!("open keyspace failed: {e}");
            std::process::exit(1);
        }
    };

    let mut parts: HashMap<&str, fjall::PartitionHandle> = HashMap::new();
    for name in PARTITIONS {
        match keyspace.open_partition(name, Default::default()) {
            Ok(p) => {
                parts.insert(name, p);
            }
            Err(e) => {
                eprintln!("open partition {name} failed: {e}");
                std::process::exit(1);
            }
        }
    }

    let mut stdin = std::io::stdin().lock();
    let mut stdout = std::io::stdout().lock();

    loop {
        let mut len = [0u8; 4];
        if stdin.read_exact(&mut len).is_err() {
            // 父进程（server）关闭了管道：正常退出
            break;
        }
        let n = u32::from_be_bytes(len) as usize;
        let mut buf = vec![0u8; n];
        if stdin.read_exact(&mut buf).is_err() {
            break;
        }

        let resp = match serde_json::from_slice::<serde_json::Value>(&buf) {
            Ok(req) => handle(&parts, req),
            Err(e) => serde_json::json!({"ok": false, "error": format!("bad json: {e}")}),
        };

        let out = serde_json::to_vec(&resp).expect("serialize response");
        if stdout.write_all(&(out.len() as u32).to_be_bytes()).is_err() {
            break;
        }
        if stdout.write_all(&out).is_err() {
            break;
        }
        if stdout.flush().is_err() {
            break;
        }
    }
}

fn partition<'a>(
    parts: &'a HashMap<&'a str, fjall::PartitionHandle>,
    req: &serde_json::Value,
) -> Option<&'a fjall::PartitionHandle> {
    let ks = req["ks"].as_str().unwrap_or("kv");
    // 白名单校验：未知 partition 直接拒绝
    parts.get(ks)
}

fn handle(
    parts: &HashMap<&str, fjall::PartitionHandle>,
    req: serde_json::Value,
) -> serde_json::Value {
    let key = req["key"].as_str().unwrap_or("");
    let part = match partition(parts, &req) {
        Some(p) => p,
        None => return serde_json::json!({"ok": false, "error": "unknown ks"}),
    };

    match req["op"].as_str() {
        Some("put") => match req["value"].as_str() {
            Some(value) => match part.insert(key, value) {
                Ok(()) => serde_json::json!({"ok": true}),
                Err(e) => serde_json::json!({"ok": false, "error": e.to_string()}),
            },
            None => serde_json::json!({"ok": false, "error": "missing value"}),
        },
        Some("get") => match part.get(key) {
            Ok(Some(v)) => serde_json::json!({
                "ok": true,
                "found": true,
                "value": String::from_utf8_lossy(&v),
            }),
            Ok(None) => serde_json::json!({"ok": true, "found": false}),
            Err(e) => serde_json::json!({"ok": false, "error": e.to_string()}),
        },
        Some("delete") => match part.remove(key) {
            Ok(()) => serde_json::json!({"ok": true}),
            Err(e) => serde_json::json!({"ok": false, "error": e.to_string()}),
        },
        Some("list") => {
            let prefix = req["prefix"].as_str().unwrap_or("");
            let mut items = Vec::new();
            let mut bad: Option<String> = None;
            for pair in part.prefix(prefix) {
                match pair {
                    Ok((k, v)) => items.push(serde_json::json!({
                        "key": String::from_utf8_lossy(&k),
                        "value": String::from_utf8_lossy(&v),
                    })),
                    Err(e) => {
                        bad = Some(e.to_string());
                        break;
                    }
                }
            }
            match bad {
                Some(e) => serde_json::json!({"ok": false, "error": e}),
                None => serde_json::json!({"ok": true, "items": items}),
            }
        }
        other => serde_json::json!({"ok": false, "error": format!("unknown op: {other:?}")}),
    }
}
