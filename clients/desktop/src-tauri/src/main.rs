//! hermes 桌面壳 —— 视图层零业务逻辑：业务全在 hermes-core，
//! 这里只做"命令进、事件出"的桥。

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::sync::Mutex;

use tauri::{Emitter, Manager, State};
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
    space: String,
    channel: String,
) -> Result<(), String> {
    // 先断旧的（重复连接时）
    if let Some(old) = state.0.lock().unwrap().take() {
        old.leave();
    }

    // 身份密钥持久化目录：同一名 = 同一身份，跨重启会话不失效
    let keys_dir = app
        .path()
        .app_data_dir()
        .map(|d| d.to_string_lossy().into_owned())
        .unwrap_or_else(|_| ".".into());
    std::fs::create_dir_all(&keys_dir).ok();

    let (handle, mut events) = hermes_core::connect(&url, &keys_dir).await?;
    handle.join(name.clone(), cursor, space, channel);
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

// ---- 空间/频道管理（fire-and-forget；结果经事件回流渲染）----

#[tauri::command]
fn create_space(state: State<'_, AppState>, space: String) -> Result<(), String> {
    match state.0.lock().unwrap().as_ref() {
        Some(handle) => {
            handle.create_space(space);
            Ok(())
        }
        None => Err("未连接".into()),
    }
}

#[tauri::command]
fn list_spaces(state: State<'_, AppState>) -> Result<(), String> {
    match state.0.lock().unwrap().as_ref() {
        Some(handle) => {
            handle.list_spaces();
            Ok(())
        }
        None => Err("未连接".into()),
    }
}

#[tauri::command]
fn create_channel(state: State<'_, AppState>, space: String, channel: String) -> Result<(), String> {
    match state.0.lock().unwrap().as_ref() {
        Some(handle) => {
            handle.create_channel(space, channel);
            Ok(())
        }
        None => Err("未连接".into()),
    }
}

#[tauri::command]
fn list_channels(state: State<'_, AppState>, space: String) -> Result<(), String> {
    match state.0.lock().unwrap().as_ref() {
        Some(handle) => {
            handle.list_channels(space);
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
        .invoke_handler(tauri::generate_handler![
            connect, send_message, disconnect, create_space, list_spaces, create_channel, list_channels
        ])
        .run(tauri::generate_context!())
        .expect("hermes desktop 启动失败");
}
