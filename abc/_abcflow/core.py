"""Backend-agnostic plumbing for the abc-flow launcher.

Everything here is shared by the Vivado, XSim, and Verilator backends:
the `SimPlan` dataclass that holds the result of parsing a `.abc` file,
the `collect_sim_plan` collector (which shells out to `abc-export` and
runs Tcl on the user's behalf), CLI argument helpers, output streaming
with optional color/filter, and small filesystem utilities.
"""

from __future__ import annotations

import os
import platform
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, Iterator, List, Optional, Tuple

try:
    import termios
except ImportError:
    termios = None  # type: ignore[assignment]


# --------------------------------------------------------------------------------------
# Output coloring / filtering


class Ansi:
    ESC = "\x1b"
    RESET = f"{ESC}[0m"
    BOLD_RED = f"{ESC}[1;31m"
    BOLD_YELLOW = f"{ESC}[1;33m"
    BOLD_GREEN = f"{ESC}[1;32m"
    BOLD_CYAN = f"{ESC}[1;36m"
    BOLD_BLUE = f"{ESC}[1;34m"
    CYAN = f"{ESC}[36m"


_SKIP_LINE_PATTERNS: List[re.Pattern[str]] = [
    # Historically noisy in some setups.
    re.compile(r"\[XSIM 43-4100\]"),
]

_CLASSIFIERS: List[Tuple[re.Pattern[str], str]] = [
    (re.compile(r"(?i)(ERROR:|Fatal:)"), Ansi.BOLD_RED),
    (re.compile(r"(?i)CRITICAL"), Ansi.BOLD_YELLOW),
    (re.compile(r"(?i)WARNING"), Ansi.BOLD_YELLOW),
    (re.compile(r"(?i)^INFO:"), Ansi.CYAN),
    (re.compile(r"(?i)(SUCCESS|No errors)"), Ansi.BOLD_GREEN),
    (re.compile(r"(?i)DEBUG"), Ansi.BOLD_BLUE),
]


def _env_truthy(name: str) -> bool:
    v = os.environ.get(name)
    if v is None:
        return False
    return v.strip().lower() not in ("", "0", "false", "no", "off")


def want_colored_output() -> bool:
    """Decide whether to colorize/filter Vivado output.

    Rules:
      - Disable if ABC_NO_COLOR=1 or NO_COLOR is set.
      - Enable if ABC_COLOR=1 (force).
      - Otherwise: only enable on interactive terminals.
    """

    if _env_truthy("ABC_NO_COLOR") or ("NO_COLOR" in os.environ):
        return False
    if _env_truthy("ABC_COLOR"):
        return True
    return bool(sys.stdout.isatty())


def want_filtered_output() -> bool:
    """Whether to filter (skip/trim/classify) Vivado output.

    Defaults to the same decision as coloring (interactive terminals).
    Can be forced on/off via ABC_FILTER=1/0.
    """

    if "ABC_FILTER" in os.environ:
        return _env_truthy("ABC_FILTER")
    return want_colored_output()


def enable_windows_vt_mode() -> bool:
    """Enable ANSI escape processing on Windows consoles.

    On recent Windows 10/11 terminals this is typically already enabled, but
    classic conhost may require toggling ENABLE_VIRTUAL_TERMINAL_PROCESSING.

    Returns True if VT mode is enabled (or not needed), False otherwise.
    """

    if platform.system().lower() != "windows":
        return True
    try:
        import ctypes

        kernel32 = ctypes.windll.kernel32
        handle = kernel32.GetStdHandle(-11)  # STD_OUTPUT_HANDLE
        if handle == 0:
            return False
        mode = ctypes.c_uint32()
        if kernel32.GetConsoleMode(handle, ctypes.byref(mode)) == 0:
            return False
        ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004
        new_mode = mode.value | ENABLE_VIRTUAL_TERMINAL_PROCESSING
        if kernel32.SetConsoleMode(handle, new_mode) == 0:
            return False
        return True
    except Exception:
        return False


def iter_filtered_colored_lines(stream: Iterator[str], *, use_color: bool) -> Iterator[str]:
    """Filter / colorize Vivado output line-by-line.

    Yields lines *without* trailing newlines, so callers can decide how to emit.
    """

    for raw in stream:
        line = raw.rstrip("\r\n").strip()
        if not line:
            continue

        if any(p.search(line) for p in _SKIP_LINE_PATTERNS):
            continue

        if use_color:
            for pat, color in _CLASSIFIERS:
                if pat.search(line):
                    yield f"{color}{line}{Ansi.RESET}"
                    break
            else:
                yield line
        else:
            yield line


