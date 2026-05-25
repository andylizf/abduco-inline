use std::collections::VecDeque;
use std::env;
use std::ffi::CString;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::mem;
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

static WINCH_PENDING: AtomicBool = AtomicBool::new(false);

/// Set by SIGTERM/SIGINT handlers. server_loop polls this every tick and
/// initiates graceful shutdown (forwards SIGTERM to the inner process group,
/// drains client queues, removes the socket file) when true. Replaces the
/// default `terminate` action which left the socket file orphaned and surfaced
/// to clients as ECONNREFUSED.
static SHUTDOWN_REQUESTED: AtomicBool = AtomicBool::new(false);

/// Per-server log path, set by the server child immediately after fork so the
/// panic hook and signal-triggered shutdown path can write forensic entries
/// even though stdio is redirected to /dev/null. Format: lines of
/// `<ISO_TIMESTAMP_UTC> <PID> <KIND> <MSG>\n`. Best-effort: any IO error is
/// silently dropped to avoid recursive failure.
static SERVER_LOG_PATH: OnceLock<PathBuf> = OnceLock::new();

extern "C" fn handle_sigwinch(_sig: libc::c_int) {
    WINCH_PENDING.store(true, Ordering::Relaxed);
}

extern "C" fn handle_shutdown_signal(_sig: libc::c_int) {
    SHUTDOWN_REQUESTED.store(true, Ordering::Relaxed);
}

const MSG_CONTENT: u32 = 0;
const MSG_ATTACH: u32 = 1;
const MSG_DETACH: u32 = 2;
const MSG_RESIZE: u32 = 3;
const MSG_EXIT: u32 = 4;
const MSG_PID: u32 = 5;
const MSG_DUMP: u32 = 6;
const MSG_DUMP_END: u32 = 7;
const MSG_SEND_KEYS: u32 = 8;

const CLIENT_READONLY: u32 = 1 << 0;
const CLIENT_LOWPRIORITY: u32 = 1 << 1;
const HISTORY_CAP: usize = 1024 * 1024;
const MAX_PAYLOAD: usize = 4096 - 8;
// Per-client outbound buffer cap. Linux Unix-stream SO_SNDBUF default is
// ~208 KB; HISTORY_CAP is 1 MiB; broadcast traffic + replay must coexist for
// idle attach clients without disconnecting them on a single full-buffer hit.
// 16 MiB is an inferred cap that covers history replay + a generous broadcast
// backlog without unbounded growth.
const SEND_QUEUE_CAP: usize = 16 * 1024 * 1024;
// Once a client has been queued an MSG_EXIT or MSG_DUMP_END packet, give it
// up to this long to drain before forcing a disconnect.
const EXIT_DRAIN_DEADLINE: Duration = Duration::from_secs(5);

#[derive(Clone, Copy, PartialEq, Eq)]
enum Action {
    Attach,
    AttachOrCreate,
    CreateAttach,
    Create,
    Dump,
    SendKeys,
}

struct Opts {
    action: Option<Action>,
    name: Option<String>,
    rest: Vec<String>,
    literal: bool,
    max_bytes: usize,
    max_lines: usize,
    flags: u32,
    quiet: bool,
    force: bool,
    passthrough: bool,
    detach_key: u8,
}

#[derive(Clone)]
struct Packet {
    typ: u32,
    payload: Vec<u8>,
}

struct Client {
    stream: UnixStream,
    buf: Vec<u8>,
    attached: bool,
    flags: u32,
    disconnected: bool,
    /// Outbound bytes that didn't fit into the kernel send buffer yet.
    /// We retry these on every server tick instead of disconnecting the
    /// client mid-packet (which corrupts the wire and surfaces as
    /// "exited due to I/O errors" on the attach side).
    send_queue: VecDeque<u8>,
    /// When set, the client has already been queued a terminal packet
    /// (MSG_EXIT or MSG_DUMP_END) and should be disconnected as soon as
    /// the queue drains, or after EXIT_DRAIN_DEADLINE — whichever first.
    close_after_drain: Option<Instant>,
}

struct History {
    bytes: VecDeque<u8>,
}

impl History {
    fn new() -> Self {
        Self {
            bytes: VecDeque::with_capacity(HISTORY_CAP),
        }
    }

    fn append(&mut self, data: &[u8]) {
        if data.len() >= HISTORY_CAP {
            self.bytes.clear();
            self.bytes
                .extend(data[data.len() - HISTORY_CAP..].iter().copied());
            return;
        }
        while self.bytes.len() + data.len() > HISTORY_CAP {
            self.bytes.pop_front();
        }
        self.bytes.extend(data.iter().copied());
    }

    fn snapshot(&self) -> Vec<u8> {
        self.bytes.iter().copied().collect()
    }
}

/// Overwrite the server process's own argv so `pkill -f <pattern>` cannot
/// match user-supplied content (e.g. an agent's bootstrap prompt) that was
/// passed on the original lich command line. Without this, the prompt sits in
/// `/proc/<server-pid>/cmdline` and any user-issued `pkill -f <prompt-fragment>`
/// SIGTERMs the lich server itself (root cause of the
/// lich-crash-spd-session incident, 2026-05-17). Equivalent in spirit to
/// tmux's short-and-fixed server argv. Inner forkpty children (e.g. the
/// codex/claude process) are unaffected; killing those still triggers the
/// normal child-exit → graceful shutdown path.
#[cfg(target_os = "linux")]
fn shorten_server_proctitle(session_name: &str) {
    let Some((arg_start, arg_end)) = proc_self_argv_region() else {
        return;
    };
    let total_len = arg_end.saturating_sub(arg_start);
    if total_len < 2 {
        return;
    }
    let title = format!("lich-server[{session_name}]");
    let bytes = title.as_bytes();
    let write_len = bytes.len().min(total_len - 1);

    // Zero the entire argv region, then write the new title. Even if the
    // PR_SET_MM call below is rejected by the container's seccomp profile,
    // the cmdline content is now NUL-padded after our short title, so
    // pkill -f against the original prompt will not match.
    unsafe {
        std::ptr::write_bytes(arg_start as *mut u8, 0, total_len);
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), arg_start as *mut u8, write_len);
    }

    // Tell the kernel the new arg_end so /proc/<pid>/cmdline reports the
    // shorter region (cosmetic; PR_SET_MM may require CAP_SYS_RESOURCE which
    // can be missing inside containers). Failure is non-fatal.
    let new_arg_end = arg_start + write_len + 1;
    unsafe {
        libc::prctl(
            libc::PR_SET_MM,
            libc::PR_SET_MM_ARG_END as libc::c_ulong,
            new_arg_end as libc::c_ulong,
            0_u64,
            0_u64,
        );
    }

    // Also set the short comm field (15-char limit) so `top`, `ps -o comm`,
    // and `pkill <name>` (without -f) target the right thing.
    if let Ok(short) = CString::new("lich-server") {
        unsafe {
            libc::prctl(
                libc::PR_SET_NAME,
                short.as_ptr() as libc::c_ulong,
                0_u64,
                0_u64,
                0_u64,
            );
        }
    }
}

