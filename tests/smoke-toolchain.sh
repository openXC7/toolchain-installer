#!/usr/bin/env bash
# Run after sourcing the installed export.sh. No board is programmed.
set -eo pipefail

# Source the default (or $INSTALL_PREFIX) installation if the environment is
# not set up yet.  Sourcing the README's export.sh step is easy to skip, and
# the failure without it names a file under an empty NEXTPNR_XILINX_DIR.
install_prefix=${INSTALL_PREFIX:-/opt/openxc7}
export_sh=$install_prefix/export.sh
environment_is_unset=false
if [[ -z ${NEXTPNR_XILINX_DIR:-} && -z ${PRJXRAY_DB_DIR:-} ]]; then
    environment_is_unset=true
fi
default_export_is_present=false
if [[ -f $export_sh ]]; then
    default_export_is_present=true
fi
if [[ $environment_is_unset == true && $default_export_is_present == true ]]; then
    # shellcheck disable=SC1090
    source "$export_sh"
fi

# A prefix installed before the openXC7/nextpnr engine is indistinguishable
# from a missing environment until the tools are checked by name.  Fail here
# with the installer version rather than on the first file the script opens.
nextpnr_dir_is_set=false
if [[ -n ${NEXTPNR_XILINX_DIR:-} ]]; then
    nextpnr_dir_is_set=true
fi
if [[ $nextpnr_dir_is_set == false ]]; then
    printf '%s\n' \
        "Error: NEXTPNR_XILINX_DIR is not set." \
        "Source the installed export.sh first, e.g. /opt/openxc7/export.sh," \
        "or set INSTALL_PREFIX to the prefix it was installed in. If you did" \
        "source it, the prefix was installed before toolchain-installer 1.0.0;" \
        "rerun the current toolchain-sources-builder.sh." >&2
    exit 1
fi

db_dir_is_set=false
if [[ -n ${PRJXRAY_DB_DIR:-} ]]; then
    db_dir_is_set=true
fi
if [[ $db_dir_is_set == false ]]; then
    printf '%s\n' \
        "Error: PRJXRAY_DB_DIR is not set." \
        "Source the installed export.sh first, e.g. /opt/openxc7/export.sh." >&2
    exit 1
fi

xilinx_gen=$NEXTPNR_XILINX_DIR/share/nextpnr/himbaechel/uarch/xilinx/gen/xilinx_gen.py
generator_is_present=false
if [[ -f $xilinx_gen ]]; then
    generator_is_present=true
fi
if [[ $generator_is_present == false ]]; then
    printf '%s\n' \
        "Error: $xilinx_gen is missing." \
        "The prefix predates the openXC7/nextpnr engine (nextpnr-xilinx" \
        "0.9.x); rerun the current toolchain-sources-builder.sh, or use the" \
        "nix toolchain." >&2
    exit 1
fi

fpga_as_is_present=false
if command -v fpga-as >/dev/null 2>&1; then
    fpga_as_is_present=true
fi
if [[ $fpga_as_is_present == false ]]; then
    printf '%s\n' \
        "Error: fpga-as is not on PATH." \
        "toolchain-installer release 1.0.0 and older predate fpga-as;" \
        "install from a current checkout of toolchain-installer (main), or" \
        "use the nix toolchain." >&2
    exit 1
fi

workdir=$(mktemp -d)
cleanup() {
    if [[ $? == 0 ]]; then
        rm -rf "$workdir"
    else
        echo "Smoke test failed; artifacts retained in $workdir" >&2
    fi
}
trap cleanup EXIT
cd "$workdir"

cat > blinky.v <<'VERILOG'
module blinky(input clk, output led);
    reg [25:0] counter = 0;
    always @(posedge clk) counter <= counter + 1;
    assign led = counter[25];
endmodule
VERILOG
cat > blinky.xdc <<'XDC'
set_property LOC E3 [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports clk]
set_property LOC H5 [get_ports led]
set_property IOSTANDARD LVCMOS33 [get_ports led]
XDC

python3 -c 'import fasm.parser; assert fasm.parser.implementation == "antlr"'
yosys -Q -p 'synth_xilinx -flatten -abc9 -arch xc7 -top blinky; write_json blinky.json' blinky.v
# The engine generates a database per DIE and takes a die name: xc7a35tcsg324
# is served by the xc7a50t database.  The file is named after the PART because
# the nextpnr-xilinx shim derives --device from the chipdb filename, the same
# convention openXC7.mk uses.
python3 "$NEXTPNR_XILINX_DIR/share/nextpnr/himbaechel/uarch/xilinx/gen/xilinx_gen.py" \
    --xray "$PRJXRAY_DB_DIR/artix7" --device xc7a50t --bba chipdb.bba
bbasm -l chipdb.bba xc7a35tcsg324.bin
nextpnr-xilinx --chipdb xc7a35tcsg324.bin --xdc blinky.xdc --json blinky.json --fasm blinky.fasm --freq 100
fasm2frames --part xc7a35tcsg324-1 --db-root "$PRJXRAY_DB_DIR/artix7" blinky.fasm > blinky.frames
xc7frames2bit --part_file "$PRJXRAY_DB_DIR/artix7/xc7a35tcsg324-1/part.yaml" \
    --part_name xc7a35tcsg324-1 --frm_file blinky.frames --output_file blinky.bit
[[ -s blinky.bit ]]

# fpga-as assembles the same configuration in one process and is what the
# makefiles call.  Compare frames rather than .bit files: their headers carry
# the design name and a build timestamp.
fpga-as --prjxray_db_path="$PRJXRAY_DB_DIR/artix7" --part xc7a35tcsg324-1 blinky.fasm > blinky-as.bit
[[ -s blinky-as.bit ]]
fpga-as --dump_frames_file=blinky-as.frames --prjxray_db_path="$PRJXRAY_DB_DIR/artix7" \
    --part xc7a35tcsg324-1 blinky.fasm > /dev/null
python3 - <<'PY'
def parse(path):
    frames = {}
    for line in open(path):
        fields = line.replace(',', ' ').split()
        if fields:
            frames[int(fields[0], 16)] = [int(word, 16) for word in fields[1:]]
    return frames


reference = parse('blinky.frames')
assembled = parse('blinky-as.frames')
assert set(assembled) <= set(reference), 'fpga-as set frames fasm2frames did not'
assert all(reference[a] == w for a, w in assembled.items()), 'frame content differs'
assert all(not any(reference[a]) for a in set(reference) - set(assembled)), \
    'fpga-as dropped a frame that carries data'
print('fpga-as frames match fasm2frames')
PY

# Regression for the missing HP-bank/column features and edge-tile mapping
# reported by the Kintex-7 DDR/HDMI demo with the old 0.9.1 database.
cat > kintex.fasm <<'FASM'
RIOB18_X95Y73.IOB_Y0.IBUFDS_BANK_GLUE
INT_R_X95Y1.IOB_COL_BANK_ACTIVE
INT_R_X95Y1.IOB_COL_OBUF_CASCADE_Y1
RIOI_X95Y9.OLOGIC_Y0.ZINV_T1
FASM
fasm2frames --part xc7k325tffg676-1 --db-root "$PRJXRAY_DB_DIR/kintex7" kintex.fasm > kintex.frames
[[ -s kintex.frames ]]
echo 'PASS: synthesis, chip database generation, place/route, FASM, fpga-as parity and bitstream generation'
