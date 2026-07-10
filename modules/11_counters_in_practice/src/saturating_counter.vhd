-- saturating_counter.vhd
--
-- An error/status counter that refuses to lie.
--
-- Module 03's scalers wrap silently, like uint32_t: 255 + 1 = 0 for an
-- 8-bit counter, no exception, no flag. For a FREE-RUNNING bookkeeping
-- counter (timestamp, event number) that's fine -- even desirable --
-- because the consumer knows the width and unwraps it offline (rollover
-- correction: whenever the value goes DOWN, add 2**WIDTH). The capstone's
-- 16-bit event timestamp is exactly such a counter.
--
-- But picture an 8-bit CRC-error counter on a serial link, read out once
-- a spill. It reads 3. Three errors? Or 259? Or 515? A wrapped diagnostic
-- counter is worse than no counter: it reports a small number precisely
-- when the situation is worst. The fix is to SATURATE: stick at the
-- maximum instead of wrapping. A counter pegged at 255 says unambiguously
-- "at least 255 -- investigate", which is the only honest thing a
-- too-narrow counter can say.
--
-- Rule of thumb: monotonic bookkeeping wraps; alarm/diagnostic counters
-- saturate.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity saturating_counter is
  generic (
    WIDTH : natural := 8   -- counter width; saturates at 2**WIDTH - 1
  );
  port (
    clk       : in  std_logic;
    rst       : in  std_logic;
    inc       : in  std_logic;                       -- count this cycle's event
    count     : out unsigned(WIDTH - 1 downto 0);    -- current count, pegged at max
    saturated : out std_logic                        -- '1' = count is a lower bound
  );
end entity saturating_counter;

architecture rtl of saturating_counter is

  -- All-ones = the maximum value, written width-generically. The same
  -- (others => '1') aggregate works for WIDTH = 4 or WIDTH = 64.
  constant MAX_COUNT : unsigned(WIDTH - 1 downto 0) := (others => '1');

begin

  -- The Module 03 counting idiom with ONE extra condition: stop at max.
  -- The entire difference between a counter that lies and one that
  -- doesn't is the "and count /= MAX_COUNT" guard.
  count_events : process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        count <= (others => '0');
      else
        if inc = '1' and count /= MAX_COUNT then
          count <= count + 1;
        end if;
        -- No else: once at MAX_COUNT the counter simply stops moving
        -- (an unassigned signal holds -- Module 03). Only rst unpegs it,
        -- typically at start of run, after the shifter has investigated.
      end if;
    end if;
  end process count_events;

  -- The flag is a combinational decode of the register, exactly like the
  -- pulse stretcher's output in Module 03: registers plus gates. Software
  -- polls `count`; the flag can also drive an LED or a status register
  -- bit so a pegged counter is visible without a readout cycle.
  --
  -- The `and` here is VHDL-2008's UNARY REDUCTION operator: applied to a
  -- whole vector, it ANDs all the bits together -- '1' exactly when every
  -- bit is '1', i.e. count = MAX_COUNT. It reads like a trick but it is
  -- the most literal line in the file: an all-ones detector IS a
  -- WIDTH-input AND gate, and that's precisely what gets synthesized.
  saturated <= and count;

  -- Software note: in C++, signed overflow is undefined behaviour you
  -- hope never happens, and unsigned wrap is legal but silent. In
  -- hardware, wrap-vs-saturate is a DESIGN DECISION you make per counter,
  -- costing one comparator either way. Nothing is undefined; everything
  -- is exactly what you wrote.

end architecture rtl;
