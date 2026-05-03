# lich Rust Implementation Spec

Rewrite `lich` in Rust. The C reference implementation is in `c/`. The Rust implementation goes in `src/` and becomes the primary build. CI generates shell completions automatically.

## What lich does

Terminal session manager. Key behaviors:

1. **Create session**: fork a daemon server process that owns a PTY and runs the user's command
2. **Attach inline**: client connects to the server via Unix socket, replays history, then forwards terminal I/O — WITHOUT entering alternate screen (`?1049h` is suppressed)
3. **Detach**: Ctrl-\ sends detach signal; client exits, server keeps running
4. **List sessions**: show active sessions
5. **Automation**: dump session output (`-d`), send keystrokes (`-K`), tail lines/bytes (`-L`/`-N`), literal mode (`-x`)

The C source in `c/abduco.c` (which `#include`s `client.c`, `server.c`, `debug.c`) is the canonical reference.

## CLI interface (must match exactly)

```
lich [-a|-A|-c|-n|-d|-K] [-N bytes] [-L lines] [-x] [-p] [-r] [-q] [-l] [-f] [-e detachkey] name [command|keys...]
```

| Flag | Behavior |
|------|----------|
| (no flag) | List active sessions |
| `-n name cmd` | Create session, don't attach |
| `-A name [cmd]` | Attach inline (create if not exists). **No alternate screen.** |
| `-a name` | Attach to existing session |
| `-c name cmd` | Create and attach |
| `-d name` | Dump full session output to stdout, then exit |
| `-d -L n name` | Dump last N lines |
| `-d -N bytes name` | Dump last N bytes |
| `-K name token...` | Send keystrokes by name (Enter, Tab, C-c, Up, etc.) |
| `-K -x name string` | Send raw bytes (literal mode, no key-name parsing) |
| `-e key` | Set detach key (default: Ctrl-\) |
| `-r` | Read-only attach |
| `-q` | Quiet |
| `-l` | Low priority attach |
| `-f` | Force create |
| `-p` | Pass-through |

