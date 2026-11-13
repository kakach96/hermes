# -*- coding: utf-8 -*-
import io

# tests: spawn() now needs a keys dir; use a temp dir under target
P = r"D:\projects\hermes\core\src\crypto.rs"
c = io.open(P, encoding="utf-8").read()

old1 = "        let (alice_tx, mut alice_ev) = spawn();"
new1 = '        let keys_dir = std::env::temp_dir().join("hermes-test-keys").to_string_lossy().into_owned();\n        let (alice_tx, mut alice_ev) = spawn(keys_dir.clone());'
assert old1 in c
c = c.replace(old1, new1)

old2 = "        let (bob_tx, mut bob_ev) = spawn();"
new2 = "        let (bob_tx, mut bob_ev) = spawn(keys_dir.clone());"
assert old2 in c
c = c.replace(old2, new2)

io.open(P, "w", encoding="utf-8", newline="\n").write(c)
print("patched test spawn")
