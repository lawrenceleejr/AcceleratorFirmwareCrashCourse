-- tb_prbs7.vhd
--
-- Self-checking testbench for the PRBS-7 generator/checker pair.
--
-- The wiring is the whole point: generator output straight into checker
-- input, a zero-length, zero-error "fiber". On a real link the same two
-- blocks would sit in different FPGAs a hundred meters apart -- the test
-- plan is identical:
--
--   1. the checker must LOCK within a bounded time,
--   2. a clean link must count ZERO errors,
--   3. a deliberately injected error must be counted EXACTLY once
--      (proving the checker actually checks -- Module 04's mutation
--      instinct: never trust a test you haven't seen fail),
--   4. and a single bit error must NOT unlock the checker.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_prbs7 is
end entity tb_prbs7;

architecture sim of tb_prbs7 is

  signal clk        : std_logic := '0';
  signal rst        : std_logic := '1';
  signal err_inject : std_logic := '0';
  signal serial_bit : std_logic;               -- the "fiber"
  signal locked     : std_logic;
  signal err_count  : unsigned(15 downto 0);

  -- Set by the stimulus process when the test is over; stops the clock so
  -- the simulation ends by itself instead of running forever.
  signal stop : boolean := false;

begin

  -- 100 MHz clock (10 ns period), gated by the stop flag.
  clock : process
  begin
    while not stop loop
      clk <= '0';
      wait for 5 ns;
      clk <= '1';
      wait for 5 ns;
    end loop;
    wait;  -- clock stopped: no more events, simulator exits
  end process clock;

  -- The far end of the link: the pattern source.
  gen : entity work.prbs7_gen
    port map (
      clk        => clk,
      rst        => rst,
      err_inject => err_inject,
      prbs_out   => serial_bit
    );

  -- The near end: the checker, fed directly -- a perfect fiber.
  chk : entity work.prbs7_check
    port map (
      clk       => clk,
      rst       => rst,
      rx_bit    => serial_bit,
      locked    => locked,
      err_count => err_count
    );

  stimulus : process
  begin
    -- Hold reset for a few cycles, then release. Both ends share rst here;
    -- on a real link each end has its own -- which is exactly why the
    -- checker must self-synchronize rather than rely on a common start.
    rst <= '1';
    for i in 1 to 3 loop
      wait until rising_edge(clk);
    end loop;
    rst <= '0';

    ------------------------------------------------------------------
    -- Test 1: the checker locks within a bounded time.
    -- It needs 7 clean bits to seed its mirror LFSR, plus a cycle for
    -- the locked flag; 20 cycles is generous. Bounding the wait matters:
    -- "wait until locked" with no bound would hang forever on a broken
    -- design instead of failing loudly.
    ------------------------------------------------------------------
    for i in 1 to 20 loop
      wait until rising_edge(clk);
      exit when locked = '1';
    end loop;
    assert locked = '1'
      report "FAIL: checker did not lock within 20 cycles" severity failure;

    ------------------------------------------------------------------
    -- Test 2: a clean link counts zero errors. 300 bits is more than two
    -- full PRBS-7 periods (2 x 127 = 254), so every state transition of
    -- the sequence gets exercised at least twice.
    ------------------------------------------------------------------
    for i in 1 to 300 loop
      wait until rising_edge(clk);
    end loop;
    assert err_count = 0
      report "FAIL: errors counted on a perfect link (err_count = "
             & integer'image(to_integer(err_count)) & ")"
      severity failure;
    assert locked = '1'
      report "FAIL: checker lost lock on a perfect link" severity failure;

    ------------------------------------------------------------------
    -- Test 3: inject exactly one error; expect exactly one count.
    -- err_inject is raised just after one rising edge and lowered just
    -- after the next, so precisely ONE edge samples a flipped bit at the
    -- checker. If this assertion ever reports 3, someone has changed the
    -- checker to shift RECEIVED bits after lock -- see the error-
    -- multiplication note in prbs7_check.vhd.
    ------------------------------------------------------------------
    wait until rising_edge(clk);
    err_inject <= '1';
    wait until rising_edge(clk);
    err_inject <= '0';
    for i in 1 to 4 loop  -- a few cycles for the count to register
      wait until rising_edge(clk);
    end loop;
    assert err_count = 1
      report "FAIL: one injected error, but err_count = "
             & integer'image(to_integer(err_count))
      severity failure;

    -- The crucial companion check: one bad bit must NOT unlock a healthy
    -- checker. Errors are the measurement; loss of lock is a catastrophe
    -- signal. A checker that resyncs on every hit could never measure a
    -- link's BER -- it would spend its life re-seeding.
    assert locked = '1'
      report "FAIL: a single bit error unlocked the checker" severity failure;

    ------------------------------------------------------------------
    -- Test 4: three more injected errors -> total of exactly 4.
    ------------------------------------------------------------------
    for k in 1 to 3 loop
      wait until rising_edge(clk);
      err_inject <= '1';
      wait until rising_edge(clk);
      err_inject <= '0';
      for i in 1 to 4 loop
        wait until rising_edge(clk);
      end loop;
    end loop;
    assert err_count = 4
      report "FAIL: four injected errors, but err_count = "
             & integer'image(to_integer(err_count))
      severity failure;
    assert locked = '1'
      report "FAIL: checker lost lock after repeated single errors"
      severity failure;

    report "ALL TESTS PASSED";
    stop <= true;  -- stop the clock; simulation ends on its own
    wait;
  end process stimulus;

end architecture sim;
