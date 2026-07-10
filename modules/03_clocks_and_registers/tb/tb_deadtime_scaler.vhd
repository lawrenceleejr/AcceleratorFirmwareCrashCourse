-- tb_deadtime_scaler.vhd
--
-- Self-checking testbench for the dead-time scaler pair.
--
-- Strategy: drive a busy pattern whose cycle counts we know exactly, then
-- compare both scalers against pencil-and-paper arithmetic. Because the
-- DUT counts EVERY rising edge after reset, the testbench must account
-- for every edge too -- a good first taste of the cycle-exact bookkeeping
-- that firmware verification demands.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_deadtime_scaler is
end entity tb_deadtime_scaler;

architecture sim of tb_deadtime_scaler is

  signal clk  : std_logic := '0';
  signal rst  : std_logic := '1';   -- start in reset
  signal busy : std_logic := '0';

  signal total_count : unsigned(31 downto 0);
  signal busy_count  : unsigned(31 downto 0);

  -- Flag that stops the clock generator so the simulation terminates.
  signal finished : boolean := false;

begin

  dut : entity work.deadtime_scaler
    port map (
      clk         => clk,
      rst         => rst,
      busy        => busy,
      total_count => total_count,
      busy_count  => busy_count
    );

  -- 100 MHz clock, halted when 'finished' goes true.
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

  -- As in tb_pulse_stretcher: change inputs just after an edge, check
  -- outputs 1 ns after an edge. Note that "total_count = 7" compares an
  -- unsigned with an integer -- numeric_std defines that comparison, which
  -- is exactly why this course uses it and not the legacy libraries.
  stimulus : process
  begin
    ---------------------------------------------------------------------
    -- Reset for two edges ("run start"), then check both scalers are 0.
    ---------------------------------------------------------------------
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst <= '0';
    wait for 1 ns;
    assert total_count = 0
      report "FAIL: total_count not zero after reset" severity failure;
    assert busy_count = 0
      report "FAIL: busy_count not zero after reset" severity failure;

    ---------------------------------------------------------------------
    -- Known busy pattern: 4 live cycles, 3 busy cycles, 3 live cycles.
    -- Expected: total_count = 10, busy_count = 3, live fraction = 70%.
    ---------------------------------------------------------------------
    for i in 1 to 4 loop                 -- edges 1..4: live
      wait until rising_edge(clk);
    end loop;
    busy <= '1';                         -- readout goes busy

    for i in 1 to 3 loop                 -- edges 5..7: busy
      wait until rising_edge(clk);
    end loop;
    busy <= '0';                         -- readout live again
    wait for 1 ns;

    -- Mid-run spot check, 7 edges in.
    assert total_count = 7
      report "FAIL: total_count /= 7 after 7 edges, got "
             & integer'image(to_integer(total_count))
      severity failure;
    assert busy_count = 3
      report "FAIL: busy_count /= 3 after busy pattern, got "
             & integer'image(to_integer(busy_count))
      severity failure;

    for i in 1 to 3 loop                 -- edges 8..10: live
      wait until rising_edge(clk);
    end loop;
    wait for 1 ns;

    assert total_count = 10
      report "FAIL: total_count /= 10 at end of pattern, got "
             & integer'image(to_integer(total_count))
      severity failure;
    assert busy_count = 3
      report "FAIL: busy_count changed while not busy, got "
             & integer'image(to_integer(busy_count))
      severity failure;

    ---------------------------------------------------------------------
    -- Mid-run reset (new run starts): both scalers must clear at the
    -- next edge and count correctly afterwards -- even while busy.
    ---------------------------------------------------------------------
    rst <= '1';
    wait until rising_edge(clk);         -- synchronous clear happens here
    rst  <= '0';
    busy <= '1';                         -- busy right out of reset
    wait for 1 ns;
    assert total_count = 0 and busy_count = 0
      report "FAIL: scalers not cleared by mid-run reset" severity failure;

    wait until rising_edge(clk);         -- 2 busy edges after the new run
    wait until rising_edge(clk);
    busy <= '0';
    wait for 1 ns;
    assert total_count = 2 and busy_count = 2
      report "FAIL: scalers wrong after restart (expected 2 and 2, got "
             & integer'image(to_integer(total_count)) & " and "
             & integer'image(to_integer(busy_count)) & ")"
      severity failure;

    report "ALL TESTS PASSED";
    finished <= true;   -- stop the clock; simulation ends
    wait;
  end process stimulus;

end architecture sim;
