// Engine supervisor: starts, monitors and stops the bundled ebook2audiobook
// Python engine (Gradio server on 127.0.0.1:7860).
//
// Resource layout expected under the app bundle (Contents/Resources):
//   app/          python engine source (app.py, lib/, ...)
//   python_env/   relocatable conda env (python, ffmpeg, sox, tesseract, ...)
//   calibre.app/  embedded Calibre (ebook-convert)
//   seed/         first-run seed data (voices/, tessdata/)
//
// Writable state lives under E2A_HOME (~/Library/Application Support/ebook2audiobook).

use std::fs;
use std::io::{Read, Seek, SeekFrom, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub const ENGINE_HOST: &str = "127.0.0.1";
pub const ENGINE_PORT: u16 = 7860;
pub const ENGINE_URL: &str = "http://127.0.0.1:7860/";

const STARTUP_TIMEOUT_SECS: u64 = 300;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum State {
    Starting,
    Running,
    Failed,
}

pub struct EngineSupervisor {
    state: Arc<Mutex<State>>,
    child_pid: Mutex<Option<u32>>,
    child: Mutex<Option<Child>>,
    resources: PathBuf,
    e2a_home: PathBuf,
    log_path: PathBuf,
}

impl EngineSupervisor {
    pub fn new() -> Self {
        let home = home_dir();
        let e2a_home = std::env::var_os("E2A_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join("Library/Application Support/ebook2audiobook"));
        let log_path = home.join("Library/Logs/ebook2audiobook.log");
        EngineSupervisor {
            state: Arc::new(Mutex::new(State::Starting)),
            child_pid: Mutex::new(None),
            child: Mutex::new(None),
            resources: locate_resources(),
            e2a_home,
            log_path,
        }
    }

    pub fn state_name(&self) -> &'static str {
        match *self.state.lock().unwrap() {
            State::Starting => "starting",
            State::Running => "running",
            State::Failed => "failed",
        }
    }

    pub fn log_path(&self) -> &Path {
        &self.log_path
    }

    /// Tail of the engine log, for surfacing startup failures in the UI.
    pub fn log_tail(&self) -> String {
        let mut f = match fs::File::open(&self.log_path) {
            Ok(f) => f,
            Err(_) => return String::new(),
        };
        let len = f.seek(SeekFrom::End(0)).unwrap_or(0);
        let start = len.saturating_sub(4096);
        if f.seek(SeekFrom::Start(start)).is_err() {
            return String::new();
        }
        let mut buf = String::new();
        let _ = f.read_to_string(&mut buf);
        buf
    }

    pub fn start(&self) -> bool {
        self.shutdown();

        if let Err(e) = self.prepare_state_dirs() {
            eprintln!("engine: prepare_state_dirs failed: {e}");
            self.set_state(State::Failed);
            return false;
        }

        let python = self.resources.join("python_env/bin/python");
        let app_dir = self.resources.join("app");
        if !python.exists() || !app_dir.join("app.py").exists() {
            eprintln!(
                "engine: bundled engine not found under {}",
                self.resources.display()
            );
            self.set_state(State::Failed);
            return false;
        }

        if let Ok(mut log) = fs::OpenOptions::new().create(true).append(true).open(&self.log_path)
        {
            let _ = writeln!(log, "\n===== engine start {} =====", timestamp());
        }
        let open_log = || {
            fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&self.log_path)
                .map(Stdio::from)
                .unwrap_or(Stdio::null())
        };
        let log_file = open_log();

        let mut cmd = Command::new(&python);
        cmd.args(["-u", "app.py", "--script_mode", "native"]);
        cmd.current_dir(&app_dir);
        cmd.stdin(Stdio::null());
        cmd.stdout(open_log());
        cmd.stderr(log_file);
        self.apply_engine_env(&mut cmd);

        let child = match cmd.spawn() {
            Ok(c) => c,
            Err(e) => {
                eprintln!("engine: spawn failed: {e}");
                self.set_state(State::Failed);
                return false;
            }
        };
        let pid = child.id();
        *self.child.lock().unwrap() = Some(child);
        *self.child_pid.lock().unwrap() = Some(pid);
        self.set_state(State::Starting);
        eprintln!("engine: started pid {pid}");

        // Watcher: flips to Running once the Gradio port answers, or Failed
        // if the process dies or never comes up in time.
        let state = Arc::clone(&self.state);
        std::thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(STARTUP_TIMEOUT_SECS);
            loop {
                std::thread::sleep(Duration::from_millis(700));
                if !pid_alive(pid) {
                    eprintln!("engine: pid {pid} exited during startup");
                    *state.lock().unwrap() = State::Failed;
                    return;
                }
                if port_open() {
                    eprintln!("engine: port {ENGINE_PORT} is up");
                    *state.lock().unwrap() = State::Running;
                    return;
                }
                if Instant::now() >= deadline {
                    eprintln!("engine: startup timed out after {STARTUP_TIMEOUT_SECS}s");
                    *state.lock().unwrap() = State::Failed;
                }
            }
        });
        true
    }

    pub fn restart(&self) -> bool {
        self.start()
    }

    pub fn shutdown(&self) {
        if let Some(pid) = self.child_pid.lock().unwrap().take() {
            // SIGTERM the child tree first (gradio workers), then the engine.
            let _ = Command::new("/usr/bin/pkill")
                .args(["-TERM", "-P", &pid.to_string()])
                .status();
            let _ = Command::new("/bin/kill")
                .args(["-TERM", &pid.to_string()])
                .status();
            std::thread::sleep(Duration::from_millis(400));
            let _ = Command::new("/usr/bin/pkill")
                .args(["-KILL", "-P", &pid.to_string()])
                .status();
        }
        if let Some(mut child) = self.child.lock().unwrap().take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }

    fn set_state(&self, s: State) {
        *self.state.lock().unwrap() = s;
    }

    fn prepare_state_dirs(&self) -> std::io::Result<()> {
        for d in ["audiobooks", "ebooks", "models/tessdata", "run", "tmp", "voices"] {
            fs::create_dir_all(self.e2a_home.join(d))?;
        }
        if let Some(parent) = self.log_path.parent() {
            fs::create_dir_all(parent)?;
        }
        self.seed(
            &self.resources.join("seed/tessdata"),
            &self.e2a_home.join("models/tessdata"),
            "eng.traineddata",
        );
        self.seed(
            &self.resources.join("seed/voices"),
            &self.e2a_home.join("voices"),
            "eng/adult/male/KumarDahl.wav",
        );
        Ok(())
    }

    /// Copy seed data into E2A_HOME on first run (marker file must not exist).
    fn seed(&self, from: &Path, to: &Path, marker: &str) {
        if !from.exists() || to.join(marker).exists() {
            return;
        }
        eprintln!("engine: seeding {} -> {}", from.display(), to.display());
        #[cfg(target_os = "macos")]
        let ok = Command::new("/usr/bin/ditto")
            .arg(from)
            .arg(to)
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        #[cfg(not(target_os = "macos"))]
        let ok = copy_dir_recursive(from, to).is_ok();
        if !ok {
            eprintln!("engine: seeding failed for {}", from.display());
        }
    }

    fn apply_engine_env(&self, cmd: &mut Command) {
        let py_env = self.resources.join("python_env");
        let calibre_bin = self.resources.join("calibre.app/Contents/MacOS");
        let path = std::env::var("PATH").unwrap_or_default();
        cmd.env(
            "PATH",
            format!("{}:{}:{}", py_env.join("bin").display(), calibre_bin.display(), path),
        );
        cmd.env("E2A_BUNDLE", "1");
        cmd.env("E2A_HOME", &self.e2a_home);
        cmd.env("PYTHONUTF8", "1");
        cmd.env("PYTHONIOENCODING", "utf-8");
        let cacert = py_env.join("ssl/cacert.pem");
        if cacert.exists() {
            cmd.env("SSL_CERT_FILE", &cacert);
            cmd.env("REQUESTS_CA_BUNDLE", &cacert);
        }
        let fonts_conf = py_env.join("etc/fonts/fonts.conf");
        if fonts_conf.exists() {
            cmd.env("FONTCONFIG_FILE", &fonts_conf);
            if let Some(dir) = fonts_conf.parent() {
                cmd.env("FONTCONFIG_PATH", dir);
            }
        }
        cmd.env_remove("PYTHONHOME");
        cmd.env_remove("PYTHONPATH");
        cmd.env_remove("VIRTUAL_ENV");
        cmd.env_remove("CONDA_DEFAULT_ENV");
        cmd.env_remove("CONDA_PREFIX");
    }
}

