# -*- coding: utf-8 -*-
import io

P = r"D:\projects\hermes\core\src\crypto.rs"
c = io.open(P, encoding="utf-8").read()

# 1. spawn() gains keys_dir parameter and passes it into init
old1 = "pub fn spawn() -> (CryptoCmdTx, CryptoEventRx) {"
new1 = "pub fn spawn(keys_dir: String) -> (CryptoCmdTx, CryptoEventRx) {"
assert old1 in c
c = c.replace(old1, new1)

old2 = "                    state = init(name, &ev_tx);"
new2 = "                    state = init(name, &keys_dir, &ev_tx);"
assert old2 in c
c = c.replace(old2, new2)

# 2. load/save take &str for name
old3 = "let material = match load_key_material(name, keys_dir) {"
new3 = "let material = match load_key_material(&name, keys_dir) {"
assert old3 in c
c = c.replace(old3, new3)

old4 = "save_key_material(name, keys_dir, &m)?;"
new4 = "save_key_material(&name, keys_dir, &m)?;"
assert old4 in c
c = c.replace(old4, new4)

io.open(P, "w", encoding="utf-8", newline="\n").write(c)
print("patched")
