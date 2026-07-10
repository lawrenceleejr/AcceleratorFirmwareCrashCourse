-- tb_debug_demo.vhd
--
-- Self-checking SMOKE TEST for the debug demo.
--
-- The point of Module 12 is on-hardware debugging with ILAs and VIOs -- but
-- the course discipline does not get a holiday just because a design exists
-- "to be debugged in Vivado". EVEN the debug demo gets simulated first: if it
-- does not pass here, no amount of JTAG will save you, and you would waste a
-- multi-minute synthesis run discovering a bug a five-second simulation would
-- have caught. So before anyone straps an ILA to these nets, we prove in
-- simulation that the FSM's busy envelope and the two scalers behave.
--
-- What we check:
--   * after reset the machine is idle, quiet, both counters zero;
--   * a clean trigger is ACCEPTED: trig_count bumps, busy goes high;
--   * busy stays high for exactly the processing + cooldown envelope;
--   * a trigger injected WHILE BUSY is LOST: lost_count bumps, trig_count
--     does NOT (this is the dead-time bug an ILA is often hunting);
--   * a second clean trigger, fired after the machine rearms, is accepted.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_debug_demo is
end entity tb_debug_demo;

architecture sim of tb_debug_demo is

  -- Every expected number below derives from these two constants, so
  -- changing them re-derives the whole test.
  constant process_cycles_tb  : natural := 8;
  constant cooldown_cycles_tb : natural := 4;

  -- busy is asserted on the trigger-accept edge, stays high through the
  -- processing and cooldown states, and drops one edge after the machine
  -- returns to idle -- hence the "+ 1".
  constant busy_envelope : natural := process_cycles_tb + cooldown_cycles_tb + 1;

  signal clk        : std_logic := '0';
  signal rst        : std_logic := '1';   -- start in reset
  signal trigger_in : std_logic := '0';

  signal busy                   : std_logic;
  signal trig_count, lost_count : unsigned(15 downto 0);

  -- Flag that stops the clock generator so the simulation terminates.
  signal finished : boolean := false;

begin

  dut : entity work.debug_demo
    generic map (
      PROCESS_CYCLES  => process_cycles_tb,
      COOLDOWN_CYCLES => cooldown_cycles_tb
    )
    port map (
      clk        => clk,
      rst        => rst,
      trigger_in => trigger_in,
      busy       => busy,
      trig_count => trig_count,
      lost_count => lost_count
    );

  -- 100 MHz clock (10 ns period), halted when 'finished' goes true.
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

  -- As always: change inputs just after an edge, check outputs 1 ns after
  -- an edge.
  stimulus : process
    variable busy_cycles : natural;
  begin
    ---------------------------------------------------------------------
    -- Reset for two edges, then confirm the machine wakes up idle.
    ---------------------------------------------------------------------
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst <= '0';
    wait for 1 ns;
    assert busy = '0'
      report "FAIL: busy asserted after reset" severity failure;
    assert trig_count = 0 and lost_count = 0
      report "FAIL: counters not zero after reset" severity failure;

    -- A few live cycles with no trigger: nothing may happen.
    for i in 1 to 3 loop
      wait until rising_edge(clk);
    end loop;
    wait for 1 ns;
    assert busy = '0' and trig_count = 0
      report "FAIL: machine left idle without a trigger" severity failure;

    ---------------------------------------------------------------------
    -- Event 1: one clean trigger, with a ROGUE trigger injected while the
    -- machine is busy. The accepted trigger must count once; the rogue must
    -- count as a loss and must NOT count as an accepted event.
    ---------------------------------------------------------------------
    trigger_in <= '1';
    wait until rising_edge(clk);            -- FSM accepts it on this edge
    trigger_in <= '0';
    wait for 1 ns;
    assert busy = '1'
      report "FAIL: busy not asserted on the trigger-accept cycle"
      severity failure;
    assert trig_count = 1
      report "FAIL: accepted trigger not counted (trig_count = "
             & integer'image(to_integer(trig_count)) & ")" severity failure;
    assert lost_count = 0
      report "FAIL: phantom loss counted on a clean trigger" severity failure;

    -- Follow the busy envelope edge by edge, counting how long busy stays
    -- high, and inject one rogue trigger partway through (on busy cycle 3,
    -- safely inside the processing window).
    busy_cycles := 1;                       -- the accept cycle we just saw
    while busy = '1' loop
      if busy_cycles = 3 then
        trigger_in <= '1';                  -- a trigger that arrives too soon
      else
        trigger_in <= '0';
      end if;
      wait until rising_edge(clk);
      wait for 1 ns;
      if busy = '1' then
        busy_cycles := busy_cycles + 1;
      end if;
      assert busy_cycles < 100
        report "FAIL: busy never dropped (cooldown stuck?)" severity failure;
    end loop;

    -- Envelope and scalers after the event completes.
    assert busy_cycles = busy_envelope
      report "FAIL: busy high for " & integer'image(busy_cycles)
             & " cycles, expected " & integer'image(busy_envelope)
      severity failure;
    assert trig_count = 1
      report "FAIL: rogue trigger was wrongly accepted (trig_count = "
             & integer'image(to_integer(trig_count)) & ", expected 1)"
      severity failure;
    assert lost_count = 1
      report "FAIL: rogue-while-busy not counted as a loss (lost_count = "
             & integer'image(to_integer(lost_count)) & ", expected 1)"
      severity failure;

    ---------------------------------------------------------------------
    -- Event 2: a second clean trigger after the machine has rearmed. It
    -- must be accepted (trig_count -> 2) with no new losses.
    ---------------------------------------------------------------------
    for i in 1 to 3 loop                    -- a short live gap first
      wait until rising_edge(clk);
    end loop;
    wait for 1 ns;
    assert busy = '0'
      report "FAIL: machine did not return to idle" severity failure;

    trigger_in <= '1';
    wait until rising_edge(clk);
    trigger_in <= '0';
    wait for 1 ns;
    assert busy = '1' and trig_count = 2
      report "FAIL: second clean trigger not accepted (trig_count = "
             & integer'image(to_integer(trig_count)) & ", expected 2)"
      severity failure;

    -- Let it finish and confirm nothing new was lost.
    for i in 1 to busy_envelope + 4 loop
      wait until rising_edge(clk);
    end loop;
    wait for 1 ns;
    assert busy = '0'
      report "FAIL: busy still high long after the second event"
      severity failure;
    assert trig_count = 2 and lost_count = 1
      report "FAIL: final counts wrong (trig_count = "
             & integer'image(to_integer(trig_count)) & ", lost_count = "
             & integer'image(to_integer(lost_count))
             & ", expected 2 and 1)" severity failure;

    report "ALL TESTS PASSED";
    finished <= true;   -- stop the clock; simulation ends
    wait;
  end process stimulus;

end architecture sim;
