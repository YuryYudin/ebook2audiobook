mod engine;

use serde::Serialize;
use std::process::Command;
use tauri::{Manager, RunEvent, State};

pub struct AppState {
    engine: engine::EngineSupervisor,
}

#[derive(Serialize)]
pub struct EngineStatus {
    state: &'static str,
    url: &'static str,
    log_path: String,
    log_tail: String,
}

#[tauri::command]
fn engine_status(state: State<AppState>) -> EngineStatus {
    EngineStatus {
        state: state.engine.state_name(),
        url: engine::ENGINE_URL,
        log_path: state.engine.log_path().to_string_lossy().into_owned(),
        log_tail: state.engine.log_tail(),
    }
}

#[tauri::command]
fn restart_engine(state: State<AppState>) -> bool {
    state.engine.restart()
}

#[tauri::command]
fn open_logs(state: State<AppState>) -> bool {
    Command::new("/usr/bin/open")
        .arg("-t")
        .arg(state.engine.log_path())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Open the engine UI in the system browser. URL is validated to be the
/// engine's own address — never an arbitrary string from the page.
#[tauri::command]
fn open_engine_in_browser() -> bool {
    Command::new("/usr/bin/open")
        .arg(engine::ENGINE_URL)
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

pub fn run() {
    tauri::Builder::default()
        .manage(AppState {
            engine: engine::EngineSupervisor::new(),
        })
        .invoke_handler(tauri::generate_handler![
            engine_status,
            restart_engine,
            open_logs,
            open_engine_in_browser
        ])
        .setup(|app| {
            let state = app.state::<AppState>();
            state.engine.start();
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|app_handle, event| {
            if let RunEvent::Exit = event {
                app_handle.state::<AppState>().engine.shutdown();
            }
        });
}
