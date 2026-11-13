# -*- coding: utf-8 -*-
import io

P = r"D:\projects\hermes\core\src\crypto.rs"
c = io.open(P, encoding="utf-8").read()

# KeyPair::from_public_and_private 也返回 Result → 闭包里用 ok()?
old = """    let pair = |x: &serde_json::Value| -> Option<KeyPair> {
        Some(KeyPair::from_public_and_private(
            &b64d(x["public"].as_str()?),
            &b64d(x["private"].as_str()?),
        ))
    };"""
new = """    let pair = |x: &serde_json::Value| -> Option<KeyPair> {
        Some(
            KeyPair::from_public_and_private(
                &b64d(x["public"].as_str()?),
                &b64d(x["private"].as_str()?),
            )
            .ok()?,
        )
    };"""
assert old in c
c = c.replace(old, new)

io.open(P, "w", encoding="utf-8", newline="\n").write(c)
print("patched pair load")
