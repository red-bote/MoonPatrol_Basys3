#!/bin/bash
# Apply fix patches to the pristine DeMiSTify/PACE source, then chain into the
# rom-prep script.
#
# This port bypasses the DeMiSTify build framework and its git submodules
# entirely (see contrib/basys3/PORTING_SPEC.md §0): MoonPatrol_DeMiSTified/
# (this directory) IS the pristine source, pinned via its own git history
# (a checkout of https://github.com/robinsonb5/MoonPatrol_DeMiSTified).
#
# 1. Apply fix patches idempotently (patch -p1 --forward). Glob covers both
#    contrib/*/code/*.patch and contrib/code/*.patch.
#    Excludes *_basys3_top.patch (if any is ever added): a record of a
#    top-level rewrite, not a fix to apply to the pristine tree.
#    Excludes *scandoubler_fix.patch: applied later by create_project.sh to
#    the imported scandoubler copy inside basys3/, not to the pristine
#    contrib/code/scandoubler.v import.
# 2. Run contrib/tools/prep_roms.sh (compile make_vhdl_prom, concatenate the
#    12 ROMs into one blob per the .mra recipe, generate one PROM VHDL file).
#
# Roms and the generated PROM VHDL stay local (never distributed).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

step() { printf '\n==> %s\n' "$1"; }

step "1/2 Applying fix patches (contrib/*/code/*.patch and contrib/code/*.patch)"
for p in "$ROOT"/contrib/*/code/*.patch "$ROOT"/contrib/code/*.patch; do
    [ -e "$p" ] || continue
    case "$p" in
        *_basys3_top.patch) continue ;;
        *scandoubler_fix.patch) continue ;;
    esac
    # GNU patch's --forward still exits 1 (and writes a .rej) on an
    # already-applied patch instead of silently no-op'ing -- check via a
    # reverse dry-run first so re-running `make setup` is actually
    # idempotent (known project-wide finding, see
    # vhdl_congo_bongo/contrib/basys3/PORTING_SPEC.md §0).
    if (cd "$ROOT" && patch -p1 -R --dry-run --forward < "$p" > /dev/null 2>&1); then
        echo "==> already applied, skipping $p"
    else
        echo "==> applying $p"
        (cd "$ROOT" && patch -p1 --forward < "$p")
    fi
done

step "2/2 Running rom-prep"
"$ROOT/contrib/tools/prep_roms.sh"

echo
echo "Setup complete. Source tree in:"
echo "  $ROOT"
