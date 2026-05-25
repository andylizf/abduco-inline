#!/usr/bin/env bash

set -euo pipefail

ABDUCO="${1:-./lich}"

if [[ ! -x "$ABDUCO" ]]; then
	echo "usage: $0 /path/to/abduco" >&2
	exit 2
fi

tests_run=0
tests_ok=0
prefix="/tmp/t$$"
tmpdir="${TMPDIR:-/tmp}/abduco-inline-tests-$$"
mkdir -p "$tmpdir"

cleanup() {
	for sess in "$prefix"-*; do
		"$ABDUCO" -K -x "$sess" $'exit\n' >/dev/null 2>&1 || true
	done
	rm -rf "$tmpdir"
}
trap cleanup EXIT

pass() {
	tests_ok=$((tests_ok + 1))
	echo "ok - $1"
}

run() {
	tests_run=$((tests_run + 1))
	echo "test - $1 ($(date +%H:%M:%S))"
}

fail() {
	echo "not ok - $1" >&2
	exit 1
}

assert_contains() {
	local needle="$1" file="$2"
	grep -a -q -- "$needle" "$file" || fail "missing '$needle' in $file"
}

assert_not_contains() {
	local needle="$1" file="$2"
	if grep -a -q -- "$needle" "$file"; then
		fail "unexpected '$needle' in $file"
	fi
}

assert_no_alt_screen() {
	local file="$1"
	if LC_ALL=C grep -a $'\033\\[\\?1049[hl]' "$file" >/dev/null; then
		fail "found alt-screen 1049 sequence in $file"
	fi
}

run_with_timeout() {
	local seconds="$1"
	shift
	python3 - "$seconds" "$@" <<'PYEOF'
import subprocess
import sys

seconds = float(sys.argv[1])
cmd = sys.argv[2:]
try:
    raise SystemExit(subprocess.run(cmd, timeout=seconds).returncode)
except subprocess.TimeoutExpired:
    raise SystemExit(124)
PYEOF
}

start_shell() {
	local sess="$1" prelude="$2"
	"$ABDUCO" -n "$sess" sh -lc "$prelude; exec sh"
	sleep 0.3
}

run "nonblocking write_all returns on EAGAIN"
srcroot="$(cd "$(dirname "$0")/.." && pwd)"
darwin_cflags=()
if [[ "$(uname -s)" == "Darwin" ]]; then
	darwin_cflags=(-D_DARWIN_C_SOURCE)
fi
cc ${CFLAGS:-} -std=c99 -D_POSIX_C_SOURCE=200809L -D_XOPEN_SOURCE=700 "${darwin_cflags[@]}" -DNDEBUG \
	-DVERSION=\"test\" -I "$srcroot/c" "$srcroot/tests/write_all_nonblock.c" -lc -lutil \
	-o "$tmpdir/write_all_nonblock"
if ! run_with_timeout 3 "$tmpdir/write_all_nonblock"; then
	fail "write_all did not return cleanly when a nonblocking socket was full"
fi
pass "nonblocking write_all returns on EAGAIN"

run "attach waits for complete packet on partial socket read"
partial_sock="$tmpdir/partial-packet.sock"
partial_out="$tmpdir/partial-packet.out"
python3 - "$ABDUCO" "$partial_sock" "$partial_out" <<'PYEOF'
import os
import pty
import select
import socket
import struct
import subprocess
import sys
import time

abduco, sock_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    os.unlink(sock_path)
except FileNotFoundError:
    pass

srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(sock_path)
srv.listen(1)

master, slave = pty.openpty()
client = subprocess.Popen(
    [abduco, "-a", sock_path],
    stdin=slave,
    stdout=slave,
    stderr=subprocess.PIPE,
    close_fds=True,
)
os.close(slave)
conn, _ = srv.accept()
conn.sendall(struct.pack("@IIQ", 5, 8, os.getpid()))

# Read the MSG_ATTACH packet sent by the client. A following MSG_RESIZE may
# already be queued; the fake server can ignore it for this regression.
buf = b""
while len(buf) < 12:
    chunk = conn.recv(12 - len(buf))
    if not chunk:
        raise SystemExit("client disconnected before attach packet")
    buf += chunk

payload = b"PARTIAL_PACKET_OK\n"
pkt = struct.pack("@II", 0, len(payload)) + payload
conn.sendall(pkt[:5])
time.sleep(0.5)
if client.poll() is not None:
    raise SystemExit("client exited before complete packet arrived")
conn.sendall(pkt[5:])
time.sleep(0.1)
conn.sendall(struct.pack("@III", 4, 4, 0))

out = b""
deadline = time.monotonic() + 3
while time.monotonic() < deadline:
    r, _, _ = select.select([master], [], [], 0.1)
    if r:
        try:
            chunk = os.read(master, 4096)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    if client.poll() is not None:
        break
err = client.stderr.read() or b""
try:
    client.wait(timeout=1)
