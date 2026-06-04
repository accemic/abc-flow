"""XSim backend: direct headless invocation of xvlog/xelab/xsim.

Bypasses the Vivado project flow for `-sim` runs by invoking the XSim
tools (which ship with Vivado) directly against the source list emerged
from the `.abc` collector. Tasks that use commands the collector cannot
translate (e.g. `create_ip`) fall back to the Vivado backend — that
fallback path lives in `_abc.vivado.run_vivado_fallback_task` so this
module stays focused on the XSim happy path.
"""

from __future__ import annotations

import tempfile
from pathlib import Path
from typing import Optional

from _abcflow.core import (
    SimPlan,
    _env_truthy,
    eprint,
    is_hdl_source,
    order_sim_compile_files,
    run_streaming_command,
    sanitize_snapshot_name,
    stage_sim_support_files,
    unique_strings,
)
from _abcflow.vivado import (
    VivadoSelection,
    sibling_tool_from_vivado,
    vivado_glbl_path,
)


def run_direct_xsim_task(
    *,
    selection: VivadoSelection,
    task: Path,
    plan: SimPlan,
    use_filter: bool,
    use_color: bool,
) -> int:
    xvlog = sibling_tool_from_vivado(selection.exe, "xvlog")
    xelab = sibling_tool_from_vivado(selection.exe, "xelab")
    xsim = sibling_tool_from_vivado(selection.exe, "xsim")

    missing = [tool for tool in (xvlog, xelab, xsim) if not tool.exists()]
    if missing:
        missing_str = ", ".join(str(p) for p in missing)
        raise FileNotFoundError(f"missing XSim tool(s) next to {selection.exe}: {missing_str}")
    glbl_v = vivado_glbl_path(selection.exe)
    if not glbl_v.is_file():
        raise FileNotFoundError(f"Vivado glbl.v not found near {selection.exe}: {glbl_v}")

    keep_work = _env_truthy("ABC_KEEP_XSIM_WORK")
    work_ctx = None
    work_dir: Optional[Path] = None
    try:
        if keep_work:
            work_dir = Path(tempfile.mkdtemp(prefix=f"abc_xsim_{task.stem}_"))
            eprint(f"abc: keeping xsim work dir at {work_dir}")
        else:
            work_ctx = tempfile.TemporaryDirectory(prefix=f"abc_xsim_{task.stem}_")
            work_dir = Path(work_ctx.name)

        assert work_dir is not None
        compile_files = order_sim_compile_files([*plan.src_files, *(p for p in plan.sim_files if is_hdl_source(p)), glbl_v])
        if not compile_files:
            raise RuntimeError(f"no Verilog/SystemVerilog sources collected for {task}")
        if not plan.simulate_tops:
            eprint(f"abc: info: no simulate action recorded for {task}; skipping xsim run")
            return 0
        stage_sim_support_files(plan, work_dir)

        compile_cmd = [str(xvlog), "-nolog", "--relax", "-L", "uvm"]
        for define in unique_strings(plan.sim_verilog_defines):
            compile_cmd.extend(["-d", define])
        compile_cmd.extend(["-sv", *[str(path) for path in compile_files]])
        rc = run_streaming_command(compile_cmd, cwd=work_dir, use_filter=use_filter, use_color=use_color)
        if rc != 0:
            return rc

        for top in plan.simulate_tops:
            snapshot = sanitize_snapshot_name(top)
            elab_cmd = [
                str(xelab),
                "-nolog",
                "--relax",
                "-L",
                "uvm",
                "-L",
                "unisims_ver",
                "-L",
                "unimacro_ver",
                "-L",
                "secureip",
                *[arg for generic in unique_strings(plan.sim_generics) for arg in ("--generic_top", generic)],
                top,
                "glbl",
                "-s",
                snapshot,
            ]
            rc = run_streaming_command(elab_cmd, cwd=work_dir, use_filter=use_filter, use_color=use_color)
            if rc != 0:
                return rc

            sim_cmd = [str(xsim), "-nolog", snapshot, *plan.xsim_more_options, "-R"]
            rc = run_streaming_command(sim_cmd, cwd=work_dir, use_filter=use_filter, use_color=use_color)
            if rc != 0:
                return rc
        return 0
    finally:
        if work_ctx is not None:
            work_ctx.cleanup()
