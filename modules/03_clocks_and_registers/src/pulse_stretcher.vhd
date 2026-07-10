-- pulse_stretcher.vhd
--
-- Stretch a narrow discriminated pulse to a programmable coincidence window.
--
-- Physics context: a discriminator output for a PMT pulse may be only one
-- clock cycle wide (10 ns at our 100 MHz), and two detectors never fire on
-- exactly the same cycle -- cable lengths, transit-time spread, and jitter
-- see to that. ANDing two 1-cycle pulses would miss almost every real
-- coincidence. So real trigger firmware first STRETCHES each pulse to a
-- defined window (say 4 cycles = 40 ns), and only then ANDs. This is the
-- gate-width knob on a NIM discriminator, reborn as a generic.
--
-- This file is your first piece of SEQUENTIAL (clocked) logic: it has to
-- REMEMBER that a pulse happened, for several cycles after the input has
-- gone away. Memory means flip-flops; flip-flops mean a clock.
--
library ieee;
use ieee.std_logic_1164.all;

entity pulse_stretcher is
  generic (
    -- How many clock cycles the output stays high per input pulse.
    -- A generic is a compile-time parameter (a C++ template argument):
    -- each instance can pick its own window width, fixed in silicon.
    STRETCH_CYCLES : natural := 4
  );
  port (
    clk       : in  std_logic;  -- 100 MHz system clock, rising edge
    rst       : in  std_logic;  -- active-high SYNCHRONOUS reset
    pulse_in  : in  std_logic;  -- narrow discriminated pulse (>= 1 cycle)
    pulse_out : out std_logic   -- stretched to STRETCH_CYCLES cycles
  );
end entity pulse_stretcher;

architecture rtl of pulse_stretcher is

  -- The design's entire memory: how many cycles of window remain.
  -- An integer with a constrained range synthesizes to just enough
  -- flip-flops to hold it (STRETCH_CYCLES = 4 needs 3 bits). For counters
  -- of a fixed bit width you'd use unsigned instead -- see
  -- deadtime_scaler.vhd; both styles are common and synthesizable.
  signal cycles_left : natural range 0 to STRETCH_CYCLES := 0;

begin

  -- THE clocked process. This exact shape is the idiom for all synchronous
  -- logic in this course -- learn it as a fixed template:
  --
  --   * sensitivity list is (clk) ONLY: nothing here happens except at a
  --     clock event. rst and pulse_in are merely SAMPLED at the edge, so
  --     they don't belong in the list.
  --   * rising_edge(clk) guards everything: the code inside describes what
  --     the flip-flops do at each rising edge -- and, by omission, that
  --     they HOLD their value the rest of the time. Holding = memory.
  --   * rst is checked INSIDE the edge (synchronous reset): reset is just
  --     another data input, obeyed at the next tick like everything else.
  --
  stretch : process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        cycles_left <= 0;               -- window closed
      else
        if pulse_in = '1' then
          -- A pulse (re)arms the full window. Checking pulse_in FIRST
          -- makes the stretcher RETRIGGERABLE: a second pulse arriving
          -- mid-window restarts the countdown instead of being lost --
          -- exactly what an updating discriminator gate does.
          cycles_left <= STRETCH_CYCLES;
        elsif cycles_left > 0 then
          cycles_left <= cycles_left - 1;  -- window ticking down
        end if;
        -- No final else: if the window is closed and no pulse arrives,
        -- no assignment happens, so cycles_left keeps its value (0).
        -- "Do nothing" in a clocked process means "hold" -- for free.
      end if;
    end if;
  end process stretch;

  -- The output is a combinational decode of the register: window open
  -- while any cycles remain. This gate lives OUTSIDE the process, so it
  -- tracks cycles_left continuously (concurrently), like in Module 01.
  pulse_out <= '1' when cycles_left > 0 else '0';

end architecture rtl;
