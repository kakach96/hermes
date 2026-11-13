# -*- coding: utf-8 -*-
import io

# transport.rs: connect() gains keys_dir; tauri main.rs passes it
P = r"D:\projects\hermes\core\src\transport.rs"
c = io.open(P, encoding="utf-8").read()

old1 = """pub async fn connect(
    url: &str,
) -> Result<(Handle, mpsc::UnboundedReceiver<ClientEvent>), String> {
    let (ws, _resp) = tokio_tungstenite::connect_async(url)
        .await
        .map_err(|e| format!("连接失败: {e}"))?;

    // crypto 线程：明文/密文转换全部发生在那条线程里，密钥不出界
    let (crypto_tx, mut crypto_rx) = crypto::spawn();"""
new1 = """pub async fn connect(
    url: &str,
    keys_dir: &str,
) -> Result<(Handle, mpsc::UnboundedReceiver<ClientEvent>), String> {
    let (ws, _resp) = tokio_tungstenite::connect_async(url)
        .await
        .map_err(|e| format!("连接失败: {e}"))?;

    // crypto 线程：明文/密文转换全部发生在那条线程里，密钥不出界
    let (crypto_tx, mut crypto_rx) = crypto::spawn(keys_dir.to_string());"""
assert old1 in c
c = c.replace(old1, new1)
io.open(P, "w", encoding="utf-8", newline="\n").write(c)

# tauri main.rs: pass app data dir
P2 = r"D:\projects\hermes\clients\desktop\src-tauri\src\main.rs"
c2 = io.open(P2, encoding="utf-8").read()

old2 = """    let (handle, mut events) = hermes_core::connect(&url).await?;"""
new2 = """    // 身份密钥持久化目录：同一名 = 同一身份，跨重启会话不失效
    let keys_dir = app
        .path()
        .app_data_dir()
        .map(|d| d.to_string_lossy().into_owned())
        .unwrap_or_else(|_| ".".into());
    std::fs::create_dir_all(&keys_dir).ok();

    let (handle, mut events) = hermes_core::connect(&url, &keys_dir).await?;"""
assert old2 in c2
c2 = c2.replace(old2, new2)

old3 = "use tauri::{Emitter, State};"
new3 = "use tauri::{Emitter, Manager, State};"
assert old3 in c2
c2 = c2.replace(old3, new3)

io.open(P2, "w", encoding="utf-8", newline="\n").write(c2)
print("patched transport + tauri")
