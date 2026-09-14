# openXC7 toolchain installer

This is an open source FPGA toolchain using yosys and nextpnr-xilinx for
Xilinx 7 series FPGAs (Spartan7, Artix7, Zynq7),
with added support for Kintex7 FPGAs (70T, 160T, 325T, 420T, 480T).

## Recommended Installation Methods

### Nix

The nix-based toolchain is the recommended option for Linux and macOS.
It supports the full feature set, including the GHDL plugin in yosys for VHDL.

See: https://github.com/openXC7/toolchain-nix/

### Apio

Apio is a lightweight, pip-installable CLI that wraps yosys, nextpnr, and
the openXC7 database. It provides the simplest getting-started experience:
no snap, no nix, no manual builds.

```
pip install apio
apio install system
```

See: https://github.com/FPGAwars/apio

## Alternative: Build from Sources

The `toolchain-sources-builder.sh` script provides an alternative to Nix or
Apio for users who prefer to build from source. It automates downloading,
building, and installing the toolchain components into `/opt/openxc7`.

The source builder supports macOS with Homebrew and Debian/Ubuntu Linux with
APT. On macOS, install the Xcode command line tools (`xcode-select --install`)
and [Homebrew](https://brew.sh/) first. Run the script as your normal user;
it uses `sudo` when system packages or the installation directory require it.

Use a dedicated build directory. The script resets and cleans its downloaded
source repositories on subsequent runs. Keep these repositories after installation:
Project X-Ray's Python packages are installed in editable mode.

### Objectives

The script handles the following tasks:
- cloning, updating and checking out `yosys`/`nextpnr-xilinx`/`prjxray`/`prjxray-db` repositories
- building each specified tool
- installing the resulting binaries into `/opt/openxc7`

### Usage

The script can be executed with or without arguments:
- with no arguments or `all`: downloads, builds and installs **all** supported tools
- with specific tool names (`yosys` and/or `nextpnr` and/or `prjxray`) only the
  specified tools will be downloaded, built, and installed

```bash
./toolchain-sources-builder.sh all
```

To use a different absolute installation path or limit parallel compilation:

```bash
INSTALL_PREFIX="$HOME/opt/openxc7" JOBS=4 ./toolchain-sources-builder.sh all
```

Python dependencies, including FASM's statically linked ANTLR parser, are installed
in a virtual environment under the installation prefix. System Python packages
are not modified. If the system CMake is older than the 3.28 required by Yosys,
the builder installs a newer CMake in that environment as well.

The Project X-Ray database pin must match the database submodule of the pinned
nextpnr revision. Updating just one can produce missing-feature errors during
`fasm2frames` conversion.

### Environment setup

After installation, the script generates a file at `/opt/openxc7/export.sh`, which can be sourced
in your terminal to update the environment variables accordingly:

```bash
source /opt/openxc7/export.sh
```

For a custom `INSTALL_PREFIX`, source `export.sh` from that directory instead.

This allows you to use the installed tools in your current shell session
without manually modifying/adding:
- `PATH`
- `NEXTPNR_XILINX_PYTHON_DIR`
- `PRJXRAY_DB_DIR`

### Installer checks

The offline regression checks require Bash, Git and Python 3:

```bash
bash -n toolchain-sources-builder.sh
python3 -m unittest discover -s tests -v
shellcheck toolchain-sources-builder.sh tests/smoke-toolchain.sh
```

These checks cover installer control flow; validating a toolchain build also
requires running the builder and generating a bitstream with the installed tools.
After sourcing `export.sh`, run `bash tests/smoke-toolchain.sh` to synthesize,
place and route an Arty A7-35T blinky design and generate its bitstream. This
also exercises chip database generation and FASM's fast parser; it does not
program hardware.
