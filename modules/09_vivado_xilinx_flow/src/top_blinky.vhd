-- top_blinky.vhd
--
-- The traditional first design to put on real hardware: a blinking LED.
-- Here dressed up as a "beam-gate heartbeat": a free-running counter divides
-- the 100 MHz board oscillator, and the top four counter bits drive the four
-- LEDs. The slowest LED blinks at 100 MHz / 2^27 = about 0.75 Hz -- a rate a
-- human can verify by eye, which is the entire point of a first design: it
-- proves the clock is reaching the fabric, the pins are the ones you think
-- they are, and the whole build flow works end to end.
--
-- Target board: Digilent Arty A7-35 (see constraints/arty_a7.xdc). Any
-- Xilinx board works if you adjust the pin constraints.
--
-- Note the button synchronizer: BTN0 is a mechanical button wired straight
-- to an FPGA pin. It is ASYNCHRONOUS to clk, so Module 08 applies in full --
-- it MUST pass through a two-flop synchronizer before any synchronous logic
-- is allowed to look at it. Even in a toy design, we do it properly.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity top_blinky is
  port (
    clk : in  std_logic;                     -- 100 MHz board oscillator (pin E3)
    btn : in  std_logic_vector(0 downto 0);  -- BTN0, active-high, ASYNC to clk
    led : out std_logic_vector(3 downto 0)   -- board LEDs LD4..LD7
  );
end entity top_blinky;

architecture rtl of top_blinky is

  -- Two-flop synchronizer for the button (Module 08). btn_meta may go
  -- metastable; rst, one flop later, is safe to use as a synchronous reset.
  signal btn_meta : std_logic := '0';
  signal rst      : std_logic := '0';

  -- Tell Vivado these are a synchronizer chain: keep the flops adjacent and
  -- exclude them from optimizations that would break the chain (Module 08).
  attribute async_reg : string;
  attribute async_reg of btn_meta : signal is "true";
  attribute async_reg of rst      : signal is "true";

  -- 27-bit free-running divider. At 100 MHz, bit 23 toggles at ~6 Hz and
  -- bit 26 at ~0.75 Hz -- the LEDs count in slow binary.
  signal count : unsigned(26 downto 0) := (others => '0');

begin

  -- Synchronize the asynchronous button into the clk domain.
  sync_button : process (clk)
  begin
    if rising_edge(clk) then
      btn_meta <= btn(0);   -- first flop: absorbs metastability
      rst      <= btn_meta; -- second flop: clean, synchronous
    end if;
  end process;

  -- The heartbeat itself: count forever; holding BTN0 freezes it at zero,
  -- so all four LEDs go dark -- your proof that the button path works too.
  heartbeat : process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        count <= (others => '0');
      else
        count <= count + 1;
      end if;
    end if;
  end process;

  -- Top four bits to the LEDs: led(0) is the fastest, led(3) the slowest.
  led <= std_logic_vector(count(26 downto 23));

end architecture rtl;
