# The `.abc` Flow
## Goals
- Reliable, dependency-driven assembly of testbench and design projects.
- Isolation from Vivado project file versioning.
- Construction of projects and build artefacts outside of source tree.

## Foundations
The flow relies on `.abc` files specifying all dependencies for including
the represented module into a project:
- own sources and constraints,
- instantiated modules and used packages, as well as
- other dependencies (IP cores, design checkpoints, testbench data, ...).

`.abc` files specifying a test case will typically also:
- run a specified testbench, or
- trigger the synthesis of a specified top-level module.

`.abc` files are plain Tcl scripts sourced during the project construction.
They do, however, have designated commands at their disposal for a concise
formulation of dependencies.

## Dependency Specification

### Basic Form
The dependency specification of a module implemented by the source file
`foo.sv` is typically provided by the file `foo.abc`. It is generally
structured *bottom-up* defining all `import`s before including its own
module sources, e.g.:
```tcl
import	../../stream : sink_if source_if
import	../../common : math_pkg cross_reset
read_sv	fifo2clk_fwft.sv
constraints impl fifo2clk_fwft.xdc
```
All non-absolute paths are relative to the location of the `.abc` file.
The function `resolve` enables a compact specification of multiple
related paths. It is automatically applied to the arguments passed
to `import` and may be used explicitly otherwise as well. It:
- removes the path preceding a colon (:) element to use it as a
  prefix to all subsequent list members, and
- locates all paths preceded by an '@' character relative to the
  root of the working copy of the containing git repo. The anchor
  can be overridden with `-root=<DIR>` on the `abc` command line --
  required when not in a git repo, or when `@`-imports anchor at a
  sub-directory (e.g. `@modules/...` lives under a sub-tree of the
  repo, not at its root).

As much as possible, constraints should be restricted to be used
either specifically for synthesis or implementation by using one
of the corresponding markers `synth` or `impl`. All constraints
are scoped explicitly referencing the represented module unless
the switch `-top` is provided, e.g.:
```tcl
constraints -top impl ftdi.xdc
```

### Importing Rules
The `import`s must reference:
- all submodules that are instantiated unconditionally, and
- all packages whose use is introduced.

The `import`s should defer referencing:
- conditionally instantiated submodules up the hierarchy to the first
  module that must know, and
- packages whose use is implied by submodule interfaces to these
  submodules.
For instance, conditional subhierarchies for different target
architectures, say ARM and PPC, should not be imported eagerly as
the decision, which is actually used, is made by some other
instantiating module. Likewise, using a wishbone component
renders additional `import`s of `wb_package` surely redundant.

### Implementation Top-Level Modules
Implementation top-level modules must divert from the general
*bottom-up* construction with respect to their constraints
specification. For the correct interpretation of all subordinate
constraints, it is necessary to have a well defined implementation context,
in particular, defined clocks. Consequently, an implementation
project must start with including the corresponding dependencies, e.g.:
```tcl
constraints -top impl ../../boards/myboard/xdc/myboard.xdc
import	@modules/myip/core : myip_core myip_clk_gen myip_link
...
```

## Test Case Specification
`.abc` files may define tests. These `.abc` files should be containted to designated
`test/` directories. The commands `build` and `simulate` take a top-level module
argument to process accordingly. The command `read_sim` is used to add simulation-only sources
and auxiliary files to the current simulation file set, e.g.:
```tcl
...
read_sim	wb_pump_tb.sv
simulate	wb_pump_tb
```
The actual execution of a simulation or implementation must be explicitly requested when
invoking `abc`. By default these commands are no-ops.

A `build` clause specifies the top-level module for implementation:
```tcl
...
read_sv	myproj_top.sv
build	myproj_top
```
Any of the command-line switches `-synth`, `-impl`, and `-bitgen` will activate
the command and carry the implementation all the way to the specified stage.

## Usage
The typical user entry point into the `.abc` flow is the `abc` launcher script.
Its operation is controlled by a few switches and takes an
arbitrary number of paths as arguments otherwise. Paths that are directories
are explored recursively for `test/**/*.abc` files. All others are extended by
`.abc` and processed.

### Vivado selection
If the desired Vivado version is not implied by the processing mode (e.g. `-gui` only), you can force it:

```bash
abc --vivado-version 2024.1 -gui myproj.abc
```

The processing options are:

1) Build the first specified project and open the Vivado GUI on it:

```bash
mkdir bld && cd bld
abc -gui ../projects/myboard/myproj
```

:bulb: The above, and subsequent commands require the `abc` launcher in your system `PATH`.

2) Recursively explore all test projects and run their simulations:

```bash
mkdir bld && cd bld
abc -sim ../modules/wishbone
```
3) Recursively explore all test projects and run their implementations:

```bash
mkdir bld && cd bld
abc -synth ../modules/wishbone
```
The implementation can be carried up to several stages:
- `-synth` and `-impl` usually used for module tests, as well as
- `-bitgen` for a ready bitstream for a full project.


The processing options may be combined. Using the `-gui` switch will,
however, always terminate the traversal of projects after building
and, optionally, simulating and synthesizing the first one by opening the
GUI.

## Simulation backends

By default, simulations run under Vivado. Two experimental headless
backends are available via `--sim-backend`:

- `xsim` invokes `xvlog`/`xelab`/`xsim` directly, bypassing full Vivado
  project startup. Tasks using `create_ip`/`read_ip`/etc. transparently
  fall back to the Vivado backend.
- `verilator` runs the SystemVerilog testbench under `verilator --binary`.
  Requires `verilator` on `PATH` (>= 4.220, for `--binary`). Vivado is
  not needed. Tasks using Xilinx IP (`create_ip`/`read_ip`) fail with a
  clear error rather than falling back. `xsim.simulate.xsim.more_options`
  is ignored under this backend. The build and run happen in a
  `<task>.vsim/` directory created next to your current directory (e.g.
  in `bld/`); it persists after the run, so any waveforms or trace dumps
  the testbench writes — and the paths it prints — remain valid.
  Re-running reuses the directory for faster incremental rebuilds.

Both backends require `-sim` and headless operation (no `-gui`,
`-synth`, `-impl`, `-bitgen`). Example:

```bash
abc --sim-backend verilator -sim example/alu_tb.abc
```

### Choosing a default backend

Rather than passing `--sim-backend` every time, set a project-wide
default in `<git-root>/.abc.config`:

```ini
sim_backend=verilator
```

Resolution order is: an explicit `--sim-backend` on the command line,
then the `sim_backend` key in `.abc.config`, then the built-in `vivado`
default. A configured `xsim`/`verilator` default applies **only** to
`-sim` runs — `-synth`, `-impl`, `-bitgen`, and `-gui` always use
Vivado, since those backends cannot drive them. (Passing an explicit
`--sim-backend xsim`/`verilator` together with a non-sim mode is still
an error, because it asks for something impossible.)

## Part definition
By default, the FPGA `xczu19eg-ffvb1517` is chosen. `.abc` files can be called with `-11eg`, `-7ev`, `-7ev1517`, or `-xc7` to select an alternate target part.

## User-defined Arguments

All arguments following "`--`" will be passed to the abc files and can be used for user-defined parametrization, etc.

Example:

```
abc -sim my_testbench -- foo bar
```

`my_testbench.abc:`
```tcl
set arg1 [lindex $::argv_user 0]
# arg1 = "foo"
```
