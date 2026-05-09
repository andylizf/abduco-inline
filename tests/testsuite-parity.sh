#!/usr/bin/env bash

set -euo pipefail

C_LICH="${1:-./c/lich}"
R_LICH="${2:-./target/release/lich}"

if [[ ! -x "$C_LICH" || ! -x "$R_LICH" ]]; then
	echo "usage: $0 /path/to/c/lich /path/to/rust/lich" >&2
	exit 2
fi

tmpdir="${TMPDIR:-/tmp}/lich-parity-tests-$$"
prefix="/tmp/lich-parity-$$"
mkdir -p "$tmpdir"
tests_run=0
tests_ok=0

cleanup() {
	for sess in "$prefix"-*; do
		"$C_LICH" -K -x "$sess" $'exit\n' >/dev/null 2>&1 || true
		"$R_LICH" -K -x "$sess" $'exit\n' >/dev/null 2>&1 || true
	done
	rm -rf "$tmpdir"
}
trap cleanup EXIT

run() {
	tests_run=$((tests_run + 1))
	echo "test - $1 ($(date +%H:%M:%S))"
}

pass() {
	tests_ok=$((tests_ok + 1))
	echo "ok - $1"
}

fail() {
	echo "not ok - $1" >&2
	exit 1
}

assert_contains() {
	local needle="$1" file="$2"
	grep -a -q -- "$needle" "$file" || fail "missing '$needle' in $file"
}

normalize() {
	tr -d '\r' < "$1" | sed -E 's/[[:space:]]+$//'
}

start_pair() {
	local name="$1" prelude="$2"
	"$C_LICH" -n "$prefix-c-$name" sh -lc "$prelude; exec sh"
	"$R_LICH" -n "$prefix-r-$name" sh -lc "$prelude; exec sh"
	sleep 0.4
}

dump_pair() {
	local name="$1" label="$2"
	shift 2
	"$C_LICH" -d "$@" "$prefix-c-$name" > "$tmpdir/c-$label.out"
	"$R_LICH" -d "$@" "$prefix-r-$name" > "$tmpdir/r-$label.out"
	normalize "$tmpdir/c-$label.out" > "$tmpdir/c-$label.norm"
	normalize "$tmpdir/r-$label.out" > "$tmpdir/r-$label.norm"
	diff -u "$tmpdir/c-$label.norm" "$tmpdir/r-$label.norm" > "$tmpdir/$label.diff" ||
		fail "C/Rust dump mismatch for $label; see $tmpdir/$label.diff"
}

run "missing command fails before reporting session created"
set +e
"$C_LICH" -n "$prefix-c-missing" /no/such/lich-command > "$tmpdir/c-missing.out" 2> "$tmpdir/c-missing.err"
c_code=$?
"$R_LICH" -n "$prefix-r-missing" /no/such/lich-command > "$tmpdir/r-missing.out" 2> "$tmpdir/r-missing.err"
r_code=$?
set -e
[[ "$c_code" -ne 0 ]] || fail "C missing command unexpectedly succeeded"
[[ "$r_code" -ne 0 ]] || fail "Rust missing command unexpectedly succeeded"
assert_contains "server-execvp" "$tmpdir/c-missing.err"
assert_contains "server-execvp" "$tmpdir/r-missing.err"
pass "missing command fails before reporting session created"

run "no-tty winsize parity"
LICH_ROWS=33 LICH_COLS=111 "$C_LICH" -n "$prefix-c-winsize" sh -lc 'stty size; exec sh'
LICH_ROWS=33 LICH_COLS=111 "$R_LICH" -n "$prefix-r-winsize" sh -lc 'stty size; exec sh'
sleep 0.4
dump_pair winsize winsize
assert_contains "33 111" "$tmpdir/c-winsize.norm"
assert_contains "33 111" "$tmpdir/r-winsize.norm"
pass "no-tty winsize parity"

run "dump tail parity"
start_pair tail 'for i in $(seq 1 60); do printf "PARITY_TAIL_%03d\n" "$i"; done'
dump_pair tail tail-full
dump_pair tail tail-lines -L 7
dump_pair tail tail-bytes -N 180
assert_contains "PARITY_TAIL_060" "$tmpdir/c-tail-lines.norm"
assert_contains "PARITY_TAIL_060" "$tmpdir/r-tail-lines.norm"
pass "dump tail parity"