#[cfg(target_os = "linux")]
fn proc_self_argv_region() -> Option<(usize, usize)> {
    // /proc/self/stat fields per proc(5): pid (1), comm (2, parenthesised and
    // may contain spaces), state (3), ..., arg_start (48), arg_end (49).
    // We must locate the last ')' to anchor field 3, because comm can embed
    // ')' or whitespace if a binary renames itself.
    let stat = fs::read_to_string("/proc/self/stat").ok()?;
    let after_comm = stat.rfind(')')?;
    let rest = &stat[after_comm + 1..];
    let fields: Vec<&str> = rest.split_ascii_whitespace().collect();
    // After the last ')', index 0 = state (field 3), so arg_start (field 48)
    // is at index 48 - 3 = 45; arg_end (field 49) at 46.
    let arg_start = fields.get(45)?.parse::<usize>().ok()?;
    let arg_end = fields.get(46)?.parse::<usize>().ok()?;
    if arg_end > arg_start { Some((arg_start, arg_end)) } else { None }
}

#[cfg(not(target_os = "linux"))]
fn shorten_server_proctitle(_session_name: &str) {
    // macOS (and other non-Linux Unixes) intentionally noop:
    //   * macOS does not ship setproctitle(3) in libSystem — Apple did not
    //     port the BSD API, despite the kernel exposing proc_set_name() for
    //     the short comm field only (15 bytes, like PR_SET_NAME).
    //   * Linking a private libbsd / libsetproctitle would force every
    //     Mac user to install a Homebrew formula just to build lich.
    //   * The crash this fix targets was reported on Linux containers; macOS
    //     CI exists only for parity. Leaving this empty keeps macOS users at
    //     the previous (pre-fix) safety level: vulnerable to pkill -f against
    //     the original prompt, but no worse than before.
    // If a macOS-specific path is ever needed, the closest shim is to use
    // sysctl KERN_PROCNAME + dlsym("setproctitle") from a private framework;
    // not worth the build-system complexity here.
}

/// Derive the per-server log path: `<socket_dir>/<socket_basename>.log`.
/// For socket `~/.lich/foo@hostname` the log goes to
/// `~/.lich/foo@hostname.log` (same dir, same permissions model).
fn derive_server_log_path(socket_path: &Path) -> PathBuf {
    let mut p = socket_path.to_path_buf();
    let new_name = match p.file_name().and_then(|n| n.to_str()) {
        Some(s) => format!("{s}.log"),
        None => "lich.log".to_string(),
    };
    p.set_file_name(new_name);
    p
}

/// Best-effort append to the server log. Silent on any IO error to avoid
/// recursive failures from inside a panic hook or signal-triggered path.
/// Format: `<ISO_TS_UTC> <PID> <KIND> <MSG>\n`.
fn server_log(kind: &str, msg: &str) {
    let Some(log_path) = SERVER_LOG_PATH.get() else {
        return;
    };
    let ts = iso_utc_now();
    let pid = unsafe { libc::getpid() };
    let _ = OpenOptions::new()
        .append(true)
        .create(true)
        .mode(0o600)
        .open(log_path)
        .and_then(|mut f| writeln!(f, "{ts} {pid} {kind} {msg}"));
}

fn iso_utc_now() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as libc::time_t)
        .unwrap_or(0);
    let mut tm: libc::tm = unsafe { mem::zeroed() };
    let rc = unsafe { libc::gmtime_r(&secs, &mut tm) };
    if rc.is_null() {
        return "unknown".to_string();
    }
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        tm.tm_year + 1900,
        tm.tm_mon + 1,
        tm.tm_mday,
        tm.tm_hour,
        tm.tm_min,
        tm.tm_sec,
    )
}

/// RAII socket-file cleanup. Drop runs on every code path that unwinds:
/// normal return from server_loop, propagated `?` errors, and Rust panic
/// unwinds. Does NOT run on `process::exit`, `process::abort`, SIGKILL,
/// SIGSEGV, SIGBUS, or kernel OOM kill — for those, the next attaching
/// client's `connect_session` removes the orphan on ECONNREFUSED.
struct SocketGuard {
    path: PathBuf,
    armed: bool,
}

impl SocketGuard {
    fn new(path: PathBuf) -> Self {
        Self { path, armed: true }
    }
}

impl Drop for SocketGuard {
    fn drop(&mut self) {
        if self.armed {
            let _ = fs::remove_file(&self.path);
        }
    }
}

/// Install a panic hook that logs the panic location and payload before the
/// runtime unwinds. The unwind itself causes `SocketGuard::drop` to fire,
/// removing the socket file even on a crash.
fn install_server_panic_hook() {
    std::panic::set_hook(Box::new(|info| {
        let location = info
            .location()
            .map(|l| format!("{}:{}", l.file(), l.line()))
            .unwrap_or_else(|| "?".to_string());
        let payload = info
            .payload_as_str()
            .unwrap_or("<non-string panic payload>");
        server_log("panic", &format!("at {location} payload={payload}"));
    }));
}

fn main() {
    if let Err(err) = real_main() {
        eprintln!("lich: {err}");
        process::exit(1);
    }
}

