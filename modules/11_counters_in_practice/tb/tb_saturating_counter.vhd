-- tb_saturating_counter.vhd
--
-- Self-checking testbench for the saturating counter.
--
-- WIDTH = 4 keeps the test short: the counter pegs at 15 instead of 255,
-- so the whole life cycle -- count up, hold when idle, hit the ceiling,
-- refuse to wrap, clear on reset -- fits in a few dozen cycles. The
-- generic is the point: the same DUT code runs at WIDTH = 8 in a real
-- design, and a testbench that exercises the boundary at 4 bits
-- exercises the same logic that guards it at 8.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_saturating_counter is
end entity tb_saturating_counter;

architecture sim of tb_saturating_counter is

  constant WIDTH     : natural := 4;
  constant MAX_COUNT : unsigned(WIDTH - 1 downto 0) := (others => '1');  -- 15

  signal clk       : std_logic := '0';
  signal rst       : std_logic := '1';   -- start in reset
  signal inc       : std_logic := '0';
  signal count     : unsigned(WIDTH - 1 downto 0);
  signal saturated : std_logic;

  signal finished : boolean := false;

begin

  dut : entity work.saturating_counter
    generic map (
      WIDTH => WIDTH
    )
    port map (
      clk       => clk,
      rst       => rst,
      inc       => inc,
      count     => count,
      saturated => saturated
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
  begin
    ---------------------------------------------------------------------
    -- Reset: hold rst for two edges, then release.
    ---------------------------------------------------------------------
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst <= '0';
    wait for 1 ns;
    assert count = 0
      report "FAIL: count not zero after reset" severity failure;
    assert saturated = '0'
      report "FAIL: saturated flag set after reset" severity failure;

    ---------------------------------------------------------------------
    -- Test 1: count three errors, then go quiet -- the value must hold.
    ---------------------------------------------------------------------
    inc <= '1';
    for i in 1 to 3 loop
      wait until rising_edge(clk);
      wait for 1 ns;
      assert count = to_unsigned(i, WIDTH)
        report "FAIL: count /= " & integer'image(i) & " while counting up"
        severity failure;
    end loop;

    inc <= '0';
    for i in 1 to 3 loop
      wait until rising_edge(clk);
      wait for 1 ns;
      assert count = to_unsigned(3, WIDTH)
        report "FAIL: count moved with inc = '0'" severity failure;
    end loop;

    ---------------------------------------------------------------------
    -- Test 2: count the rest of the way to the ceiling. The flag must
    -- stay low at 14 and rise exactly at 15 -- off-by-one here is the
    -- difference between "alarm at the ceiling" and "alarm one early".
    ---------------------------------------------------------------------
    inc <= '1';
    for i in 4 to 15 loop
      wait until rising_edge(clk);
      wait for 1 ns;
      assert count = to_unsigned(i, WIDTH)
        report "FAIL: count /= " & integer'image(i) & " on the way to max"
        severity failure;
      if i < 15 then
        assert saturated = '0'
          report "FAIL: saturated flag set early, at count "
                 & integer'image(i)
          severity failure;
      else
        assert saturated = '1'
          report "FAIL: saturated flag not set at max count" severity failure;
      end if;
    end loop;

    ---------------------------------------------------------------------
    -- Test 3: THE test. Keep incrementing past the ceiling; a wrapping
    -- counter would read 0, 1, 2, ... and lie to the shift crew. Ours
    -- must peg at 15 with the flag up.
    ---------------------------------------------------------------------
    for i in 1 to 5 loop
      wait until rising_edge(clk);
      wait for 1 ns;
      assert count = MAX_COUNT
        report "FAIL: counter wrapped past max (reads "
               & integer'image(to_integer(count)) & ")"
        severity failure;
      assert saturated = '1'
        report "FAIL: saturated flag dropped while pegged" severity failure;
    end loop;
    inc <= '0';

    ---------------------------------------------------------------------
    -- Test 4: reset unpegs it -- the start-of-run clear.
    ---------------------------------------------------------------------
    rst <= '1';
    wait until rising_edge(clk);   -- synchronous reset obeyed at this edge
    rst <= '0';
    wait for 1 ns;
    assert count = 0
      report "FAIL: reset did not clear the counter" severity failure;
    assert saturated = '0'
      report "FAIL: reset did not clear the saturated flag" severity failure;

    report "ALL TESTS PASSED";
    finished <= true;
    wait;
  end process stimulus;

end architecture sim;
