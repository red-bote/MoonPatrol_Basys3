# Moon Patrol — Porting spec (Basys 3)

Status: bitstream built and flashed to real Basys 3 hardware. First bring-up
showed garbled video cycling with the ROM/RAM test screen — root-caused to
`switches_i`'s all-zero default permanently asserting Test Mode (bit 15,
active-low), fixed (§6). Not yet re-verified on hardware with the fix.
Earlier: two synthesis-failing VHDL defects (`dpram_direct_entity_instantiation.patch`,
`platform_vblank_count_high.patch`) and one project source-list omission
(missing `T80se.vhd`) were found and fixed across the `make synth`/`make
bitstream` cycle — see §3.

## 0. Deviations from the sf-darfpga project convention (confirmed with user)

This port does not follow the `sf-darfpga/<Machine>-by-Dar/` layout, the
SourceForge-archive setup convention, or the DeMiSTify framework this core
itself is built on. Confirmed decisions:

- **Location**: ported in place inside `MoonPatrol_DeMiSTified/`, not as a
  new `sf-darfpga/Moon-Patrol-by-Dar/` directory. `MoonPatrol_DeMiSTified/`
  itself plays the role every other machine's `<Machine>-by-Dar/` directory
  plays — the same in-place convention as `vhdl_congo_bongo`/
  `vhdl_naughty_boy`.
- **Source acquisition**: `MoonPatrol_DeMiSTified/` is its own git checkout
  of `https://github.com/robinsonb5/MoonPatrol_DeMiSTified` (pinned at
  `301921b`, "Initial DeMiSTification"). No archive-fetch/SHA-256 step.
- **Framework bypass — stronger than `vhdl_congo_bongo`'s deviation**:
  `vhdl_congo_bongo` deviated only in *source acquisition* (git checkout
  instead of a SourceForge fetch) while still following the general
  hand-authored-top-level pattern. This port additionally bypasses the
  *entire DeMiSTify build framework* the core ships with: investigation
  found no Xilinx/Vivado target anywhere in DeMiSTify (all real targets —
  `de10lite`, `chameleon64`, `chameleon64v2` — are Altera: MAX10/Cyclone
  III/MAX10), and the framework's actual board-scaffolding/build-generator
  logic lives in an uninitialized git submodule (`DeMiSTify/`, declared in
  `.gitmodules`, never fetched — a network/git operation not taken without
  explicit user request). Confirmed with the user (Option B of two
  investigated directions): hand-author a standalone Basys3 top level
  wrapping `rtl/target_top.vhd` directly, following this repo's established
  Dar-convention style (bake ROM into BRAM at synthesis time, bespoke
  scandoubler/audio-DAC wrapper) — **not** `Arcade-MoonPatrol.sv` (MiSTer
  top) or `moonpatrol_mist.sv` (MiST top), which are board glue this port
  replaces entirely, not adapts.
- `setup_moonpatrol.sh` skips any archive fetch and any submodule
  initialization; it starts from `rtl/`, already present in this
  directory's own git history.

## 1. Reference model

- Source: `MoonPatrol_DeMiSTified/` (this directory), pinned pristine
  reference — see §0.
- Wrapped module: `rtl/target_top.vhd` (entity `target_top`) — the actual
  game-hardware boundary, common to both the MiSTer and MiST board tops.
  Full port list (confirmed by reading the file):
  `clock_30`/`clock_v`/`clock_3p58`/`reset` (clocks/reset), `switches_i`
  (18-bit dip-switch-equivalent, `from_SWITCHES_t` = `std_logic_vector(17
  downto 0)`), `dn_addr(15:0)`/`dn_data(7:0)`/`dn_wr` (download bus, no
  index — see §7), `AUDIO` (`signed(12 downto 0)`), `JOY`/`JOY2`
  (`std_logic_vector(7 downto 0)` each), `VGA_VBLANK`/`VGA_HBLANK`/`VGA_VS`/
  `VGA_HS`/`VGA_R`/`VGA_G`/`VGA_B` (`R`/`G`/`B` are `std_logic_vector(3
  downto 0)` each), `palmode`, `hs_offset`/`vs_offset` (4-bit trim), `pause`,
  `hs_address(10:0)`/`hs_data_out(7:0)`/`hs_data_in(7:0)`/`hs_write`
  (hiscore RAM port — dropped, see §6).
- Top entity (new): `moonpatrol_basys3` (target file
  `sources_1/new/moonpatrol_basys3.vhd`) — **original**, not a diff of an
  existing pristine top (no DE10-lite/MiST VHDL top exists to adapt; the
  closest analogues, `Arcade-MoonPatrol.sv`/`moonpatrol_mist.sv`, are
  discarded board glue, not a baseline).
