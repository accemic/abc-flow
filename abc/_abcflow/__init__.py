"""Internal package for the `abc` launcher.

This package houses the implementation of the `abc` entry script
(`abc/abc`, kept adjacent to `abc.tcl` and `abc-export`). Layout:

  core       - backend-agnostic plumbing: argument parsing, output
               streaming, the .abc `SimPlan` dataclass, and the Tcl-
               based dependency collector (`collect_sim_plan`) that all
               backends consume.
  vivado     - Vivado installation discovery, version selection, and the
               full project-flow dispatch (`build_vivado_command`).
  xsim       - Direct xvlog/xelab/xsim runner for headless -sim runs.
  verilator  - Vivado-free Verilator runner.
  main       - The CLI entry point: parses argv, resolves the backend,
               and dispatches to one of the modules above.

Named `_abcflow` (rather than `abc` or `_abc`) to avoid colliding with
the stdlib `abc` module (Abstract Base Classes) and CPython's built-in
`_abc` C-extension that backs it.
"""
