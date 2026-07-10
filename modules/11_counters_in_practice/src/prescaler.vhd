-- prescaler.vhd
--
-- Trigger prescaler: pass exactly 1 of every PRESCALE input pulses.
--
-- High-rate triggers (minimum-bias, single-paddle singles, a calibration
-- pulser) would drown the DAQ if every one were read out. The standard fix
-- is to prescale: count the input pulses and emit an output pulse only on
-- every PRESCALE-th one. The recorded sample is an unbiased 1/PRESCALE
-- slice of the original stream, and offline analysis multiplies measured
-- rates back up by PRESCALE.
--
-- That last sentence is why this counter is more than plumbing: the
-- prescale factor is a PHYSICS SYSTEMATIC. Real experiments write it into
-- the run database / event header alongside the data, because a rate
-- normalized with the wrong prescale is silently wrong by an integer
-- factor. When you change PRESCALE, you change the analysis.
--
-- Input contract (important!): pulse_in must be ONE-CYCLE pulses,
-- synchronous to clk -- the kind produced by Module 04's one-shot
-- discriminator. This process counts every cycle in which pulse_in = '1';
-- feed it a level that stays high for three cycles and it will dutifully
-- count three "pulses". Counting EVENTS when your input is a LEVEL needs
-- an edge detector (one-shot) in front -- the classic trap.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity prescaler is
  generic (
    -- Keep 1 of every PRESCALE pulses. PRESCALE = 1 passes everything.
    PRESCALE : natural := 8
  );
  port (
    clk       : in  std_logic;
    rst       : in  std_logic;
    pulse_in  : in  std_logic;   -- 1-cycle pulses, synchronous to clk
    pulse_out : out std_logic    -- 1-cycle pulse on every PRESCALE-th input
  );
end entity prescaler;

architecture rtl of prescaler is

  -- Counts input pulses 0 .. PRESCALE-1 and wraps. The constrained-integer
  -- style from Module 03: the synthesizer packs this into exactly
  -- ceil(log2(PRESCALE)) flip-flops. Note what we count: PULSES, not clock
  -- cycles -- the counter only moves when pulse_in is high.
  signal count : natural range 0 to PRESCALE - 1 := 0;

begin

  -- The Module 03 clocked-process template, verbatim. Counting is state:
  -- "how many pulses since the last output" must be remembered across
  -- cycles, so it lives in registers.
  count_pulses : process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        count     <= 0;
        pulse_out <= '0';
      else
        -- Default assignment: pulse_out is low on any cycle where the
        -- code below doesn't override it. This "default first, override
        -- on condition" idiom is THE way to make a clean 1-cycle pulse:
        -- the override lasts one cycle, then the default reasserts.
        pulse_out <= '0';

        if pulse_in = '1' then
          if count = PRESCALE - 1 then
            -- This is the PRESCALE-th pulse: fire and wrap. Here the
            -- wraparound Module 06 warns about is not a bug, it is the
            -- entire mechanism -- the counter is a modulo-PRESCALE
            -- machine and the wrap IS the output event.
            count     <= 0;
            pulse_out <= '1';
          else
            count <= count + 1;
          end if;
        end if;
      end if;
    end if;
  end process count_pulses;

  -- Related pattern you'll meet everywhere (NOT built here): the
  -- divide-by-N CLOCK ENABLE. Same counter, but counting clk cycles
  -- instead of input pulses, its wrap producing a 1-cycle "tick" every N
  -- cycles. That tick gates slow logic (LED heartbeats, a 1 Hz status
  -- strobe) while everything stays on the one 100 MHz clock -- you enable
  -- slowly, you never clock slowly. Module 09's blinky was the lazy
  -- special case: divide by 2**k by tapping bit k of a free-running
  -- counter. This module's counter is the general divide-by-any-N.

end architecture rtl;