# --------------------------------------------------------------------------------------
# Plan dataclass: the structured form of a parsed .abc file. Produced by
# `collect_sim_plan` (via abc-export) and consumed by every backend.


@dataclass(frozen=True)
class SimPlan:
    src_files: List[Path]
    sim_files: List[Path]
    simulate_tops: List[str]
    sim_generics: List[str]
    sim_verilog_defines: List[str]
    xsim_more_options: List[str]
    unsupported_commands: List[str]
    root_dir: Path


# --------------------------------------------------------------------------------------
# Terminal state restore for subprocesses that may leave the tty in a bad mode.


class TerminalStateGuard:
    """Best-effort terminal state restore for interactive subprocess runs."""

    def __init__(self) -> None:
        self._states: List[Tuple[int, List[object]]] = []

    def __enter__(self) -> "TerminalStateGuard":
        if termios is None:
            return self

        seen_ttys: set[str] = set()
        for stream in (sys.stdin, sys.stderr, sys.stdout):
            try:
                fd = stream.fileno()
            except (AttributeError, OSError, ValueError):
                continue
            if not os.isatty(fd):
                continue
            try:
                tty_name = os.ttyname(fd)
            except OSError:
                tty_name = f"fd:{fd}"
            if tty_name in seen_ttys:
                continue
            seen_ttys.add(tty_name)

            dup_fd = os.dup(fd)
            try:
                attrs = termios.tcgetattr(dup_fd)
            except termios.error:
                os.close(dup_fd)
                continue
            self._states.append((dup_fd, attrs))

        if self._states:
            return self

        try:
            tty_fd = os.open("/dev/tty", os.O_RDWR)
        except OSError:
            return self

        try:
            attrs = termios.tcgetattr(tty_fd)
        except termios.error:
            os.close(tty_fd)
            return self

        self._states.append((tty_fd, attrs))
        return self

    def restore(self) -> None:
        if termios is None:
            return
        for fd, attrs in self._states:
            try:
                termios.tcsetattr(fd, termios.TCSANOW, attrs)
            except termios.error:
                pass

    def close(self) -> None:
        for fd, _ in self._states:
            try:
                os.close(fd)
            except OSError:
                pass
        self._states.clear()

    def __exit__(self, exc_type, exc, tb) -> None:
        self.restore()
        self.close()


def eprint(msg: str) -> None:
    if os.environ.get("ABC_QUIET") == "1":
        return
    print(msg, file=sys.stderr)


# --------------------------------------------------------------------------------------
# Config + git discovery


def parse_simple_kv_config(path: Path) -> Dict[str, str]:
    """Parse a simple key=value config file.

    Supports:
      - comments starting with '#' or ';'
      - blank lines
      - keys are case-sensitive (kept as-is)
    """

    cfg: Dict[str, str] = {}
    if not path.is_file():
        return cfg

    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith(";"):
            continue
        if "=" not in line:
            raise ValueError(f"Invalid .abc.config line (expected key=value): {raw!r}")
        k, v = line.split("=", 1)
        k = k.strip()
        v = v.strip()
        if not k:
            raise ValueError(f"Invalid .abc.config line (empty key): {raw!r}")
        cfg[k] = v
    return cfg


def find_git_root(start: Path) -> Optional[Path]:
    """Return git root for `start`, or None if not in a git repo."""
    try:
        out = subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"],
            cwd=str(start),
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
        if out:
            return Path(out)
    except Exception:
        return None
    return None


def split_path_list(value: str) -> List[str]:
    parts = [p.strip() for p in value.split(os.pathsep)]
    return [p for p in parts if p]


# --------------------------------------------------------------------------------------
# CLI argv helpers


def parse_args_mode(argv: List[str]) -> Tuple[bool, bool]:
    """Return (wants_sim, wants_impl).

    Note: abc.tcl supports combining switches in general, but user requested
    that -sim and (-synth|-impl|-bitgen) must not be combined.
    """
    wants_sim = "-sim" in argv
    wants_impl = any(flag in argv for flag in ("-synth", "-impl", "-bitgen"))
    return wants_sim, wants_impl


