-- tb_pulse_cdc.vhd
--
-- Self-checking testbench for the toggle-based pulse crossing.
--
-- HONESTY UP FRONT: this testbench proves FUNCTIONAL behavior only — that
-- N pulses sent in the source domain arrive as N single-cycle pulses in the
-- destination domain. It does NOT and CANNOT prove metastability safety.
-- GHDL's flip-flops are ideal digital objects: they never hover between
-- states, so a broken CDC (a raw wire across domains, a synchronized bus)
-- simulates perfectly and fails on the bench once an hour. Safety comes
-- from the STRUCTURE of sync_2ff and the toggle scheme, not from this test
-- passing. That is the whole lesson of this module.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_pulse_cdc is
end entity tb_pulse_cdc;

architecture sim of tb_pulse_cdc is

  -- Two UNRELATED clock periods, deliberately chosen with a non-integer
  -- ratio (10/7). With an integer ratio the two clocks would keep a fixed
  -- phase relationship forever and the test would only ever exercise one
  -- alignment; 10:7 makes the relative phase drift every cycle, sweeping
  -- the toggle edge across the destination clock edge — the closest a
  -- digital simulator can get to "asynchronous".
  constant clk_src_period : time := 10 ns;  -- e.g. a 100 MHz DAQ clock
  constant clk_dst_period : time := 7 ns;   -- e.g. a ~143 MHz link clock

  constant num_pulses : natural := 5;

  signal clk_src, clk_dst   : std_logic := '0';
  signal rst_src, rst_dst   : std_logic := '1';
  signal pulse_in, pulse_out : std_logic := '0';

  -- Count of single-cycle pulses seen in the destination domain.
  signal rx_count : natural := 0;

  -- When true, both clock processes stop toggling and the simulation ends
  -- cleanly (GHDL exits when no more events are scheduled).
  signal stop_sim : boolean := false;

begin

  dut : entity work.pulse_cdc
    port map (
      clk_src   => clk_src,
      rst_src   => rst_src,
      pulse_in  => pulse_in,
      clk_dst   => clk_dst,
      rst_dst   => rst_dst,
      pulse_out => pulse_out
    );

  -- Two independent clock generators — this testbench, unlike every other
  -- one in the course, contains TWO simulated universes ticking at
  -- unrelated rates. Each loops until stop_sim, then halts, so the
  -- simulation terminates instead of running forever.
  gen_clk_src : process
  begin
    while not stop_sim loop
      clk_src <= '0';  wait for clk_src_period / 2;
      clk_src <= '1';  wait for clk_src_period / 2;
    end loop;
    wait;
  end process gen_clk_src;

  gen_clk_dst : process
  begin
    while not stop_sim loop
      clk_dst <= '0';  wait for clk_dst_period / 2;
      clk_dst <= '1';  wait for clk_dst_period / 2;
    end loop;
    wait;
  end process gen_clk_dst;

  -- Each domain releases its own reset synchronously to its own clock —
  -- per-domain resets are part of the discipline this module teaches.
  reset_dst : process
  begin
    rst_dst <= '1';
    for i in 1 to 4 loop
      wait until rising_edge(clk_dst);
    end loop;
    rst_dst <= '0';
    wait;
  end process reset_dst;

  -- Stimulus lives entirely in the SOURCE domain: it releases rst_src,
  -- then fires num_pulses single-cycle pulses with generous spacing.
  stimulus : process
  begin
    rst_src <= '1';
    for i in 1 to 4 loop
      wait until rising_edge(clk_src);
    end loop;
    rst_src <= '0';

    for p in 1 to num_pulses loop
      -- One clean single-cycle pulse, aligned to clk_src.
      wait until rising_edge(clk_src);
      pulse_in <= '1';
      wait until rising_edge(clk_src);
      pulse_in <= '0';

      -- Spacing: 10 source cycles = 100 ns >> a few clk_dst periods (21 ns
      -- for the crossing itself). Respecting the pulse_cdc spacing rule is
      -- the USER's job; pulses closer than ~4 clk_dst periods would cancel
      -- in the toggle and silently disappear. (Try it: shrink this loop to
      -- 1 and watch the count assertion below fail.)
      for i in 1 to 9 loop
        wait until rising_edge(clk_src);
      end loop;
    end loop;

    -- Let the last toggle propagate through the synchronizer and edge
    -- detector before judging the count.
    wait for 20 * clk_dst_period;

    assert rx_count = num_pulses
      report "FAIL: sent " & integer'image(num_pulses) & " pulses, received "
             & integer'image(rx_count)
      severity failure;

    report "ALL TESTS PASSED";
    stop_sim <= true;  -- stops both clocks -> clean end of simulation
    wait;
  end process stimulus;

  -- Monitor lives entirely in the DESTINATION domain: it counts received
  -- pulses and checks each one is EXACTLY one clk_dst period wide (i.e.
  -- pulse_out is never high on two consecutive clk_dst edges). Width-1
  -- plus a correct total count is the full contract of pulse_cdc.
  monitor : process (clk_dst)
    variable prev : std_logic := '0';
  begin
    if rising_edge(clk_dst) then
      if pulse_out = '1' then
        assert prev = '0'
          report "FAIL: pulse_out wider than one clk_dst cycle"
          severity failure;
        rx_count <= rx_count + 1;
      end if;
      prev := pulse_out;
    end if;
  end process monitor;

end architecture sim;