fn real_main() -> io::Result<()> {
    let mut opts = parse_args()?;
    if opts.name.is_some()
        && !isatty(libc::STDIN_FILENO)
        && !matches!(opts.action, Some(Action::Dump | Action::SendKeys))
    {
        opts.passthrough = true;
        opts.quiet = true;
        opts.flags |= CLIENT_LOWPRIORITY;
        if opts.action.is_none() {
            opts.action = Some(Action::Attach);
        }
    }

    if opts.action.is_none() && opts.name.is_none() {
        return list_sessions();
    }

    let action = opts.action.ok_or_else(usage_err)?;
    let name = opts.name.clone().ok_or_else(usage_err)?;

    match action {
        Action::Create => create_session(&name, command_args(&opts)?, true, &opts),
        Action::CreateAttach => {
            create_session(&name, command_args(&opts)?, true, &opts)?;
            attach_session(&name, true, &opts)
        }
        Action::Attach => attach_session(&name, true, &opts),
        Action::AttachOrCreate => {
            if session_alive(&name) {
                attach_session(&name, true, &opts)
            } else {
                create_session(&name, command_args(&opts)?, true, &opts)?;
                attach_session(&name, true, &opts)
            }
        }
        Action::Dump => dump_session(&name, opts.max_bytes, opts.max_lines),
        Action::SendKeys => send_keys_session(&name, &opts.rest, opts.literal),
    }
}

fn parse_args() -> io::Result<Opts> {
    let mut args = env::args().skip(1);
    let mut opts = Opts {
        action: None,
        name: None,
        rest: Vec::new(),
        literal: false,
        max_bytes: 0,
        max_lines: 0,
        flags: 0,
        quiet: false,
        force: false,
        passthrough: false,
        detach_key: 0x1c,
    };

    while let Some(arg) = args.next() {
        if !arg.starts_with('-') || arg == "-" {
            opts.name = Some(arg);
            opts.rest.extend(args);
            break;
        }
        match arg.as_str() {
            "-a" => opts.action = Some(Action::Attach),
            "-A" => opts.action = Some(Action::AttachOrCreate),
            "-c" => opts.action = Some(Action::CreateAttach),
            "-n" => opts.action = Some(Action::Create),
            "-d" => opts.action = Some(Action::Dump),
            "-K" => opts.action = Some(Action::SendKeys),
            "-x" => opts.literal = true,
            "-q" => opts.quiet = true,
            "-f" => opts.force = true,
            "-p" => opts.passthrough = true,
            "-r" => opts.flags |= CLIENT_READONLY,
            "-l" => opts.flags |= CLIENT_LOWPRIORITY,
            "-v" => {
                println!("lich-rust-0.1.0");
                process::exit(0);
            }
            "-N" => opts.max_bytes = parse_size(args.next())?,
            "-L" => opts.max_lines = parse_size(args.next())?,
            "-e" => {
                let key = args.next().ok_or_else(usage_err)?;
                opts.detach_key = parse_detach_key(&key);
            }
            _ if arg.starts_with("-N") && arg.len() > 2 => {
                opts.max_bytes = parse_size(Some(arg[2..].to_string()))?
            }
            _ if arg.starts_with("-L") && arg.len() > 2 => {
                opts.max_lines = parse_size(Some(arg[2..].to_string()))?
            }
            _ => return Err(usage_err()),
        }
    }

    if opts.max_bytes != 0 && opts.max_lines != 0 {
        return Err(usage_err());
    }
    if opts.action != Some(Action::Dump) && (opts.max_bytes != 0 || opts.max_lines != 0) {
        return Err(usage_err());
    }
    if opts.action != Some(Action::SendKeys) && opts.literal {
        return Err(usage_err());
    }
    if opts.action == Some(Action::Dump) && !opts.rest.is_empty() {
        return Err(usage_err());
    }
    if opts.action == Some(Action::SendKeys) && opts.rest.is_empty() {
        return Err(usage_err());
    }
    Ok(opts)
}

fn usage_err() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidInput,
        "usage: lich [-a|-A|-c|-n|-d|-K] [-N bytes] [-L lines] [-x] [-p] [-r] [-q] [-l] [-f] [-e detachkey] name [command|keys...]",
    )
}

fn parse_size(value: Option<String>) -> io::Result<usize> {
    value
        .ok_or_else(usage_err)?
        .parse::<usize>()
        .map_err(|_| usage_err())
}

fn parse_detach_key(key: &str) -> u8 {
    let bytes = key.as_bytes();
    if bytes.len() >= 2 && bytes[0] == b'^' {
        bytes[1] & 0x1f
    } else {
        bytes.first().copied().unwrap_or(0x1c)
    }
}

fn command_args(opts: &Opts) -> io::Result<Vec<String>> {
    if !opts.rest.is_empty() {
        return Ok(opts.rest.clone());
    }
    if let Ok(cmd) = env::var("ABDUCO_CMD") {
        return Ok(vec!["/bin/sh".into(), "-c".into(), cmd]);
    }
    Ok(vec!["dvtm".into()])
}

fn socket_path(name: &str) -> io::Result<PathBuf> {
    if name.starts_with('/') {
        return Ok(PathBuf::from(name));
    }
    if name.starts_with("./") || name.starts_with("../") {
        return Ok(env::current_dir()?.join(name));
    }
    let host = hostname();
    let base = socket_base_dir()?;
    Ok(base.join(format!("{name}@{host}")))
}

fn socket_base_dir() -> io::Result<PathBuf> {
    let user = env::var("USER").unwrap_or_else(|_| unsafe { libc::getuid().to_string() });
    let candidates = [
        env::var_os("ABDUCO_SOCKET_DIR").map(PathBuf::from),
        env::var_os("HOME").map(|h| PathBuf::from(h).join(".lich")),
        env::var_os("TMPDIR").map(|t| PathBuf::from(t).join("lich").join(&user)),
        Some(PathBuf::from("/tmp").join("lich").join(&user)),
    ];
    for dir in candidates.into_iter().flatten() {
        if fs::create_dir_all(&dir).is_ok() {
            let _ = fs::set_permissions(&dir, fs::Permissions::from_mode(0o700));
            return Ok(dir);
        }
    }
    Err(io::Error::new(
        io::ErrorKind::NotFound,
        "no socket directory",
    ))
}

fn hostname() -> String {
    let mut buf = [0u8; 255];
    let rc = unsafe { libc::gethostname(buf.as_mut_ptr().cast(), buf.len()) };
    if rc == 0 {
        let len = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
        String::from_utf8_lossy(&buf[..len]).into_owned()
    } else {
        "localhost".into()
    }
}

fn connect_session(name: &str) -> io::Result<UnixStream> {
    let path = socket_path(name)?;
    UnixStream::connect(&path).inspect_err(|err| {
        if err.kind() == io::ErrorKind::ConnectionRefused {
            let _ = fs::remove_file(&path);
        }
    })
}

fn session_alive(name: &str) -> bool {
    let Ok(mut stream) = connect_session(name) else {
        return false;
    };
    recv_packet_blocking(&mut stream).is_ok_and(|pkt| pkt.typ == MSG_PID)
}