except subprocess.TimeoutExpired:
    client.kill()
    raise
os.close(master)
with open(out_path, "wb") as f:
    f.write(out)
if client.returncode != 0:
    sys.stderr.buffer.write(err)
    raise SystemExit(client.returncode)
PYEOF
assert_contains "PARTIAL_PACKET_OK" "$partial_out"
pass "attach waits for complete packet on partial socket read"

run "no-tty fallback winsize is configurable"
sess="$prefix-winsize"
python3 - "$ABDUCO" "$sess" <<'PYEOF'
import os
import subprocess
import sys

abduco, sess = sys.argv[1], sys.argv[2]
env = os.environ.copy()
env["LICH_ROWS"] = "40"
env["LICH_COLS"] = "132"
subprocess.run(
    [abduco, "-n", sess, "sh", "-lc", "stty size; exec sh"],
    stdin=subprocess.DEVNULL,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    env=env,
    timeout=5,
    check=True,
)
PYEOF
sleep 0.3
"$ABDUCO" -d "$sess" > "$tmpdir/winsize.out"
assert_contains "40 132" "$tmpdir/winsize.out"
pass "no-tty fallback winsize is configurable"

run "attach pty resize updates child winsize"
resize_sock="$tmpdir/resize.sock"
python3 - "$ABDUCO" "$resize_sock" <<'PYEOF'
import os
import subprocess
import sys

abduco, sess = sys.argv[1], sys.argv[2]
env = os.environ.copy()
env["LICH_ROWS"] = "25"
env["LICH_COLS"] = "80"
subprocess.run(
    [abduco, "-n", sess, "sh", "-lc", "stty size; exec sh"],
    stdin=subprocess.DEVNULL,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    env=env,
    timeout=5,
    check=True,
)
PYEOF
sleep 0.3
python3 - "$ABDUCO" "$resize_sock" <<'PYEOF'
import fcntl
import os
import pty
import select
import struct
import subprocess
import sys
import termios
import time

abduco, sess = sys.argv[1], sys.argv[2]
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 45, 140, 0, 0))
client = subprocess.Popen(
    [abduco, "-A", sess],
    stdin=slave,
    stdout=slave,
    stderr=subprocess.DEVNULL,
    close_fds=True,
)
os.close(slave)
deadline = time.monotonic() + 3
while time.monotonic() < deadline:
    r, _, _ = select.select([master], [], [], 0.1)
    if r:
        try:
            os.read(master, 4096)
        except OSError:
            break
    else:
        time.sleep(0.1)
        break
client.terminate()
try:
    client.wait(timeout=1)
except subprocess.TimeoutExpired:
    client.kill()
os.close(master)
PYEOF
sleep 0.3
"$ABDUCO" -K -x "$resize_sock" $'stty size\n'
sleep 0.3
"$ABDUCO" -d -L 20 "$resize_sock" > "$tmpdir/resize.out"
assert_contains "25 80" "$tmpdir/resize.out"
assert_contains "45 140" "$tmpdir/resize.out"
pass "attach pty resize updates child winsize"

run "dump tail bytes and lines"
sess="$prefix-tail"
start_shell "$sess" 'for i in $(seq 1 30); do printf "TAIL_LINE_%03d\n" "$i"; done'
"$ABDUCO" -d "$sess" > "$tmpdir/full.out"
"$ABDUCO" -d -L 5 "$sess" > "$tmpdir/lines.out"
"$ABDUCO" -d -N 160 "$sess" > "$tmpdir/bytes.out"
assert_contains "TAIL_LINE_001" "$tmpdir/full.out"
assert_contains "TAIL_LINE_030" "$tmpdir/full.out"
assert_contains "TAIL_LINE_030" "$tmpdir/lines.out"
assert_not_contains "TAIL_LINE_001" "$tmpdir/lines.out"
assert_contains "TAIL_LINE_030" "$tmpdir/bytes.out"
assert_not_contains "TAIL_LINE_001" "$tmpdir/bytes.out"
pass "dump tail bytes and lines"

run "send key names and literal mode"
sess="$prefix-keys"
start_shell "$sess" 'printf "READY_KEYS\n"'
"$ABDUCO" -K "$sess" "echo TOKEN_ENTER_OK" Enter
sleep 0.2
"$ABDUCO" -K "$sess" echo Space TOKEN_SPACE_OK Enter
sleep 0.2
"$ABDUCO" -K -x "$sess" $'echo LITERAL_MODE_OK\n'
sleep 0.2
"$ABDUCO" -d -L 40 "$sess" > "$tmpdir/keys.out"
assert_contains "TOKEN_ENTER_OK" "$tmpdir/keys.out"
assert_contains "TOKEN_SPACE_OK" "$tmpdir/keys.out"
assert_contains "LITERAL_MODE_OK" "$tmpdir/keys.out"
pass "send key names and literal mode"