def extract_opt(argv: List[str], opt: str) -> Tuple[Optional[str], List[str]]:
    """Extract an option of the form `--opt VALUE`.

    Returns (value, remaining_argv).
    If the option is not present, returns (None, argv).
    If present but missing value, raises ValueError.
    """
    out: List[str] = []
    value: Optional[str] = None
    i = 0
    while i < len(argv):
        if argv[i] == opt:
            if value is not None:
                raise ValueError(f"{opt} specified multiple times")
            if i + 1 >= len(argv):
                raise ValueError(f"{opt} requires a value")
            value = argv[i + 1]
            i += 2
            continue
        out.append(argv[i])
        i += 1
    return value, out


def extract_flag(argv: List[str], flag: str) -> Tuple[bool, List[str]]:
    """Extract a boolean flag.

    Returns (present, remaining_argv).
    If the flag appears multiple times, it is treated as present.
    """
    out: List[str] = []
    present = False
    for a in argv:
        if a == flag:
            present = True
        else:
            out.append(a)
    return present, out


def validate_abc_tcl_args(argv: List[str]) -> List[str]:
    """Validate args forwarded to abc.tcl.

    Historically the flow accepted `-root=<value>` but not a bare `-root`
    followed by a separate argument. Keep this as a dedicated helper so tests
    and the launcher share the same validation.
    """

    for a in argv:
        if a == "--":
            break
        if a == "-root" or a == "-root=":
            raise ValueError("-root must be passed as -root=<value>")
    return argv


def extract_root_override(argv: List[str]) -> Optional[str]:
    for a in argv:
        if a == "--":
            break
        if a.startswith("-root="):
            return a[len("-root=") :]
    return None


def split_argv_user(argv: List[str]) -> Tuple[List[str], List[str]]:
    if "--" not in argv:
        return list(argv), []
    idx = argv.index("--")
    return argv[:idx], argv[idx + 1 :]


def expand_tasks(paths: List[str]) -> List[Path]:
    tasks: List[Path] = []
    for arg in paths:
        p = Path(arg)
        if p.is_file():
            tasks.append(p)
        elif Path(f"{arg}.abc").is_file():
            tasks.append(Path(f"{arg}.abc"))
        elif p.is_dir():
            dirs = [p]
            while dirs:
                cur = dirs.pop(0)
                try:
                    subdirs = sorted((child for child in cur.iterdir() if child.is_dir()), key=lambda child: child.name)
                except FileNotFoundError:
                    subdirs = []
                dirs.extend(subdirs)
                if "test" in cur.parts:
                    for proj in sorted(cur.glob("*.abc")):
                        tasks.append(proj)
        else:
            raise FileNotFoundError(f"File or directory not found '{arg}'")
    return tasks


# --------------------------------------------------------------------------------------
# Subprocess streaming


def run_streaming_command(cmd: List[str], *, cwd: Optional[Path] = None, use_filter: bool, use_color: bool) -> int:
    with TerminalStateGuard():
        try:
            proc = subprocess.Popen(
                cmd,
                cwd=str(cwd) if cwd else None,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
                errors="replace",
            )
        except FileNotFoundError as e:
            print(f"Error: failed to execute {' '.join(cmd[:1])}: {e}", file=sys.stderr)
            return 1

        assert proc.stdout is not None

        try:
            if use_filter:
                for out_line in iter_filtered_colored_lines(proc.stdout, use_color=use_color):
                    print(out_line, flush=True)
            else:
                for raw in proc.stdout:
                    sys.stdout.write(raw)
                    sys.stdout.flush()
        except KeyboardInterrupt:
            try:
                proc.terminate()
            except Exception:
                pass
            try:
                proc.wait(timeout=5)
            except Exception:
                try:
                    proc.kill()
                except Exception:
                    pass
                try:
                    proc.wait()
                except Exception:
                    pass
            return 130
        finally:
            try:
                proc.stdout.close()
            except Exception:
                pass

        return proc.wait()


# --------------------------------------------------------------------------------------
# abc-export records → SimPlan


def tcl_unescape_braced(value: str) -> str:
    out: List[str] = []
    i = 0
    while i < len(value):
        ch = value[i]
        if ch == "\\" and i + 1 < len(value):
            out.append(value[i + 1])
            i += 2
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def resolve_recorded_path(recorded_path: str, root_dir: Path) -> Path:
    p = Path(recorded_path)
    if p.is_absolute():
        return p.resolve()
    return (root_dir / p).resolve()