fn create_session(name: &str, cmd: Vec<String>, read_pty: bool, _opts: &Opts) -> io::Result<()> {
    if session_alive(name) {
        return Err(io::Error::new(io::ErrorKind::AddrInUse, "session exists"));
    }
    let path = socket_path(name)?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let _ = fs::remove_file(&path);
    let listener = UnixListener::bind(&path)?;
    let _ = fs::set_permissions(&path, fs::Permissions::from_mode(0o600));

    let mut sync_pipe = [0; 2];
    if unsafe { libc::pipe(sync_pipe.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    let winsize = current_winsize();
    let fork_result = unsafe { libc::fork() };
    if fork_result < 0 {
        unsafe {
            libc::close(sync_pipe[0]);
            libc::close(sync_pipe[1]);
        }
        return Err(io::Error::last_os_error());
    }
    if fork_result > 0 {
        unsafe {
            libc::close(sync_pipe[1]);
        }
        drop(listener);
        let result = read_startup_status(sync_pipe[0]);
        if result.is_err() {
            let _ = fs::remove_file(&path);
        }
        return result;
    }

    unsafe {
        libc::close(sync_pipe[0]);
        libc::setsid();
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
        libc::signal(libc::SIGHUP, libc::SIG_IGN);
        // P1: catch SIGTERM/SIGINT so server_loop can run graceful shutdown
        // (drain client queues, remove socket file) instead of being terminated
        // mid-write and leaving an orphan socket. Handler only sets an atomic
        // flag (signal-safe); the loop polls it.
        libc::signal(
            libc::SIGTERM,
            handle_shutdown_signal as *const () as libc::sighandler_t,
        );
        libc::signal(
            libc::SIGINT,
            handle_shutdown_signal as *const () as libc::sighandler_t,
        );
    }
    // P0: shrink the server's own argv so `pkill -f <prompt>` cannot match.
    shorten_server_proctitle(name);
    // P2: set up server-only forensic log and panic hook BEFORE entering the
    // server loop. Done in this scope so the client/dump/list code paths
    // (which also run main()) do not install these as side effects.
    let log_path = derive_server_log_path(&path);
    let _ = SERVER_LOG_PATH.set(log_path);
    install_server_panic_hook();
    server_log(
        "start",
        &format!("pid={} session={}", unsafe { libc::getpid() }, name),
    );

    // SocketGuard owns the socket-file cleanup for every unwind path
    // (returning Err from run_server, panics). For SIGTERM-initiated graceful
    // shutdown, server_loop returns Ok(()) and the guard's Drop still removes
    // the file. process::exit below does NOT run Drop, so we explicitly drop
    // the guard first.
    let guard = SocketGuard::new(path.clone());
    let result = unsafe { run_server(listener, path, cmd, winsize, read_pty, sync_pipe[1]) };
    let exit_code = match &result {
        Ok(()) => 0,
        Err(_) => 1,
    };
    if let Err(err) = &result {
        server_log("exit-error", &format!("{err}"));
    }
    drop(guard);
    process::exit(exit_code);
}

unsafe fn run_server(
    listener: UnixListener,
    path: PathBuf,
    cmd: Vec<String>,
    winsize: libc::winsize,
    read_pty: bool,
    startup_fd: RawFd,
) -> io::Result<()> {
    let mut master: libc::c_int = -1;
    #[cfg(target_os = "macos")]
    let mut winsize_for_forkpty = winsize;
    #[cfg(target_os = "macos")]
    let pid = unsafe {
        libc::forkpty(
            &mut master,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            &mut winsize_for_forkpty,
        )
    };
    #[cfg(not(target_os = "macos"))]
    let pid = unsafe {
        libc::forkpty(
            &mut master,
            std::ptr::null_mut(),
            std::ptr::null(),
            &winsize,
        )
    };
    if pid < 0 {
        let msg = format!("server-forkpty: {}\n", io::Error::last_os_error());
        let _ = fd_write_all(startup_fd, msg.as_bytes());
        unsafe {
            libc::close(startup_fd);
        }
        return Err(io::Error::last_os_error());
    }
    if pid == 0 {
        unsafe {
            libc::fcntl(startup_fd, libc::F_SETFD, libc::FD_CLOEXEC);
        }
        let cstrings: Vec<CString> = cmd
            .iter()
            .map(|s| CString::new(s.as_str()).unwrap_or_else(|_| CString::new("").unwrap()))
            .collect();
        let mut argv: Vec<*const libc::c_char> = cstrings.iter().map(|s| s.as_ptr()).collect();
        argv.push(std::ptr::null());
        unsafe {
            libc::execvp(argv[0], argv.as_ptr());
            let msg = format!(
                "server-execvp: {}: {}\n",
                cmd[0],
                io::Error::last_os_error()
            );
            let _ = fd_write_all(startup_fd, msg.as_bytes());
            libc::_exit(127);
        }
    }

    unsafe {
        libc::close(startup_fd);
    }
    let _ = env::set_current_dir("/");
    redirect_stdio_to_null();
    set_nonblocking(listener.as_raw_fd())?;
    set_nonblocking(master)?;
    server_loop(listener, path, master, pid, read_pty)
}

fn read_startup_status(fd: RawFd) -> io::Result<()> {
    let mut buf = Vec::new();
    let mut tmp = [0u8; 256];
    loop {
        match fd_read(fd, &mut tmp) {
            Ok(0) => break,
            Ok(n) => buf.extend_from_slice(&tmp[..n]),
            Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
            Err(err) => {
                unsafe {
                    libc::close(fd);
                }
                return Err(err);
            }
        }
    }
    unsafe {
        libc::close(fd);
    }
    if buf.is_empty() {
        Ok(())
    } else {
        Err(io::Error::other(
            String::from_utf8_lossy(&buf).trim_end().to_string(),
        ))
    }
}

fn server_loop(
    listener: UnixListener,
    path: PathBuf,
    master: RawFd,
    child_pid: libc::pid_t,
    mut read_pty: bool,
) -> io::Result<()> {
    let mut clients: Vec<Client> = Vec::new();
    let mut history = History::new();
    let mut child_exit: Option<i32> = None;

    loop {
        // P1: SIGTERM/SIGINT polling. Set by handle_shutdown_signal in async
        // context; here we promote it to the same internal state as a child
        // exit (status 143 = 128 + SIGTERM) and forward SIGTERM to the inner
        // process group so the user's command also tears down rather than
        // being reparented to init. The existing close_after_drain machinery
        // then queues MSG_EXIT, waits up to EXIT_DRAIN_DEADLINE for clients
        // to drain, and finally returns Ok(()) via the clients.is_empty()
        // branch below — letting SocketGuard remove the file.
        if SHUTDOWN_REQUESTED.swap(false, Ordering::Relaxed) && child_exit.is_none() {
            server_log("shutdown", "signal-requested SIGTERM/SIGINT");
            unsafe {
                libc::kill(-child_pid, libc::SIGTERM);
            }
            child_exit = Some(128 + libc::SIGTERM);
            let _ = fs::set_permissions(&path, fs::Permissions::from_mode(0o610));
        }

        loop {
            match listener.accept() {
                Ok((mut stream, _)) => {
                    let _ = send_packet_blocking(
                        &mut stream,
                        &Packet {
                            typ: MSG_PID,
                            payload: unsafe { (libc::getpid() as u64).to_ne_bytes().to_vec() },
                        },
                    );
                    // P2: do not propagate fcntl failures up to run_server
                    // (which would exit dirty via process::exit(1)). Log and
                    // drop the offending stream; the server stays alive for
                    // the other (already-attached) clients.
                    if let Err(err) = stream.set_nonblocking(true) {
                        server_log(
                            "accept-error",
                            &format!("set_nonblocking failed: {err}"),
                        );
                        continue;
                    }
                    clients.push(Client {
                        stream,
                        buf: Vec::new(),
                        attached: false,
                        flags: 0,
                        disconnected: false,
                        send_queue: VecDeque::new(),
                        close_after_drain: None,
                    });
                    read_pty = true;
                }
                Err(err) if err.kind() == io::ErrorKind::WouldBlock => break,
                Err(_) => break,
            }
        }

        if read_pty {
            let mut buf = [0u8; MAX_PAYLOAD];
            loop {
                match fd_read(master, &mut buf) {
                    Ok(0) => {
                        read_pty = false;
                        break;
                    }
                    Ok(n) => {
                        history.append(&buf[..n]);
                        broadcast_content(&mut clients, &buf[..n]);
                    }
                    Err(err) if err.kind() == io::ErrorKind::WouldBlock => break,
                    Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
                    Err(_) => {
                        read_pty = false;
                        break;
                    }
                }
            }
        }

        if child_exit.is_none() {
            let mut status = 0;
            let r = unsafe { libc::waitpid(child_pid, &mut status, libc::WNOHANG) };
            if r == child_pid {
                child_exit = Some(exit_status(status));
                let _ = fs::set_permissions(&path, fs::Permissions::from_mode(0o610));
            }
        }

        for idx in 0..clients.len() {
            read_client_packets(idx, &mut clients, master, child_pid, &history);
        }

        // Once the child has exited, queue MSG_EXIT for any client that
        // hasn't already been scheduled for graceful close. We do NOT
        // mark the client disconnected here — let try_flush_client drain
        // the queue first so MSG_EXIT (and any preceding broadcast/replay
        // backlog) actually reaches the client.
        if let Some(status) = child_exit {
            let payload = (status as u32).to_ne_bytes().to_vec();
            for client in &mut clients {
                if client.disconnected || client.close_after_drain.is_some() {
                    continue;
                }
                let _ = send_packet_nonblocking(
                    client,
                    &Packet {
                        typ: MSG_EXIT,
                        payload: payload.clone(),
                    },
                );
                client.close_after_drain = Some(Instant::now());
            }
        }

        // Drain pending outbound bytes. Real socket errors (EPIPE,
        // ECONNRESET, queue overflow, etc.) → mark disconnected; a plain
        // WouldBlock just leaves bytes in the queue for the next tick.
        for client in &mut clients {
            if client.disconnected {
                continue;
            }
            if try_flush_client(client).is_err() {
                client.disconnected = true;
            }
        }

        // For graceful-close clients, disconnect once the queue has
        // drained or EXIT_DRAIN_DEADLINE has elapsed (the latter prevents
        // a hung peer from pinning the server forever).
        let now = Instant::now();
        for client in &mut clients {
            if client.disconnected {
                continue;
            }
            if let Some(t) = client.close_after_drain
                && (client.send_queue.is_empty()
                    || now.duration_since(t) >= EXIT_DRAIN_DEADLINE)
            {
                client.disconnected = true;
            }
        }

        clients.retain(|c| !c.disconnected);

        if let Some(code) = child_exit
            && clients.is_empty()
        {
            server_log(
                "shutdown",
                &format!("clean child_exit={code} clients=0"),
            );
            // Socket file removal is owned by SocketGuard in create_session;
            // returning Ok(()) triggers its Drop along the unwind from
            // run_server. Suppress an extra fs::remove_file here so the
            // cleanup site stays single-owner.
            return Ok(());
        }

        std::thread::sleep(Duration::from_millis(5));
    }
}

fn read_client_packets(
    idx: usize,
    clients: &mut [Client],
    master: RawFd,
    child_pid: libc::pid_t,
    history: &History,
) {
    let mut tmp = [0u8; 8192];
    let mut saw_eof = false;
    loop {
        match clients[idx].stream.read(&mut tmp) {
            Ok(0) => {
                saw_eof = true;
                break;
            }
            Ok(n) => clients[idx].buf.extend_from_slice(&tmp[..n]),
            Err(err) if err.kind() == io::ErrorKind::WouldBlock => break,
            Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => {
                clients[idx].disconnected = true;
                return;
            }
        }
    }

    while let Some(pkt) = pop_packet(&mut clients[idx].buf) {
        match pkt.typ {
            MSG_CONTENT | MSG_SEND_KEYS if clients[idx].flags & CLIENT_READONLY == 0 => {
                let _ = fd_write_all(master, &pkt.payload);
            }
            MSG_CONTENT | MSG_SEND_KEYS => {}
            MSG_ATTACH => {
                clients[idx].attached = true;
                clients[idx].flags = read_u32(&pkt.payload).unwrap_or(0);
                send_history(&mut clients[idx], history, false);
            }
            MSG_DUMP => {
                send_history(&mut clients[idx], history, true);
                if clients[idx].close_after_drain.is_none() {
                    clients[idx].close_after_drain = Some(Instant::now());
                }
            }
            MSG_RESIZE if pkt.payload.len() >= 4 => {
                let rows = u16::from_ne_bytes([pkt.payload[0], pkt.payload[1]]);
                let cols = u16::from_ne_bytes([pkt.payload[2], pkt.payload[3]]);
                let ws = libc::winsize {
                    ws_row: rows,
                    ws_col: cols,
                    ws_xpixel: 0,
                    ws_ypixel: 0,
                };
                unsafe {
                    libc::ioctl(master, libc::TIOCSWINSZ, &ws);
                    libc::kill(-child_pid, libc::SIGWINCH);
                }
            }
            MSG_RESIZE => {}
            MSG_DETACH | MSG_EXIT => clients[idx].disconnected = true,
            _ => {}
        }
    }
    if saw_eof {
        clients[idx].disconnected = true;
    }
}

fn send_history(client: &mut Client, history: &History, send_end: bool) {
    let snap = history.snapshot();
    for chunk in snap.chunks(MAX_PAYLOAD) {
        if send_packet_nonblocking(
            client,
            &Packet {
                typ: MSG_CONTENT,
                payload: chunk.to_vec(),
            },
        )
        .is_err()
        {
            client.disconnected = true;
            return;
        }
    }
    if send_end {
        let _ = send_packet_nonblocking(
            client,
            &Packet {
                typ: MSG_DUMP_END,
                payload: Vec::new(),
            },
        );
    }
}

fn broadcast_content(clients: &mut [Client], bytes: &[u8]) {
    for client in clients.iter_mut().filter(|c| c.attached) {
        if send_packet_nonblocking(
            client,
            &Packet {
                typ: MSG_CONTENT,
                payload: bytes.to_vec(),
            },
        )
        .is_err()
        {
            client.disconnected = true;
        }
    }
}

fn attach_session(name: &str, terminate: bool, opts: &Opts) -> io::Result<()> {
    let mut stream = connect_session(name)?;
    let _pid = recv_packet_blocking(&mut stream)?;
    send_packet_blocking(
        &mut stream,
        &Packet {
            typ: MSG_ATTACH,
            payload: opts.flags.to_ne_bytes().to_vec(),
        },
    )?;
    send_resize(&mut stream)?;

    unsafe {
        libc::signal(libc::SIGWINCH, handle_sigwinch as *const () as libc::sighandler_t);
    }
    let raw_guard = RawMode::enter(opts.passthrough)?;
    let status = client_loop(&mut stream, opts)?;
    drop(raw_guard);
    unsafe {
        libc::signal(libc::SIGWINCH, libc::SIG_DFL);
    }

    match status {
        ClientStatus::Detached => info(opts, name, "detached"),
        ClientStatus::IoError => info(
            opts,
            name,
            "disconnected (no MSG_EXIT received; server may still be alive)",
        ),
        ClientStatus::Exited(code) => {
            info(
                opts,
                name,
                &format!("session terminated with exit status {code}"),
            );
            if terminate {
                process::exit(code);
            }
        }
    }
    Ok(())
}

enum ClientStatus {
    Detached,
    IoError,
    Exited(i32),
}

fn client_loop(stream: &mut UnixStream, opts: &Opts) -> io::Result<ClientStatus> {
    loop {
        let sock = stream.as_raw_fd();
        let mut fds: libc::fd_set = unsafe { mem::zeroed() };
        unsafe {
            libc::FD_SET(libc::STDIN_FILENO, &mut fds);
            libc::FD_SET(sock, &mut fds);
        }
        let maxfd = sock.max(libc::STDIN_FILENO) + 1;
        let rc = unsafe {
            libc::select(
                maxfd,
                &mut fds,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        if rc < 0 {
            let err = io::Error::last_os_error();
            if err.kind() == io::ErrorKind::Interrupted {
                if WINCH_PENDING.swap(false, Ordering::Relaxed) {
                    send_resize(stream)?;
                }
                continue;
            }
            return Err(err);
        }
        if unsafe { libc::FD_ISSET(sock, &fds) } {
            match recv_packet_blocking(stream) {
                Ok(pkt) => match pkt.typ {
                    MSG_CONTENT if !opts.passthrough => {
                        io::stdout().write_all(&pkt.payload)?;
                        io::stdout().flush()?;
                    }
                    MSG_CONTENT => {}
                    MSG_RESIZE => send_resize(stream)?,
                    MSG_EXIT => {
                        let code = read_u32(&pkt.payload).unwrap_or(0) as i32;
                        let _ = send_packet_blocking(stream, &pkt);
                        return Ok(ClientStatus::Exited(code));
                    }
                    _ => {}
                },
                Err(_) => return Ok(ClientStatus::IoError),
            }
        }
        if unsafe { libc::FD_ISSET(libc::STDIN_FILENO, &fds) } {
            let mut buf = [0u8; MAX_PAYLOAD];
            let n = match io::stdin().read(&mut buf) {
                Ok(0) => return Ok(ClientStatus::Detached),
                Ok(n) => n,
                Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
                Err(err) => return Err(err),
            };
            if buf[0] == opts.detach_key {
                send_packet_blocking(
                    stream,
                    &Packet {
                        typ: MSG_DETACH,
                        payload: Vec::new(),
                    },
                )?;
                return Ok(ClientStatus::Detached);
            }
            if opts.flags & CLIENT_READONLY == 0 {
                send_packet_blocking(
                    stream,
                    &Packet {
                        typ: MSG_CONTENT,
                        payload: buf[..n].to_vec(),
                    },
                )?;
            }
        }
    }
}

fn dump_session(name: &str, max_bytes: usize, max_lines: usize) -> io::Result<()> {
    let mut stream = connect_session(name)?;
    let _pid = recv_packet_blocking(&mut stream)?;
    send_packet_blocking(
        &mut stream,
        &Packet {
            typ: MSG_DUMP,
            payload: Vec::new(),
        },
    )?;
    let mut out = Vec::new();
    loop {
        let pkt = recv_packet_blocking(&mut stream)?;
        match pkt.typ {
            MSG_CONTENT => out.extend_from_slice(&pkt.payload),
            MSG_DUMP_END => break,
            _ => {}
        }
    }
    let mut start = 0;
    if max_bytes != 0 && max_bytes < out.len() {
        start = out.len() - max_bytes;
    }
    if max_lines != 0 {
        start += tail_line_start(&out[start..], max_lines);
    }
    io::stdout().write_all(&out[start..])?;
    Ok(())
}

fn tail_line_start(buf: &[u8], lines: usize) -> usize {
    if lines == 0 || buf.is_empty() {
        return 0;
    }
    let mut pos = buf.len();
    if pos > 0 && buf[pos - 1] == b'\n' {
        pos -= 1;
    }
    let mut found = 0;
    while pos > 0 {
        pos -= 1;
        if buf[pos] == b'\n' {
            found += 1;
            if found == lines {
                return pos + 1;
            }
        }
    }
    0
}

fn send_keys_session(name: &str, keys: &[String], literal: bool) -> io::Result<()> {
    let mut stream = connect_session(name)?;
    let _pid = recv_packet_blocking(&mut stream)?;
    let mut bytes = Vec::new();
    for (idx, key) in keys.iter().enumerate() {
        if literal {
            if idx > 0 {
                bytes.push(b' ');
            }
            bytes.extend_from_slice(key.as_bytes());
        } else if let Some(encoded) = key_token_bytes(key) {
            bytes.extend_from_slice(&encoded);
        } else {
            bytes.extend_from_slice(key.as_bytes());
        }
    }
    for chunk in bytes.chunks(MAX_PAYLOAD) {
        send_packet_blocking(
            &mut stream,
            &Packet {
                typ: MSG_SEND_KEYS,
                payload: chunk.to_vec(),
            },
        )?;
    }
    Ok(())
}

fn key_token_bytes(token: &str) -> Option<Vec<u8>> {
    Some(match token {
        "Enter" | "Return" | "C-m" => b"\r".to_vec(),
        "Tab" | "C-i" => b"\t".to_vec(),
        "Esc" | "Escape" => b"\x1b".to_vec(),
        "Space" => b" ".to_vec(),
        "Backspace" | "BSpace" => vec![0x7f],
        "Delete" => b"\x1b[3~".to_vec(),
        "Insert" => b"\x1b[2~".to_vec(),
        "Up" => b"\x1b[A".to_vec(),
        "Down" => b"\x1b[B".to_vec(),
        "Right" => b"\x1b[C".to_vec(),
        "Left" => b"\x1b[D".to_vec(),
        "Home" => b"\x1b[H".to_vec(),
        "End" => b"\x1b[F".to_vec(),
        "PageUp" => b"\x1b[5~".to_vec(),
        "PageDown" => b"\x1b[6~".to_vec(),
        _ if token.starts_with("C-") && token.len() == 3 => vec![token.as_bytes()[2] & 0x1f],
        _ if token.starts_with('^') && token.len() == 2 => vec![token.as_bytes()[1] & 0x1f],
        _ => return None,
    })
}

fn list_sessions() -> io::Result<()> {
    let base = socket_base_dir()?;
    let host = hostname();
    println!("Active sessions (on host {host})");
    for entry in fs::read_dir(base)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if !name.ends_with(&format!("@{host}")) {
            continue;
        }
        let session = name.trim_end_matches(&format!("@{host}"));
        if let Ok(mut stream) = UnixStream::connect(entry.path())
            && let Ok(pkt) = recv_packet_blocking(&mut stream)
            && pkt.typ == MSG_PID
        {
            let pid = read_u64(&pkt.payload).unwrap_or(0);
            // 4-field tab output, matching the C abduco column ordering
            // expected by quests/status.py and similar parsers:
            //   STATUS \t START_DATE \t PID \t NAME
            // After whitespace split parts[-2] must be the PID and
            // parts[-1] the session name; the START_DATE column is the
            // mtime of the bound socket file (close enough to abduco's
            // "started at" semantics for downstream tooling).
            let mtime = entry
                .metadata()
                .and_then(|m| m.modified())
                .ok()
                .map(format_iso_local)
                .unwrap_or_else(|| "unknown".to_string());
            println!("  ?\t{mtime}\t{pid}\t{session}");
        }
    }
    Ok(())
}

fn format_iso_local(t: SystemTime) -> String {
    let secs = t
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as libc::time_t)
        .unwrap_or(0);
    let mut tm: libc::tm = unsafe { mem::zeroed() };
    let rc = unsafe { libc::localtime_r(&secs, &mut tm) };
    if rc.is_null() {
        return "unknown".to_string();
    }
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}",
        tm.tm_year + 1900,
        tm.tm_mon + 1,
        tm.tm_mday,
        tm.tm_hour,
        tm.tm_min,
    )
}

