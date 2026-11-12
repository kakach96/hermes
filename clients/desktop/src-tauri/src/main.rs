//! hermes 桌面壳 —— 视图层零业务逻辑：业务全在 hermes-core，
//! 这里只做"命令进、事件出"的桥。

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::sync::Mutex;

use tauri::{Emitter, State};
use hermes_core::Handle;

struct AppState(Mutex<Option<Handle>>);

/// 连接 + 入房。之后所有服务端事件经 "hermes" 事件推给窗口。
#[tauri::command]
async fn connect(
    app: tauri::AppHandle,
    state: State<'_, AppState>,
    url: String,
    name: String,
    cursor: u64,
) -> Result<(), String> {
    // 先断旧的（重复连接时）
    if let Some(old) = state.0.lock().unwrap().take() {
        old.leave();
    }

    let (handle, mut events) = hermes_core::connect(&url).await?;
    handle.join(name.clone(), cursor);
    *state.0.lock().unwrap() = Some(handle);

    let emitter = app.clone();
    tokio::spawn(async move {
        while let Some(ev) = events.recv().await {
            let _ = emitter.emit("hermes", ev);
        }
    });
    Ok(())
}

#[tauri::command]
fn send_message(state: State<'_, AppState>, text: String) -> Result<(), String> {
    match state.0.lock().unwrap().as_ref() {
        Some(handle) => {
            handle.send_text(text);
            Ok(())
        }
        None => Err("未连接".into()),
    }
}

#[tauri::command]
fn disconnect(state: State<'_, AppState>) {
    if let Some(handle) = state.0.lock().unwrap().take() {
        handle.leave();
    }
}

fn main() {
    tauri::Builder::default()
        .manage(AppState(Mutex::new(None)))
        .invoke_handler(tauri::generate_handler![connect, send_message, disconnect])
        .run(tauri::generate_context!())
        .expect("hermes desktop 启动失败");
}
