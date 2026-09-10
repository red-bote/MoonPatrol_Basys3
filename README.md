# Moon Patrol (Basys 3 port)

Moon Patrol (Irem, 1982). Original core: "Moon Patrol" port to MiSTer,
Copyright (C) 2017 Sorgelig, backported to the DeMiSTify framework by
Alastair M. Robinson (source: https://github.com/robinsonb5/MoonPatrol_DeMiSTified).
Sound board by Dar (`darfpga@aol.fr`). See `README.txt` (upstream) for full
attribution. Basys 3 (Artix-7) port.

- Vivado 2020.2 project: `basys3/moonpatrol_basys3.xpr` (top entity
  `moonpatrol_basys3`)
- Core clocks: 30 MHz (system/Z80), 12 MHz (also the scandoubler's `clk_sys`;
  6 MHz `clock_v`/`ce_x1` derived from it) and 14.31818 MHz (4x the sound
  board clock; the 7-series MMCM can't generate 3.579545 MHz directly --
  hard output floor ~4.687 MHz -- so `clock_3p58` is divided down by 4 in
  fabric) -- all from the 100 MHz Basys 3 oscillator via `clk_wiz_0`.
- Video: 31 kHz progressive VGA via an imported MiST scandoubler (no native
  15 kHz TV passthrough option in this port).

This port bypasses the DeMiSTify build framework and its git submodules
entirely -- no Xilinx/Vivado target exists anywhere in that framework -- and
wraps `rtl/target_top.vhd` directly, in this repo's Dar-convention style
(ROM baked into BRAM at synthesis time). See `contrib/basys3/PORTING_SPEC.md`
§0 for the full rationale.

**Build driver note**: the root `Makefile` is the pristine upstream
DeMiSTify framework's own build driver (untouched, still usable for its
original Quartus-based targets) -- the Basys3 build steps below are driven
by **`Makefile.basys3`** instead (`make -f Makefile.basys3 <target>`), to
avoid overwriting pristine content.

## Features supported

- **Video**: 31 kHz progressive VGA via an imported MiST scandoubler
  (`imports/mist/scandoubler.v`, vendored from `vhdl_congo_bongo`'s same
  import). `target_top` already drives real `video_hs`/`video_vs` and
  4-bit/channel RGB -- no dead-port fix needed (unlike `vhdl_congo_bongo`'s
  core).
- **Sound**: mono PWM audio on PmodAMP2. `target_top`'s `AUDIO` is a signed
  13-bit PCM sample, converted to unsigned offset-binary before feeding the
  same PWM-accumulator shape used by every other Basys3 port in this repo.