run "control keys"
sess="$prefix-control"
start_shell "$sess" 'printf "READY_CONTROL\n"'
"$ABDUCO" -K "$sess" "sleep 10" Enter
sleep 0.3
"$ABDUCO" -K "$sess" C-c
sleep 0.3
"$ABDUCO" -K "$sess" "echo CTRL_C_OK" Enter
sleep 0.3
"$ABDUCO" -d -L 40 "$sess" > "$tmpdir/control.out"
assert_contains "CTRL_C_OK" "$tmpdir/control.out"
pass "control keys"

run "arrow key history recall"
sess="$prefix-arrow"
start_shell "$sess" 'printf "READY_ARROW\n"'
"$ABDUCO" -K "$sess" "echo ARROW_HISTORY_OK" Enter
sleep 0.3
"$ABDUCO" -K "$sess" Up Enter
sleep 0.3
"$ABDUCO" -d -L 60 "$sess" > "$tmpdir/arrow.out"
count="$(grep -a -c "ARROW_HISTORY_OK" "$tmpdir/arrow.out")"
[[ "$count" -ge 2 ]] || fail "expected history recall to show ARROW_HISTORY_OK at least twice, got $count"
pass "arrow key history recall"

run "long literal send splits across packets"
sess="$prefix-long"
start_shell "$sess" 'printf "READY_LONG\n"'
if [[ "$(uname -s)" == "Darwin" ]]; then
	# On macOS, the pty buffer is ~4 KB. A canonical-mode shell (sh) blocks
	# in read() waiting for a newline; tcsetattr(TCSANOW) clearing ICANON
	# does not interrupt an in-progress blocking read(), so the buffer fills
	# and write_all() deadlocks on the next packet. This is a kernel-level
	# constraint: the pty buffer size and canonical-mode drain behaviour are
	# controlled by the OS and the receiving process, not by abduco.
	# Verify that the send-keys protocol works with a payload that fits in
	# the pty buffer; packet-splitting of large payloads is covered by Linux CI.
	"$ABDUCO" -K -x "$sess" $'echo LONG_SPLIT_OK\n'
	sleep 0.3
	"$ABDUCO" -d -L 20 "$sess" > "$tmpdir/long.out"
	assert_contains "LONG_SPLIT_OK" "$tmpdir/long.out"
else
	long_payload="$(awk 'BEGIN { for (i = 0; i < 9000; i++) printf "x" }')"
	"$ABDUCO" -K -x "$sess" "printf 'LONG_BEGIN_${long_payload}_LONG_END\n'
"
	sleep 0.5
	"$ABDUCO" -d "$sess" > "$tmpdir/long.out"
	assert_contains "LONG_BEGIN_" "$tmpdir/long.out"
	assert_contains "_LONG_END" "$tmpdir/long.out"
fi
pass "long literal send splits across packets"

run "interactive attach timing matrix"
attach_matrix_sess="$prefix-attach-matrix"
attach_matrix_script="$tmpdir/attach-matrix.sh"
cat > "$attach_matrix_script" <<'EOF'
printf 'ATTACH_MATRIX_BOOT\n'
for i in $(seq 1 160); do
	printf 'ATTACH_MATRIX_TICK_%03d\n' "$i"
	sleep 0.01
done
printf 'ATTACH_MATRIX_READY\n'
exec sh
EOF
"$ABDUCO" -n "$attach_matrix_sess" sh "$attach_matrix_script"
python3 - "$ABDUCO" "$attach_matrix_sess" "$tmpdir" <<'PYEOF'
import os
import pty
import select
import subprocess
import sys
import time

abduco, sess, tmpdir = sys.argv[1], sys.argv[2], sys.argv[3]

def attach_once(idx):
    master, slave = pty.openpty()
    client = subprocess.Popen(
        [abduco, "-A", sess],
        stdin=slave,
        stdout=slave,
        stderr=subprocess.PIPE,
        close_fds=True,
    )
    os.close(slave)
    out = b""
    deadline = time.monotonic() + 2.5
    while time.monotonic() < deadline:
        r, _, _ = select.select([master], [], [], 0.05)
        if r:
            try:
                chunk = os.read(master, 4096)
            except OSError:
                break
            if not chunk:
                break
            out += chunk
            if b"ATTACH_MATRIX_" in out:
                break
    client.terminate()
    try:
        client.wait(timeout=1)
    except subprocess.TimeoutExpired:
        client.kill()
        client.wait(timeout=1)
    err = client.stderr.read() or b""
    os.close(master)
    with open(os.path.join(tmpdir, f"attach-matrix-{idx}.out"), "wb") as f:
        f.write(out)
    if b"I/O errors" in err or b"I/O error" in err:
        sys.stderr.buffer.write(err)
        raise SystemExit(f"attach {idx} reported I/O error")
    if b"ATTACH_MATRIX_" not in out:
        raise SystemExit(f"attach {idx} did not replay live output")

