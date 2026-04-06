use std::{
    net::TcpStream,
    path::PathBuf,
    process::{Child, Command},
    sync::Mutex,
    time::{Duration, Instant},
};

use serde::Serialize;
use tauri::{Manager, State, WebviewUrl, WebviewWindowBuilder};

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

/// Holds the live npu_wrapper child process (if any).
/// Placed in Tauri's managed state so every command and the close-handler
/// can reach it.
pub struct BackendProcess(pub Mutex<Option<Child>>);

// SAFETY: Child is Send; Mutex<Option<Child>> is Send + Sync.

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Resolve the npu_wrapper binary next to the installed executable (release builds only).
#[cfg(not(debug_assertions))]
fn find_backend_binary() -> PathBuf {
    std::env::current_exe()
        .expect("current_exe")
        .parent()
        .expect("exe dir")
        .join("npu_wrapper.exe")
}

/// Resolve the workspace root in debug builds (project folder next to src-tauri).
#[cfg(debug_assertions)]
fn workspace_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("workspace root exists")
        .to_path_buf()
}

/// Returns true if port 8000 is accepting TCP connections.
fn is_backend_ready() -> bool {
    TcpStream::connect_timeout(
        &"127.0.0.1:8000".parse().unwrap(),
        Duration::from_millis(300),
    )
    .is_ok()
}

/// Block until port 8000 is ready or `timeout` elapses.
fn wait_for_backend(timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if is_backend_ready() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(500));
    }
    false
}

fn spawn_backend_child() -> Result<Child, String> {
    #[cfg(debug_assertions)]
    {
        let root = workspace_root();
        let run_script = root.join("run.ps1");
        if !run_script.exists() {
            return Err(format!("run.ps1 not found at {}", run_script.display()));
        }

        let model = root.join("models").join("Qwen2.5-0.5B-Instruct");
        if !model.exists() {
            return Err(format!("default model path not found at {}", model.display()));
        }

        return Command::new("powershell")
            .arg("-NoProfile")
            .arg("-ExecutionPolicy")
            .arg("Bypass")
            .arg("-File")
            .arg(run_script)
            .arg(model)
            .arg("--server")
            .arg("--port")
            .arg("8000")
            .current_dir(root)
            .spawn()
            .map_err(|e| format!("spawn via run.ps1 failed: {e}"));
    }

    #[cfg(not(debug_assertions))]
    {
        let binary = find_backend_binary();
        if !binary.exists() {
            return Err(format!(
                "npu_wrapper.exe not found at {}",
                binary.display()
            ));
        }

        return Command::new(&binary)
            .arg("--server")
            .arg("--port")
            .arg("8000")
            .spawn()
            .map_err(|e| format!("spawn failed: {e}"));
    }
}

// ---------------------------------------------------------------------------
// Tauri commands – callable from the JS frontend via window.__TAURI__.core.invoke()
// ---------------------------------------------------------------------------

#[derive(Debug, Serialize)]
pub struct BackendStatus {
    pub running: bool,
    pub pid: Option<u32>,
    /// true when port 8000 is accepting connections
    pub ready: bool,
}

/// Start npu_wrapper --server if not already running.
/// Waits up to 30 s for the port to open before returning.
#[tauri::command]
fn start_backend(state: State<'_, BackendProcess>) -> Result<BackendStatus, String> {
    let mut guard = state.0.lock().unwrap();

    // If a child is already alive, return its status.
    if let Some(ref mut child) = *guard {
        if child.try_wait().ok().flatten().is_none() {
            let ready = is_backend_ready();
            return Ok(BackendStatus {
                running: true,
                pid: Some(child.id()),
                ready,
            });
        }
        // process exited – fall through and restart
        *guard = None;
    }

    let child = spawn_backend_child()?;

    let pid = child.id();
    *guard = Some(child);
    drop(guard); // release the mutex before the blocking poll

    let ready = wait_for_backend(Duration::from_secs(30));
    Ok(BackendStatus {
        running: true,
        pid: Some(pid),
        ready,
    })
}

/// Kill the running npu_wrapper process.
#[tauri::command]
fn stop_backend(state: State<'_, BackendProcess>) -> Result<(), String> {
    let mut guard = state.0.lock().unwrap();
    if let Some(ref mut child) = *guard {
        child.kill().map_err(|e| e.to_string())?;
        let _ = child.wait();
    }
    *guard = None;
    Ok(())
}

/// Return the current process status without changing anything.
#[tauri::command]
fn backend_status(state: State<'_, BackendProcess>) -> BackendStatus {
    let mut guard = state.0.lock().unwrap();
    match *guard {
        None => BackendStatus {
            running: false,
            pid: None,
            ready: false,
        },
        Some(ref mut child) => {
            let running = child.try_wait().ok().flatten().is_none();
            let ready = running && is_backend_ready();
            BackendStatus {
                running,
                pid: Some(child.id()),
                ready,
            }
        }
    }
}

// ---------------------------------------------------------------------------
// App entry point
// ---------------------------------------------------------------------------

pub fn run() {
    eprintln!("[tauri] starting...");
    tauri::Builder::default()
        .manage(BackendProcess(Mutex::new(None)))
        .setup(|app| {
            // Explicitly create the main window. On some setups, relying only on
            // config-defined windows can lead to an immediate process exit.
            #[cfg(debug_assertions)]
            let window_url = WebviewUrl::External("http://127.0.0.1:5173".parse().unwrap());

            #[cfg(not(debug_assertions))]
            let window_url = WebviewUrl::App("index.html".into());

            let _ = WebviewWindowBuilder::new(app, "main", window_url)
                .title("NPU Companion")
                .inner_size(1280.0, 860.0)
                .min_inner_size(900.0, 600.0)
                .build();

            // Eager-start backend at app boot so UI controls are live immediately.
            // In dev mode tauri_dev.ps1 already launched the backend; skip the
            // spawn to avoid a double-instance race on port 8000.
            let state = app.state::<BackendProcess>();
            let mut guard = state.0.lock().unwrap();
            if guard.is_none() {
                if is_backend_ready() {
                    eprintln!("[tauri] backend already listening on :8000 – skipping auto-spawn");
                } else {
                    match spawn_backend_child() {
                        Ok(child) => {
                            let pid = child.id();
                            *guard = Some(child);
                            eprintln!("[tauri] backend spawn requested (pid={pid})");
                        }
                        Err(err) => {
                            eprintln!("[tauri] backend auto-start failed: {err}");
                        }
                    }
                }
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            start_backend,
            stop_backend,
            backend_status,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
    eprintln!("[tauri] run() returned");
}
