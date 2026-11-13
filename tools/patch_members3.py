# -*- coding: utf-8 -*-
import io

# core: ServerFrame::Members + transport updates members list
P = r"D:\projects\hermes\core\src\codec.rs"
c = io.open(P, encoding="utf-8").read()

old = """    /// prekey_fetch 的回执；bundle 为空 = 对方无登记（不在线）
    PrekeyBundle {"""
new = """    /// 成员名单快照（presence 通道广播，加入/退房时更新）
    Members { members: Vec<String> },
    /// prekey_fetch 的回执；bundle 为空 = 对方无登记（不在线）
    PrekeyBundle {"""
assert old in c, "codec anchor"
c = c.replace(old, new)
io.open(P, "w", encoding="utf-8", newline="\n").write(c)
print("codec patched")

P2 = r"D:\projects\hermes\core\src\transport.rs"
c2 = io.open(P2, encoding="utf-8").read()

old_t = """                        ServerFrame::Notice { text } => {
                            let _ = ev_tx.send(ClientEvent::Notice { text });
                        }"""
new_t = """                        ServerFrame::Members { members: list } => {
                            // 名单活水：加入/退房时更新加密目标集合
                            members = list;
                        }
                        ServerFrame::Notice { text } => {
                            let _ = ev_tx.send(ClientEvent::Notice { text });
                        }"""
assert old_t in c2, "transport notice anchor"
c2 = c2.replace(old_t, new_t)

io.open(P2, "w", encoding="utf-8", newline="\n").write(c2)
print("transport patched")