fn packet_bytes(pkt: &Packet) -> Vec<u8> {
    let mut out = Vec::with_capacity(8 + pkt.payload.len());
    out.extend_from_slice(&pkt.typ.to_ne_bytes());
    out.extend_from_slice(&(pkt.payload.len() as u32).to_ne_bytes());
    out.extend_from_slice(&pkt.payload);
    out
}

fn send_packet_blocking(stream: &mut UnixStream, pkt: &Packet) -> io::Result<()> {
    stream.write_all(&packet_bytes(pkt))
}

/// Queue a packet for the client and try to flush as much as the kernel
/// send buffer can accept right now. Bytes that don't fit stay in the
/// per-client queue and are retried by `try_flush_client` on every
/// server tick. The previous implementation called `write_all` directly
/// on a non-blocking socket: a `WouldBlock` mid-packet returned `Err`
/// while leaving partial bytes already on the wire, which the attach
/// client then read as a corrupted packet — surfacing as
/// "exited due to I/O errors" or "failed to fill whole buffer".
fn send_packet_nonblocking(client: &mut Client, pkt: &Packet) -> io::Result<()> {
    let bytes = packet_bytes(pkt);
    if client.send_queue.len().saturating_add(bytes.len()) > SEND_QUEUE_CAP {
        return Err(io::Error::new(
            io::ErrorKind::WriteZero,
            "client send queue overflow",
        ));
    }
    client.send_queue.extend(bytes);
    try_flush_client(client)
}

