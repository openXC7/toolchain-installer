# openXC7 toolchain installer

This is an open source FPGA toolchain using yosys and nextpnr-xilinx for 
Xilinx 7 series FPGAs (Spartan7 (coming soon), Artix7, Zynq7),
with added support for Kintex7 FPGAs. (70T, 160T, 325T, 420T, 480T).

In this repository, you can find the snap-based installer, suitable
for Ubuntu 22.04 LTS (and maybe some of its derivatives, YMMV).
For other distributions or operating systems like Mac OS X (untested),
we recommend the nix based toolchain installer, see:
https://github.com/openXC7/toolchain-nix/

To install the snap based toolchain, copy-paste this instruction into a shell:
```
wget -qO - https://raw.githubusercontent.com/openXC7/toolchain-installer/main/toolchain-installer.sh | bash
```

To uninstall the toolchain, copy-pase this command into a shell:
```
wget -qO - https://raw.githubusercontent.com/openXC7/toolchain-installer/main/uninstall.sh | bash
```
