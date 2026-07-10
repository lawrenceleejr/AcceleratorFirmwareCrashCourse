-- tb_coincidence.vhd
--
-- Self-checking testbench for the coincidence unit.
--
-- A testbench is VHDL that will never become hardware: it exists only to
-- poke stimulus into the design under test (DUT) and check the responses.
-- Because it never has to be synthesizable, it may use software-like
-- conveniences (wait statements, file I/O, printing) that are forbidden or
-- meaningless in real hardware. Module 04 covers testbenches in depth.
--
library ieee;
use ieee.std_logic_1164.all;

-- A testbench entity has NO ports: nothing outside the simulator ever
-- connects to it. It is the whole (simulated) universe.
entity tb_coincidence is
end entity tb_coincidence;

architecture sim of tb_coincidence is

  -- Local signals to wire up to the DUT's ports.
  signal pmt_a, pmt_b, trigger : std_logic := '0';

begin

  -- Instantiate the design under test and connect ('map') its ports to
  -- our local signals. This is like wiring a chip onto a test board.
  dut : entity work.coincidence
    port map (
      pmt_a   => pmt_a,
      pmt_b   => pmt_b,
      trigger => trigger
    );

  -- The stimulus process: this ONE process is sequential, like a script.
  -- It walks the DUT through all four input combinations and asserts the
  -- expected output for each.
  stimulus : process
  begin
    -- Case 1: no pulses -> no trigger.
    pmt_a <= '0';  pmt_b <= '0';
    wait for 10 ns;   -- let the signals propagate (only legal in simulation!)
    assert trigger = '0'
      report "FAIL: trigger fired with no input pulses" severity failure;

    -- Case 2: only the top paddle fires (e.g. a gamma) -> no trigger.
    pmt_a <= '1';  pmt_b <= '0';
    wait for 10 ns;
    assert trigger = '0'
      report "FAIL: trigger fired on top paddle alone" severity failure;

    -- Case 3: only the bottom paddle fires -> no trigger.
    pmt_a <= '0';  pmt_b <= '1';
    wait for 10 ns;
    assert trigger = '0'
      report "FAIL: trigger fired on bottom paddle alone" severity failure;

    -- Case 4: a muon! Both paddles fire -> trigger.
    pmt_a <= '1';  pmt_b <= '1';
    wait for 10 ns;
    assert trigger = '1'
      report "FAIL: trigger missed a coincidence" severity failure;

    report "ALL TESTS PASSED";
    wait;  -- a wait with no condition halts this process forever = end of test
  end process stimulus;

end architecture sim;