- Part: `xc7a35tcpg236-1`, VHDL target language.
- Reference cores used unchanged: `rtl/target_top.vhd` → `rtl/pace.vhd` →
  `rtl/input_mapper.vhd` + `rtl/platform.vhd` + `rtl/Graphics.VHD` (PACE
  framework: video timing, sprite/tilemap/bitmap controllers, Z80 core —
  `rtl/cpu/Z80.vhd` instantiates `T80se` (component `Z80.vhd:33-60,108`),
  which in turn instantiates `T80` (`T80se.vhd:115`) — **correction**: an
  earlier research pass concluded `T80se.vhd` was unused/dead and it was
  initially excluded from the `.xpr` source list; a `make bitstream`
  implementation run caught this (`DRC INBB-3` black-box error on
  `Z80_uP`/`T80se`, §3) — `T80se.vhd` is required and now included, alongside
  `T80.vhd`/`T80_ALU.vhd`/`T80_MCode.vhd`/`T80_Pack.vhd`/`T80_Reg.vhd`) and
  `rtl/moon_patrol_sound_board.vhd` (Dar's Z80-era sound board reused
  directly: `cpu68` 6800/6801-class CPU,
  two `YM2149` PSGs (`rtl/ym_2149_linmix.vhd`), MSM5205-model ADPCM).

## 2. Clocking — three genuine domains

`target_top` takes three separate clock inputs (confirmed by reading the
entity and cross-referencing every `work.dpram` instance's `clock_a`
wiring, all of which use `clock_30` directly or via `clk_sys` alias):

- `clock_30` (30 MHz) — system/Z80 clock domain. `platform.vhd`'s
  `clk_sys` is an alias for `clkrst_i.clk(0)`, driven from `clock_30`.
- `clock_v` (6 MHz) — **a genuine derived clock, not a clock-enable**.
  MiSTer's own top divides its 48 MHz PLL output by 8 to produce this
  (`Arcade-MoonPatrol.sv:320-326`) before feeding it to `target_top` as
  `clock_v`. `platform.vhd`'s `clk_video` alias (`clkrst_i.clk(1)`) drives
  every graphics-ROM read port and the video timing generator.
  `iremm52_video_controller.vhd` confirms the pixel clock is genuinely
  ~6.144 MHz (`384 pixels / 6.144 MHz = 62.5 µs/line = 16.000 kHz`); this
  port approximates it as an even 6 MHz (~0.7% deviation), the same kind of
  integer-clock approximation MiSTer's own PLL already makes.
- `clock_3p58` (3.579545 MHz) — sound board clock, feeds
  `moon_patrol_sound_board.vhd` directly (which further divides it
  internally: `cpu_clock <= clock_div(1)`, i.e. `clock_3p58/4`).
- All three come from **one** Basys3 `clk_wiz_0` MMCM (100 MHz in):
  `clk_out1`=30 MHz, `clk_out2`=12 MHz. `clock_v` (6 MHz) and the
  scandoubler's `ce_x1` enable are both derived from `clk_out2` (12 MHz,
  also used directly as the scandoubler's `clk_sys`) by **one toggle
  flip-flop** in the top level — a generated clock, the same technique
  `vhdl_congo_bongo`'s `clock_div_kbd` already uses elsewhere in this repo,
  not a clock-enable-gated version of the 12 MHz clock.
  **`clock_3p58` cannot come directly from the MMCM**: a 7-series MMCM has
  a hard output-frequency floor of ~4.687 MHz (confirmed empirically — a
  `clk_wiz_0` IP customization requesting `CLKOUT3_REQUESTED_OUT_FREQ =
  3.579545` failed Vivado's own parameter validation with exactly that
  range). Fix: `clk_out3` requests **14.31818 MHz** (4x, safely above the
  floor) instead, and `clock_3p58` is derived from it by a 2-bit
  free-running counter's top bit (an exact divide-by-4, 50% duty cycle) —
  same derived-clock technique as `clock_v`.
- Reset: `reset <= btnC or not mmcm_locked or loading` (see §7 for
  `loading`) — standard project pattern, `target_top` synchronizes it
  per-domain internally (`GEN_RESETS`, `target_top.vhd:90-103`; two of its
  four reset-shift-register domains are driven by clocks `target_top` never
  connects — pre-existing dead logic in the pristine core, not introduced
  by this port).

## 3. `rtl/dpram.vhd` — must be replaced (patched)

Confirmed by reading the file: wraps Altera's `altsyncram` megafunction
(`BIDIR_DUAL_PORT`, `intended_device_family => "Cyclone V"`) with generics
`addr_width_g`/`data_width_g` and ports `address_a/b`, `clock_a/b`,
`data_a/b`, `enable_a/b`, `wren_a/b`, `q_a/b`. No static-init mechanism —
will not synthesize under Vivado.