/// Drain whatever already-queued bytes the kernel will accept right now.
/// Returns `Ok(())` whether the queue was fully flushed or merely paused
/// at a `WouldBlock`; only real socket errors propagate up.
fn try_flush_client(client: &mut Client) -> io::Result<()> {
    loop {
        let front_len = client.send_queue.as_slices().0.len();
        if front_len == 0 {
            return Ok(());
        }
        // Borrow a slice of the front segment for the write call.
        let written = {
            let front = &client.send_queue.as_slices().0[..front_len];
            match client.stream.write(front) {
                Ok(0) => {
                    return Err(io::Error::new(
                        io::ErrorKind::WriteZero,
                        "client send returned 0",
                    ));
                }
                Ok(n) => n,
                Err(err) if err.kind() == io::ErrorKind::WouldBlock => return Ok(()),
                Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
                Err(err) => return Err(err),
            }
        };
        client.send_queue.drain(..written);
    }
}

fn recv_packet_blocking(stream: &mut UnixStream) -> io::Result<Packet> {
    let mut hdr = [0u8; 8];
    stream.read_exact(&mut hdr)?;
    let typ = u32::from_ne_bytes([hdr[0], hdr[1], hdr[2], hdr[3]]);
    let len = u32::from_ne_bytes([hdr[4], hdr[5], hdr[6], hdr[7]]) as usize;
    if len > MAX_PAYLOAD {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "packet too large",
        ));
    }
    let mut payload = vec![0u8; len];
    stream.read_exact(&mut payload)?;
    Ok(Packet { typ, payload })
}