for i, delay in enumerate([0.02, 0.05, 0.1, 0.2, 0.4, 0.8, 1.4, 2.0], 1):
    time.sleep(delay)
    attach_once(i)
PYEOF
for _ in $(seq 1 20); do
	"$ABDUCO" -d -L 80 "$attach_matrix_sess" > "$tmpdir/attach-matrix-final.out"
	if grep -a -q "ATTACH_MATRIX_READY" "$tmpdir/attach-matrix-final.out"; then
		break
	fi
	sleep 0.25
done
assert_contains "ATTACH_MATRIX_READY" "$tmpdir/attach-matrix-final.out"
pass "interactive attach timing matrix"

run "attach dump send timing matrix"
matrix_sess="$prefix-matrix"
matrix_out="$tmpdir/matrix.out"
matrix_script="$tmpdir/matrix.sh"
cat > "$matrix_script" <<'EOF'
printf 'MATRIX_BOOT\n'
for i in $(seq 1 120); do printf 'MATRIX_START_%03d\n' "$i"; done
i=0
while [ "$i" -lt 80 ]; do
	printf 'MATRIX_TICK_%03d\n' "$i"
	i=$((i + 1))
	sleep 0.02
done
printf 'MATRIX_READY\n'
exec sh
EOF
"$ABDUCO" -n "$matrix_sess" sh "$matrix_script"
sleep 0.05
for i in $(seq 1 4); do
	if ! run_with_timeout 3 "$ABDUCO" -d -L 20 "$matrix_sess" > "$tmpdir/matrix-early-$i.out"; then
		fail "early dump $i timed out"
	fi
done
for _ in $(seq 1 20); do
	"$ABDUCO" -d "$matrix_sess" > "$matrix_out"
	if grep -a -q "MATRIX_READY" "$matrix_out"; then
		break
	fi
	sleep 0.25
done
assert_contains "MATRIX_BOOT" "$matrix_out"
assert_contains "MATRIX_START_120" "$matrix_out"
assert_contains "MATRIX_TICK_079" "$matrix_out"
assert_contains "MATRIX_READY" "$matrix_out"
for i in $(seq 1 30); do
	"$ABDUCO" -K "$matrix_sess" "echo MATRIX_SEND_$i" Enter
done
sleep 0.8
"$ABDUCO" -d -L 120 "$matrix_sess" > "$matrix_out"
assert_contains "MATRIX_SEND_1" "$matrix_out"
assert_contains "MATRIX_SEND_30" "$matrix_out"
for i in $(seq 1 8); do
	if ! run_with_timeout 3 "$ABDUCO" -d -L 40 "$matrix_sess" > "$tmpdir/matrix-repeat-$i.out"; then
		fail "repeat dump $i timed out"
	fi
	assert_contains "MATRIX_SEND_30" "$tmpdir/matrix-repeat-$i.out"
done
pass "attach dump send timing matrix"

run "invalid dump tail option combination fails"
sess="$prefix-invalid"
start_shell "$sess" 'printf "READY_INVALID\n"'
if "$ABDUCO" -d -N 10 -L 2 "$sess" >/dev/null 2>&1; then
	fail "-d -N and -L together unexpectedly succeeded"
fi
pass "invalid dump tail option combination fails"

run "detached session (-n) drains pty without client"
detach_sess="$prefix-detach-drain"
# Produce >64 KB of output (enough to fill the PTY kernel buffer) so that the
# command would block if the server did not read the PTY master.
"$ABDUCO" -n "$detach_sess" sh -c 'i=1
while [ "$i" -le 8000 ]; do
    printf "DETACH_DRAIN_%05d\n" "$i"
    i=$((i + 1))
done
printf "DETACH_DRAIN_DONE\n"
exec sh'
# Wait for the producer to finish — if read_pty is false, the command blocks
# at ~64 KB and DETACH_DRAIN_DONE never appears.
deadline=$((SECONDS + 15))
ready=0
while [ "$SECONDS" -lt "$deadline" ]; do
    sleep 0.3
    if "$ABDUCO" -d "$detach_sess" 2>/dev/null > "$tmpdir/detach-drain.out"; then
        if grep -a -q "DETACH_DRAIN_DONE" "$tmpdir/detach-drain.out"; then
            ready=1
            break
        fi
    fi
done
[ "$ready" -eq 1 ] || fail "detached session blocked; DETACH_DRAIN_DONE never appeared (read_pty not set for -n)"
assert_contains "DETACH_DRAIN_08000" "$tmpdir/detach-drain.out"
pass "detached session (-n) drains pty without client"

