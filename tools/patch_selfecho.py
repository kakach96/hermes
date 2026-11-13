# -*- coding: utf-8 -*-
import io

# transport: 本地回显自己的消息 + 发送时跳过自己
P = r"D:\projects\hermes\core\src\transport.rs"
c = io.open(P, encoding="utf-8").read()

old = """                        ClientFrame::Msg { text, dedup_id } => {
                            if !joined { continue; }
                            dispatch_outgoing(
                                &text, &dedup_id, &members, &mut established,
                                &mut fetching, &mut pending, &crypto_tx, &mut sink,
                            )
                            .await;
                        }"""
new = """                        ClientFrame::Msg { text, dedup_id } => {
                            if !joined { continue; }
                            // 自己的消息本地即时回显（不经过加密自发自收——
                            // 自会话是 Signal 里最拧巴的路径，v0 直接绕开）
                            let _ = ev_tx.send(ClientEvent::Chat {
                                from: me.clone(),
                                text: text.clone(),
                                dedup_id: dedup_id.clone(),
                                seq: cursor,
                            });
                            dispatch_outgoing(
                                &text, &dedup_id, &members, &me, &mut established,
                                &mut fetching, &mut pending, &crypto_tx, &mut sink,
                            )
                            .await;
                        }"""
assert old in c, "msg anchor"
c = c.replace(old, new)

old2 = """async fn dispatch_outgoing(
    text: &str,
    dedup_id: &str,
    members: &[String],
    established: &mut HashSet<String>,"""
new2 = """async fn dispatch_outgoing(
    text: &str,
    dedup_id: &str,
    members: &[String],
    me: &str,
    established: &mut HashSet<String>,"""
assert old2 in c, "dispatch sig anchor"
c = c.replace(old2, new2)

old3 = """    for peer in members {
        let peer = peer.clone();
        if established.contains(&peer) {"""
new3 = """    for peer in members {
        let peer = peer.clone();
        if peer == me {
            continue; // 自己的消息不走加密分发（本地已回显）
        }
        if established.contains(&peer) {"""
assert old3 in c, "dispatch self-skip anchor"
c = c.replace(old3, new3)

io.open(P, "w", encoding="utf-8", newline="\n").write(c)
print("transport patched")
