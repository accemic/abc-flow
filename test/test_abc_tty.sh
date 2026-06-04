#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/abc/abc"
TMP_ROOT="$(mktemp -d)"

cleanup() {
	rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

TOOL_ROOT="$TMP_ROOT/tools"
REPO_DIR="$TMP_ROOT/repo"
mkdir -p "$TOOL_ROOT/2024.1/bin" "$REPO_DIR"
git -C "$REPO_DIR" init -q

cat >"$TOOL_ROOT/2024.1/bin/vivado" <<'EOF'
#!/usr/bin/env python3
import sys
import termios
import time

if len(sys.argv) > 1 and sys.argv[1] == "-version":
    print("Vivado v2024.1 (64-bit)")
    raise SystemExit(0)

fd = sys.stdin.fileno()
attrs = termios.tcgetattr(fd)
if hasattr(termios, "INLCR"):
    attrs[0] |= termios.INLCR
attrs[3] &= ~(termios.ICANON | termios.ECHO)

cc = attrs[6]
for name, value in (
    ("VEOF", b"\x00"),
    ("VREPRINT", b"\x00"),
    ("VWERASE", b"\x00"),
    ("VLNEXT", b"\x00"),
):
    idx = getattr(termios, name, None)
    if idx is not None:
        cc[idx] = value

termios.tcsetattr(fd, termios.TCSANOW, attrs)
print("ERROR: stub vivado failure", flush=True)
time.sleep(30)
EOF

chmod +x "$TOOL_ROOT/2024.1/bin/vivado"

python3 - "$SCRIPT" "$TOOL_ROOT" "$REPO_DIR" <<'PY'
import os
import signal
import subprocess
import sys
import termios


def apply_expected_state(fd):
    attrs = termios.tcgetattr(fd)
    if hasattr(termios, "INLCR"):
        attrs[0] &= ~termios.INLCR
    attrs[3] |= termios.ICANON | termios.ECHO

    cc = attrs[6]
    for name, value in (
        ("VEOF", b"\x04"),
        ("VREPRINT", b"\x12"),
        ("VWERASE", b"\x17"),
        ("VLNEXT", b"\x16"),
    ):
        idx = getattr(termios, name, None)
        if idx is not None:
            cc[idx] = value

    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    return termios.tcgetattr(fd)


script, tool_root, repo_dir = sys.argv[1:4]
master_fd, slave_fd = os.openpty()
proc = None
first_line = ""

try:
    expected = apply_expected_state(slave_fd)
    env = os.environ.copy()
    env["ABC_VIVADO_ROOTS"] = tool_root

    proc = subprocess.Popen(
        [script, "--vivado-version", "2024.1", "-sim", "dummy.abc"],
        cwd=repo_dir,
        env=env,
        stdin=slave_fd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )

    assert proc.stdout is not None
    first_line = proc.stdout.readline()
    if "ERROR: stub vivado failure" not in first_line:
        raise SystemExit(f"did not observe the expected failure line, saw: {first_line!r}")

    proc.send_signal(signal.SIGINT)
    stdout_rest, stderr_text = proc.communicate(timeout=10)
    stdout_text = first_line + stdout_rest

    if proc.returncode != 130:
        raise SystemExit(
            f"expected abc to exit with 130 after SIGINT, got {proc.returncode}\n"
            f"stdout:\n{stdout_text}\n"
            f"stderr:\n{stderr_text}\n"
        )

    actual = termios.tcgetattr(slave_fd)
    if actual != expected:
        raise SystemExit(
            "terminal settings were not restored after interrupt\n"
            f"expected: {expected!r}\n"
            f"actual:   {actual!r}\n"
            f"stdout:\n{stdout_text}\n"
            f"stderr:\n{stderr_text}\n"
        )
finally:
    if proc is not None and proc.poll() is None:
        proc.kill()
        proc.wait()
    os.close(master_fd)
    os.close(slave_fd)
PY

echo "ok - tty restore on interrupt"
