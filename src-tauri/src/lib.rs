use std::{net::TcpStream, sync::Mutex, thread, time::Duration};
use tauri::{Manager, RunEvent};
use tauri_plugin_shell::{process::CommandChild, ShellExt};

/// Live child processes. SurrealDB is a Tauri shell sidecar (single static
/// binary, externalBin). The Python API is a plain child process spawned from a
/// relocatable interpreter bundled under resources/ (python-build-standalone) —
/// it does not fit the single-file sidecar model.
#[derive(Default)]
struct Procs {
    surreal: Mutex<Option<CommandChild>>,
    api: Mutex<Option<std::process::Child>>,
}

/// Replace the splash contents with a diagnosable error so a failed startup
/// doesn't hang forever on a blank "Starting…" screen.
fn show_startup_error(handle: &tauri::AppHandle, msg: &str) {
    eprintln!("startup error: {msg}");
    if let Some(win) = handle.get_webview_window("main") {
        // JSON-encode to safely embed the message in the injected script.
        let js = serde_json::to_string(msg)
            .map(|m| format!("document.body.innerText = 'Open Notebook failed to start:\\n\\n' + {m};"))
            .unwrap_or_else(|_| "void 0;".into());
        let _ = win.eval(&js);
    }
}

/// Poll a localhost port until it accepts a TCP connection (or we give up).
fn wait_for_port(port: u16, tries: u32) -> bool {
    for _ in 0..tries {
        if TcpStream::connect(("127.0.0.1", port)).is_ok() {
            return true;
        }
        thread::sleep(Duration::from_millis(500));
    }
    false
}

/// Kill both sidecars. Idempotent: `.take()` ensures each is killed at most once,
/// so it is safe to call from both ExitRequested and Exit.
fn shutdown(app: &tauri::AppHandle) {
    if let Some(state) = app.try_state::<Procs>() {
        if let Some(child) = state.surreal.lock().unwrap().take() {
            eprintln!("[teardown] killing surrealdb");
            let _ = child.kill();
        }
        if let Some(child) = state.api.lock().unwrap().take() {
            // The API runs in its own process group (see spawn). Kill the whole
            // group so any grandchildren (content extraction, ffmpeg, …) die too.
            #[cfg(unix)]
            {
                let pid = child.id() as i32;
                eprintln!("[teardown] killing api process group {pid}");
                unsafe {
                    libc::kill(-pid, libc::SIGTERM);
                }
                // Give uvicorn a beat to shut down, then SIGKILL the group.
                thread::sleep(Duration::from_millis(300));
                unsafe {
                    libc::kill(-pid, libc::SIGKILL);
                }
            }
            let mut child = child;
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .manage(Procs::default())
        .setup(|app| {
            let handle = app.handle().clone();
            let data_dir = app.path().app_data_dir()?;
            std::fs::create_dir_all(&data_dir).ok();
            // resources/api -> "api" under the resource dir (see tauri.conf.json).
            let api_dir = app.path().resource_dir()?.join("api");

            thread::spawn(move || {
                let shell = handle.shell();

                // 1) SurrealDB (persistent rocksdb in the app data dir).
                let db = format!("rocksdb:{}", data_dir.join("on.db").display());
                match shell.sidecar("surrealdb").unwrap()
                    .args([
                        "start", "--user", "root", "--pass", "root",
                        "--bind", "127.0.0.1:8000", &db,
                    ])
                    .spawn()
                {
                    Ok((_rx, child)) => {
                        *handle.state::<Procs>().surreal.lock().unwrap() = Some(child);
                    }
                    Err(e) => { show_startup_error(&handle, &format!("could not start the database: {e}")); return; }
                }
                if !wait_for_port(8000, 60) {
                    show_startup_error(&handle, "the database did not become reachable on 127.0.0.1:8000 (is another instance already using that port?)");
                    return;
                }

                // 2) Python API. The encryption key must persist across launches —
                //    it encrypts stored provider credentials. Generate once, reuse.
                let key_path = data_dir.join("encryption.key");
                let enc_key = std::fs::read_to_string(&key_path).unwrap_or_else(|_| {
                    let k = random_key();
                    std::fs::write(&key_path, &k).ok();
                    k
                });

                // Use the generic python3 (a copy of python3.<minor>) so the bundled
                // interpreter's minor version isn't pinned here. See freeze-api.sh.
                let python = api_dir.join("python/bin/python3");
                let src = api_dir.join("src");
                let mut cmd = std::process::Command::new(&python);
                cmd.arg("run_api.py")
                    .current_dir(&src)
                    .env("API_HOST", "127.0.0.1")
                    .env("API_PORT", "5055")
                    // Single uvicorn process — no reload watcher child to orphan.
                    .env("API_RELOAD", "false")
                    .env("SURREAL_URL", "ws://127.0.0.1:8000/rpc")
                    .env("SURREAL_USER", "root")
                    .env("SURREAL_PASSWORD", "root")
                    .env("SURREAL_NAMESPACE", "open_notebook")
                    .env("SURREAL_DATABASE", "open_notebook")
                    .env("OPEN_NOTEBOOK_ENCRYPTION_KEY", enc_key)
                    // Spike 3: FastAPI reads CORS_ORIGINS (api/main.py). The bundled
                    // app's origin is tauri://localhost (macOS/Linux) /
                    // http://tauri.localhost (Windows); allow both explicitly.
                    .env("CORS_ORIGINS", "tauri://localhost,http://tauri.localhost");
                // Own process group so teardown can kill the whole tree.
                #[cfg(unix)]
                {
                    use std::os::unix::process::CommandExt;
                    cmd.process_group(0);
                }
                match cmd.spawn() {
                    Ok(child) => {
                        *handle.state::<Procs>().api.lock().unwrap() = Some(child);
                    }
                    Err(e) => { show_startup_error(&handle, &format!("could not start the API ({}): {e}", python.display())); return; }
                }
                if !wait_for_port(5055, 120) {
                    show_startup_error(&handle, "the API did not become reachable on 127.0.0.1:5055 (check Console logs; another process may be using that port)");
                    return;
                }
                // TODO(hardening): replace the TCP check above with an HTTP GET
                // to http://127.0.0.1:5055/health for true readiness.

                // 3) Stack is live — swap the window from the splash to the app.
                //    index.html is the exported root route; it client-redirects to
                //    /notebooks on hydration (Spike 2).
                if let Some(win) = handle.get_webview_window("main") {
                    let _ = win.eval("location.replace('index.html')");
                }
            });
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error building app")
        .run(|app, event| {
            // Tear down sidecars on either lifecycle event. macOS Cmd-Q / AppleScript
            // quit fires ExitRequested; Exit is the final backstop.
            match event {
                RunEvent::ExitRequested { .. } => {
                    eprintln!("[teardown] ExitRequested");
                    shutdown(app);
                }
                RunEvent::Exit => {
                    eprintln!("[teardown] Exit");
                    shutdown(app);
                }
                _ => {}
            }
        });
}

/// Generate a 256-bit key as hex, from the OS CSPRNG. This key encrypts stored
/// provider credentials, so it must not be predictable (a timestamp would be).
fn random_key() -> String {
    let mut buf = [0u8; 32];
    getrandom::getrandom(&mut buf).expect("OS CSPRNG unavailable");
    buf.iter().map(|b| format!("{b:02x}")).collect()
}