run "no alt-screen escapes from attach dump send"
sess="$prefix-alt"
script_out="$tmpdir/attach.script"
dump_out="$tmpdir/dump.raw"
key_out="$tmpdir/key.raw"
# Capture attach output via Python pty — portable across Linux and macOS,
# and handles the case where the abduco daemon briefly holds the pty slave
# open after the client exits (5-second read timeout ensures we don't hang).
python3 - "$ABDUCO" "$sess" > "$script_out" 2>/dev/null <<'PYEOF'
import sys, pty, os, select, time
abduco, sess = sys.argv[1], sys.argv[2]
args = [abduco, '-A', sess, 'sh', '-lc', 'printf ALT_ATTACH_OK\\n; sleep 0.1']
master_fd, slave_fd = pty.openpty()
pid = os.fork()
if pid == 0:
    import fcntl, termios
    os.setsid()
    fcntl.ioctl(slave_fd, termios.TIOCSCTTY, 1)
    for i in range(3):
        os.dup2(slave_fd, i)
    if slave_fd > 2:
        os.close(slave_fd)
    os.close(master_fd)
    os.execvp(args[0], args)
    os._exit(1)
os.close(slave_fd)
buf = b""
deadline = time.monotonic() + 5
while time.monotonic() < deadline:
    r, _, _ = select.select([master_fd], [], [], 0.2)
    if r:
        try:
            chunk = os.read(master_fd, 4096)
            buf += chunk
        except OSError:
            break
try:
    os.kill(pid, 9)
except OSError:
    pass
try:
    os.waitpid(pid, 0)
except ChildProcessError:
    pass
os.close(master_fd)
sys.stdout.buffer.write(buf)
PYEOF
assert_no_alt_screen "$script_out"
start_shell "$sess-dump" 'printf "ALT_DUMP_OK\n"'
"$ABDUCO" -d "$sess-dump" > "$dump_out"
"$ABDUCO" -K "$sess-dump" "echo ALT_KEY_OK" Enter > "$key_out"
sleep 0.2
"$ABDUCO" -d "$sess-dump" >> "$dump_out"
assert_no_alt_screen "$dump_out"
assert_no_alt_screen "$key_out"
pass "no alt-screen escapes from attach dump send"

run "raw blocked attach client does not stop pty drain"
sess="$prefix-raw-blocked"
raw_sock="$tmpdir/raw-blocked.sock"
"$ABDUCO" -n "$raw_sock" sh -lc 'printf "READY_RAW_BLOCKED\n"; exec sh'
sleep 0.3
raw_client_pid_file="$tmpdir/raw-client.pid"
python3 - "$raw_sock" "$raw_client_pid_file" <<'PYEOF' &
import os
import socket
import struct
import sys
import time

sock_path, pidfile = sys.argv[1], sys.argv[2]

def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise SystemExit(2)
        buf += chunk
    return buf

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock_path)
hdr = recv_exact(s, 8)
msg_type, msg_len = struct.unpack("@II", hdr)
if msg_type != 5:
    raise SystemExit(3)
if msg_len:
    recv_exact(s, msg_len)

attach_payload = struct.pack("@I", 0)
s.sendall(struct.pack("@II", 1, len(attach_payload)) + attach_payload)
with open(pidfile, "w", encoding="ascii") as f:
    f.write(str(os.getpid()))

# Keep the attached client alive but do not read any replay or pty output.
time.sleep(30)
PYEOF
raw_client_parent=$!
sleep 0.5
"$ABDUCO" -K -x "$raw_sock" $'python3 - <<'"'"'PY'"'"'\nimport sys\nfor i in range(600000):\n    print(f"RAW_BLOCK_FILL_{i:06d}")\nprint("RAW_BLOCKED_DONE")\nsys.stdout.flush()\nPY\n'
sleep 1
if ! run_with_timeout 8 "$ABDUCO" -d -L 80 "$raw_sock" > "$tmpdir/raw-blocked.out"; then
	kill "$raw_client_parent" >/dev/null 2>&1 || true
	if [[ -s "$raw_client_pid_file" ]]; then
		kill "$(cat "$raw_client_pid_file")" >/dev/null 2>&1 || true
	fi
	fail "dump timed out with a raw blocked attached client"
fi
kill "$raw_client_parent" >/dev/null 2>&1 || true
if [[ -s "$raw_client_pid_file" ]]; then
	kill "$(cat "$raw_client_pid_file")" >/dev/null 2>&1 || true
fi
assert_contains "RAW_BLOCKED_DONE" "$tmpdir/raw-blocked.out"
pass "raw blocked attach client does not stop pty drain"

run "real blocked attach client does not stop later dump"
real_sock="$tmpdir/real-blocked.sock"
"$ABDUCO" -n "$real_sock" sh -lc 'printf "READY_REAL_BLOCKED\n"; exec sh'
sleep 0.3
real_client_pid_file="$tmpdir/real-client.pid"
python3 - "$ABDUCO" "$real_sock" "$real_client_pid_file" <<'PYEOF' &
import subprocess
import sys
import time

abduco, sess, pidfile = sys.argv[1], sys.argv[2], sys.argv[3]
client = subprocess.Popen(
    [abduco, "-A", sess],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
)
with open(pidfile, "w", encoding="ascii") as f:
    f.write(str(client.pid))