- **Controls**: JA joystick (movement + fire) + dedicated buttons for
  coin/start. Jump (the game's second action button) is wired from JA's up
  direction rather than a dedicated button. No PS/2 keyboard in this port
  (this core has no built-in scancode decoder, confirmed with the user).

| Input | JA / Button |
|-------|-------------|
| Move | JA1-JA4 |
| Fire (button 1) | JA7 |
| Jump (button 2) | JA4 (up) |
| Start | btnL |
| Coin | btnU |
| Reset | btnC |

JA joystick (active-low, switch to GND): JA1 = Right, JA2 = Left, JA3 = Down,
JA4 = Up (also Jump), JA7 = Fire.

## IO mapping

| Basys 3 resource | Wrapper port | Function |
|------------------|--------------|----------|
| clk (W5, 100 MHz) | `clk` | clock into `clk_wiz_0` MMCM |
| btnC | `btnC` | reset (active-high) |
| btnU | `btnU` | coin |
| btnL | `btnL` | start |
| sw(15) | `O_PMODAMP2_GAIN` | AMP gain: 0 = 12 dB, 1 = 6 dB |
| sw(14) | `O_PMODAMP2_SHUTD` | AMP shutdown: 0 = off, 1 = on |
| sw(0-13) | unused | dip-switch-equivalent (`switches_i`) tied to the "everything off" default (see `contrib/basys3/PORTING_SPEC.md` §6 -- NOT all-zero: bit 15/Test Mode is active-low), no physical mapping |
| JA1-JA4, JA7 | `JA(0..4)` | joystick (active-low); JA4/up also drives jump |
| JC (PmodAMP2) | `O_PMODAMP2_AIN` | PWM audio (mono) |
| VGA | `vgaRed/vgaGreen/vgaBlue(3:0)`, `vgaHsync`, `vgaVsync` | 4-4-4 RGB, 31 kHz VGA |

## Scripted setup

Unlike every sf-darfpga-convention machine, this port has no SourceForge
archive to fetch, and unlike its own upstream DeMiSTify framework it has no
git submodule to initialize either: this repository
(`MoonPatrol_DeMiSTified/`) is itself the pristine source, pinned via its own
git history. `contrib/tools/setup_moonpatrol.sh` applies
`contrib/code/dpram_xilinx_bram.patch` (rewrites `rtl/dpram.vhd` as a
vendor-neutral true dual-port RAM -- the pristine version wraps Altera's
`altsyncram` megafunction and will not synthesize under Vivado) idempotently,
then runs `contrib/tools/prep_roms.sh` to compile `make_vhdl_prom`,
concatenate the romset into one 48 KB blob per the ROM recipe below, and
generate one PROM VHDL file. Run it via `make -f Makefile.basys3 setup`.

`$ROMZIP` (default `~/roms/mpatrol.zip`) is used exactly as it ships -- its
12 relevant filenames already match this port's expected inputs
byte-for-byte, no translation needed.

The remaining steps are wrapped by `Makefile.basys3`: `create_prj` (copies
`moonpatrol_basys3.xpr` and `Basys-3-Master.xdc` into `basys3/`, imports
`scandoubler.v`), `clk_wiz` (generates the `clk_wiz_0` MMCM IP wrappers),
`patch` (authors `moonpatrol_basys3.vhd`), then `synth` / `bitstream`
(Vivado batch runs; logs stay outside the repo) -- e.g.
`make -f Makefile.basys3 create_prj`.

`make -f Makefile.basys3 clean` removes only the generated `basys3/` Vivado project tree and
the staged `tools/roms/` (romset + generated PROM VHDL) -- this port has no
separate extracted archive tree to remove, since the pristine source is this
repository itself.

## ROM set required

Romset staged into `tools/roms/`:

```
$ROMZIP (default ~/roms/mpatrol.zip)   ->   tools/roms/
```

12 files (out of the zip's 16 -- the other 4 are the original arcade's
color/lookup PROMs, unused by this core, which hardcodes palette constants
in VHDL instead), concatenated in `releases/Moon Patrol.mra`'s index-0
order into one 48 KB (0xC000) blob:
`mpa-1.3m`, `mpa-2.3l`, `mpa-3.3k`, `mpa-4.3j`, `mpe-5.3e`, `mpe-4.3f`,
`mpb-2.3m`, `mpb-1.3n`, `mpe-3.3h`, `mpe-2.3k`, `mpe-1.3l`, `mp-s1.1a`.

Generated PROM VHDL: `prom_moonpatrol.vhd` (single 48 KB registered ROM,
played back into `target_top`'s `dn_addr`/`dn_data`/`dn_wr` download bus by
a power-on state machine in `moonpatrol_basys3.vhd` -- see
`contrib/basys3/PORTING_SPEC.md` for the full derivation).

machine ROMs are copyrighted -- never commit or redistribute them.

## Build status

Scripted (`make -f Makefile.basys3 setup create_prj clk_wiz patch`),
verified with a read-only Vivado smoke test (45/45 files resolve, top
entity resolves). `make -f Makefile.basys3 synth` passes, after fixing two
VHDL defects found across two synth attempts: `ERROR: [Synth 8-998] dpram
is not a component` (bare `work.dpram` instantiations require an `entity`
keyword under Vivado, fixed via
`contrib/code/dpram_direct_entity_instantiation.patch`), then `ERROR:
[Synth 8-2559] prefix of attribute high is not a type mark` (a scalar
variable's invalid `'high` use in `platform.vhd`, fixed via
`contrib/code/platform_vblank_count_high.patch`). A `make -f
Makefile.basys3 bitstream` attempt then found a project source-list
omission (not an RTL defect): `T80se.vhd`, required by `rtl/cpu/Z80.vhd`,
was missing from `moonpatrol_basys3.xpr` -- fixed by adding it.

**Bitstream built and flashed to real hardware.** The ROM-playback FSM,
video pipeline, and audio path are evidently working end to end (a
recognizable image and the ROM/RAM test screen both rendered), but video
was found cycling between garbled tiles and the test screen every few
seconds -- root-caused to the dip-switch default (`switches_i`) permanently
asserting Test Mode. Fixed (see IO mapping above and
`contrib/basys3/PORTING_SPEC.md` §6); re-verified with a read-only Vivado
smoke test but not yet re-flashed to hardware.
