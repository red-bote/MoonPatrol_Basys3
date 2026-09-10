#!/bin/bash
# Drive Vivado to synthesise and build the Moon Patrol Basys3 bitstream.
#
# Usage: make_moonpatrol_basys3_bitstream.sh {synth|bitstream}
#
#   synth     reset and run synthesis only (synth_1)
#   bitstream run implementation + write_bitstream (impl_1, SynthRun=synth_1)
#
# The project must already have its sources in place: run `make setup`, `make
# clk_wiz` and `make patch` first (all covered by `make synth`). The .xpr's
# impl_1 run has GenFullBitstream=true, so it emits
#   basys3/moonpatrol_basys3.runs/impl_1/moonpatrol_basys3.bit
#
# Per project rules this script runs from /tmp so vivado.log / vivado.jou stay
# outside the repository.

set -euo pipefail

MODE="${1:-}"
if [ "$MODE" != "synth" ] && [ "$MODE" != "bitstream" ]; then
    echo "usage: $0 {synth|bitstream}" >&2
    exit 2
fi

VIVADO=/tools/Xilinx/Vivado/2020.2/bin/vivado

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
XPR="$ROOT/basys3/moonpatrol_basys3.xpr"

if [ ! -f "$XPR" ]; then
    echo "error: Vivado project not found: $XPR" >&2
    echo "Run 'make setup clk_wiz patch' first." >&2
    exit 1
fi

WORK=/tmp/moonpatrol_bitstream
mkdir -p "$WORK"
TCL="$WORK/run_${MODE}.tcl"

cat > "$TCL" <<EOF
open_project "$XPR"
if { "$MODE" eq "synth" } {
    reset_run synth_1
    launch_runs synth_1 -jobs 4
    wait_on_run synth_1
    if { [get_property PROGRESS [get_runs synth_1]] ne "100%" } {
        puts "ERROR: synthesis failed (PROGRESS [get_property PROGRESS [get_runs synth_1]])"
        exit 1
    }
} else {
    launch_runs impl_1 -to_step write_bitstream -jobs 4
    wait_on_run impl_1
    if { [get_property PROGRESS [get_runs impl_1]] ne "100%" } {
        puts "ERROR: implementation/bitstream failed"
        exit 1
    }
}
close_project
EOF

# Run from /tmp so vivado.log / vivado.jou land outside the repo.
(cd "$WORK" && "$VIVADO" -mode batch -nolog -nojournal -source "$TCL")

rm -rf "$WORK"

if [ "$MODE" = "synth" ]; then
    echo "Synthesis complete: synth_1"
else
    BIT="$ROOT/basys3/moonpatrol_basys3.runs/impl_1/moonpatrol_basys3.bit"
    if [ -f "$BIT" ]; then
        echo "Bitstream: $BIT"
    else
        echo "warning: bitstream not found at $BIT" >&2
    fi
fi