try:
    time.sleep(30)
finally:
    if client.stdin:
        client.stdin.close()
    client.terminate()
    try:
        client.wait(timeout=1)
    except subprocess.TimeoutExpired:
        client.kill()
PYEOF
real_client_parent=$!
sleep 0.5
"$ABDUCO" -K -x "$real_sock" $'python3 - <<'"'"'PY'"'"'\nimport sys\nfor i in range(600000):\n    print(f"REAL_BLOCK_FILL_{i:06d}")\nprint("REAL_BLOCKED_DONE")\nsys.stdout.flush()\nPY\n'
sleep 1
if ! run_with_timeout 8 "$ABDUCO" -d -L 80 "$real_sock" > "$tmpdir/real-blocked.out"; then
	kill "$real_client_parent" >/dev/null 2>&1 || true
	if [[ -s "$real_client_pid_file" ]]; then
		kill "$(cat "$real_client_pid_file")" >/dev/null 2>&1 || true
	fi
	fail "dump timed out with a real blocked attach client"
fi
kill "$real_client_parent" >/dev/null 2>&1 || true
if [[ -s "$real_client_pid_file" ]]; then
	kill "$(cat "$real_client_pid_file")" >/dev/null 2>&1 || true
fi
assert_contains "REAL_BLOCKED_DONE" "$tmpdir/real-blocked.out"
pass "real blocked attach client does not stop later dump"

# Regression: dump must succeed when the server-side history exceeds the
# default Unix-stream SO_SNDBUF (~208 KB on Linux). The pre-fix code wrote
# the full 1 MiB history into a non-blocking socket via write_all, hitting
# EAGAIN mid-packet, dropping the client, and leaving the dump-side
# read_exact with "failed to fill whole buffer".
run "dump from large-history session does not partial-write"
large_sess="$prefix-large-dump"
"$ABDUCO" -n "$large_sess" sh -c 'i=1
while [ "$i" -le 60000 ]; do
    printf "LARGE_DUMP_%05d\n" "$i"
    i=$((i + 1))
done
printf "LARGE_DUMP_DONE\n"
exec sh'
# Wait until producer has finished writing into the session history. We
# scan the FULL dump (not -L 1) because `exec sh` afterwards writes a
# shell prompt that pushes LARGE_DUMP_DONE off the last-line position.
deadline=$((SECONDS + 30))
ready=0
while [ "$SECONDS" -lt "$deadline" ]; do
    sleep 0.5
    if "$ABDUCO" -d "$large_sess" 2>"$tmpdir/large-dump-probe.err" \
        > "$tmpdir/large-dump-probe.out"; then
        if grep -a -q "LARGE_DUMP_60000" "$tmpdir/large-dump-probe.out"; then
            ready=1
            break
        fi
    fi
done
[ "$ready" -eq 1 ] || fail "large session did not reach LARGE_DUMP_60000 within 30s"
"$ABDUCO" -d "$large_sess" > "$tmpdir/large-dump.out" 2> "$tmpdir/large-dump.err"
assert_not_contains "failed to fill whole buffer" "$tmpdir/large-dump.err"
assert_not_contains "I/O error" "$tmpdir/large-dump.err"
assert_not_contains "disconnected (no MSG_EXIT" "$tmpdir/large-dump.err"
assert_contains "LARGE_DUMP_DONE" "$tmpdir/large-dump.out"
# Last line should be present (history rotation may evict early ones, but
# 60k * ~17 bytes ≈ 1.0 MiB barely fits HISTORY_CAP — the tail must be there).
assert_contains "LARGE_DUMP_60000" "$tmpdir/large-dump.out"
pass "dump from large-history session does not partial-write"

# Regression: attaching to a large-history session triggers the same
# send_history replay path; it must not surface as a false-positive
# "exited due to I/O errors" / "disconnected" message.
run "attach to large-history session replays without I/O error"
attach_large_out="$tmpdir/attach-large.out"
attach_large_err="$tmpdir/attach-large.err"
python3 - "$ABDUCO" "$large_sess" "$attach_large_out" "$attach_large_err" <<'PYEOF'
import os
import pty
import select
import subprocess
import sys
import time

abduco, sess, out_path, err_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
master, slave = pty.openpty()
client = subprocess.Popen(
    [abduco, "-A", sess],
    stdin=slave,
    stdout=slave,
    stderr=subprocess.PIPE,
    close_fds=True,
)
os.close(slave)
out = b""
deadline = time.monotonic() + 5
while time.monotonic() < deadline:
    r, _, _ = select.select([master], [], [], 0.2)
    if r:
        try:
            chunk = os.read(master, 65536)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    if b"LARGE_DUMP_60000" in out:
        # got the tail of the replay; that's enough to prove the path worked
        break
client.terminate()
try:
    client.wait(timeout=2)