fn pop_packet(buf: &mut Vec<u8>) -> Option<Packet> {
    if buf.len() < 8 {
        return None;
    }
    let typ = u32::from_ne_bytes([buf[0], buf[1], buf[2], buf[3]]);
    let len = u32::from_ne_bytes([buf[4], buf[5], buf[6], buf[7]]) as usize;
    if len > MAX_PAYLOAD {
        buf.clear();
        return None;
    }
    if buf.len() < 8 + len {
        return None;
    }
    let payload = buf[8..8 + len].to_vec();
    buf.drain(..8 + len);
    Some(Packet { typ, payload })
}

fn read_u32(bytes: &[u8]) -> Option<u32> {
    (bytes.len() >= 4).then(|| u32::from_ne_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
}

fn read_u64(bytes: &[u8]) -> Option<u64> {
    (bytes.len() >= 8).then(|| {
        u64::from_ne_bytes([
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        ])
    })
}

fn current_winsize() -> libc::winsize {
    let mut ws = libc::winsize {
        ws_row: 25,
        ws_col: 80,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    let rc = unsafe { libc::ioctl(libc::STDIN_FILENO, libc::TIOCGWINSZ, &mut ws) };
    if rc != 0 || ws.ws_row == 0 || ws.ws_col == 0 {
        ws.ws_row = env_u16("LICH_ROWS").unwrap_or(25);
        ws.ws_col = env_u16("LICH_COLS").unwrap_or(80);
    }
    ws
}

fn env_u16(name: &str) -> Option<u16> {
    env::var(name).ok()?.parse::<u16>().ok().filter(|&v| v != 0)
}

fn send_resize(stream: &mut UnixStream) -> io::Result<()> {
    let ws = current_winsize();
    let mut payload = Vec::with_capacity(4);
    payload.extend_from_slice(&ws.ws_row.to_ne_bytes());
    payload.extend_from_slice(&ws.ws_col.to_ne_bytes());
    send_packet_blocking(
        stream,
        &Packet {
            typ: MSG_RESIZE,
            payload,
        },
    )
}

fn set_nonblocking(fd: RawFd) -> io::Result<()> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL, 0) };
    if flags < 0 {
        return Err(io::Error::last_os_error());
    }
    let rc = unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) };
    if rc < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

