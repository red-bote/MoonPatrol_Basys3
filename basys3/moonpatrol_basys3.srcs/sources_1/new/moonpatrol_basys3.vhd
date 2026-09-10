---------------------------------------------------------------------------------
-- Basys3 Top level for Moon Patrol (Irem, 1982)
--
-- Original core: "Moon Patrol" port to MiSTer, Copyright (C) 2017 Sorgelig,
-- backported to the DeMiSTify framework by Alastair M. Robinson. Sound board
-- by Dar (darfpga@aol.fr). See ../../README.txt for full upstream attribution.
--
-- Basys3 port by Red~Bote.
--
-- This port bypasses the DeMiSTify build framework and its git submodules
-- entirely (no Xilinx/Vivado target exists anywhere in that framework -- see
-- contrib/basys3/PORTING_SPEC.md §0) and wraps rtl/target_top.vhd directly --
-- NOT Arcade-MoonPatrol.sv / moonpatrol_mist.sv, which are MiSTer/MiST board
-- glue replaced by this file.
--
-- Key design points (see PORTING_SPEC.md for the full derivation):
--  - Three genuine clock domains from one clk_wiz_0 MMCM (100 MHz in):
--    clock_30 (30 MHz, system/Z80), clk12 (12 MHz, doubles as the imported
--    MiST scandoubler's clk_sys), clock_3p58 (3.579545 MHz, sound board).
--    clock_v (6 MHz, target_top's video clock) and ce_x1 (the scandoubler's
--    6 MHz-rate enable) are both derived from clk12 by a single toggle
--    flip-flop -- a generated clock, not a clock-enable-gated version of
--    clk12; the same technique already used for keyboard-clock derivation
--    elsewhere in this repo (vhdl_congo_bongo's clock_div_kbd).
--  - ROM loading: target_top's dn_addr/dn_data/dn_wr download bus normally
--    carries a runtime SD-card/HPS stream; here it is driven once at power-on
--    by a small state machine that walks the single generated
--    tools/roms/prom_moonpatrol.vhd ROM (48 KB, address 0x0000..0xBFFF, the
--    exact byte order releases/Moon Patrol.mra's index-0 stream specifies)
--    while holding target_top's reset asserted, reproducing what the
--    framework's real downloader would have done. No patch to platform.vhd/
--    moon_patrol_sound_board.vhd was needed for this -- their existing
--    per-region chip-select decode on dn_addr already routes each byte
--    correctly. rtl/dpram.vhd itself IS patched (contrib/code/
--    dpram_xilinx_bram.patch): the pristine version wraps Altera's
--    altsyncram megafunction and will not synthesize under Vivado; the
--    replacement is a vendor-neutral true dual-port RAM with the same
--    generic/port interface.
--  - Video: target_top already outputs real, driven video_hs/video_vs and
--    4-bit/channel RGB (no dead-port fix needed, unlike vhdl_congo_bongo's
--    core). Native timing is a low-res arcade signal (~16 kHz line rate) --
--    scan-doubled via the same MiST-ecosystem scandoubler already imported
--    and Vivado-2020.2-patched for vhdl_congo_bongo (contrib/code/
--    scandoubler.v + scandoubler_fix.patch, reused here rather than
--    reimporting a fresh copy). No 15 kHz TV passthrough option in this
--    port (deliberate simplification -- this core has no built-in
--    tv15kHz_mode-style switch to key off, unlike the Dar-convention cores).
--  - Audio: target_top's AUDIO is a SIGNED 13-bit PCM sample (not the
--    unsigned PWM-ready accumulator input the Dar-convention cores use) --
--    converted to unsigned offset-binary (invert the sign bit) before
--    feeding a PWM accumulator, same accumulator shape as every other
--    Basys3 port in this repo. sw(14)/sw(15) = AMP shutdown/gain, standard
--    project convention.
--  - Controls: JA (movement + one fire button) OR is not used here -- unlike
--    the Dar-convention cores, this core has no PS/2 keyboard decoder and
--    none is added (confirmed with the user): JA only, plus dedicated
--    buttons for coin/start. This game has two action buttons -- fire and
--    jump -- but per the user's direction, jump is wired from JA's up
--    direction (JA4, the same pin that drives the "up" bit) instead of a
--    dedicated button. btnU = coin, btnL = start; no btnR (freed up --
--    jump no longer needs a dedicated button). JOY2 mirrors JOY (no
--    genuine second control set), matching every sibling port's convention.
--  - Dip switches (switches_i, 18 bits): tied to the "everything off"
--    default derived from moonpatrol_mist.sv's exact bit assignments (see
--    PORTING_SPEC.md §6) -- no physical switch mapping. An earlier version
--    of this port tied switches_i to all-zero based on the (incomplete)
--    observation that the MiSTer top never references switches_i; that
--    left bit 15 (Test Mode, active-low) permanently asserted, causing a
--    real hardware symptom (stuck showing the ROM/RAM test screen) --
--    caught during hardware bring-up and corrected here.
--  - Hiscore/NVRAM (hs_address/hs_data_in/out/hs_write) tied inactive
--    (confirmed with the user -- Basys3 has no persistent storage in the
--    base design). The same RAM instance serves as ordinary CPU work RAM
--    through its other port regardless, so this is a zero-risk drop.
--  - palmode tied to '0' (NTSC), hs_offset/vs_offset tied to "0000" (no
--    trim), pause tied to '0' -- reasonable defaults, no dedicated Basys3
--    IO for any of these.
--  - btnC = reset, held asserted (together with the ROM-load-in-progress
--    flag and !mmcm_locked) until the MMCM locks and the ROM finishes
--    loading.
---------------------------------------------------------------------------------
-- Educational use only. Do not redistribute synthesized output with ROMs.
-- Do not redistribute ROMs whatever the form. Use at your own risk.
---------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;

entity moonpatrol_basys3 is
port(
 clk             : in  std_logic;
 sw              : in  std_logic_vector(15 downto 0);
 btnC            : in  std_logic;  -- reset
 btnU            : in  std_logic;  -- coin
 btnL            : in  std_logic;  -- start

 JA              : in  std_logic_vector(4 downto 0);  -- joystick (movement + fire); up also drives jump

 O_PMODAMP2_AIN  : out std_logic;
 O_PMODAMP2_GAIN : out std_logic;
 O_PMODAMP2_SHUTD: out std_logic;

 vgaRed   : out std_logic_vector(3 downto 0);
 vgaGreen : out std_logic_vector(3 downto 0);
 vgaBlue  : out std_logic_vector(3 downto 0);
 vgaHsync : out std_logic;
 vgaVsync : out std_logic
);
end moonpatrol_basys3;

architecture struct of moonpatrol_basys3 is

 component scandoubler
     port (
         clk_sys   : in  std_logic;
         scanlines : in  std_logic_vector (1 downto 0);
         ce_x1     : in  std_logic;
         ce_x2     : in  std_logic;
         hs_in     : in  std_logic;
         vs_in     : in  std_logic;
         r_in      : in  std_logic_vector (5 downto 0);
         g_in      : in  std_logic_vector (5 downto 0);
         b_in      : in  std_logic_vector (5 downto 0);
         hs_out    : out std_logic;
         vs_out    : out std_logic;
         r_out     : out std_logic_vector (5 downto 0);
         g_out     : out std_logic_vector (5 downto 0);
         b_out     : out std_logic_vector (5 downto 0)
     );
 end component;

 -- clk_wiz_0 outputs
 signal clock_30    : std_logic;
 signal clk12       : std_logic;  -- also the scandoubler's clk_sys
 signal clk_snd4x   : std_logic;  -- 14.31818 MHz, 4x the sound board clock
 signal mmcm_locked : std_logic;

 -- clock_v (6 MHz, target_top's video clock) and the scandoubler's ce_x1,
 -- both derived from clk12 by one toggle flip-flop (a generated clock, not
 -- a clock-enable) -- see header.
 signal clock_v : std_logic := '0';
 signal ce_x1   : std_logic := '0';

 -- clock_3p58 (3.579545 MHz, sound board): the 7-series MMCM cannot
 -- generate this directly (hard output floor ~4.687 MHz) -- derived from
 -- clk_snd4x (14.31818 MHz) by a 2-bit counter (divide-by-4).
 signal snd_div     : unsigned(1 downto 0) := (others => '0');
 signal clock_3p58  : std_logic := '0';

 signal reset : std_logic;

 -- ROM-playback state machine (see header)
 constant ROM_BYTES : integer := 49152; -- 0xC000, releases/Moon Patrol.mra index-0 stream
 signal rom_state    : integer range 0 to 2 := 0;
 signal rom_cnt      : unsigned(15 downto 0) := (others => '0');
 signal rom_prom_d   : std_logic_vector(7 downto 0);
 signal loading      : std_logic := '1';
 signal dn_addr_r    : std_logic_vector(15 downto 0) := (others => '0');
 signal dn_data_r    : std_logic_vector(7 downto 0)  := (others => '0');
 signal dn_wr_r      : std_logic := '0';

 -- target_top video/audio
 signal video_r, video_g, video_b : std_logic_vector(3 downto 0);
 signal video_hs, video_vs         : std_logic;
 signal audio_signed  : signed(12 downto 0);
 signal audio_unsigned : unsigned(12 downto 0);

 signal sd_r_in, sd_g_in, sd_b_in    : std_logic_vector(5 downto 0);
 signal sd_r_out, sd_g_out, sd_b_out : std_logic_vector(5 downto 0);
 signal sd_hs_out, sd_vs_out         : std_logic;

 signal JOY  : std_logic_vector(7 downto 0);

 signal pwm_accumulator : std_logic_vector(13 downto 0);

begin

 -- btnC is active-high: it resets the MMCM and, together with !locked and
 -- the ROM-load-in-progress flag, holds the core in reset.
 reset <= btnC or not mmcm_locked or loading;

 clocks : entity work.clk_wiz_0
 port map(
  clk_in1  => clk,
  clk_out1 => clock_30,
  clk_out2 => clk12,
  clk_out3 => clk_snd4x,
  reset    => btnC,
  locked   => mmcm_locked
 );

 -- clock_v (6 MHz) / ce_x1: one toggle flip-flop off clk12 (12 MHz).
 process(clk12)
 begin
   if rising_edge(clk12) then
     clock_v <= not clock_v;
     ce_x1   <= not clock_v;
   end if;
 end process;

 -- clock_3p58 (3.579545 MHz): divide-by-4 off clk_snd4x (14.31818 MHz), the
 -- top bit of a free-running 2-bit counter -- an exact /4, 50% duty cycle --
 -- see the signal declaration comment above.
 process(clk_snd4x)
 begin
   if rising_edge(clk_snd4x) then
     snd_div <= snd_div + 1;
   end if;
 end process;
 clock_3p58 <= snd_div(1);

 ---------------------------------------------------------------------------
 -- ROM-playback state machine: walk prom_moonpatrol's full 48 KB range once,
 -- driving dn_addr/dn_data/dn_wr into target_top exactly as a real
 -- SD-card/HPS downloader would, while target_top's reset is held asserted.
 ---------------------------------------------------------------------------
 prom_inst : entity work.prom_moonpatrol
 port map(
   clk  => clock_30,
   addr => std_logic_vector(rom_cnt),
   data => rom_prom_d
 );

 process(clock_30)
 begin
   if rising_edge(clock_30) then
     if mmcm_locked = '0' then
       rom_state <= 0;
       rom_cnt   <= (others => '0');
       loading   <= '1';
       dn_wr_r   <= '0';
     else
       case rom_state is
         when 0 =>
           -- rom_cnt already presented to prom_inst; wait one cycle for
           -- its registered output to become valid.
           dn_wr_r   <= '0';
           rom_state <= 1;
         when 1 =>
           -- rom_prom_d now holds the byte at address rom_cnt.
           dn_addr_r <= std_logic_vector(rom_cnt);
           dn_data_r <= rom_prom_d;
           dn_wr_r   <= '1';
           if rom_cnt = to_unsigned(ROM_BYTES - 1, 16) then
             rom_state <= 2;
           else
             rom_cnt   <= rom_cnt + 1;
             rom_state <= 0;
           end if;
         when others =>  -- 2: done, idle forever
           dn_wr_r <= '0';
           loading <= '0';
       end case;
     end if;
   end if;
 end process;

 ---------------------------------------------------------------------------
 -- Moon Patrol core
 ---------------------------------------------------------------------------
 target_inst : entity work.target_top
 port map(
   clock_30   => clock_30,
   clock_v    => clock_v,
   clock_3p58 => clock_3p58,
   reset      => reset,

   -- "Everything off" default, per moonpatrol_mist.sv's exact bit
   -- assignments (active-low OSD-status-derived bits default high when
   -- their status bit is 0; two nibbles are hardcoded fixed values there,
   -- not OSD-derived at all) -- see PORTING_SPEC.md §6:
   --   (17:16) unused/reserved -- default high like every other unused bit
   --   (15)    Test mode,       ~status[9]  default off -> '1'
   --   (14)    (unlabeled),     ~status[7]  default off -> '1'
   --   (13)    Sector select,   ~status[8]  default off -> '1'
   --   (12)    Freeze enable,   ~status[10] default off -> '1'
   --   (11:8)  fixed "1100" (moonpatrol_mist.sv:164), not OSD-derived
   --   (7:4)   fixed "1111" (moonpatrol_mist.sv:165), not OSD-derived
   --   (3:2)   New car,         ~status[6:5] default "00" -> "11"
   --   (1:0)   Patrol cars,     ~status[4:3] default "00" -> "11"
   switches_i => "11" & "1111" & "11" & "00" & "1111" & "11" & "11",

   dn_addr    => dn_addr_r,
   dn_data    => dn_data_r,
   dn_wr      => dn_wr_r,

   AUDIO      => audio_signed,
   JOY        => JOY,
   JOY2       => JOY,  -- no genuine second control set, mirror P1

   VGA_VBLANK => open,
   VGA_HBLANK => open,
   VGA_VS     => video_vs,
   VGA_HS     => video_hs,
   VGA_R      => video_r,
   VGA_G      => video_g,
   VGA_B      => video_b,

   palmode    => '0',              -- NTSC
   hs_offset  => "0000",
   vs_offset  => "0000",

   pause      => '0',

   -- hiscore: confirmed dropped (no persistent storage on Basys3)
   hs_address  => (others => '0'),
   hs_data_out => open,
   hs_data_in  => (others => '0'),
   hs_write    => '0'
 );

 -- JA (active-low, invert to active-high) + dedicated buttons -> JOY(7:0):
 -- bit7=coin, bit6=start, bit5=jump(button2), bit4=fire(button1),
 -- bit3=up, bit2=down, bit1=left, bit0=right (target_top.vhd's own mapping).
 -- JA physical map: JA1=right, JA2=left, JA3=down, JA4=up, JA7=fire, i.e.
 -- JA(0)=right, JA(1)=left, JA(2)=down, JA(3)=up, JA(4)=fire -- same pin
 -- convention as every other machine in this repo.
 -- Per the user's direction, jump (bit5) is driven from JA's up direction
 -- (JA(3)) rather than a dedicated button -- the same physical press now
 -- asserts both "up" (bit3) and "jump" (bit5) simultaneously.
 JOY(0) <= not JA(0);  -- right
 JOY(1) <= not JA(1);  -- left
 JOY(2) <= not JA(2);  -- down
 JOY(3) <= not JA(3);  -- up
 JOY(4) <= not JA(4);  -- fire (button 1)
 JOY(5) <= not JA(3);  -- jump (button 2) -- same pin as up
 JOY(6) <= btnL;       -- start
 JOY(7) <= btnU;       -- coin

 ---------------------------------------------------------------------------
 -- Video: scan-double target_top's native ~16 kHz RGB into 31 kHz VGA.
 ---------------------------------------------------------------------------
 sd_r_in <= video_r & "00";
 sd_g_in <= video_g & "00";
 sd_b_in <= video_b & "00";

 scandoubler_inst : scandoubler
 port map(
   clk_sys   => clk12,
   scanlines => "00",
   ce_x1     => ce_x1,
   ce_x2     => '1',
   hs_in     => video_hs,
   vs_in     => video_vs,
   r_in      => sd_r_in,
   g_in      => sd_g_in,
   b_in      => sd_b_in,
   hs_out    => sd_hs_out,
   vs_out    => sd_vs_out,
   r_out     => sd_r_out,
   g_out     => sd_g_out,
   b_out     => sd_b_out
 );

 vgaHsync <= sd_hs_out;
 vgaVsync <= sd_vs_out;
 vgaRed   <= sd_r_out(5 downto 2);
 vgaGreen <= sd_g_out(5 downto 2);
 vgaBlue  <= sd_b_out(5 downto 2);

 ---------------------------------------------------------------------------
 -- Audio: signed 13-bit PCM -> offset-binary unsigned -> PWM accumulator
 -- (same accumulator shape as every other Basys3 port in this repo).
 ---------------------------------------------------------------------------
 audio_unsigned <= unsigned(not audio_signed(12) & std_logic_vector(audio_signed(11 downto 0)));

 process(clock_30)
 begin
   if rising_edge(clock_30) then
     pwm_accumulator <= std_logic_vector(unsigned('0' & pwm_accumulator(12 downto 0)) + unsigned(std_logic_vector(audio_unsigned) & '0'));
   end if;
 end process;

 O_PMODAMP2_AIN   <= pwm_accumulator(13);
 O_PMODAMP2_SHUTD <= sw(14);  -- shutdown: 0 = off, 1 = on
 O_PMODAMP2_GAIN  <= sw(15);  -- gain: 0 = 12 dB, 1 = 6 dB

end struct;