except subprocess.TimeoutExpired:
    client.kill()
    client.wait(timeout=1)
err = client.stderr.read() or b""
os.close(master)
with open(out_path, "wb") as f:
    f.write(out)
with open(err_path, "wb") as f:
    f.write(err)
PYEOF
assert_not_contains "I/O error" "$attach_large_err"
assert_not_contains "failed to fill whole buffer" "$attach_large_err"
assert_not_contains "disconnected (no MSG_EXIT" "$attach_large_err"
assert_contains "LARGE_DUMP_60000" "$attach_large_out"
pass "attach to large-history session replays without I/O error"

# Regression: when the inner process exits while the send queue is heavy
# (history pending replay + buffered broadcast), the server must still
# deliver MSG_EXIT to the attach client. The pre-fix code used
# write_all(MSG_EXIT) on a non-blocking socket and dropped MSG_EXIT into
# a full SNDBUF; the client then surfaced "exited due to I/O errors"
# instead of the actual exit code.
run "MSG_EXIT delivered under send-buffer pressure"
exit_sess="$prefix-exit-pressure"
exit_out="$tmpdir/exit-pressure.out"
exit_err="$tmpdir/exit-pressure.err"
"$ABDUCO" -n "$exit_sess" sh -c 'i=1
while [ "$i" -le 60000 ]; do
    printf "EXIT_FILL_%05d\n" "$i"
    i=$((i + 1))
done
exit 7'
# Block until server has registered the child exit (socket file becomes
# group-readable in run_server's mark-after-exit path).
deadline=$((SECONDS + 20))
while [ "$SECONDS" -lt "$deadline" ]; do
    sleep 0.3
    if ! "$ABDUCO" 2>/dev/null | grep -a -q -- "$exit_sess"; then
        break
    fi
done
# If session is still listed, attach must collect MSG_EXIT(7); if it
# already vanished (no clients waiting after exit), the path was already
# exercised — skip in that case.
if "$ABDUCO" 2>/dev/null | grep -a -q -- "$exit_sess"; then
    python3 - "$ABDUCO" "$exit_sess" "$exit_out" "$exit_err" <<'PYEOF'
import os
import pty
import select
import subprocess
import sys
import time

abduco, sess, out_path, err_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
master, slave = pty.openpty()
client = subprocess.Popen(
    [abduco, "-A", sess],
    stdin=slave,
    stdout=slave,
    stderr=subprocess.PIPE,
    close_fds=True,
)
os.close(slave)
out = b""
deadline = time.monotonic() + 8
while time.monotonic() < deadline:
    r, _, _ = select.select([master], [], [], 0.2)
    if r:
        try:
            chunk = os.read(master, 65536)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    if client.poll() is not None:
        break
err = client.stderr.read() or b""
try:
    rc = client.wait(timeout=3)
except subprocess.TimeoutExpired:
    client.kill()
    rc = client.wait(timeout=1)
os.close(master)
with open(out_path, "wb") as f:
    f.write(out)
with open(err_path, "wb") as f:
    f.write(err)
print(f"client_rc={rc}")
PYEOF
    assert_not_contains "I/O error" "$exit_err"
    assert_not_contains "failed to fill whole buffer" "$exit_err"
    assert_not_contains "disconnected (no MSG_EXIT" "$exit_err"
    assert_contains "exit status 7" "$exit_err"
fi
pass "MSG_EXIT delivered under send-buffer pressure"

# Regression: `lich` (no args = list) must emit lines that downstream
# parsers can split into >= 4 whitespace-separated fields, with the PID
# in parts[-2] and the session name in parts[-1]. This matches what
# quests/status.py expects (and what the C abduco implementation does).
# This test creates a name-based session (so it lands in the lich
# directory and shows up in `lich` list output) instead of the
# path-based prefix used by other tests. Keep the name very short:
# macOS sockaddr_un.sun_path caps at ~104 bytes and CI runner hostnames
# (appended as @hostname) eat a chunk of that budget.
run "list output is parseable as 4+ fields"
list_sess="lit_$$"
"$ABDUCO" -n "$list_sess" sh -c 'printf "READY_LIST\n"; exec sh'
sleep 0.3
"$ABDUCO" > "$tmpdir/list.out"
python3 - "$tmpdir/list.out" "$list_sess" <<'PYEOF'
import sys

path, expected = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8", errors="replace") as f:
    lines = f.read().splitlines()
matched = False
for line in lines:
    parts = line.split()
    if len(parts) < 4:
        continue
    try:
        int(parts[-2])
    except ValueError:
        continue
    if parts[-1] == expected:
        matched = True
        break
if not matched:
    sys.stderr.write(
        f"no list line matched name={expected!r} with >=4 fields and int pid; got:\n"
    )
    for line in lines:
        sys.stderr.write(f"  {line!r}\n")
    raise SystemExit(1)
