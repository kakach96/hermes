# -*- coding: utf-8 -*-
import io

P = r"D:\projects\hermes\core\src\crypto.rs"
c = io.open(P, encoding="utf-8").read()

# kyber KeyPair 的私钥字段名是 secret_key（不是 private_key）
c = c.replace(
    '"private": b64e(&m.kyber.private_key.serialize()),',
    '"private": b64e(&m.kyber.secret_key.serialize()),',
)

# kem::KeyPair::from_public_and_private 返回 KeyPair？查实际形状：
# 若它是 Result 则 .unwrap()；先按直接构造写，编译器会纠正。

io.open(P, "w", encoding="utf-8", newline="\n").write(c)
print("patched kyber field")