fn pid_alive(pid: u32) -> bool {
    Command::new("/bin/kill")
        .arg("-0")
        .arg(pid.to_string())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn port_open() -> bool {
    use std::net::ToSocketAddrs;
    match format!("{ENGINE_HOST}:{ENGINE_PORT}")
        .to_socket_addrs()
        .ok()
        .and_then(|mut a| a.next())
    {
        Some(sa) => TcpStream::connect_timeout(&sa, Duration::from_millis(400)).is_ok(),
        None => false,
    }
}

fn locate_resources() -> PathBuf {
    if let Some(p) = std::env::var_os("E2A_RESOURCES") {
        return PathBuf::from(p);
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            // .app bundle layout: Contents/MacOS/<exe> -> Contents/Resources
            let cand = dir.join("../Resources");
            if cand.join("python_env").exists() {
                return cand;
            }
            let cand2 = dir.join("Resources");
            if cand2.join("python_env").exists() {
                return cand2;
            }
        }
    }
    // Dev fallback: desktop/engine-resources (gitignored, for local runs).
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../engine-resources")
}

fn home_dir() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

#[cfg(not(target_os = "macos"))]
fn copy_dir_recursive(src: &Path, dst: &Path) -> std::io::Result<()> {
    fs::create_dir_all(dst)?;
    for entry in fs::read_dir(src)? {
        let entry = entry?;
        let ty = entry.file_type()?;
        let to = dst.join(entry.file_name());
        if ty.is_dir() {
            copy_dir_recursive(&entry.path(), &to)?;
        } else {
            fs::copy(entry.path(), to)?;
        }
    }
    Ok(())
}

fn timestamp() -> String {
    // Local timestamp without pulling in a chrono dependency.
    match Command::new("/bin/date").arg("+%Y-%m-%d %H:%M:%S").output() {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).trim().to_string(),
        _ => String::from("unknown time"),
    }
}
