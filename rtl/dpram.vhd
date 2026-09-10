LIBRARY ieee;
USE ieee.std_logic_1164.all;
USE ieee.numeric_std.all;

-- Basys3 port: rewritten as a vendor-neutral true dual-port RAM (two
-- independent clocks, one cycle read latency, new-data read-during-write on
-- each port) inferring Xilinx block RAM under Vivado. The original wraps
-- Altera's altsyncram megafunction (BIDIR_DUAL_PORT, Cyclone V) and will not
-- synthesize on non-Altera targets. Generic/port names are unchanged so no
-- caller (platform.vhd, moon_patrol_sound_board.vhd) needs to change.
-- See contrib/basys3/PORTING_SPEC.md.

entity dpram is
	generic (
		 addr_width_g : integer := 8;
		 data_width_g : integer := 8
	);
	PORT
	(
		address_a	: IN STD_LOGIC_VECTOR (addr_width_g-1 DOWNTO 0);
		address_b	: IN STD_LOGIC_VECTOR (addr_width_g-1 DOWNTO 0) := (others => '0');
		clock_a		: IN STD_LOGIC  := '1';
		clock_b		: IN STD_LOGIC  := '1';
		data_a		: IN STD_LOGIC_VECTOR (data_width_g-1 DOWNTO 0);
		data_b		: IN STD_LOGIC_VECTOR (data_width_g-1 DOWNTO 0) := (others => '0');
		enable_a		: IN STD_LOGIC  := '1';
		enable_b		: IN STD_LOGIC  := '1';
		wren_a		: IN STD_LOGIC  := '0';
		wren_b		: IN STD_LOGIC  := '0';
		q_a			: OUT STD_LOGIC_VECTOR (data_width_g-1 DOWNTO 0);
		q_b			: OUT STD_LOGIC_VECTOR (data_width_g-1 DOWNTO 0)
	);
END dpram;


ARCHITECTURE SYN OF dpram IS

	type ram_t is array(0 to 2**addr_width_g-1) of std_logic_vector(data_width_g-1 downto 0);
	shared variable ram : ram_t := (others => (others => '0'));

BEGIN

	-- Port A: registered address/data, new-data read-during-write (matches
	-- the original's read_during_write_mode_port_a => NEW_DATA_NO_NBE_READ).
	process(clock_a)
	begin
		if rising_edge(clock_a) then
			if enable_a = '1' then
				if wren_a = '1' then
					ram(to_integer(unsigned(address_a))) := data_a;
				end if;
				q_a <= ram(to_integer(unsigned(address_a)));
			end if;
		end if;
	end process;

	-- Port B: same, independent clock.
	process(clock_b)
	begin
		if rising_edge(clock_b) then
			if enable_b = '1' then
				if wren_b = '1' then
					ram(to_integer(unsigned(address_b))) := data_b;
				end if;
				q_b <= ram(to_integer(unsigned(address_b)));
			end if;
		end if;
	end process;

END SYN;
