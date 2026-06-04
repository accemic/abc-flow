# `abc` fixture tests

The fixture tests are organized as behavior-specific directories:

- `abc-export-.../repo/`: source repository content copied into a temporary git repo
- `abc-export-.../case.conf`: the `abc-export` call and high-level expectations
- `abc-bundle-.../repo/`: source repository content copied into a temporary git repo
- `abc-bundle-.../case.conf`: the `abc-bundle` call and high-level expectations
- `abc-xsim-.../repo/`: source repository content copied into a temporary git repo
- `abc-xsim-.../case.conf`: the `abc` launcher call and high-level expectations for the direct XSim backend
- `abc-export-.../expected/`: human-readable references for exported file lists and deterministic generated files
- `abc-bundle-.../expected/`: human-readable references for bundled file lists and deterministic manifests
- `abc-xsim-.../expected/`: stable stdout/stderr snippets for the direct XSim backend

This keeps each case easy to inspect by hand:

- the `.abc`, `.sv`, and `.xdc` inputs sit next to each other under `repo/`
- `expected/export.files` shows the exported file structure
- `expected/export/` contains exact reference content only for deterministic generated files we want to pin
- `expected/stdout.contains.txt` lists stable stdout snippets to check for each case
- `verify.sh` is optional and can run a case-specific post-run assertion against the generated output

The tests intentionally do not pin `stdout`, `stderr`, `README.md`, or `add_to_vivado.tcl` content.
Those outputs are still covered indirectly through exit code and exported file structure checks.

Each `case.conf` uses shell variables that are available to the fixture:

```bash
REPO=/tmp/.../repo
OUT_DIR=/tmp/.../export

ABC_EXPORT_CALL=("$REPO/path/to/input" "$OUT_DIR" --generate-abc)
EXPECT_EXIT_CODE=0
EXPECT_EXPORT_DIR=present
```

That keeps the fixture close to the real command line while still letting the
runner place the case in a temporary workspace.

The direct XSim fixtures follow the same pattern:

```bash
REPO=/tmp/.../repo

ABC_XSIM_CALL=(--vivado-version 2024.1 --sim-backend xsim -sim "$REPO/tb/top.abc")
EXPECT_EXIT_CODE=0
```

The current `abc-xsim-*` cases cover:

- basic source collection and runtime support files
- `build` plus `simulate`, where only explicit `simulate` tops are run
- build-only `.abc` files, which should skip the direct XSim run with an info message
- project-level Vivado properties such as `set_property part ... [current_project]`
- simulation-fileset properties such as `generic`, `verilog_define`, and `xsim.simulate.xsim.more_options`
- `argv_user` handling for task scripts that read arguments after `--`
- compile ordering where package files are dependency-ordered before consumers, even if the recorded source order is wrong
- automatic per-task fallback to Vivado for IP/project-flow commands such as `create_ip`

Run the export cases with:

```bash
test/test_abc_export.sh
```

Run the bundle cases with:

```bash
test/test_abc_bundle.sh
```

Run the direct XSim launcher regression with:

```bash
test/test_abc_xsim.sh
```
