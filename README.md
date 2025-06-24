# openXC7 toolchain installer

This is an open source FPGA toolchain using yosys and nextpnr-xilinx for 
Xilinx 7 series FPGAs (Spartan7 (coming soon), Artix7, Zynq7),
with added support for Kintex7 FPGAs. (70T, 160T, 325T, 420T, 480T).

In this repository, you can find the snap-based installer, suitable
for Ubuntu 22.04 LTS (and maybe some of its derivatives, YMMV).
For other distributions or operating systems like Mac OS X (untested),
we recommend the nix based toolchain installer, see:
https://github.com/openXC7/toolchain-nix/

We actually would recommend the nix toolchain, because contrary to the snap toolchain,
it has the GHDL plugin in yosys. If you use GHDL standalone,
or don't have VHDL code, you can use the snap toolchain.

To install the snap based toolchain, copy-paste this instruction into a shell:
```
wget -qO - https://raw.githubusercontent.com/openXC7/toolchain-installer/main/toolchain-installer.sh | bash
```

To uninstall the toolchain, copy-pase this command into a shell:
```
wget -qO - https://raw.githubusercontent.com/openXC7/toolchain-installer/main/uninstall.sh | bash
```

## toolchain-sources-build.sh

This *bash* script provides an alternative to using Nix or Snap for setting up the toolchain.
It automates the process of downloading, building, and installing FPGA toolchain components manually.

### Objectives

The script handles the following tasks:
- cloning, updating and checking out `yosys`/`nextpnr-xilinx`/`prjxray`/`prjxray-db` repositories
- building each specified tools
- installing the resulting binaries into the `/opt/openxc7` directory.

### Usage

The script can be excuted with or without arguments:
- with no arguments or `all`: downloads, builds and installs **all** supported tools
- with specific tool names (`yosys` and/or `nextpnr` and/or `prjxray`) only the
  specified tools will be downloaded, built, and installed.

### Environment setup

After installation, the script generate a file at `opt/openxc7/export.sh`, which can be sourced
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
