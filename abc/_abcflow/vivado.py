"""Vivado backend: installation discovery, version selection, and the
full Vivado project flow.

This module is the *only* place that knows how to find a Vivado
executable, how to invoke `vivado -mode tcl -source abc.tcl`, and how to
extract Vivado-specific passthrough flags like `-log`/`-notrace`. The
xsim backend imports `run_vivado_fallback_task` from here when a `.abc`
task uses commands it cannot translate (e.g. `create_ip`).
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
from typing import Dict, Iterable, List, Optional, Tuple

from _abcflow.core import (
    extract_flag,
    extract_opt,
    run_streaming_command,
    split_path_list,
)


VERSION_RE = re.compile(r"^(?P<year>\d{4})\.(?P<minor>\d+)$")


@dataclass(frozen=True)
class VivadoSelection:
    exe: Path
    version: Optional[str]
    reason: str


# --------------------------------------------------------------------------------------
# Vivado-only passthrough options


def extract_vivado_passthrough_opts(argv: List[str]) -> Tuple[List[str], List[str]]:
    """Extract a limited set of Vivado-level options.

    These options are passed to Vivado itself and must not be forwarded as -tclargs.

    Supported:
      - -log <file>
      - -notrace
      - -nojournal

    Returns (vivado_opts, remaining_argv).
    """
    vivado_opts: List[str] = []

    # -log <file>
    log_file, argv = extract_opt(argv, "-log")
    if log_file:
        vivado_opts.extend(["-log", log_file])

    # simple flags
    notrace, argv = extract_flag(argv, "-notrace")
    if notrace:
        vivado_opts.append("-notrace")

    nojournal, argv = extract_flag(argv, "-nojournal")
    if nojournal:
        vivado_opts.append("-nojournal")

    return vivado_opts, argv


# --------------------------------------------------------------------------------------
# Installation discovery


def default_search_roots() -> List[Path]:
    sysname = platform.system().lower()
    roots: List[Path] = []
    if sysname == "windows":
        roots.extend([Path(r"C:\Xilinx\Vivado"), Path(r"C:\Xilinx")])
    else:
        # Linux
        roots.extend([Path("/tools/Xilinx/Vivado"), Path("/opt/Xilinx/Vivado"), Path("/opt/Xilinx")])
    return roots


def vivado_executable_names() -> List[str]:
    if platform.system().lower() == "windows":
        # Vivado on Windows is typically invoked as vivado.bat.
        return ["vivado.bat", "vivado.exe", "vivado"]
    return ["vivado"]


def which_vivado_from_path() -> Optional[Path]:
    for name in vivado_executable_names():
        found = shutil.which(name)
        if found:
            return Path(found)
    return None


def try_get_vivado_version(exe: Path) -> Optional[str]:
    """Best-effort extraction of Vivado version.

    We try `vivado -version` and parse something like:
      Vivado v2024.1 (64-bit)
    If this fails, return None.
    """
    try:
        out = subprocess.check_output([str(exe), "-version"], stderr=subprocess.STDOUT, text=True)
    except Exception:
        return None
    m = re.search(r"Vivado\s+v(?P<ver>\d{4}\.\d+)", out)
    if m:
        return m.group("ver")
    return None


def parse_version_key(ver: str) -> Tuple[int, int]:
    m = VERSION_RE.match(ver)
    if not m:
        raise ValueError(f"Invalid Vivado version format {ver!r}. Expected like '2024.1'.")
    return int(m.group("year")), int(m.group("minor"))


def iter_candidate_version_dirs(root: Path) -> Iterable[Tuple[str, Path]]:
    """Yield (version, version_dir) for version directories under `root`.

    Supports:
      - root is a container: <root>/<YYYY.X>/...
      - root itself might be a version dir: <root> is <YYYY.X>
    """
    if not root.exists():
        return

    # Direct version dir
    if VERSION_RE.match(root.name):
        yield root.name, root
        return

    try:
        for child in root.iterdir():
            if child.is_dir() and VERSION_RE.match(child.name):
                yield child.name, child
    except PermissionError:
        return


def vivado_exe_in_version_dir(version_dir: Path) -> Optional[Path]:
    # Typical: <...>/<ver>/bin/vivado(.bat)
    bin_dir = version_dir / "bin"
    for name in vivado_executable_names():
        exe = bin_dir / name
        if exe.exists():
            return exe
    return None


def collect_roots_from_env_and_config(cfg: Dict[str, str]) -> List[Path]:
    roots: List[Path] = []
    if "vivado_roots" in cfg and cfg["vivado_roots"].strip():
        roots.extend(Path(p) for p in split_path_list(cfg["vivado_roots"]))

    env = os.environ.get("ABC_VIVADO_ROOTS", "").strip()
    if env:
        roots.extend(Path(p) for p in split_path_list(env))

    roots.extend(default_search_roots())

    # De-duplicate while keeping order
    seen: set[str] = set()
    out: List[Path] = []
    for r in roots:
        key = str(r)
        if key not in seen:
            seen.add(key)
            out.append(r)
    return out


def select_vivado(
    *,
    cfg: Dict[str, str],
    cfg_path: Optional[Path],
    wants_sim: bool,
    wants_impl: bool,
    forced_version: Optional[str],
) -> VivadoSelection:
    # Highest priority: explicit CLI override.
    requested_version: Optional[str] = None
    requested_key: Optional[str] = None
    config_used_for_version = False

    if forced_version:
        requested_version = forced_version
        requested_key = "--vivado-version"
    else:
        if wants_sim:
            requested_version = cfg.get("vivado_sim")
            requested_key = "vivado_sim" if requested_version else None
            config_used_for_version = requested_version is not None
        elif wants_impl:
            requested_version = cfg.get("vivado_impl")
            requested_key = "vivado_impl" if requested_version else None
            config_used_for_version = requested_version is not None
        else:
            # Ambiguous mode (e.g. only -gui). If both are present, ask.
            v_sim = cfg.get("vivado_sim")
            v_impl = cfg.get("vivado_impl")
            if v_sim and v_impl:
                if not (sys.stdin.isatty() and sys.stderr.isatty()):
                    raise RuntimeError(
                        "Vivado version is ambiguous for this invocation (neither -sim nor -synth/-impl/-bitgen detected), "
                        "and interactive prompting is not available."
                    )
                prompt = (
                    "abc: Vivado version is ambiguous for this invocation (neither -sim nor -synth/-impl/-bitgen detected).\n"
                    f"  1) simulation  (vivado_sim={v_sim})\n"
                    f"  2) implementation (vivado_impl={v_impl})\n"
                    "Select which default to use [1/2] (or Ctrl+C to abort): "
                )
                while True:
                    try:
                        choice = input(prompt).strip()
                    except KeyboardInterrupt:
                        raise RuntimeError("Aborted by user")
                    if choice == "1":
                        requested_version = v_sim
                        requested_key = "vivado_sim (interactive)"
                        config_used_for_version = True
                        break
                    if choice == "2":
                        requested_version = v_impl
                        requested_key = "vivado_impl (interactive)"
                        config_used_for_version = True
                        break
                    print("Please enter '1' or '2'.", file=sys.stderr)
            elif v_sim and not v_impl:
                requested_version = v_sim
                requested_key = "vivado_sim (only config default present)"
                config_used_for_version = True
            elif v_impl and not v_sim:
                requested_version = v_impl
                requested_key = "vivado_impl (only config default present)"
                config_used_for_version = True
            else:
                # Neither detectable nor configured.
                requested_version = None
                requested_key = None

    if requested_version:
        # Validate early
        parse_version_key(requested_version)

    # Default behavior: if no version requested, prefer PATH `vivado`.
    if not requested_version:
        exe = which_vivado_from_path()
        if exe:
            ver = try_get_vivado_version(exe)
            return VivadoSelection(
                exe=exe,
                version=ver,
                reason="found vivado on PATH (no version requested)",
            )

    roots = collect_roots_from_env_and_config(cfg)

    # If a version was requested, search for that version first.
    if requested_version:
        for root in roots:
            for ver, ver_dir in iter_candidate_version_dirs(root):
                if ver != requested_version:
                    continue
                exe = vivado_exe_in_version_dir(ver_dir)
                if exe:
                    cfg_info = f"; config={cfg_path}" if (cfg_path and config_used_for_version) else ""
                    return VivadoSelection(
                        exe=exe,
                        version=ver,
                        reason=f"requested by {requested_key}{cfg_info} (resolved under {root})",
                    )

        # Only fallback to PATH if the request came from config (or sim/impl mode)
        # and not from the explicit override.
        if not forced_version:
            exe = which_vivado_from_path()
            if exe:
                ver = try_get_vivado_version(exe)
                cfg_info = f"; config={cfg_path}" if (cfg_path and config_used_for_version) else ""
                return VivadoSelection(
                    exe=exe,
                    version=ver,
                    reason=f"requested {requested_version} but not found in roots{cfg_info}; using vivado from PATH",
                )

        searched = "\n".join(f"  - {r}" for r in roots)
        cfg_info = f" (config={cfg_path})" if (cfg_path and config_used_for_version) else ""
        raise FileNotFoundError(
            "Vivado not found. "
            f"Requested version {requested_version} ({requested_key}){cfg_info}, searched roots:\n{searched}\n"
            "Tip: set ABC_VIVADO_ROOTS to include your installation root(s)."
        )

    # No requested version and nothing on PATH: scan roots and pick highest version.
    best: Optional[Tuple[Tuple[int, int], str, Path]] = None  # ((year,minor), version, exe)
    for root in roots:
        for ver, ver_dir in iter_candidate_version_dirs(root):
            exe = vivado_exe_in_version_dir(ver_dir)
            if not exe:
                continue
            try:
                key = parse_version_key(ver)
            except ValueError:
                continue
            if best is None or key > best[0]:
                best = (key, ver, exe)

    if best:
        _, ver, exe = best
        return VivadoSelection(exe=exe, version=ver, reason="vivado not on PATH; selected highest version from search roots")

    searched = "\n".join(f"  - {r}" for r in roots)
    raise FileNotFoundError(
        "Vivado not found on PATH and no installations discovered in search roots:\n"
        f"{searched}\n"
        "Tip: set ABC_VIVADO_ROOTS to include your installation root(s)."
    )


# --------------------------------------------------------------------------------------
# Sibling-tool resolution (xvlog/xelab/xsim live next to vivado)


def sibling_tool_from_vivado(vivado_exe: Path, tool_name: str) -> Path:
    if vivado_exe.name.endswith(".bat"):
        suffix = ".bat"
    elif vivado_exe.suffix:
        suffix = vivado_exe.suffix
    else:
        suffix = ""
    return vivado_exe.with_name(f"{tool_name}{suffix}")


def vivado_data_dir_from_exe(vivado_exe: Path) -> Path:
    return vivado_exe.resolve().parent.parent / "data" / "verilog" / "src"


def vivado_glbl_path(vivado_exe: Path) -> Path:
    return vivado_data_dir_from_exe(vivado_exe) / "glbl.v"


# --------------------------------------------------------------------------------------
# Vivado command construction + dispatch


def build_vivado_command(
    vivado_exe: Path,
    script_dir: Path,
    passthrough_args: List[str],
    vivado_passthrough_opts: List[str],
) -> List[str]:
    abc_tcl = script_dir / "abc.tcl"
    if not abc_tcl.is_file():
        raise FileNotFoundError(f"abc.tcl not found next to launcher: {abc_tcl}")

    tclargs: List[str] = []
    for a in passthrough_args:
        tclargs.extend(["-tclargs", a])

    # Default vivado flags used by abc-flow.
    base: List[str] = [str(vivado_exe)]

    # Ensure journal is disabled unless user explicitly wants journaling.
    if "-nojournal" not in vivado_passthrough_opts:
        base.append("-nojournal")

    # If the user requested a vivado log file, avoid forcing -nolog.
    if "-log" not in vivado_passthrough_opts:
        base.append("-nolog")

    base.extend(
        [
            *vivado_passthrough_opts,
            "-mode",
            "tcl",
            "-source",
            str(abc_tcl),
            *tclargs,
        ]
    )

    return base


def build_single_task_passthrough_args(argv_main: List[str], task: Path) -> List[str]:
    out: List[str] = []
    inserted_task = False
    for arg in argv_main:
        if arg.startswith("-"):
            out.append(arg)
            continue
        if not inserted_task:
            out.append(str(task))
            inserted_task = True
    if not inserted_task:
        out.append(str(task))
    return out


def run_vivado_fallback_task(
    *,
    selection: VivadoSelection,
    script_dir: Path,
    argv_main: List[str],
    argv_user: List[str],
    vivado_passthrough_opts: List[str],
    task: Path,
    use_filter: bool,
    use_color: bool,
) -> int:
    """Run a single .abc task under the full Vivado project flow.

    Used by the xsim backend when the collector reports unsupported
    commands (e.g. `create_ip`), so individual tasks transparently fall
    back to Vivado within an otherwise xsim-driven directory run.
    """
    passthrough_args = build_single_task_passthrough_args(argv_main, task)
    if argv_user:
        passthrough_args = [*passthrough_args, "--", *argv_user]
    cmd = build_vivado_command(selection.exe, script_dir, passthrough_args, vivado_passthrough_opts)
    return run_streaming_command(cmd, use_filter=use_filter, use_color=use_color)
