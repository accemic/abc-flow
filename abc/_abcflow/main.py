"""CLI entry point for the abc-flow launcher.

Parses argv, reads `.abc.config`, resolves the simulation backend, and
dispatches to one of the backend modules:

  * `_abcflow.vivado`    — full Vivado project flow (default; covers -gui,
                       -synth, -impl, -bitgen, and -sim under Vivado).
  * `_abcflow.xsim`      — direct xvlog/xelab/xsim for -sim, with per-task
                       Vivado fallback for unsupported `.abc` commands.
  * `_abcflow.verilator` — Vivado-free `verilator --binary` for -sim.

All three consume the same `SimPlan` produced by the Tcl-based
`collect_sim_plan` collector in `_abcflow.core`.
"""

from __future__ import annotations

import shutil
import sys
from pathlib import Path
from typing import Dict, List, Optional

from _abcflow.core import (
    collect_sim_plan,
    enable_windows_vt_mode,
    eprint,
    expand_tasks,
    extract_flag,
    extract_opt,
    extract_root_override,
    find_git_root,
    parse_args_mode,
    parse_simple_kv_config,
    run_streaming_command,
    split_argv_user,
    validate_abc_tcl_args,
    want_colored_output,
    want_filtered_output,
)
from _abcflow.verilator import run_direct_verilator_task
from _abcflow.vivado import (
    VERSION_RE,
    VivadoSelection,
    build_vivado_command,
    extract_vivado_passthrough_opts,
    parse_version_key,
    run_vivado_fallback_task,
    select_vivado,
)
from _abcflow.xsim import run_direct_xsim_task


def wants_help(argv: List[str]) -> bool:
    return any(a in ("-h", "--help") for a in argv)


def print_help() -> None:
    print(
        """abc - .abc dependency-driven build/sim launcher

Usage:
  abc [--vivado-version YYYY.X] [--sim-backend vivado|xsim|verilator] [--coverage] [ABC options] [paths...]

Notes:
  - All arguments except launcher-only options are forwarded to abc.tcl as -tclargs.
  - Project-local defaults may be defined in <git-root>/.abc.config:
      vivado_sim=2024.1
      vivado_impl=2024.1
      vivado_roots=/opt/Xilinx/Vivado:/tools/Xilinx/Vivado
      sim_backend=vivado|xsim|verilator   (default simulation backend)
  - Machine-local install roots can be provided via:
      ABC_VIVADO_ROOTS (path-separator separated)
  - Logging is printed to stderr unless ABC_QUIET=1.

Special behavior:
  - It is an error to combine -sim with -synth/-impl/-bitgen.
  - If neither sim nor implementation mode is detectable (e.g. only -gui),
    and .abc.config provides both vivado_sim and vivado_impl, you will be
    asked interactively to choose.

Options:
  --vivado-version YYYY.X
      Force a specific Vivado version. Overrides .abc.config and automatic
      selection.

  --sim-backend vivado|xsim|verilator
      Select the simulation backend. Overrides the sim_backend key in
      .abc.config; if neither is set the default is vivado.
      xsim is an experimental fast path for -sim that drives abc-export +
      xvlog/xelab/xsim directly to avoid full Vivado project startup.
      verilator is an experimental Vivado-free path that runs the SV
      testbench under `verilator --binary`. Requires `verilator` on PATH
      (>= 4.220). Does not support Xilinx IP (create_ip/read_ip): such
      tasks fail with a clear error instead of falling back to Vivado.
      A configured xsim/verilator default applies only to -sim runs;
      -synth/-impl/-bitgen/-gui always use Vivado.

  --coverage
      Collect Verilator line coverage for the -sim run (requires
      --sim-backend verilator). Builds with `--coverage-line`, then runs
      `verilator_coverage` to write coverage.info (lcov) and an annotated/
      source tree into the <task>.vsim/ work dir. If `genhtml` is on PATH,
      an HTML report is also rendered to <task>.vsim/coverage_html/.

  -log <file>
      Passed through to Vivado. (This is a Vivado option, not an abc.tcl option.)

  -notrace
      Passed through to Vivado.

  -nojournal
      Passed through to Vivado.

abc.tcl options (forwarded to the flow):
  -new                  Create a new Vivado project instead of reusing the existing one.
  -sim                  Run simulation.
  -synth                Run synthesis.
  -netlist              Run synthesis and export a netlist (out_of_context).
  -impl                 Run implementation.
  -bitgen               Generate a bitfile (implies -impl).
  -gui                  Open the Vivado GUI on the project.

  -root=<DIR>           Anchor directory for `@`-prefixed paths inside .abc files.
                        Defaults to the git root of the current working directory.
                        Required when not in a git repo, or when the project's
                        @-imports anchor at a sub-directory of the repo (e.g.
                        `@modules/...` lives under a sub-tree, not the repo root).
                        Must be passed as `-root=<value>` (no space).

FPGA part (default: xczu19eg-ffvb1517-1-e):
  -11eg                 Use xczu11eg-ffvb1517-1-e
  -7ev                  Use xczu7ev-ffvc1156-2-i
  -7ev1517              Use xczu7ev-ffvf1517-1-e
  -xc7                  Use xc7v585tffg1761-1
"""
    )


