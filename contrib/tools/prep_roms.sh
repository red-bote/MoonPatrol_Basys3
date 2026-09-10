#!/bin/bash
# Linux rom-prep for the Moon Patrol Basys3 port.
#
# Unlike the Dar-convention machines elsewhere in this repo, this core has no
# make_*_proms.bat -- the ROM recipe comes from releases/Moon Patrol.mra
# (contrib/basys3/PORTING_SPEC.md §ROM recipe): 12 raw MAME "mpatrol" files,
# concatenated in .mra order, form one flat 48 KB (0xC000) byte stream that
# the pristine RTL's dn_addr/dn_data/dn_wr download bus already expects
# (platform.vhd/moon_patrol_sound_board.vhd each chip-select their own
# address range out of that same flat space -- no per-region split needed
# here, one PROM blob covers all 9 ROM regions).
#
# 1. Compile make_vhdl_prom from the tracked tools_prom_src on the host (gcc).
# 2. Unzip the romset ($ROMZIP, default ~/roms/mpatrol.zip) into tools/roms/.
# 3. Concatenate the 12 files in .mra order into one moonpatrol.bin blob.
# 4. Run make_vhdl_prom once on that blob to generate prom_moonpatrol.vhd
#    (a single 48 KB registered ROM entity, entity name = output filename).
#
# Roms and the generated PROM VHDL stay local (never distributed).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TOOLS_DIR="$ROOT/tools"
ROMS_DIR="$TOOLS_DIR/roms"
TOOLS_SRC="$TOOLS_DIR/tools_prom_src/src"

ROMZIP="${ROMZIP:-$HOME/roms/mpatrol.zip}"

# .mra rom-recipe order (releases/Moon Patrol.mra, index 0 part list).
ROM_FILES=(mpa-1.3m mpa-2.3l mpa-3.3k mpa-4.3j mpe-5.3e mpe-4.3f \
           mpb-2.3m mpb-1.3n mpe-3.3h mpe-2.3k mpe-1.3l mp-s1.1a)

step() { printf '\n==> %s\n' "$1"; }

if [ ! -f "$TOOLS_SRC/make_vhdl_prom.c" ]; then
    echo "error: source tree not found: $TOOLS_SRC" >&2
    exit 1
fi

mkdir -p "$ROMS_DIR"

step "1/4 Compiling make_vhdl_prom on the host"
gcc "$TOOLS_SRC/make_vhdl_prom.c" -lm -o "$TOOLS_DIR/make_vhdl_prom"

step "2/4 Unzipping romset"
unzip -o "$ROMZIP" -d "$ROMS_DIR"

missing=()
for f in "${ROM_FILES[@]}"; do
    [ -f "$ROMS_DIR/$f" ] || missing+=("$f")
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "error: ROMZIP ($ROMZIP) is missing files this port expects:" >&2
    printf '  %s\n' "${missing[@]}" >&2
    echo "See contrib/basys3/PORTING_SPEC.md for the ROM recipe." >&2
    exit 1
fi

step "3/4 Concatenating ROMs in .mra order (48 KB blob)"
CAT_ARGS=()
for f in "${ROM_FILES[@]}"; do
    CAT_ARGS+=("$ROMS_DIR/$f")
done
cat "${CAT_ARGS[@]}" > "$ROMS_DIR/moonpatrol.bin"

blob_size=$(stat -c%s "$ROMS_DIR/moonpatrol.bin")
if [ "$blob_size" -ne 49152 ]; then
    echo "error: concatenated ROM blob is $blob_size bytes, expected 49152 (0xC000)" >&2
    exit 1
fi

step "4/4 Generating PROM VHDL"
# Run with cwd = roms/ and bare filenames: make_vhdl_prom derives the VHDL
# entity name from argv[2] with only the ".vhd" suffix stripped, not any
# directory component, so a path argument would bake an illegal (slash-
# containing) entity name into the generated file.
( cd "$ROMS_DIR" && "$TOOLS_DIR/make_vhdl_prom" moonpatrol.bin prom_moonpatrol.vhd )

if [ ! -s "$ROMS_DIR/prom_moonpatrol.vhd" ]; then
    echo "error: make_vhdl_prom did not produce $ROMS_DIR/prom_moonpatrol.vhd" >&2
    exit 1
fi

echo
echo "Rom-prep complete. PROM VHDL generated:"
ls -1 "$ROMS_DIR/prom_moonpatrol.vhd"
