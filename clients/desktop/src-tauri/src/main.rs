//! hermes 桌面壳 —— 视图层零业务逻辑：业务全在 hermes-core，
//! 这里只做"命令进、事件出"的桥。
//!
//! 三段式会话：connect（只建 WS）→ login（确定身份）→ join_room（入频道）。
//! 大厅页的目录/建频道命令只要 login 过即可，不需要在房间里。

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::sync::Mutex;

use tauri::{Emitter, Manager, State};
use hermes_core::Handle;

struct Session {
    handle: Handle,
    name: String,
}

struct AppState(Mutex<Option<Session>>);

/// 建立 WS 连接（身份已在 URL ?name= 里，由 http::auth 认证后生成）。
/// 之后所有服务端事件经 "hermes" 事件推给窗口。
#[tauri::command]
async fn connect(
    app: tauri::AppHandle,
    state: State<'_, AppState>,
    url: String,
    name: String,
) -> Result<(), String> {
    // 先断旧的（重复连接时）
    if let Some(old) = state.0.lock().unwrap().take() {
        old.handle.logout();
    }

    // 身份密钥持久化目录：同一名 = 同一身份，跨重启会话不失效
    let keys_dir = app
        .path()
        .app_data_dir()
        .map(|d| d.to_string_lossy().into_owned())
        .unwrap_or_else(|_| ".".into());
    std::fs::create_dir_all(&keys_dir).ok();

    let (handle, mut events) = hermes_core::connect(&url, &keys_dir, &name).await?;
    *state.0.lock().unwrap() = Some(Session { handle, name });

    let emitter = app.clone();
    tokio::spawn(async move {
        while let Some(ev) = events.recv().await {
            let _ = emitter.emit("hermes", ev);
        }
    });
    Ok(())
}

/// HTTP 平面认证：登录（register=false）/ 注册（register=true）。
/// 成功返回带 ?name= 的 WS 地址，交给 connect。
#[tauri::command]
async fn auth(base: String, name: String, register: bool) -> Result<String, String> {
    let a = hermes_core::auth(&base, &name, register).await?;
    Ok(a.ws_url)
}

#[tauri::command]
fn join_room(
    state: State<'_, AppState>,
    cursor: u64,
    space: String,
    channel: String,
) -> Result<(), String> {
    let guard = state.0.lock().unwrap();
    match guard.as_ref() {
        Some(s) => {
            s.handle.join(s.name.clone(), cursor, space, channel);
            Ok(())
        }
        None => Err("未连接".into()),
    }
}

#[tauri::command]
fn leave_room(state: State<'_, AppState>) -> Result<(), String> {
    match state.0.lock().unwrap().as_ref() {
        Some(s) => {
            s.handle.leave_room();
            Ok(())
        }
        None => Err("未连接".into()),
    }
}

/// 退出登录 = 真正断开 WS
#[tauri::command]
fn logout(state: State<'_, AppState>) {
    if let Some(s) = state.0.lock().unwrap().take() {
        s.handle.logout();
    }
}

#[tauri::command]
fn send_message(state: State<'_, AppState>, text: String) -> Result<(), String> {
    match state.0.lock().unwrap().as_ref() {
        Some(s) => {
            s.handle.send_text(text);
            Ok(())
        }
        None => Err("未连接".into()),
    }
}

// ---- 空间/频道管理（fire-and-forget；结果经事件回流渲染）----

#[tauri::command]
fn create_space(state: State<'_, AppState>, space: String) -> Result<(), String> {
    match state.0.lock().unwrap().as_ref() {
        Some(s) => {
            s.handle.create_space(space);
            Ok(())
        }
        None => Err("未连接".into()),
    }
}

#[tauri::command]
fn list_spaces(state: State<'_, AppState>) -> Result<(), String> {
    match state.0.lock().unwrap().as_ref() {
        Some(s) => {
            s.handle.list_spaces();
            Ok(())
        }
        None => Err("未连接".into()),
    }
}

#[tauri::command]
fn create_channel(state: State<'_, AppState>, space: String, channel: String) -> Result<(), String> {
    match state.0.lock().unwrap().as_ref() {
        Some(s) => {
            s.handle.create_channel(space, channel);
            Ok(())
        }
        None => Err("未连接".into()),
    }
}

#[tauri::command]
fn list_channels(state: State<'_, AppState>, space: String) -> Result<(), String> {
    match state.0.lock().unwrap().as_ref() {
        Some(s) => {
            s.handle.list_channels(space);
            Ok(())
        }
        None => Err("未连接".into()),
    }
}

fn main() {
    tauri::Builder::default()
        .manage(AppState(Mutex::new(None)))
        .invoke_handler(tauri::generate_handler![
            connect, auth, join_room, leave_room, logout, send_message,
            create_space, list_spaces, create_channel, list_channels
        ])
        .run(tauri::generate_context!())
        .expect("hermes desktop 启动失败");
}
