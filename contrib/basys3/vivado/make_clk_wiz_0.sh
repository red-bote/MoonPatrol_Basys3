#!/bin/bash
# Generate the clk_wiz_0 MMCM IP (100 MHz -> 30/12/3.579545 MHz) for the
# Basys3 port and place its Verilog wrappers where moonpatrol_basys3.xpr
# expects them.
#
# Three genuine clock domains are needed (contrib/basys3/PORTING_SPEC.md):
#   clk_out1 = 30 MHz         -- system/Z80 clock (target_top's clock_30)
#   clk_out2 = 12 MHz         -- also the scandoubler's clk_sys; target_top's
#                                 6 MHz clock_v and the scandoubler's ce_x1 are
#                                 both derived from this by one toggle
#                                 flip-flop in the top level, not generated here
#   clk_out3 = 14.31818 MHz   -- 4x the sound board clock. The 7-series MMCM
#                                 cannot generate 3.579545 MHz directly (hard
#                                 output floor ~4.687 MHz, confirmed by a
#                                 failed IP customization attempt); clock_3p58
#                                 is derived from this by a 2-bit counter
#                                 (divide-by-4) in the top level, the same
#                                 technique used for clock_v above.
#
# The main project's .xpr references two imported files:
#   sources_1/imports/clk_wiz_0/clk_wiz_0.v
#   sources_1/imports/clk_wiz_0/clk_wiz_0_clk_wiz.v
# The IP is generated here in a throwaway Vivado project named mmcm_moonpatrol
# and only those two .v files are copied into the repo. Per project rules
# this script runs from /tmp so vivado.log / vivado.jou stay outside the repo.

set -euo pipefail

VIVADO="${VIVADO:-/tools/Xilinx/Vivado/2020.2/bin/vivado}"
PART=xc7a35tcpg236-1

# Absolute path to this repo's basys3 port tree.
XPR_DIR="$(cd "$(dirname "$0")/../../../basys3" && pwd)"
CLK_WIZ_IMPORT_DIR="$XPR_DIR/moonpatrol_basys3.srcs/sources_1/imports/clk_wiz_0"

# Throwaway project location (logs stay outside the repo).
WORK=/tmp/mmcm_moonpatrol
TCL=$WORK/gen_clk_wiz_0.tcl

rm -rf "$WORK"
mkdir -p "$WORK"

cat > "$TCL" <<EOF
create_project mmcm_moonpatrol "$WORK" -part $PART -force

create_ip -name clk_wiz -vendor xilinx.com -library ip -version 6.0 \
    -module_name clk_wiz_0 -dir "$WORK"

set_property -dict [list \
    CONFIG.PRIMITIVE {MMCM} \
    CONFIG.PRIM_SOURCE {Single_ended_clock_capable_pin} \
    CONFIG.CLKIN1_JITTER_PS {50.0} \
    CONFIG.CLKOUT1_USED {true} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {30} \
    CONFIG.CLKOUT2_USED {true} \
    CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {12} \
    CONFIG.CLKOUT3_USED {true} \
    CONFIG.CLKOUT3_REQUESTED_OUT_FREQ {14.31818} \
    CONFIG.USE_PHASE_ALIGNMENT {true} \
] [get_ips clk_wiz_0]

generate_target all [get_ips clk_wiz_0]
EOF

"$VIVADO" -mode batch -nolog -nojournal -source "$TCL"

GEN_DIR="$WORK/clk_wiz_0"
mkdir -p "$CLK_WIZ_IMPORT_DIR"
cp "$GEN_DIR/clk_wiz_0.v"            "$CLK_WIZ_IMPORT_DIR/"
cp "$GEN_DIR/clk_wiz_0_clk_wiz.v"    "$CLK_WIZ_IMPORT_DIR/"

rm -rf "$WORK"

echo "Generated clk_wiz_0 IP files:"
ls -l "$CLK_WIZ_IMPORT_DIR"