run "send keys parity"
start_pair keys 'printf "PARITY_KEYS_READY\n"'
"$C_LICH" -K "$prefix-c-keys" "echo PARITY_ENTER_OK" Enter
"$R_LICH" -K "$prefix-r-keys" "echo PARITY_ENTER_OK" Enter
sleep 0.2
"$C_LICH" -K "$prefix-c-keys" echo Space PARITY_SPACE_OK Enter
"$R_LICH" -K "$prefix-r-keys" echo Space PARITY_SPACE_OK Enter
sleep 0.2
"$C_LICH" -K -x "$prefix-c-keys" $'echo PARITY_LITERAL_OK\n'
"$R_LICH" -K -x "$prefix-r-keys" $'echo PARITY_LITERAL_OK\n'
sleep 0.4
dump_pair keys keys -L 80
assert_contains "PARITY_ENTER_OK" "$tmpdir/c-keys.norm"
assert_contains "PARITY_SPACE_OK" "$tmpdir/c-keys.norm"
assert_contains "PARITY_LITERAL_OK" "$tmpdir/c-keys.norm"
pass "send keys parity"

run "-A create-if-missing parity"
"$C_LICH" -A "$prefix-c-create-a" sh -lc 'printf "PARITY_A_CREATE\n"; exec sh' >/dev/null 2>&1 || true
"$R_LICH" -A "$prefix-r-create-a" sh -lc 'printf "PARITY_A_CREATE\n"; exec sh' >/dev/null 2>&1 || true
sleep 0.4
dump_pair create-a create-a -L 20
assert_contains "PARITY_A_CREATE" "$tmpdir/c-create-a.norm"
assert_contains "PARITY_A_CREATE" "$tmpdir/r-create-a.norm"
pass "-A create-if-missing parity"

run "read-only attach blocks stdin parity"
start_pair readonly 'printf "PARITY_READONLY_READY\n"'
python3 - "$C_LICH" "$prefix-c-readonly" <<'PYEOF'
import os
import pty
import select
import subprocess
import sys
import time

lich, sess = sys.argv[1], sys.argv[2]
master, slave = pty.openpty()
client = subprocess.Popen([lich, "-r", "-A", sess], stdin=slave, stdout=slave, stderr=subprocess.DEVNULL)
os.close(slave)
deadline = time.monotonic() + 1.5
while time.monotonic() < deadline:
    r, _, _ = select.select([master], [], [], 0.05)
    if r:
        try:
            os.read(master, 4096)
        except OSError:
            break
        break
os.write(master, b"echo PARITY_READONLY_BAD\r")
time.sleep(0.3)
os.write(master, b"\x1c")
try:
    client.wait(timeout=2)
except subprocess.TimeoutExpired:
    client.kill()
    raise
os.close(master)
PYEOF
python3 - "$R_LICH" "$prefix-r-readonly" <<'PYEOF'
import os
import pty
import select
import subprocess
import sys
import time

lich, sess = sys.argv[1], sys.argv[2]
master, slave = pty.openpty()
client = subprocess.Popen([lich, "-r", "-A", sess], stdin=slave, stdout=slave, stderr=subprocess.DEVNULL)
os.close(slave)
deadline = time.monotonic() + 1.5
while time.monotonic() < deadline:
    r, _, _ = select.select([master], [], [], 0.05)
    if r:
        try:
            os.read(master, 4096)
        except OSError:
            break
        break
os.write(master, b"echo PARITY_READONLY_BAD\r")
time.sleep(0.3)
os.write(master, b"\x1c")
try:
    client.wait(timeout=2)
except subprocess.TimeoutExpired:
    client.kill()
    raise
os.close(master)
PYEOF
sleep 0.3
dump_pair readonly readonly -L 40
if grep -a -q "PARITY_READONLY_BAD" "$tmpdir/c-readonly.norm"; then
	fail "C read-only attach allowed stdin"
fi
if grep -a -q "PARITY_READONLY_BAD" "$tmpdir/r-readonly.norm"; then
	fail "Rust read-only attach allowed stdin"
fi
pass "read-only attach blocks stdin parity"

run "invalid argument parity"
set +e
"$C_LICH" -d -N 10 -L 2 "$prefix-c-keys" > "$tmpdir/c-invalid.out" 2> "$tmpdir/c-invalid.err"
c_code=$?
"$R_LICH" -d -N 10 -L 2 "$prefix-r-keys" > "$tmpdir/r-invalid.out" 2> "$tmpdir/r-invalid.err"
r_code=$?
set -e
[[ "$c_code" -ne 0 ]] || fail "C invalid args unexpectedly succeeded"
[[ "$r_code" -ne 0 ]] || fail "Rust invalid args unexpectedly succeeded"
pass "invalid argument parity"

echo "$tests_ok/$tests_run parity tests passed"
[[ "$tests_ok" -eq "$tests_run" ]]
