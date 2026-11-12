//! 赫尔墨斯 v0 —— fjall 存储 sidecar。
//!
//! 被 Erlang port 驱动：stdio 上的 4 字节大端长度帧 + JSON 载荷。
//! 单线程顺序处理（调用方 store Actor 本来就是顺序的）。
//!
//! 协议（请求/应答都是 JSON）：
//!   {"op":"put","key":...,"value":...}      -> {"ok":true}
//!   {"op":"get","key":...}                  -> {"ok":true,"found":true,"value":...} | {"ok":true,"found":false}
//!   {"op":"delete","key":...}               -> {"ok":true}
//!   错误一律 {"ok":false,"error":...}
//!
//! key 设计（server 侧约定）：
//!   cursor:<room subject>:<name>  -> 设备游标（stream seq 十进制字符串）
//!   members:<room subject>        -> 成员名单（JSON 字符串化数组）
//! 历史消息仍在 JetStream 流里，这里只存"元数据"；第二轮拉历史时再加
//! scan/范围操作。

use std::io::{Read, Write};

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
    let kv = match keyspace.open_partition("kv", Default::default()) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("open partition failed: {e}");
            std::process::exit(1);
        }
    };

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
            Ok(req) => handle(&kv, req),
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

fn handle(kv: &fjall::PartitionHandle, req: serde_json::Value) -> serde_json::Value {
    let key = req["key"].as_str().unwrap_or("");
    if key.is_empty() {
        return serde_json::json!({"ok": false, "error": "missing key"});
    }
    match req["op"].as_str() {
        Some("put") => match req["value"].as_str() {
            Some(value) => match kv.insert(key, value) {
                Ok(()) => serde_json::json!({"ok": true}),
                Err(e) => serde_json::json!({"ok": false, "error": e.to_string()}),
            },
            None => serde_json::json!({"ok": false, "error": "missing value"}),
        },
        Some("get") => match kv.get(key) {
            Ok(Some(v)) => serde_json::json!({
                "ok": true,
                "found": true,
                "value": String::from_utf8_lossy(&v),
            }),
            Ok(None) => serde_json::json!({"ok": true, "found": false}),
            Err(e) => serde_json::json!({"ok": false, "error": e.to_string()}),
        },
        Some("delete") => match kv.remove(key) {
            Ok(()) => serde_json::json!({"ok": true}),
            Err(e) => serde_json::json!({"ok": false, "error": e.to_string()}),
        },
        other => serde_json::json!({"ok": false, "error": format!("unknown op: {other:?}")}),
    }
}