def main(argv: List[str]) -> int:
    if wants_help(argv):
        print_help()
        return 0

    try:
        forced_version, argv = extract_opt(argv, "--vivado-version")
        sim_backend, argv = extract_opt(argv, "--sim-backend")
        coverage, argv = extract_flag(argv, "--coverage")
    except ValueError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 2
    if sim_backend is not None and sim_backend not in ("vivado", "xsim", "verilator"):
        print(
            f"Error: invalid --sim-backend {sim_backend!r}. "
            f"Expected 'vivado', 'xsim', or 'verilator'.",
            file=sys.stderr,
        )
        return 2
    if forced_version:
        try:
            parse_version_key(forced_version)
        except Exception as e:
            print(f"Error: {e}", file=sys.stderr)
            return 2

    # Extract Vivado-level flags so they don't get forwarded to abc.tcl.
    # IMPORTANT: This must happen *after* parsing launcher-only options like
    # --vivado-version.
    try:
        vivado_passthrough_opts, argv = extract_vivado_passthrough_opts(argv)
    except ValueError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 2

    try:
        argv = validate_abc_tcl_args(argv)
    except ValueError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 2

    argv_main, argv_user = split_argv_user(argv)

    wants_sim, wants_impl = parse_args_mode(argv_main)
    if wants_sim and wants_impl:
        print("Error: -sim must not be combined with -synth/-impl/-bitgen.", file=sys.stderr)
        return 2

    # `script_dir` is the directory holding the `abc` entry script (and
    # `abc.tcl`, `abc-export` next to it). `_abcflow/` is one level below it.
    script_dir = Path(__file__).resolve().parent.parent

    cfg: Dict[str, str] = {}
    cfg_path: Optional[Path] = None
    git_root = find_git_root(Path.cwd())
    if git_root:
        cfg_path = git_root / ".abc.config"
        try:
            cfg = parse_simple_kv_config(cfg_path)
        except Exception as e:
            print(f"Error: failed to parse {cfg_path}: {e}", file=sys.stderr)
            return 2

    # Resolve the simulation backend: an explicit --sim-backend wins, else
    # the sim_backend key in .abc.config, else the built-in 'vivado' default.
    # The configured default applies only to simulation runs; -synth/-impl/
    # -bitgen/-gui always use Vivado, since xsim/verilator cannot drive them.
    # (An explicit --sim-backend xsim/verilator with a non-sim mode is still
    # rejected below, because the user asked for something impossible.)
    if sim_backend is None:
        cfg_backend = cfg.get("sim_backend", "vivado")
        if cfg_backend not in ("vivado", "xsim", "verilator"):
            print(
                f"Error: invalid sim_backend {cfg_backend!r} in {cfg_path}. "
                f"Expected 'vivado', 'xsim', or 'verilator'.",
                file=sys.stderr,
            )
            return 2
        sim_backend = cfg_backend if wants_sim else "vivado"

    if sim_backend in ("xsim", "verilator"):
        if not wants_sim:
            print(f"Error: --sim-backend {sim_backend} requires -sim.", file=sys.stderr)
            return 2
        if wants_impl or "-gui" in argv:
            print(f"Error: --sim-backend {sim_backend} only supports headless -sim runs.", file=sys.stderr)
            return 2
        if vivado_passthrough_opts:
            print(
                f"Error: Vivado-only options (-log/-notrace/-nojournal) are not supported "
                f"with --sim-backend {sim_backend}.",
                file=sys.stderr,
            )
            return 2

    if coverage and sim_backend != "verilator":
        print(
            "Error: --coverage is only supported with --sim-backend verilator.",
            file=sys.stderr,
        )
        return 2

    # If we can't infer whether sim or impl is intended (e.g. -gui only) and
    # there is no unique config default, tell the user about the explicit override.
    if not wants_sim and not wants_impl and not forced_version:
        v_sim = cfg.get("vivado_sim")
        v_impl = cfg.get("vivado_impl")
        has_unique_default = (bool(v_sim) ^ bool(v_impl))
        if not has_unique_default:
            eprint("abc: note: invocation does not indicate simulation or implementation; use --vivado-version YYYY.X to select explicitly")

    selection: Optional[VivadoSelection] = None
    cmd: List[str] = []
    if sim_backend != "verilator":
        try:
            selection = select_vivado(
                cfg=cfg,
                cfg_path=cfg_path,
                wants_sim=wants_sim,
                wants_impl=wants_impl,
                forced_version=forced_version,
            )
        except Exception as e:
            # If we failed due to ambiguity and we were non-interactive, provide a hint.
            hint = ""
            if (not wants_sim and not wants_impl and not forced_version) and (cfg.get("vivado_sim") and cfg.get("vivado_impl")):
                hint = "\nHint: use --vivado-version YYYY.X to select explicitly."
            print(f"Error: {e}{hint}", file=sys.stderr)
            return 1

        # Best-effort version label for log line
        ver_label = selection.version
        if ver_label is None:
            # If not from `-version`, try infer from install path
            m = VERSION_RE.search(str(selection.exe))
            ver_label = m.group(0) if m else "?"

        eprint(f"abc: using Vivado {ver_label} from {selection.exe} (reason: {selection.reason})")

        cmd = build_vivado_command(
            selection.exe,
            script_dir,
            [*argv_main, *(["--", *argv_user] if argv_user else [])],
            vivado_passthrough_opts,
        )

    # Stream Vivado output, optionally filtering and adding ANSI colors.
    use_color = want_colored_output()
    if use_color:
        # If we can't enable VT mode (Windows), fall back to plain output.
        if not enable_windows_vt_mode():
            use_color = False

    use_filter = want_filtered_output()

    if sim_backend == "verilator":
        verilator_exe_str = shutil.which("verilator")
        if not verilator_exe_str:
            print("Error: --sim-backend verilator requires 'verilator' on PATH.", file=sys.stderr)
            return 1
        verilator_exe = Path(verilator_exe_str)

        root_override = extract_root_override(argv_main)
        task_args = [a for a in argv_main if not a.startswith("-")]
        if not task_args:
            print("Error: --sim-backend verilator requires at least one task path.", file=sys.stderr)
            return 2
        try:
            tasks = expand_tasks(task_args)
        except Exception as e:
            print(f"Error: {e}", file=sys.stderr)
            return 1
        if not tasks:
            print("Error: no .abc tasks found.", file=sys.stderr)
            return 1
        if argv_user and len(tasks) != 1:
            print(
                "Error: --sim-backend verilator does not support forwarding '--' user args to multiple tasks. "
                "Run a single .abc task or use the vivado backend for directory-wide runs.",
                file=sys.stderr,
            )
            return 2

        eprint("abc: simulation backend is verilator (experimental)")
        for task in tasks:
            try:
                plan = collect_sim_plan(
                    script_dir=script_dir,
                    task=task,
                    root_override=root_override,
                    argv_user=argv_user,
                )
            except Exception as e:
                print(f"Error: {e}", file=sys.stderr)
                return 1
            if plan.unsupported_commands:
                print(
                    f"Error: task {task} uses {plan.unsupported_commands[0]}, "
                    f"which is not supported under --sim-backend verilator.",
                    file=sys.stderr,
                )
                return 1
            try:
                rc = run_direct_verilator_task(
                    verilator_exe=verilator_exe,
                    task=task,
                    plan=plan,
                    argv_user=argv_user,
                    use_filter=use_filter,
                    use_color=use_color,
                    coverage=coverage,
                )
            except Exception as e:
                print(f"Error: {e}", file=sys.stderr)
                return 1
            if rc != 0:
                return rc
        return 0

    if sim_backend == "xsim":
        assert selection is not None
        root_override = extract_root_override(argv_main)
        task_args = [a for a in argv_main if not a.startswith("-")]
        if not task_args:
            print("Error: --sim-backend xsim requires at least one task path.", file=sys.stderr)
            return 2
        try:
            tasks = expand_tasks(task_args)
        except Exception as e:
            print(f"Error: {e}", file=sys.stderr)
            return 1
        if not tasks:
            print("Error: no .abc tasks found.", file=sys.stderr)
            return 1
        if argv_user and len(tasks) != 1:
            print(
                "Error: --sim-backend xsim does not support forwarding '--' user args to multiple tasks. "
                "Run a single .abc task or use the vivado backend for directory-wide runs.",
                file=sys.stderr,
            )
            return 2

        eprint("abc: simulation backend is xsim (experimental)")
        for task in tasks:
            try:
                plan = collect_sim_plan(
                    script_dir=script_dir,
                    task=task,
                    root_override=root_override,
                    argv_user=argv_user,
                )
            except Exception as e:
                print(f"Error: {e}", file=sys.stderr)
                return 1
            if plan.unsupported_commands:
                eprint(f"abc: info: falling back to vivado for {task} (uses {plan.unsupported_commands[0]})")
                rc = run_vivado_fallback_task(
                    selection=selection,
                    script_dir=script_dir,
                    argv_main=argv_main,
                    argv_user=argv_user,
                    vivado_passthrough_opts=vivado_passthrough_opts,
                    task=task,
                    use_filter=use_filter,
                    use_color=use_color,
                )
            else:
                try:
                    rc = run_direct_xsim_task(
                        selection=selection,
                        task=task,
                        plan=plan,
                        use_filter=use_filter,
                        use_color=use_color,
                    )
                except Exception as e:
                    print(f"Error: {e}", file=sys.stderr)
                    return 1
            if rc != 0:
                return rc
        return 0

    try:
        return run_streaming_command(cmd, use_filter=use_filter, use_color=use_color)
    except Exception as e:
        print(f"Error: failed to execute Vivado: {e}", file=sys.stderr)
        return 1