**Fix** (`contrib/code/dpram_xilinx_bram.patch`, applied idempotently by
`setup_moonpatrol.sh`): rewritten as a vendor-neutral true dual-port RAM —
two independent synchronous processes (one per port/clock), a shared
`ram_t` array variable, new-data read-during-write on each port (matching
the original's `read_during_write_mode_port_a/b =>
"NEW_DATA_NO_NBE_READ"`: the variable write happens before the read in the
same clocked process, so a same-address write-then-read returns the new
data). Same generic/port names, so **no caller needs to change** —
`platform.vhd` (8 ROM instances + `vram_inst`/`cram_inst`/`wram_inst`) and
`moon_patrol_sound_board.vhd` (1 ROM instance) are used completely
unmodified. Verified: applies cleanly (`patch -p1 --forward`), reverse
dry-run correctly detects "not yet applied" on a fresh checkout (the known
project-wide `patch --forward`-is-not-idempotent finding, worked around the
same way as every other machine's `setup_<machine>.sh`).

`rtl/spram.vhd` has the identical problem (also wraps `altsyncram`) but
**no instantiation exists anywhere in the `target_top` build** (confirmed
by grep) — excluded from the Vivado source list, no patch needed.

`rtl/tilemapctl.vhd`'s one `altera_attribute` pragma (`AUTO_ROM_RECOGNITION
OFF`) is a harmless-if-ignored Quartus-only synthesis directive — left
as-is.

### `dpram_direct_entity_instantiation.patch` — found via a real `make synth` run

All 10 `work.dpram` instantiations across `platform.vhd` (8) and
`moon_patrol_sound_board.vhd` (2) use bare `label : work.dpram generic
map(...)` syntax — no `entity` keyword. Vivado resolves a keyword-less
instantiation as an implicit **component** instantiation, which requires a
matching `component dpram is ... end component;` declaration; none exists
anywhere in this design. First `make synth` attempt failed RTL elaboration
with `ERROR: [Synth 8-998] dpram is not a component` at
`moon_patrol_sound_board.vhd:366,380` (elaboration aborted there before
reaching `platform.vhd`'s identically-written instances, so those weren't
independently confirmed broken, but the same defect class applies to all
10 — only `platform.vhd`'s `vram_inst`/`cram_inst`/`wram_inst`, which
already use the unambiguous `entity work.dpram` form, are unaffected).

Fix (`contrib/code/dpram_direct_entity_instantiation.patch`, applied
idempotently by `setup_moonpatrol.sh` alongside the BRAM-rewrite patch
above): add the explicit `entity` keyword to all 10 bare instantiations —
purely a keyword insertion, no other change. Verified: applies cleanly,
reverse dry-run correctly detects "not yet applied" on both files.

### `platform_vblank_count_high.patch` — found via a second `make synth` run

With the above fixed, a second `make synth` attempt got past `dpram`
resolution and failed RTL elaboration again, this time on
`ERROR: [Synth 8-2559] prefix of attribute high is not a type mark` at
`platform.vhd:389,395`. Root cause: `BLK_INTERRUPTS`'s VBLANK-interrupt
timer (`platform.vhd:384`) declares `variable count : integer range 0 to
CLK0_FREQ_MHz * 100;` and then uses `count'high` twice (reset value, and
the terminal-count comparison) — the `'HIGH` attribute's prefix must be a
type/subtype mark (or a constrained array object), not a scalar variable
object; some tools (evidently whatever this core was originally verified
against) tolerate this as a convenience, Vivado does not. (The one other
`'high` use in the tree, `sprite_pkg_body.vhd:56`'s `d_i_0'high`, is on an
array-typed object — a genuinely valid use, unaffected.)

Fix (`contrib/code/platform_vblank_count_high.patch`, applied idempotently
after the direct-entity-instantiation patch — both touch `platform.vhd`,
and this one's context lines assume that patch already applied, so
`setup_moonpatrol.sh`'s glob order matters here; verified empirically, see
below): replace both `count'high` occurrences with the actual bound
expression, `CLK0_FREQ_MHz * 100`. Verified: a full fresh `git checkout` +
`make setup` applies all three patches (`dpram_direct_entity_instantiation`
→ `dpram_xilinx_bram` → `platform_vblank_count_high`, in that order) 
cleanly in one pass, and a second `make setup` run detects all three as
already applied (idempotent).

### Missing `T80se.vhd` — found via a `make bitstream` implementation run

With both VHDL defects above fixed, `make synth` passed and a `make
bitstream` attempt got into `opt_design`, then failed DRC:
`ERROR: [DRC INBB-3] Black Box Instances: Cell
'target_inst/pace_inst/platform_inst/BLK_CPU.cpu_inst/Z80_uP' of type
'T80se' has undefined contents`. Root cause: `rtl/cpu/Z80.vhd` (the actual
CPU entity `platform.vhd` instantiates) declares and instantiates a
`component T80se` (`Z80.vhd:33-60,108`), which itself instantiates `T80`
(`T80se.vhd:115`) — i.e. `T80se.vhd` is a required wrapper, not a leaf
core, and not the dead file §1's original research concluded (that
conclusion was wrong — corrected in §1). It was excluded from
`moonpatrol_basys3.xpr`'s source list, so Vivado had no entity to bind
`T80se` to and synthesized it as an undefined black box (this is a project
**source-list omission**, not a pristine-RTL defect — no `.patch` needed).

