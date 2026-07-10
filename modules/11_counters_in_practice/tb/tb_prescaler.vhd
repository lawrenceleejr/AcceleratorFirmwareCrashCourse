-- tb_prescaler.vhd
--
-- Self-checking testbench for the trigger prescaler.
--
-- Plan (PRESCALE = 4): send 12 input pulses with a mix of spacings --
-- some isolated, some in back-to-back bursts on consecutive cycles --
-- and check that
--   * exactly 3 output pulses appear, on input pulses 4, 8 and 12;
--   * every output pulse is exactly ONE cycle wide;
--   * nothing fires on any other pulse or in any gap;
--   * a mid-count reset restarts the phase: after reset it must take a
--     FULL 4 fresh pulses to fire again.
--
-- Testbench scaffolding is Module 03's: clock generator with a
-- 'finished' stop flag, inputs driven just after an edge, outputs
-- checked 1 ns after an edge.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_prescaler is
end entity tb_prescaler;

architecture sim of tb_prescaler is

  constant PRESCALE : natural := 4;

  signal clk       : std_logic := '0';
  signal rst       : std_logic := '1';   -- start in reset
  signal pulse_in  : std_logic := '0';
  signal pulse_out : std_logic;

  signal finished : boolean := false;

  -- Idle cycles inserted BEFORE each of the 12 pulses. A 0 means the
  -- pulse rides on the very next cycle after the previous one -- a
  -- back-to-back burst. Bursts of 2-4 pulses and isolated pulses are
  -- both represented, and the firing ordinals (4, 8, 12) land both
  -- isolated (pulse 4) and inside bursts (pulses 8 and 12).
  type gap_array is array (1 to 12) of natural;
  constant GAP_BEFORE : gap_array := (2, 0, 0, 1, 3, 0, 0, 0, 2, 1, 0, 0);

begin

  dut : entity work.prescaler
    generic map (
      PRESCALE => PRESCALE
    )
    port map (
      clk       => clk,
      rst       => rst,
      pulse_in  => pulse_in,
      pulse_out => pulse_out
    );

  -- 100 MHz clock, stoppable so the simulation terminates (Module 03).
  clock_gen : process
  begin
    while not finished loop
      clk <= '0';
      wait for 5 ns;
      clk <= '1';
      wait for 5 ns;
    end loop;
    wait;
  end process clock_gen;

  stimulus : process
    variable outputs_seen : natural := 0;   -- count the fires, tallied at the end
  begin
    ---------------------------------------------------------------------
    -- Reset: hold rst for two edges, then release.
    ---------------------------------------------------------------------
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst <= '0';
    wait for 1 ns;
    assert pulse_out = '0'
      report "FAIL: pulse_out not low after reset" severity failure;

    ---------------------------------------------------------------------
    -- Test 1: 12 pulses, mixed spacing. Because pulse_out is registered,
    -- it goes high AT the edge that samples the firing pulse and must be
    -- low again one edge later -- the gap checks below therefore also
    -- verify the 1-cycle width, and the burst checks verify it when the
    -- next pulse follows immediately.
    ---------------------------------------------------------------------
    for i in 1 to 12 loop

      -- Idle cycles before pulse i: output must be low the whole time.
      -- (For the cycle right after a fire, this IS the width check.)
      for g in 1 to GAP_BEFORE(i) loop
        pulse_in <= '0';
        wait until rising_edge(clk);
        wait for 1 ns;
        assert pulse_out = '0'
          report "FAIL: output high in the gap before pulse " & integer'image(i)
          severity failure;
      end loop;

      -- Pulse i itself. Note pulse_in is only ever set to '0' inside the
      -- gap loop, so with GAP_BEFORE = 0 it simply STAYS high across
      -- consecutive edges: genuine back-to-back pulses.
      pulse_in <= '1';
      wait until rising_edge(clk);   -- DUT samples pulse i at this edge
      wait for 1 ns;

      if i mod PRESCALE = 0 then
        assert pulse_out = '1'
          report "FAIL: no output on pulse " & integer'image(i)
                 & " (expected every " & integer'image(PRESCALE) & "th)"
          severity failure;
        outputs_seen := outputs_seen + 1;
      else
        assert pulse_out = '0'
          report "FAIL: spurious output on pulse " & integer'image(i)
          severity failure;
      end if;

    end loop;

    -- Drain cycle: pulse 12 fired on the last edge, so one edge later
    -- the output must already be back low -- 1-cycle width at the very
    -- end of a burst.
    pulse_in <= '0';
    wait until rising_edge(clk);
    wait for 1 ns;
    assert pulse_out = '0'
      report "FAIL: output pulse wider than one cycle" severity failure;

    assert outputs_seen = 3
      report "FAIL: expected 3 output pulses from 12 inputs, got "
             & integer'image(outputs_seen)
      severity failure;

    ---------------------------------------------------------------------
    -- Test 2: reset mid-count restarts the phase. Send 2 pulses (count
    -- now 2 of 4), reset, then check that pulses 1-3 after reset do NOT
    -- fire and the 4th does. If reset failed to clear the count, the
    -- 2nd post-reset pulse would fire and the assert catches it.
    ---------------------------------------------------------------------
    for i in 1 to 2 loop
      pulse_in <= '1';
      wait until rising_edge(clk);
      pulse_in <= '0';
      wait for 1 ns;
      assert pulse_out = '0'
        report "FAIL: fired during the mid-count preamble" severity failure;
      wait until rising_edge(clk);   -- one idle cycle between pulses
      wait for 1 ns;
    end loop;

    rst <= '1';
    wait until rising_edge(clk);     -- synchronous reset obeyed at this edge
    rst <= '0';
    wait for 1 ns;
    assert pulse_out = '0'
      report "FAIL: output high right after reset" severity failure;

    for i in 1 to PRESCALE loop
      pulse_in <= '1';
      wait until rising_edge(clk);
      pulse_in <= '0';
      wait for 1 ns;
      if i = PRESCALE then
        assert pulse_out = '1'
          report "FAIL: prescaler did not fire on the 4th pulse after reset"
          severity failure;
      else
        assert pulse_out = '0'
          report "FAIL: fired early after reset -- phase was not cleared"
          severity failure;
      end if;
      wait until rising_edge(clk);   -- idle cycle; also the width check
      wait for 1 ns;
      assert pulse_out = '0'
        report "FAIL: post-reset output wider than one cycle" severity failure;
    end loop;

    report "ALL TESTS PASSED";
    finished <= true;
    wait;
  end process stimulus;

end architecture sim;
