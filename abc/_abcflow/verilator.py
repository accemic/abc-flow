"""Verilator backend: Vivado-free `verilator --binary` runner.

Builds and runs each `.abc` task in a persistent `<task>.vsim/`
directory next to where `abc` is invoked, so testbench output files
(traces, dumps) and the paths they print remain valid after the run.
Re-runs reuse the obj dir for incremental rebuilds. There is no Vivado
fallback: a task using Xilinx IP fails with a clear error at the
dispatcher level, before reaching this runner.
"""

from __future__ import annotations

import shutil
from pathlib import Path
from typing import List

from _abcflow.core import (
    SimPlan,
    eprint,
    is_hdl_source,
    order_sim_compile_files,
    run_streaming_command,
    sanitize_snapshot_name,
    stage_sim_support_files,
    unique_strings,
)


def run_direct_verilator_task(
    *,
    verilator_exe: Path,
    task: Path,
    plan: SimPlan,
    argv_user: List[str],
    use_filter: bool,
    use_color: bool,
    coverage: bool = False,
) -> int:
    if not plan.simulate_tops:
        eprint(f"abc: info: no simulate action recorded for {task}; skipping verilator run")
        return 0

    compile_files = order_sim_compile_files(
        [*plan.src_files, *(p for p in plan.sim_files if is_hdl_source(p))]
    )
    if not compile_files:
        raise RuntimeError(f"no Verilog/SystemVerilog sources collected for {task}")

    # Build and run in a stable, predictable directory next to where abc was
    # invoked (typically a scratch `bld/`), rather than an auto-deleted temp
    # dir. This keeps testbench output files (waveforms, trace dumps) around
    # after the run so the paths printed by the simulation still resolve, and
    # lets Verilator reuse the obj dir for faster incremental rebuilds.
    work_dir = (Path.cwd() / f"{task.stem}.vsim").resolve()
    work_dir.mkdir(parents=True, exist_ok=True)
    eprint(f"abc: verilator work dir: {work_dir}")
    stage_sim_support_files(plan, work_dir)

    if coverage:
        # Drop stale coverage data from a prior run so the report reflects
        # only this run (the work dir is persistent and reused).
        for old in work_dir.glob("coverage_*.dat"):
            old.unlink()

    for top in plan.simulate_tops:
        snapshot = sanitize_snapshot_name(top)
        obj_dir = work_dir / f"obj_{snapshot}"
        compile_cmd = [
            str(verilator_exe),
            "--binary",
            "--timing",
            # Parallelize both verilation and the C++ build across all
            # CPUs. `-j 0` lets Verilator pick one job per core.
            "-j",
            "0",
            # --timing emits std::coroutine-using C++, which needs C++20.
            # Override regardless of what verilated.mk picked at install time.
            "-CFLAGS",
            "-std=c++20",
            "-Wno-fatal",
            "-sv",
            "--top-module",
            top,
            "-Mdir",
            str(obj_dir),
            "-o",
            snapshot,
        ]
        if coverage:
            compile_cmd.append("--coverage-line")
        for define in unique_strings(plan.sim_verilog_defines):
            compile_cmd.extend(["-D", define])
        for generic in unique_strings(plan.sim_generics):
            compile_cmd.extend(["-G", generic])
        compile_cmd.extend(str(path) for path in compile_files)
        # plan.xsim_more_options is XSim-specific - intentionally ignored.

        rc = run_streaming_command(compile_cmd, cwd=work_dir, use_filter=use_filter, use_color=use_color)
        if rc != 0:
            return rc

        sim_bin = obj_dir / snapshot
        # Verilator's $display goes through buffered stdio and is NOT
        # flushed before $system spawns a child. With piped output that
        # buffer only flushes at exit, so $system child output (e.g.
        # `realpath` dumps) appears reordered ahead of its $display
        # labels. Run the sim line-buffered so each $display flushes
        # before the next $system. `stdbuf` is GNU coreutils; if it is
        # not available, fall back to the unwrapped binary.
        sim_cmd = [str(sim_bin)]
        if coverage:
            # One coverage file per top so multiple simulate tops don't clobber
            # each other; verilator_coverage merges them for the report.
            sim_cmd.append(f"+verilator+coverage+file+coverage_{snapshot}.dat")
        sim_cmd.extend(argv_user)
        stdbuf = shutil.which("stdbuf")
        if stdbuf:
            sim_cmd = [stdbuf, "-oL", "-eL", *sim_cmd]
        rc = run_streaming_command(
            sim_cmd, cwd=work_dir, use_filter=use_filter, use_color=use_color
        )
        if rc != 0:
            return rc

    if coverage:
        _emit_coverage_reports(work_dir, use_filter=use_filter, use_color=use_color)
    return 0


def _emit_coverage_reports(work_dir: Path, *, use_filter: bool, use_color: bool) -> None:
    """Post-process Verilator coverage data into lcov + annotated + HTML reports.

    Best-effort: a missing tool or missing data emits a warning and returns
    without failing the simulation run that produced the data.
    """
    dats = sorted(work_dir.glob("coverage_*.dat"))
    if not dats:
        eprint("abc: warning: --coverage was set but no coverage data was produced")
        return

    vcov = shutil.which("verilator_coverage")
    if not vcov:
        eprint("abc: warning: verilator_coverage not found on PATH; skipping coverage report")
        return

    dat_args = [str(d) for d in dats]
    info = work_dir / "coverage.info"
    annotated = work_dir / "annotated"

    # lcov-format info file (consumed by genhtml, VSCode Coverage Gutters, etc.)
    run_streaming_command(
        [vcov, "--write-info", str(info), *dat_args],
        cwd=work_dir, use_filter=use_filter, use_color=use_color,
    )
    # Annotated source tree: per-line hit counts, %000000 on uncovered lines.
    # --annotate-all includes fully-covered files too, not just ones with gaps.
    run_streaming_command(
        [vcov, "--annotate", str(annotated), "--annotate-all", "--annotate-min", "1", *dat_args],
        cwd=work_dir, use_filter=use_filter, use_color=use_color,
    )

    eprint(f"abc: coverage: lcov info  {info}")
    eprint(f"abc: coverage: annotated  {annotated}")

    genhtml = shutil.which("genhtml")
    if genhtml and info.exists():
        html_dir = work_dir / "coverage_html"
        rc = run_streaming_command(
            [genhtml, "-o", str(html_dir), str(info)],
            cwd=work_dir, use_filter=use_filter, use_color=use_color,
        )
        if rc == 0:
            eprint(f"abc: coverage: html      {html_dir / 'index.html'}")
    elif not genhtml:
        eprint("abc: note: genhtml not on PATH; skipping HTML report (open coverage.info instead)")