Fix: added `rtl/cpu/T80se.vhd` to `moonpatrol_basys3.xpr`. Verified: a
fresh `create_prj clk_wiz patch` rebuild plus a read-only Vivado smoke test
confirms 45/45 files resolve (was 44/44) and the top entity still resolves
to `moonpatrol_basys3`.

## 4. ROM download bus and playback design

`dn_addr(15:0)`/`dn_data(7:0)`/`dn_wr` is a **flat bus, no index signal** —
broadcast from `target_top` to both `pace`→`platform.vhd` and
`moon_patrol_sound_board.vhd`, each independently chip-selecting its own
address range out of `dn_addr`'s upper bits (distributed decode, confirmed
by reading both files):

| Region | `dn_addr` range | Size | `work.dpram` instance (file:line) |
|---|---|---|---|
| Main Z80 program ROM | `0x0000-0x3FFF` (`dn_addr(15:14)="00"`) | 16 KB | `platform.vhd:431` `rom_inst` |
| Char/tile ROM, plane 0 | `0x4000-0x4FFF` (`"0100"`) | 4 KB | `platform.vhd:444` `char1_rom_inst` |
| Char/tile ROM, plane 1 | `0x5000-0x5FFF` (`"0101"`) | 4 KB | `platform.vhd:457` `char2_rom_inst` |
| Sprite ROM, plane 0 | `0x6000-0x6FFF` (`"0110"`) | 4 KB | `platform.vhd:473` `sprite1_rom_inst` |
| Sprite ROM, plane 1 | `0x7000-0x7FFF` (`"0111"`) | 4 KB | `platform.vhd:489` `sprite2_rom_inst` |
| Background ROM 1 | `0x8000-0x8FFF` (`"1000"`) | 4 KB | `platform.vhd:507` `bg1_rom_inst` |
| Background ROM 2 | `0x9000-0x9FFF` (`"1001"`) | 4 KB | `platform.vhd:520` `bg2_rom_inst` |
| Background ROM 3 | `0xA000-0xAFFF` (`"1010"`) | 4 KB | `platform.vhd:533` `bg3_rom_inst` |
| Sound-CPU (`cpu68`) program ROM | `0xB000-0xBFFF` (`"1011"`) | 4 KB | `moon_patrol_sound_board.vhd:366` `cpu_prog_rom` |

Total: `0x0000`–`0xBFFF`, 48 KB (0xC000 bytes) — exactly
`releases/Moon Patrol.mra`'s index-0 12-part concatenated stream (§5). Two
further `dpram` instances (`vram_inst`, `cram_inst`, `platform.vhd:551,570`)
and one (`wram_inst`, `platform.vhd:591`) are genuine work RAM, not download
targets (`wren_a` tied to `'0'`/CPU-driven, not gated by `dn_wr`).

**Design decision — no *architectural* changes needed to `platform.vhd`/
`moon_patrol_sound_board.vhd`'s ROM wiring** (a keyword-only syntax fix was
separately needed for synthesis — see above, unrelated to the ROM-loading
design): since the existing chip-select decode already spans exactly the
same flat address space the `.mra`'s concatenated stream uses, a **new
power-on ROM-playback state machine** in `moonpatrol_basys3.vhd` reproduces
what a real SD-card/HPS downloader would have done, with no change to
*which* addresses/data reach *which* ROM instance:

1. While `mmcm_locked = '0'`: hold the state machine at its initial state,
   address counter at 0, `loading = '1'` (which keeps `target_top.reset`
   asserted).
2. Per byte (address `0` to `ROM_BYTES-1` = `49151`): present the address
   to the generated `prom_moonpatrol` ROM entity (1-cycle registered read
   latency), then on the next cycle drive `dn_addr`/`dn_data` from that
   address/its data and pulse `dn_wr` for one cycle.
3. After the last byte's write pulse, deassert `loading` one cycle later —
   `target_top.reset` drops and the core starts running with all 9 ROM
   regions loaded.