def parse_collector_records(records_text: str, *, root_dir: Path) -> SimPlan:
    src_files: List[Path] = []
    sim_files: List[Path] = []
    simulate_tops: List[str] = []
    sim_generics: List[str] = []
    sim_verilog_defines: List[str] = []
    xsim_more_options: List[str] = []
    unsupported_commands: List[str] = []

    for raw in records_text.splitlines():
        if not raw.strip():
            continue
        parts = raw.split("\t")
        kind = parts[0] if parts else ""
        value1 = parts[1] if len(parts) > 1 else ""
        value2 = parts[2] if len(parts) > 2 else ""
        if kind == "SRC":
            src_files.append(resolve_recorded_path(value1, root_dir))
        elif kind == "SIM":
            sim_files.append(resolve_recorded_path(value1, root_dir))
        elif kind == "PROP" and value1 == "generic":
            sim_generics.append(value2)
        elif kind == "PROP" and value1 == "verilog_define":
            sim_verilog_defines.append(value2)
        elif kind == "PROP" and value1 == "xsim.simulate.xsim.more_options":
            xsim_more_options.append(value2)
        elif kind == "UNSUPPORTED":
            unsupported_commands.append(value1)
        elif kind == "ACTION" and value1 == "simulate":
            simulate_tops.append(value2)

    return SimPlan(
        src_files=src_files,
        sim_files=sim_files,
        simulate_tops=simulate_tops,
        sim_generics=sim_generics,
        sim_verilog_defines=sim_verilog_defines,
        xsim_more_options=xsim_more_options,
        unsupported_commands=unsupported_commands,
        root_dir=root_dir,
    )


# --------------------------------------------------------------------------------------
# Source-list helpers used by the direct (non-Vivado) backends


def is_hdl_source(path: Path) -> bool:
    return path.suffix.lower() in {".sv", ".v"}


def unique_paths(paths: Iterable[Path]) -> List[Path]:
    out: List[Path] = []
    seen: set[Path] = set()
    for path in paths:
        resolved = path.resolve()
        if resolved in seen:
            continue
        seen.add(resolved)
        out.append(resolved)
    return out


def unique_strings(values: Iterable[str]) -> List[str]:
    out: List[str] = []
    seen: set[str] = set()
    for value in values:
        if value in seen:
            continue
        seen.add(value)
        out.append(value)
    return out


def sanitize_snapshot_name(name: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9_.-]", "_", name)
    return cleaned or "abc_snapshot"


_SV_BLOCK_COMMENT_RE = re.compile(r"/\*.*?\*/", re.DOTALL)
_SV_LINE_COMMENT_RE = re.compile(r"//.*?$", re.MULTILINE)
_SV_PACKAGE_RE = re.compile(r"\bpackage\s+([A-Za-z_][A-Za-z0-9_$]*)\b")
_SV_IMPORT_PKG_RE = re.compile(r"\bimport\s+([A-Za-z_][A-Za-z0-9_$]*)::")


@dataclass(frozen=True)
class SystemVerilogPackageInfo:
    provides: Tuple[str, ...]
    imports: Tuple[str, ...]


def analyze_systemverilog_package_info(path: Path) -> SystemVerilogPackageInfo:
    if path.suffix.lower() != ".sv":
        return SystemVerilogPackageInfo((), ())
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return SystemVerilogPackageInfo((), ())
    text = _SV_BLOCK_COMMENT_RE.sub(" ", text)
    text = _SV_LINE_COMMENT_RE.sub(" ", text)
    provides = tuple(dict.fromkeys(_SV_PACKAGE_RE.findall(text)))
    imports = tuple(dict.fromkeys(_SV_IMPORT_PKG_RE.findall(text)))
    return SystemVerilogPackageInfo(provides=provides, imports=imports)


def is_systemverilog_package_file(path: Path) -> bool:
    return bool(analyze_systemverilog_package_info(path).provides)


