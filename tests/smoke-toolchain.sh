#!/usr/bin/env bash
# Run after sourcing the installed export.sh. No board is programmed.
set -eo pipefail

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
pypy3 "$NEXTPNR_XILINX_PYTHON_DIR/bbaexport.py" --device xc7a35tcsg324-1 --bba chipdb.bba
bbasm -l chipdb.bba chipdb.bin
nextpnr-xilinx --chipdb chipdb.bin --xdc blinky.xdc --json blinky.json --fasm blinky.fasm --freq 100
fasm2frames --part xc7a35tcsg324-1 --db-root "$PRJXRAY_DB_DIR/artix7" blinky.fasm > blinky.frames
xc7frames2bit --part_file "$PRJXRAY_DB_DIR/artix7/xc7a35tcsg324-1/part.yaml" \
    --part_name xc7a35tcsg324-1 --frm_file blinky.frames --output_file blinky.bit
[[ -s blinky.bit ]]

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
echo 'PASS: synthesis, chip database generation, place/route, FASM and bitstream generation'