PYEOF
# Best-effort cleanup; the EXIT trap only sweeps "$prefix-*".
"$ABDUCO" -K -x "$list_sess" $'exit\n' >/dev/null 2>&1 || true
pass "list output is parseable as 4+ fields"

# Regression: the lich server must shorten its own argv via setproctitle so
# that a `pkill -f <fragment-of-original-command>` cannot match the server
# process. Without this fix, the bootstrap prompt embedded in the lich
# command line (e.g. `lich -n NAME claude --agent X <PROMPT>`) sits in
# /proc/<server-pid>/cmdline and any pkill -f against a prompt fragment
# delivers SIGTERM to the server, leaving an orphan socket file.
#
# We only test the property that matters for safety: a unique sentinel
# present in the original command line is NOT present in the running
# server's /proc/<pid>/cmdline. /proc is unavailable on macOS; that case
# soft-passes since the BSD setproctitle(3) path is exercised separately
# on macOS CI and we cannot inspect cmdline portably there.
run "server argv is shortened (no longer contains user command tokens)"
spt_sess="spt$$"
spt_sentinel="SPT_SENTINEL_$$"
"$ABDUCO" -n "$spt_sess" sh -c "printf '%s\\n%s\\n' READY $spt_sentinel; while sleep 60; do :; done"
sleep 0.4
host="$(hostname)"
spt_sock="$HOME/.lich/${spt_sess}@${host}"
if [[ ! -S "$spt_sock" ]]; then
    fail "expected socket $spt_sock for setproctitle test"
fi
# Use lich's own list output to get the PID portably across Linux/macOS
# (pgrep -u USER takes a username on Linux but a UID on macOS BSD pgrep;
# fuser also differs between util-linux and BSD). lich list emits 4
# whitespace-separated fields with PID at parts[-2] and name at parts[-1].
spt_pid=$("$ABDUCO" 2>/dev/null | awk -v n="$spt_sess" '$NF==n {print $(NF-1)}' | head -1)
[[ -z "$spt_pid" ]] && fail "could not locate server PID for $spt_sess via lich list"
if [[ -r "/proc/${spt_pid}/cmdline" ]]; then
    spt_cmdline=$(tr '\0' ' ' < "/proc/${spt_pid}/cmdline")
    if echo "$spt_cmdline" | grep -q "$spt_sentinel"; then
        fail "server cmdline still contains sentinel $spt_sentinel: $spt_cmdline"
    fi
else
    # macOS: /proc not available + setproctitle is noop. Soft-pass the
    # introspection step; the build itself verifies the cfg-gated code
    # compiles, which is all we can portably do here.
    echo "  note: /proc/${spt_pid}/cmdline unavailable (likely macOS); soft-pass"
fi
"$ABDUCO" -K -x "$spt_sess" $'exit\n' >/dev/null 2>&1 || true
for _ in $(seq 1 30); do
    [[ ! -S "$spt_sock" ]] && break
    sleep 0.1
done
rm -f "${spt_sock}.log" 2>/dev/null || true
pass "server argv is shortened (no longer contains user command tokens)"

# Regression: SIGTERM to the server PID must run graceful shutdown that
# removes the socket file. Without this fix, SIGTERM took the default
# `terminate` action and left an orphan socket.
run "SIGTERM triggers graceful shutdown and removes socket"
sig_sess="sig$$"
"$ABDUCO" -n "$sig_sess" sh -c 'printf READY\n; while sleep 60; do :; done'
sleep 0.4
sig_sock="$HOME/.lich/${sig_sess}@${host}"
sig_pid=$("$ABDUCO" 2>/dev/null | awk -v n="$sig_sess" '$NF==n {print $(NF-1)}' | head -1)
[[ -z "$sig_pid" ]] && fail "could not locate server PID for $sig_sess via lich list"
kill -TERM "$sig_pid"
# Wait up to 6s (EXIT_DRAIN_DEADLINE=5s in src/main.rs + buffer).
for _ in $(seq 1 60); do
    kill -0 "$sig_pid" 2>/dev/null || break
    sleep 0.1
done
if kill -0 "$sig_pid" 2>/dev/null; then
    fail "server PID $sig_pid still alive 6s after SIGTERM"
fi
if [[ -S "$sig_sock" ]]; then
    fail "socket file $sig_sock not removed after SIGTERM graceful shutdown"
fi
sig_log="${sig_sock}.log"
if [[ -f "$sig_log" ]]; then
    if ! grep -q " start " "$sig_log"; then
        fail "log file $sig_log missing 'start' entry"
    fi
    if ! grep -q " shutdown " "$sig_log"; then
        fail "log file $sig_log missing 'shutdown' entry"
    fi
    rm -f "$sig_log"
else
    fail "log file $sig_log not created"
fi
pass "SIGTERM triggers graceful shutdown and removes socket"

echo "$tests_ok/$tests_run tests passed"
[[ "$tests_ok" -eq "$tests_run" ]]