fn fd_read(fd: RawFd, buf: &mut [u8]) -> io::Result<usize> {
    let n = unsafe { libc::read(fd, buf.as_mut_ptr().cast(), buf.len()) };
    if n < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(n as usize)
    }
}

fn fd_write_all(fd: RawFd, mut buf: &[u8]) -> io::Result<()> {
    while !buf.is_empty() {
        let n = unsafe { libc::write(fd, buf.as_ptr().cast(), buf.len()) };
        if n < 0 {
            let err = io::Error::last_os_error();
            if err.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(err);
        }
        if n == 0 {
            return Err(io::Error::new(io::ErrorKind::WriteZero, "short write"));
        }
        buf = &buf[n as usize..];
    }
    Ok(())
}

fn exit_status(status: i32) -> i32 {
    if libc::WIFEXITED(status) {
        libc::WEXITSTATUS(status)
    } else if libc::WIFSIGNALED(status) {
        128 + libc::WTERMSIG(status)
    } else {
        status
    }
}

fn redirect_stdio_to_null() {
    if let Ok(file) = File::options().read(true).write(true).open("/dev/null") {
        let fd = file.as_raw_fd();
        unsafe {
            libc::dup2(fd, libc::STDIN_FILENO);
            libc::dup2(fd, libc::STDOUT_FILENO);
            libc::dup2(fd, libc::STDERR_FILENO);
        }
    }
}

fn isatty(fd: RawFd) -> bool {
    unsafe { libc::isatty(fd) == 1 }
}

struct RawMode {
    saved: Option<libc::termios>,
}

impl RawMode {
    fn enter(passthrough: bool) -> io::Result<Self> {
        if passthrough || !isatty(libc::STDIN_FILENO) {
            return Ok(Self { saved: None });
        }
        let mut term: libc::termios = unsafe { mem::zeroed() };
        if unsafe { libc::tcgetattr(libc::STDIN_FILENO, &mut term) } != 0 {
            return Ok(Self { saved: None });
        }
        let saved = term;
        term.c_iflag &= !(libc::IGNBRK
            | libc::BRKINT
            | libc::PARMRK
            | libc::ISTRIP
            | libc::INLCR
            | libc::IGNCR
            | libc::ICRNL
            | libc::IXON
            | libc::IXOFF);
        term.c_oflag &= !libc::OPOST;
        term.c_lflag &= !(libc::ECHO | libc::ECHONL | libc::ICANON | libc::ISIG | libc::IEXTEN);
        term.c_cflag &= !(libc::CSIZE | libc::PARENB);
        term.c_cflag |= libc::CS8;
        term.c_cc[libc::VMIN] = 1;
        term.c_cc[libc::VTIME] = 0;
        unsafe {
            libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, &term);
        }
        print!("\x1b[H");
        let _ = io::stdout().flush();
        Ok(Self { saved: Some(saved) })
    }
}

impl Drop for RawMode {
    fn drop(&mut self) {
        if let Some(saved) = self.saved {
            unsafe {
                libc::tcsetattr(libc::STDIN_FILENO, libc::TCSAFLUSH, &saved);
            }
            print!("\x1b[?25h");
            let _ = io::stdout().flush();
        }
    }
}

fn info(opts: &Opts, name: &str, msg: &str) {
    if !opts.quiet {
        eprintln!("lich: {name}: {msg}\r");
    }
}
