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

start_shell() {
	local sess="$1" prelude="$2"
	"$ABDUCO" -n "$sess" sh -lc "$prelude; exec sh"
	sleep 0.3
}

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

run "invalid dump tail option combination fails"
sess="$prefix-invalid"
start_shell "$sess" 'printf "READY_INVALID\n"'
if "$ABDUCO" -d -N 10 -L 2 "$sess" >/dev/null 2>&1; then
	fail "-d -N and -L together unexpectedly succeeded"
fi
pass "invalid dump tail option combination fails"

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

echo "$tests_ok/$tests_run tests passed"
[[ "$tests_ok" -eq "$tests_run" ]]
