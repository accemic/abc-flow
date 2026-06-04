# abc-flow — text-based dependency management for FPGA projects

**abc-flow** replaces hand-managed Vivado projects with small `.abc` text
files: each module declares its dependencies next to its source, and the
`abc` launcher resolves the graph and feeds it to a backend.

- **Plain text, git-friendly** — the whole build is versionable text;
  Vivado's binary, un-diffable `.xpr` is regenerated on demand, not committed.
- **Dependency-driven `.abc` files** — `import` between modules; `@`-anchored,
  repo-root-relative paths; files colocated with the HDL they describe, so a
  module and its `.abc` move and reuse together.
- **One CLI, multiple backends** — automated Vivado project generation and
  headless `synth`/`impl`/`bitgen`, plus experimental Vivado-free sim via XSim
  and Verilator.
- **Hierarchical XDC** — board/timing constraints scoped per module.
- **Xilinx IP** — IP-core support and interop on the Vivado / XSim paths.
- **Tcl underneath** — `.abc` files are Tcl, so the flow stays flexible and
  scriptable.

## What an `.abc` file looks like

```tcl
# foo/foo.abc — describes one module
import ../core/cross_reset                 # an instantiated submodule
import ../packages : wb_package math_pkg   # packages this module uses
read_sv foo.sv                             # this module's source
```

```bash
abc -gui  foo/test/foo_tb.abc   # generate + open the Vivado project
abc -sim  foo/test/foo_tb.abc   # or run the testbench headless
```

Paths are relative to the `.abc` file's directory. A `:` after a path uses
it as a shared prefix for the rest of the list (`../packages : wb_package
math_pkg` → `../packages/wb_package` + `../packages/math_pkg`). A leading `@`
anchors at your git repo root.

## Requirements

- **Python 3** — runs the `abc` launcher.
- **Git** — `.abc` files must live in a git repo (enables `@`-anchored,
  repo-root-relative imports).
- **At least one backend:**
  - Vivado / XSim flows: **Vivado** on `$PATH` (or discoverable via
    `ABC_VIVADO_ROOTS`). The examples here use 2024.1.
  - Verilator flow: **`verilator` ≥ 4.220** on `$PATH`. Vivado not required.

## Install

Both paths leave `abc` on your `PATH`.

**Release tarball** (no git required):

```bash
# Linux / macOS — replace v0.1.0 with the latest tag from the Releases page
curl -fsSL https://github.com/accemic/abc-flow/releases/download/v0.1.0/abc-flow-v0.1.0.tar.gz \
  | tar xz -C ~/.local/share
echo 'export PATH="$HOME/.local/share/abc-flow/abc:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

**Git clone** (best if you want to follow `master`):

```bash
git clone https://github.com/accemic/abc-flow.git ~/abc-flow
echo 'export PATH="$HOME/abc-flow/abc:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

Windows: download the `.zip` from the same release (or clone), extract, and
add the extracted `abc\` directory to your `PATH`. Confirm with `abc -h`.

## Example

The [`example/`](example/) directory holds a complete ALU + testbench. The
implementation `alu_top.abc` is just its source:

```tcl
read_sv alu_top.sv
```

The testbench `alu_tb.abc` pulls it in as a dependency:

```tcl
import    alu_top
read_sim  alu_tb.sv
simulate  alu_tb
```

Generate and open the Vivado project:

```bash
abc -gui example/alu_tb.abc
```

![Vivado project for ALU example](doc/proj.png)

Or run the testbench headless under any backend:

```bash
abc -sim example/alu_tb.abc                          # Vivado (default)
abc --sim-backend xsim -sim example/alu_tb.abc       # direct XSim
abc --sim-backend verilator -sim example/alu_tb.abc  # Verilator (no Vivado)
```

The full `.abc` command reference lives in [doc/abc.md](doc/abc.md).

## Configuration

Set project-wide defaults in a `.abc.config` file at your git repo root:

```ini
vivado_sim=2024.1
vivado_impl=2024.1

# Additional Vivado install roots (same semantics as $ABC_VIVADO_ROOTS)
vivado_roots=/opt/Xilinx/Vivado:/tools/Xilinx/Vivado

# Default sim backend (vivado | xsim | verilator); --sim-backend overrides it.
# Applies only to -sim; -synth/-impl/-bitgen/-gui always use Vivado.
sim_backend=vivado
```

To add machine-local Vivado search roots without touching the repo:

```bash
export ABC_VIVADO_ROOTS=/opt/Xilinx/Vivado:/tools/Xilinx/Vivado
```

To force a specific version for a single invocation — useful with `-gui`,
which on its own doesn't indicate a sim or implementation flow:

```bash
abc --vivado-version 2024.1 -gui myproj.abc
```

## Status & caveats

- **XSim and Verilator backends are experimental.** Vivado is the default and
  most complete path.
- **Git is required** — `.abc` files must live in a git repository for
  `@`-anchored imports to resolve. (This may relax in the future.)
- **`.abc` files are executable Tcl.** `abc` sources them to resolve
  dependencies, so running it executes the project's `.abc` files as code —
  treat them like any build script and don't run `abc` inside a repository
  you don't trust.
- The FPGA **part shortcuts** (`-11eg`, `-7ev`, …) and the default part are
  convenience aliases for the authors' boards; any part can be set per
  project. See `abc -h`.

## License

MIT — see [LICENSE](LICENSE). © 2023-2026 Accemic Technologies GmbH.

Authors: [Accemic Technologies GmbH](https://www.accemic.com) — Thomas
Preußer, Albert Schulz.
