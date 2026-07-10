-- tb_pulse_stretcher.vhd
--
-- Self-checking testbench for the pulse stretcher.
--
-- New in this testbench compared with Module 01: the design under test is
-- CLOCKED, so the testbench must (a) generate a clock, (b) line its
-- stimulus and checks up with clock edges, and (c) stop the clock at the
-- end -- otherwise the clock process runs forever and the simulation
-- never terminates.
--
library ieee;
use ieee.std_logic_1164.all;

entity tb_pulse_stretcher is
end entity tb_pulse_stretcher;

architecture sim of tb_pulse_stretcher is

  -- Window width used for this test. A constant here, wired to the DUT's
  -- generic below, so the checks and the DUT can't disagree.
  constant STRETCH_CYCLES : natural := 4;

  signal clk       : std_logic := '0';
  signal rst       : std_logic := '1';   -- start in reset
  signal pulse_in  : std_logic := '0';
  signal pulse_out : std_logic;

  -- When the stimulus process is done it sets this flag, the clock
  -- process stops toggling, no more events are scheduled, and GHDL exits.
  signal finished : boolean := false;

begin

  -- Instantiate the DUT; "generic map" is to generics what "port map"
  -- is to ports.
  dut : entity work.pulse_stretcher
    generic map (
      STRETCH_CYCLES => STRETCH_CYCLES
    )
    port map (
      clk       => clk,
      rst       => rst,
      pulse_in  => pulse_in,
      pulse_out => pulse_out
    );

  -- Clock generator: 100 MHz = 10 ns period. This process loops forever
  -- (a process restarts from the top when it falls off the end) until
  -- 'finished' goes true, then halts on the bare 'wait'.
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

  -- Stimulus and checking. Conventions used below:
  --   * inputs are changed just AFTER a rising edge, so they are stable
  --     well before the DUT samples them at the NEXT rising edge;
  --   * outputs are checked 1 ns after an edge, giving the DUT's
  --     flip-flops their delta cycles to settle (see the module text).
  stimulus : process
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
    -- Test 1: quiet input stays quiet. No pulses in, no window out.
    ---------------------------------------------------------------------
    for i in 1 to 5 loop
      wait until rising_edge(clk);
      wait for 1 ns;
      assert pulse_out = '0'
        report "FAIL: pulse_out went high with no input pulse" severity failure;
    end loop;

    ---------------------------------------------------------------------
    -- Test 2: a single 1-cycle pulse stretches to exactly STRETCH_CYCLES.
    ---------------------------------------------------------------------
    pulse_in <= '1';
    wait until rising_edge(clk);   -- DUT samples the pulse at this edge
    pulse_in <= '0';               -- input was high for exactly one cycle
    wait for 1 ns;

    -- The window must now be open for exactly STRETCH_CYCLES cycles...
    for i in 1 to STRETCH_CYCLES loop
      assert pulse_out = '1'
        report "FAIL: window closed early, cycle " & integer'image(i)
        severity failure;
      wait until rising_edge(clk);
      wait for 1 ns;
    end loop;

    -- ...and closed on the very next cycle. Exactly N, not N+1: a window
    -- that is one cycle too long changes your accidental-coincidence rate.
    assert pulse_out = '0'
      report "FAIL: window longer than STRETCH_CYCLES" severity failure;

    ---------------------------------------------------------------------
    -- Test 3: retrigger. A second pulse arriving MID-window must restart
    -- the countdown, extending the window instead of being swallowed.
    ---------------------------------------------------------------------
    pulse_in <= '1';
    wait until rising_edge(clk);   -- first pulse sampled; window := 4
    pulse_in <= '0';
    wait for 1 ns;
    assert pulse_out = '1'
      report "FAIL: window not open after first pulse" severity failure;

    wait until rising_edge(clk);   -- one cycle of countdown elapses
    pulse_in <= '1';
    wait until rising_edge(clk);   -- second pulse sampled; window := 4 again
    pulse_in <= '0';
    wait for 1 ns;

    -- From the retrigger, a FULL window must run again.
    for i in 1 to STRETCH_CYCLES loop
      assert pulse_out = '1'
        report "FAIL: retriggered window closed early, cycle " & integer'image(i)
        severity failure;
      wait until rising_edge(clk);
      wait for 1 ns;
    end loop;
    assert pulse_out = '0'
      report "FAIL: retriggered window did not close" severity failure;

    ---------------------------------------------------------------------
    -- Test 4: synchronous reset chops an open window at the next edge.
    ---------------------------------------------------------------------
    pulse_in <= '1';
    wait until rising_edge(clk);   -- open a window
    pulse_in <= '0';
    wait for 1 ns;
    assert pulse_out = '1'
      report "FAIL: window not open before reset test" severity failure;

    rst <= '1';
    wait until rising_edge(clk);   -- reset obeyed AT this edge (synchronous)
    rst <= '0';
    wait for 1 ns;
    assert pulse_out = '0'
      report "FAIL: reset did not close the window" severity failure;

    report "ALL TESTS PASSED";
    finished <= true;   -- stop the clock so the simulation can end
    wait;
  end process stimulus;

end architecture sim;
