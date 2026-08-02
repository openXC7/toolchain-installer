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

### Environment setup

After installation, the script generates a file at `/opt/openxc7/export.sh`, which can be sourced
in your terminal to update the environment variables accordingly:

```bash
source /opt/openxc7/export.sh
```

This allows you to use the installed tools in your current shell session
without manually modifying/adding:
- `PATH`
- `PYTHONPATH`
- `NEXTPNR_XILINX_PYTHON_DIR`
- `PRJXRAY_DB_DIR`
