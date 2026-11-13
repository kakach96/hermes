# -*- coding: utf-8 -*-
import io

P = r"D:\projects\hermes\core\src\crypto.rs"
c = io.open(P, encoding="utf-8").read()

# kem::KeyPair::from_public_and_private 返回 Result → .ok()?（Option 语义）
old = """        kyber: kem::KeyPair::from_public_and_private(
            &b64d(v["kyber_pre_key"]["public"].as_str()?),
            &b64d(v["kyber_pre_key"]["private"].as_str()?),
        ),"""
new = """        kyber: kem::KeyPair::from_public_and_private(
            &b64d(v["kyber_pre_key"]["public"].as_str()?),
            &b64d(v["kyber_pre_key"]["private"].as_str()?),
        )
        .ok()?,"""
assert old in c
c = c.replace(old, new)

io.open(P, "w", encoding="utf-8", newline="\n").write(c)
print("patched kem load")