def order_systemverilog_package_files(paths: List[Path]) -> List[Path]:
    infos = [analyze_systemverilog_package_info(path) for path in paths]
    package_indexes = [idx for idx, info in enumerate(infos) if info.provides]
    if len(package_indexes) < 2:
        return [paths[idx] for idx in package_indexes]

    provider_by_package: Dict[str, int] = {}
    for idx in package_indexes:
        for package_name in infos[idx].provides:
            provider_by_package.setdefault(package_name, idx)

    deps_by_idx: Dict[int, set[int]] = {idx: set() for idx in package_indexes}
    reverse_deps: Dict[int, set[int]] = {idx: set() for idx in package_indexes}
    indegree: Dict[int, int] = {idx: 0 for idx in package_indexes}

    for idx in package_indexes:
        for imported_pkg in infos[idx].imports:
            dep_idx = provider_by_package.get(imported_pkg)
            if dep_idx is None or dep_idx == idx:
                continue
            if dep_idx in deps_by_idx[idx]:
                continue
            deps_by_idx[idx].add(dep_idx)
            reverse_deps[dep_idx].add(idx)
            indegree[idx] += 1

    ready = [idx for idx in package_indexes if indegree[idx] == 0]
    ordered_indexes: List[int] = []
    while ready:
        ready.sort()
        idx = ready.pop(0)
        ordered_indexes.append(idx)
        for consumer_idx in sorted(reverse_deps[idx]):
            indegree[consumer_idx] -= 1
            if indegree[consumer_idx] == 0:
                ready.append(consumer_idx)

    if len(ordered_indexes) != len(package_indexes):
        remaining = [idx for idx in package_indexes if idx not in set(ordered_indexes)]
        ordered_indexes.extend(remaining)

    return [paths[idx] for idx in ordered_indexes]


def order_sim_compile_files(paths: Iterable[Path]) -> List[Path]:
    ordered = unique_paths(paths)
    package_indexes = [idx for idx, path in enumerate(ordered) if is_systemverilog_package_file(path)]
    ordered_packages = order_systemverilog_package_files(ordered)
    package_paths = {path.resolve() for path in ordered_packages}
    ordered_non_packages = [path for path in ordered if path.resolve() not in package_paths]
    return [*ordered_packages, *ordered_non_packages]


# --------------------------------------------------------------------------------------
# Sim work-dir staging


def create_link_or_copy(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists() or dst.is_symlink():
        return
    try:
        os.symlink(src, dst)
    except OSError:
        shutil.copy2(src, dst)


def stage_sim_support_files(plan: SimPlan, work_dir: Path) -> None:
    staged_by_basename: Dict[str, Path] = {}
    for path in unique_paths(p for p in plan.sim_files if not is_hdl_source(p)):
        if not path.exists():
            raise FileNotFoundError(f"simulation support file not found: {path}")

        basename = path.name
        prev = staged_by_basename.get(basename)
        if prev is not None and prev != path:
            raise RuntimeError(f"conflicting simulation support files share basename {basename!r}: {prev} vs {path}")
        staged_by_basename[basename] = path

        create_link_or_copy(path, work_dir / basename)

        try:
            rel = path.relative_to(plan.root_dir)
        except ValueError:
            continue
        create_link_or_copy(path, work_dir / rel)


def determine_task_root(task: Path, root_override: Optional[str]) -> Path:
    if root_override:
        return Path(root_override).resolve()
    git_root = find_git_root(task.parent.resolve())
    if git_root is not None:
        return git_root.resolve()
    return task.parent.resolve()


def collect_sim_plan(
    *,
    script_dir: Path,
    task: Path,
    root_override: Optional[str],
    argv_user: List[str],
) -> SimPlan:
    """Parse a `.abc` file via the abc-export Tcl collector.

    Runs `abc-export --records-only` (sibling script) which sources the
    `.abc` file through Tcl, expands `import`/`resolve`/`@`-anchored
    paths, and emits tab-separated records. Those records are parsed
    into a `SimPlan` consumed by every backend.
    """
    export_script = script_dir / "abc-export"
    if not export_script.is_file():
        raise FileNotFoundError(f"abc-export not found next to launcher: {export_script}")

    root_dir = determine_task_root(task, root_override)
    cmd = [str(export_script), str(task), ".", "--records-only", "--source-tcl", "--run-exec"]
    if root_override:
        cmd.extend(["--root", root_override])
    cmd.extend(["--", *argv_user])
    result = subprocess.run(cmd, check=False, capture_output=True, text=True, errors="replace")
    if result.returncode != 0:
        msg = (result.stderr or result.stdout or "").strip()
        raise RuntimeError(f"abc-export failed for {task}: {msg}")
    return parse_collector_records(result.stdout, root_dir=root_dir)