Key names for `-K`: `Enter`, `Tab`, `Esc`, `Space`, `Backspace`, `Up`, `Down`, `Left`, `Right`, `C-<x>` (e.g. `C-c`, `C-d`, `C-\`).

## Architecture

### Session lifecycle

```
lich -n name cmd
  → create Unix socket at $ABDUCO_SOCKET_DIR/<name>@<hostname>
    (or /tmp/<name> if name starts with /)
  → double-fork server process
  → server forkpty()s the command
  → server select() loop: forward pty→clients, clients→pty

lich -A name
  → connect to Unix socket
  → send MSG_ATTACH
  → server replays history buffer
  → client: set terminal raw mode, forward stdin→socket, socket→stdout
  → NO CSI ?1049h (this is THE key feature vs upstream abduco)
  → detach key (Ctrl-\) → send MSG_DETACH → disconnect

lich -d name
  → connect to Unix socket
  → send MSG_DUMP
  → server sends history buffer + MSG_DUMP_END
  → client writes to stdout, exits

lich -K name tokens...
  → connect to Unix socket
  → send MSG_SEND_KEYS with encoded bytes
  → disconnect
```

### Protocol (match C implementation exactly)

Packets over Unix socket:

```rust
struct Packet {
    len: u32,        // payload length
    msg_type: u8,    // one of MSG_* constants
    payload: [u8],   // up to 4096 bytes
}
```

Message types (copy from `c/abduco.c`):
- `MSG_CONTENT` — pty data
- `MSG_ATTACH` — client attaches (payload: client flags as u32)
- `MSG_DETACH` — client detaches
- `MSG_DUMP` — client requests history dump
- `MSG_DUMP_END` — server signals end of history dump
- `MSG_SEND_KEYS` — client sends keystrokes
- `MSG_RESIZE` — terminal resize (payload: rows, cols as u16)
- `MSG_EXIT` — session process exited (payload: exit status)
- `MSG_PID` — server sends its PID on connect

### History buffer

Ring buffer, capacity = 1 MB (match `HISTORY_CAP` in C). Server appends all pty output. On attach, server replays entire buffer to new client. On `-d`/`-d -L`/`-d -N`, server replays appropriate slice.

### Inline attach (no alternate screen)

The standard abduco client sends:
```
\x1b[?1049h\x1b[H   (enter alternate screen, move to top-left)
```
on attach, and:
```
\x1b[?1049l          (leave alternate screen)
```
on detach.

**lich must NOT send these sequences.** This is the entire point of the fork. The client attaches directly to the main screen.

### Socket path

```rust
fn socket_path(name: &str) -> PathBuf {
    if name.starts_with('/') {
        // absolute path used directly
        PathBuf::from(name)
    } else {
        let dir = std::env::var("ABDUCO_SOCKET_DIR")
            .unwrap_or_else(|_| {
                // use XDG_RUNTIME_DIR, then HOME/.abduco, then /tmp
                ...
            });
        let hostname = gethostname();
        dir.join(format!("{}@{}", name, hostname))
    }
}
```

Match the C logic in `c/abduco.c` `set_socket_name()`.

## Dependencies

```toml
[dependencies]
clap = { version = "4", features = ["derive"] }
nix = { version = "0.29", features = ["process", "pty", "signal", "socket", "term", "fs"] }

[build-dependencies]
clap = { version = "4", features = ["derive"] }
clap_complete = "4"
```

No async runtime. Use `std::thread` for the client I/O loop (stdin reader thread + main thread forwarding socket→stdout).

## build.rs — shell completion generation

```rust
use clap::CommandFactory;
use clap_complete::{generate_to, Shell};

fn main() {
    let out_dir = std::path::PathBuf::from(
        std::env::var("OUT_DIR").unwrap()
    );
    let mut cmd = lich::Cli::command();
    for shell in [Shell::Bash, Shell::Zsh, Shell::Fish, Shell::PowerShell] {
        generate_to(shell, &mut cmd, "lich", &out_dir).unwrap();
    }
}
```

CI copies generated completions to `completions/` and attaches them to releases.

## Release CI update

After Rust implementation, update `.github/workflows/release.yml`:

```yaml
- name: Build
  run: cargo build --release

- name: Generate completions
  run: |
    mkdir -p completions
    cargo run --release -- --generate=bash  > completions/lich.bash
    # or copy from OUT_DIR

- name: Package
  run: |
    cp target/release/lich lich-linux-x86_64
    strip lich-linux-x86_64
```

## File layout after Rust rewrite

```
lich/
├── src/               # Rust (primary)
│   ├── main.rs
│   ├── cli.rs         # clap CLI definition
│   ├── server.rs      # PTY server daemon
│   ├── client.rs      # attach/dump/send-keys client
│   ├── protocol.rs    # Packet codec
│   └── history.rs     # ring buffer
├── c/                 # C reference (keep, don't delete)
├── tests/
│   └── testsuite-inline.sh  # shell integration tests (still valid for Rust binary)
├── completions/       # generated by CI
├── build.rs
├── Cargo.toml
├── Cargo.lock
├── README.md
├── LICENSE
└── .gitignore
```

## Testing

The existing `tests/testsuite-inline.sh` tests the binary directly — it should pass unchanged with the Rust binary. Run it as:

```sh
cargo build && ./tests/testsuite-inline.sh ./target/debug/lich
```

All 7 tests must pass on Linux. macOS tests pass with the platform-aware payload sizing already in the testsuite.

## Latest Rust standards

- Rust edition 2024
- `clap` derive macros (not builder API)
- `nix` 0.29+ for Unix APIs
- No `unsafe` except where nix requires it
- `thiserror` for error types (optional but recommended)
- Clippy clean (`cargo clippy -- -D warnings`)