Runs entirely on `clock_30` (confirmed safe: every ROM `dpram` instance's
port-A/write-side clock is `clk_sys`/`clock_30` — the read side may be on a
different clock, `clk_video` or a sound-board-internal divided clock, but
`dpram`'s two ports are independently clocked by design, so the playback
FSM only needs to match the *write* side's clock).

## 5. ROM recipe (`releases/Moon Patrol.mra`, index 0)

`.mra` gives an ordered `<part>` list per `<rom index>`, no explicit
offsets — the downloader streams the named files concatenated in listed
order starting at address 0 of that index. Only index 0 feeds the download
bus (`ioctl_index==0` check in `Arcade-MoonPatrol.sv:358`); indices 1-4 are
hiscore config/NVRAM, not used by this port (§6).

| # | file | offset | length |
|---|---|---|---|
| 1 | `mpa-1.3m` | `0x0000` | `0x1000` |
| 2 | `mpa-2.3l` | `0x1000` | `0x1000` |
| 3 | `mpa-3.3k` | `0x2000` | `0x1000` |
| 4 | `mpa-4.3j` | `0x3000` | `0x1000` |
| 5 | `mpe-5.3e` | `0x4000` | `0x1000` |
| 6 | `mpe-4.3f` | `0x5000` | `0x1000` |
| 7 | `mpb-2.3m` | `0x6000` | `0x1000` |
| 8 | `mpb-1.3n` | `0x7000` | `0x1000` |
| 9 | `mpe-3.3h` | `0x8000` | `0x1000` |
| 10 | `mpe-2.3k` | `0x9000` | `0x1000` |
| 11 | `mpe-1.3l` | `0xA000` | `0x1000` |
| 12 | `mp-s1.1a` | `0xB000` | `0x1000` |

Total: `0xC000` bytes (48 KB), matching §4's `dn_addr` span exactly — one
concatenated blob covers every ROM region, no per-region splitting needed.

### Romset — resolved, no translation needed

`~/roms/mpatrol.zip` (MAME canonical "mpatrol" set, 16 files) confirmed
present; all 12 files above are in it by exact filename — no `DAR_TO_CANON`-
style translation table needed. The 4 extra files (`mpc-1.1f`/`mpc-2.2h`/
`mpc-3.1m`/`mpc-4.2a`) are the original arcade's color/lookup PROMs; this
core replaces those with hardcoded VHDL palette constants
(`rtl/platform_variant_pkg.vhd`: `tile_pal`, `bg_pal`, `sprite_pal`,
`sprite_table`), so they're unused here — consistent with no color-PROM
chip-select existing anywhere in §4's decode table. `ROMZIP` defaults to
`~/roms/mpatrol.zip`.

## 6. Dropped features (confirmed with user)

- **Dip switches** (`switches_i`, 18 bits): **corrected during hardware
  bring-up** — no physical Basys3 switch mapping, but the original
  all-zero default (justified at the time by `Arcade-MoonPatrol.sv` never
  referencing `switches_i` at all) was wrong and caused a real symptom:
  bit 15 (Test Mode) is active-low, so tying it to `'0'` permanently
  asserted test mode — observed on hardware as the display cycling
  between garbled tiles and the ROM/RAM test screen every few seconds.
  Fixed by tying `switches_i` to the exact "everything off" pattern
  `moonpatrol_mist.sv:160-167` derives from its OSD `status[]` bits
  (`~status[9]`=test mode, `~status[7]`=unlabeled, `~status[8]`=sector
  select, `~status[10]`=freeze enable, all defaulting high i.e. off;
  `switches_i[11:8]="1100"` and `switches_i[7:4]="1111"` are fixed values
  in that file, not OSD-derived at all; `~status[6:5]`=new car and
  `~status[4:3]`=patrol cars default to `"11"`) — see
  `moonpatrol_basys3.vhd`'s `switches_i` port-map comment for the exact
  per-field derivation. Bits 17:16 (beyond MiST's 16-bit `switches_i`,
  `target_top`'s port is 18 bits) are unused/reserved, defaulted high.
- **Hiscore/NVRAM** (`hs_address`/`hs_data_in`/`hs_data_out`/`hs_write`):
  tied inactive (`hs_write <= '0'`, others zeroed). Basys3 has no
  persistent storage in the base design. Zero-risk drop: `platform.vhd`'s
  `wram_inst` (the RAM this port serves) is also ordinary CPU work RAM on
  its other port — tying the hiscore port off doesn't disable or corrupt
  anything else.
- **PS/2 keyboard**: unlike the Dar-convention cores
  elsewhere in this repo, this core has no built-in scancode decoder
  (`JOY`/`JOY2` are raw bit vectors normally driven by DeMiSTify's
  OSD/HPS layer), and its bit layout differs from Dar's `JoyPCFRLDU`
  convention, so it was not a drop-in reuse of `kbd_joystick.vhd`. 
**Added by means of a small translation layer between
  `kbd_joystick`'s output and this core's `JOY` layout — not a drop-in, but
  a one-bit-order remap only; see §9. JA + dedicated buttons continue to
  work simultaneously (§9).
- **15 kHz TV passthrough**: no switch-selectable native-rate video mode
  (unlike the Dar-convention cores' `tv15kHz_mode` switch) — this core has
  no equivalent built-in option to key off. VGA-scandoubled output only.

## 7. Video

`target_top` already drives real, non-dead `video_hs`/`video_vs` and
4-bit/channel RGB (`VGA_R/G/B(3:0)`) — **no exposure/fix patch needed**,
unlike `vhdl_congo_bongo`/`Arcade_Zaxxon`'s dead-port defect class.

Scan-doubled via the same MiST-ecosystem scandoubler already imported and
Vivado-2020.2-patched for `vhdl_congo_bongo` (`contrib/code/scandoubler.v`
+ `scandoubler_fix.patch`, both **vendored locally** in this port's own
`contrib/code/` — re-derived with this port's own project-relative path
rather than reusing `vhdl_congo_bongo`'s patch file verbatim, since the
patch's target path is project-name-specific). Native 4-bit core color
zero-padded to the scandoubler's 6-bit input (`r & "00"`, the same
zero-pad style `vhdl_naughty_boy` uses, not MSB replication).
`clk_sys`=12 MHz, `ce_x1`=6 MHz-rate enable (both derived per §2), `ce_x2`
tied `'1'` (enabled every `clk_sys` edge, matching `vhdl_congo_bongo`'s
usage of the same scandoubler module).

## 8. Audio

`target_top.AUDIO` is **signed** 13-bit PCM (`signed(12 downto 0)`) — not
the unsigned PWM-ready accumulator input the Dar-convention cores expose.
Converted to unsigned offset-binary by inverting the sign bit
(`unsigned(not audio_signed(12) & audio_signed(11 downto 0))`, equivalent
to `signed_value + 2^12`), then fed into a PWM accumulator one bit wider
than `vhdl_naughty_boy`'s (14-bit accumulator for 13-bit audio, same
shape). `sw(14)`/`sw(15)` = AMP shutdown/gain, standard project convention
(not present in any pristine top for this core, added here).

## 9. Inputs

`JOY(7:0)`/`JOY2(7:0)` (confirmed by reading `target_top.vhd`'s own
internal mapping to `inputs_i.jamma_n.*`), active-high at this port
boundary: bit7=coin, bit6=start, bit5=button2/jump, bit4=button1/fire,
bit3=up, bit2=down, bit1=left, bit0=right. `JOY2` is tied to the same
signals as `JOY` in this port (no genuine second control set), matching
every sibling port's convention.

### Keyboard (USB-HID on Basys3 = PS/2 protocol; added per the user)

The Basys3's onboard USB-HID connector presents PS/2 on `ps2_clk` (C17) /
`ps2_dat` (B17). This core has no scancode decoder of its own, so the
repo-standard chain is vendored unmodified into the wrapper:

- `io_ps2_keyboard.vhd` (FPGA64, © P. Wendrich) — bit-bangs the PS/2 stream
  into `interrupt`+8-bit `scancode`.
- `kbd_joystick.vhd` (MiST project) — maps scancodes to its own convenience
  vector `joy_BBBBFRLDU(8 downto 0)`.

Both are byte-copies of the same files already vendored for the DigDug/DKJr
ports (identical md5), are clocked from `clk12` (12 MHz — comfortably above
the ≥6 MHz floor the USB-HID keyboard requires), and their only risk is the
busy-wait PS/2 receiver, which at 12 MHz has ample headroom before the
bit time enters the ±1/4-bit jitter margin.

`kbd_joystick`'s bit order differs from this core's `JOY`, so instead of a
drop-in tie the wrapper inserts a remap (`joy_kbd`), then OR-merges it with
the JA/button vector — keyboard and joystick work simultaneously:

| `kbd_joy` | remap | `JOY` bit | key |
|---|---|---|---|
| bit0 (up) | `joy_kbd(3)` | bit3 up, **bit5 jump** | ↑ |
| bit1 (down) | `joy_kbd(2)` | bit2 down | ↓ |
| bit2 (left) | `joy_kbd(1)` | bit1 left | ← |
| bit3 (right) | `joy_kbd(0)` | bit0 right | → |
| bit4 (fire) | `joy_kbd(4)` | bit4 fire | L-Ctrl |
| bit5 (1P start) | `joy_kbd(5)` | bit6 start | 1 |
| bit7 (coin) | `joy_kbd(7)` | bit7 coin | 5 |

Jump follows the same user direction as the JA path: keyboard Up asserts
both bit3 and bit5 together.

This game has **two action buttons** (fire and jump) — unlike the
single-fire Dar-convention games. Original plan: give jump a dedicated
`btnR`. **Changed per the user's direction**: jump (bit5) is instead wired
from `JA(3)` — the same pin that drives "up" (bit3) — so pushing the
joystick up asserts both simultaneously; no dedicated jump button. `btnR`
is consequently unused and was removed from the entity/XDC (commented out
in `Basys-3-Master.xdc`, matching the existing `btnD`-unused pattern),
per the constrained-ports rule (only declare ports the shared XDC actually
constrains). Final plan: JA(0..4) = right/left/down/up/fire (same physical
pin convention as every sibling port, active-low→invert; up also drives
jump), `btnU` = coin, `btnL` = start. No `btnD` declared either (single
coin/start, no second — same shape as `Arcade_Zaxxon`, not
`vhdl_congo_bongo`'s dual-coin case).

## 10. Directory / script layout (in-place, per §0)

- `contrib/code/` — `dpram_xilinx_bram.patch` (fix, applied at `setup`),
  `scandoubler.v` (vendored MiST import, never modified in place) +
  `scandoubler_fix.patch` (applied later by `create_project.sh` to the
  copy inside `basys3/`, not to this pristine import).
- `contrib/tools/` — `setup_moonpatrol.sh` (no archive fetch, no submodule
  init, see §0), `prep_roms.sh`.
- `contrib/basys3/vivado/` — `moonpatrol_basys3.xpr`, `Basys-3-Master.xdc`,
  `make_clk_wiz_0.sh`.
- `contrib/basys3/tools/` — `make_moonpatrol_basys3_top.sh` (authors the
  original top level — no diff/patch generated, unlike the Dar-convention
  `make_de10_lite_to_basys3_patch.sh` pattern, since there's no pristine
  top to diff against), `make_moonpatrol_basys3_bitstream.sh`.
- `tools/tools_prom_src/` — copy of the shared `make_vhdl_prom.c` tool
  (from `vhdl_congo_bongo/tools/tools_prom_src/`), compiled at `setup` time.
- `tools/roms/` (gitignored) — unzipped romset, concatenated
  `moonpatrol.bin` blob, generated `prom_moonpatrol.vhd`.
- **`Makefile.basys3` at repo root, NOT `Makefile`**: the root `Makefile` is
  pristine upstream content (the DeMiSTify framework's own build driver —
  `DEMISTIFYPATH`/`PROJECT`/`BOARD` variables, `mist`/`mister`
  `quartus_sh`-invoking targets, submodule-init prerequisites). An early
  version of this port overwrote it by mistake (caught before commit,
  restored via `git checkout`) — the Basys3 build driver is named
  `Makefile.basys3` instead (`all / setup / create_prj / clk_wiz / patch /
  synth / bitstream / clean`, cloned from the `vhdl_congo_bongo`/
  `vhdl_naughty_boy` structure), invoked as `make -f Makefile.basys3
  <target>`.
- `README.md` at repo root (new — the pristine upstream `README.txt`,
  MiSTer-specific, is left untouched).
- **Non-nested project layout**: `.xpr` directly at
  `basys3/moonpatrol_basys3.xpr`, sources at
  `basys3/moonpatrol_basys3.srcs/`.

Not a root-`Makefile` (`sf-darfpga/Makefile`) delegation target — this port
lives outside `sf-darfpga/`, so no root shorthand applies; build from
inside `MoonPatrol_DeMiSTified/` directly (`make -f Makefile.basys3
<step>`).

## 11. Shared conventions & hard rules (carried over)

- **Vivado build scripts run from `/tmp`** so `vivado.log`/`vivado.jou` stay
  out of the repo. Never run `make synth`/`make bitstream` unless the user
  explicitly asks for a synthesis/bitstream build in that message.
- **Tool/path resolution**: `ENV_VAR → project default → interactive
  prompt`. Vivado: `VIVADO` → `/tools/Xilinx/Vivado/2020.2/bin/vivado`.
  Roms: `ROMZIP` → `~/roms/mpatrol.zip`.
- **Roms and generated PROM VHDL are copyrighted content** — never commit
  or distribute them.
- **Mixed licensing, new consideration for this port**: unlike the
  Dar-convention cores, this core carries copyleft framework code (GPLv2,
  "Port to MiSTer, Copyright (C) 2017 Sorgelig"; GPLv3, `rtl/hiscore.v` —
  not instantiated by this port, see §6) alongside the familiar
  "educational use only / do not redistribute" header on
  `rtl/moon_patrol_sound_board.vhd`. Not resolved further here — flagged
  for the user's awareness before any distribution decision beyond local
  synthesis.
- Two `make synth` attempts (both run outside this session) each found and
  this port fixed one synthesis-failing defect in turn:
  `dpram_direct_entity_instantiation.patch` (`dpram is not a component`)
  then `platform_vblank_count_high.patch` (`prefix of attribute high is
  not a type mark`) — see §3 for both. `make synth` now passes. A
  subsequent `make bitstream` attempt (also run outside this session)
  found a project source-list omission, not an RTL defect: `T80se.vhd`
  (required by `Z80.vhd`, wrongly believed unused, see §1/§3) was missing
  from `moonpatrol_basys3.xpr` — fixed by adding it, no patch needed. Not
  yet re-verified with another `make bitstream` run. Further
  synthesis/implementation issues remain possible — this port introduces
  genuinely new RTL (the `dpram.vhd` rewrite, the ROM-playback state
  machine), not just a rewired top level, and each attempt so far has
  surfaced exactly one new issue once the prior one was fixed.

## 12. Next steps

1. ~~Scaffold `contrib/{code,tools,basys3/{tools,vivado}}/`,
   `tools/tools_prom_src/`, `Makefile.basys3`, `README.md`, `.gitignore` per §10.~~
   Done.
2. ~~Author and verify `contrib/code/dpram_xilinx_bram.patch` (applies
   cleanly, reverse dry-run correctly detects "not yet applied").~~ Done.
3. ~~Run `make setup` (`ROMZIP` default `~/roms/mpatrol.zip`) and confirm
   the 48 KB PROM VHDL generates.~~ Done — verified clean, correct entity
   name and address width (16 bits, `0 to 49151`).
4. ~~`make create_prj clk_wiz patch` — read-only Vivado smoke test (open
   project, confirm all `get_files` resolve, no runs launched).~~ Done —
   `make create_prj clk_wiz patch` ran cleanly end to end (`clk_wiz`
   required the CLKOUT3 frequency fix above, found via a real IP
   customization failure, not anticipated in the original plan); a
   read-only Vivado smoke test confirmed 44/44 files resolve (0 missing)
   and the top entity resolves to `moonpatrol_basys3` (later 45/45 once
   `T80se.vhd` was added, see item 7).
5. ~~`make synth` (run outside this session) — first real signal on whether
   the hand-rewritten `dpram.vhd`, the ROM-playback state machine, or any
   PACE-framework file hits a Xilinx-specific synthesis issue.~~ Found one:
   RTL elaboration failed, `dpram is not a component`
   (`moon_patrol_sound_board.vhd:366,380`) — fixed, see §3's
   `dpram_direct_entity_instantiation.patch`.
6. ~~`make synth` again (run outside this session), to confirm the
   direct-entity-instantiation fix clears elaboration.~~ Got further, found
   a second defect: `prefix of attribute high is not a type mark`
   (`platform.vhd:389,395`, a scalar variable's invalid `'high` use) —
   fixed, see §3's `platform_vblank_count_high.patch`. Re-staged (`setup
   create_prj clk_wiz patch`) cleanly with all three fix patches applied,
   applying in the correct sequence (verified via a fresh `git checkout` +
   `make setup`, and confirmed idempotent on a second run).
7. ~~`make synth` a third time (run outside this session).~~ Passed. Then
   `make bitstream` (also run outside this session) reached `opt_design`
   and failed DRC (`INBB-3` black box, `T80se` undefined) — fixed by adding
   the missing `T80se.vhd` to `moonpatrol_basys3.xpr` (§3); re-verified
   with a read-only Vivado smoke test (45/45 files resolve).
8. ~~`make bitstream` again, then hardware bring-up (run outside this
   session).~~ Bitstream built and flashed. ROM-playback FSM, video
   pipeline (scandoubler), and audio path are evidently working — a
   recognizable, if garbled, image and the ROM/RAM test screen both
   rendered, meaning the CPU is executing real code and the graphics/sound
   RTL chain is live end to end. Found: video cycled between garbled tiles
   and the ROM/RAM test screen every few seconds, and pressing JA(4)
   (fire) also triggered the test screen — root-caused to `switches_i`'s
   all-zero default permanently asserting Test Mode (bit 15, active-low);
   the JA(4) correlation is most likely the test-mode screen's own
   button-driven advance/exit behavior reacting to fire while test mode
   was already stuck on, not a separate input-wiring bug (`target_top`'s
   `test`/`service` JAMMA lines are hardcoded constants in `target_top.vhd`,
   never connected to `JOY`/`JA` in this wrapper — not independently
   confirmed against the game's own test-mode input handling, since no
   source in this tree documents which button advances that menu).
   Fixed switches_i's default (§6); re-verified with a read-only Vivado
   smoke test (45/45 files resolve) but not yet re-flashed to hardware.
9. **Not yet done** (requires explicit user request, needs actual
   hardware): re-flash with the `switches_i` fix and confirm Test Mode no
   longer asserts and normal gameplay/attract-mode renders correctly.
