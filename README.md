<h1 align="center">lich</h1>
<p align="center">Detach. It keeps running.<br>Works with Claude Code, Codex, and anything else that runs in a terminal.</p>

<p align="center">
  <a href="https://github.com/andylizf/lich/actions/workflows/linux.yml"><img src="https://github.com/andylizf/lich/actions/workflows/linux.yml/badge.svg" alt="Linux CI"></a>
  <a href="https://github.com/andylizf/lich/actions/workflows/macos.yml"><img src="https://github.com/andylizf/lich/actions/workflows/macos.yml/badge.svg" alt="macOS CI"></a>
</p>

<p align="center">
  <a href="#install">Install</a> &middot;
  <a href="#usage">Usage</a> &middot;
  <a href="#automation">Automation</a>
</p>

---

```sh
lich -n my-agent claude
lich -n my-agent codex --no-alt-screen
```

Close your terminal. Come back later. Everything your agent did is in your normal scrollback, as if you never left.

## Install

Download a pre-built binary from the [releases page](https://github.com/andylizf/lich/releases):

```sh
# Linux x86_64
curl -Lo lich https://github.com/andylizf/lich/releases/latest/download/lich-linux-x86_64
chmod +x lich
sudo mv lich /usr/local/bin/

# macOS arm64
curl -Lo lich https://github.com/andylizf/lich/releases/latest/download/lich-macos-arm64
chmod +x lich
sudo mv lich /usr/local/bin/
```

Or build from source (requires Rust):

```sh
git clone https://github.com/andylizf/lich
cd lich
cargo build --release
sudo install -m 755 target/release/lich /usr/local/bin/lich
```

## Usage

```sh
# Start a session
lich -n my-agent claude
lich -n my-agent codex --no-alt-screen

# Reattach. History lands in your normal terminal scrollback.
lich -A my-agent

# List sessions
lich

# Detach: Ctrl-\
```

If the agent has its own alternate-screen mode, disable it too (e.g. `codex --no-alt-screen`). lich only controls the attach client and does not intercept sequences the agent emits itself.

## Automation

lich adds flags for scripting and orchestration on top of standard abduco.

### Read session output

```sh
# Full scrollback
lich -d my-agent

# Last N lines
lich -d -L 50 my-agent

# Last N bytes
lich -d -N 4096 my-agent
```

### Send input

```sh
# Key names
lich -K my-agent "echo hello" Enter
lich -K my-agent C-c
lich -K my-agent Up Enter

# Literal bytes (raw, no key-name parsing)
lich -K -x my-agent $'echo hello\n'
```

Key names: `Enter`, `Tab`, `Esc`, `Space`, `Backspace`, `Up`, `Down`, `Left`, `Right`, `C-<x>` (e.g. `C-c`, `C-d`).

### Polling loop

```sh
lich -n my-agent claude

while true; do
  output="$(lich -d -L 20 my-agent)"
  if echo "$output" | grep -q "Task complete"; then break; fi
  lich -K my-agent "continue" Enter
  sleep 5
done
```

## Compared to

|                            | tmux | screen | abduco | dtach | **lich** |
| -------------------------- | :--: | :----: | :----: | :---: | :------: |
| Persist across disconnect  |  ✓   |   ✓    |   ✓    |   ✓   |    ✓     |
| Native terminal scrollback |  ✗   |   ✗    |   ✗    |   ✗   |    ✓     |
| History replay on attach   |  ✓   |   ✓    |   ✓    |   ✗   |    ✓     |
| Read output / send keys    |  ✓   |   ~    |   ✗    |   ✗   |    ✓     |
| Zero config, no new UI     |  ✗   |   ✗    |   ✓    |   ✓   |    ✓     |

tmux and screen replay history inside their own alternate-screen UI. lich replays directly into your terminal's native scrollback. `~` screen can send input via `-X stuff` and capture output via `hardcopy`, but with no stdout API and no way to request the last N lines directly.

## What changed from upstream

Two additions on top of [abduco](https://github.com/martanne/abduco):

**Native scrollback.** The `CSI ?1049 h/l` alternate-screen sequences are removed from the client attach path. Session output lands in your terminal's native scrollback instead of disappearing when you detach.

**Automation API.** abduco has no way to read or write a session from a script. lich adds:

| Flag | What it does |
|------|-------------|
| `-d` | Dump full session output to stdout |
| `-d -L <n>` | Last N lines |
| `-d -N <bytes>` | Last N bytes |
| `-K name token...` | Send keystrokes by name |
| `-K -x name string` | Send raw bytes |

Everything else (session management, pty forwarding, terminal raw mode, exit status) is unchanged from upstream.

ISC license. Upstream copyright Marc André Tanner.
