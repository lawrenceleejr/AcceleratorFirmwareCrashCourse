-- tb_readout_fsm.vhd
--
-- Self-checking testbench for the triggered-readout controller.
--
-- Strategy: an FSM is verified by walking it through complete events and
-- doing cycle-exact bookkeeping on every output -- exactly the discipline
-- from Module 04, wrapped in a reusable PROCEDURE because we run several
-- events. For each event we count the rd_en strobes one by one and check:
--
--   * exactly SAMPLE_COUNT strobes, contiguous, starting exactly
--     CAPTURE_CYCLES + 1 cycles after the trigger is accepted;
--   * rd_last high with the final strobe and only there;
--   * busy high from trigger acceptance until the event_done cycle
--     (the dead-time envelope Module 03's scaler would integrate);
--   * event_done exactly one cycle wide, event_count bumped by one;
--   * triggers injected mid-event are IGNORED (no phantom second event,
--     no double increment) -- that's dead time doing its job;
--   * two events back-to-back, the second triggered during the first
--     event's done cycle -- the machine really is rearmed.
--
-- The generics are mapped smaller than their defaults (4 and 8) so one
-- event is short enough to check against pencil and paper -- and it proves
-- the design honours its generics rather than hard-coding the defaults.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_readout_fsm is
end entity tb_readout_fsm;

architecture sim of tb_readout_fsm is

  -- Shrunk from the defaults; every expected number below derives from
  -- these two constants, so changing them re-derives the whole test.
  constant capture_cycles_tb : natural := 4;
  constant sample_count_tb   : natural := 8;

  signal clk     : std_logic := '0';
  signal rst     : std_logic := '1';   -- start in reset
  signal trigger : std_logic := '0';

  signal rd_en, rd_last, busy, event_done : std_logic;
  signal event_count                      : unsigned(15 downto 0);

  -- Flag that stops the clock generator so the simulation terminates.
  signal finished : boolean := false;

begin

  dut : entity work.readout_fsm
    generic map (
      CAPTURE_CYCLES => capture_cycles_tb,
      SAMPLE_COUNT   => sample_count_tb
    )
    port map (
      clk         => clk,
      rst         => rst,
      trigger     => trigger,
      rd_en       => rd_en,
      rd_last     => rd_last,
      busy        => busy,
      event_done  => event_done,
      event_count => event_count
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

  -- As in Module 03: change inputs just after an edge, check outputs
  -- 1 ns after an edge.
  stimulus : process

    -- Fire one trigger, then follow the whole event to completion,
    -- checking every output on every cycle. Declared inside the process
    -- so it may drive 'trigger' directly. When it returns, the simulation
    -- sits 1 ns into the event_done cycle -- so the caller can retrigger
    -- immediately for a back-to-back event.
    procedure run_event (
      expected_count : in natural;   -- event_count after this event
      rogue_triggers : in boolean    -- inject extra triggers mid-event?
    ) is
      variable cycles   : natural := 0;      -- edges since trigger accepted
      variable strobes  : natural := 0;      -- rd_en pulses seen
      variable saw_last : boolean := false;
    begin
      -- Fire the trigger for exactly one clock cycle.
      trigger <= '1';
      wait until rising_edge(clk);           -- FSM accepts it on this edge
      trigger <= '0';
      wait for 1 ns;
      assert busy = '1'
        report "FAIL: busy not asserted on the trigger-accept cycle"
        severity failure;

      -- Follow the event, edge by edge, until the done pulse appears.
      while event_done = '0' loop
        wait until rising_edge(clk);

        -- Rogue triggers: one during CAPTURING, one during READOUT. The
        -- FSM must be blind to both -- that is the dead time. Each is
        -- asserted just after an edge and dropped after the next, so it
        -- is sampled exactly once, like a real 1-cycle trigger pulse.
        if rogue_triggers and (cycles = 2 or cycles = 6) then
          trigger <= '1';
        elsif rogue_triggers then
          trigger <= '0';
        end if;

        wait for 1 ns;
        cycles := cycles + 1;
        assert cycles < 100
          report "FAIL: event never completed (timeout)" severity failure;

        if rd_en = '1' then
          -- The first strobe must land exactly where the capture window
          -- ends: CAPTURE_CYCLES in capturing + 1 for the registered
          -- output (see the note at the bottom of readout_fsm.vhd).
          if strobes = 0 then
            assert cycles = capture_cycles_tb + 1
              report "FAIL: first rd_en strobe on cycle "
                     & integer'image(cycles) & ", expected "
                     & integer'image(capture_cycles_tb + 1)
              severity failure;
          end if;
          strobes := strobes + 1;
          assert busy = '1'
            report "FAIL: rd_en strobe while not busy" severity failure;
        elsif strobes > 0 and not saw_last and event_done = '0' then
          assert false
            report "FAIL: gap in the rd_en burst after strobe "
                   & integer'image(strobes)
            severity failure;
        end if;

        if rd_last = '1' then
          assert rd_en = '1'
            report "FAIL: rd_last asserted without rd_en" severity failure;
          assert strobes = sample_count_tb
            report "FAIL: rd_last on strobe " & integer'image(strobes)
                   & ", expected " & integer'image(sample_count_tb)
            severity failure;
          saw_last := true;
        end if;

        if event_done = '0' then
          assert busy = '1'
            report "FAIL: busy dropped in the middle of the event"
            severity failure;
        end if;
      end loop;

      -- We are now 1 ns into the event_done cycle. Final bookkeeping:
      assert strobes = sample_count_tb
        report "FAIL: counted " & integer'image(strobes)
               & " rd_en strobes, expected "
               & integer'image(sample_count_tb)
        severity failure;
      assert saw_last
        report "FAIL: never saw rd_last" severity failure;
      assert rd_en = '0'
        report "FAIL: rd_en still high on the event_done cycle"
        severity failure;
      assert busy = '0'
        report "FAIL: busy still high on the event_done cycle "
               & "(machine should be live again)"
        severity failure;
      assert event_count = expected_count
        report "FAIL: event_count = "
               & integer'image(to_integer(event_count)) & ", expected "
               & integer'image(expected_count)
        severity failure;
    end procedure run_event;

  begin
    ---------------------------------------------------------------------
    -- Reset for two edges, then confirm the machine wakes up idle.
    ---------------------------------------------------------------------
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst <= '0';
    wait for 1 ns;
    assert busy = '0' and rd_en = '0' and event_done = '0'
      report "FAIL: outputs not quiet after reset" severity failure;
    assert event_count = 0
      report "FAIL: event_count not zero after reset" severity failure;

    -- A few live cycles with no trigger: nothing may happen.
    for i in 1 to 3 loop
      wait until rising_edge(clk);
    end loop;
    wait for 1 ns;
    assert busy = '0' and event_count = 0
      report "FAIL: FSM left idle without a trigger" severity failure;

    ---------------------------------------------------------------------
    -- Event 1: one clean event, checked cycle by cycle.
    ---------------------------------------------------------------------
    run_event(expected_count => 1, rogue_triggers => false);

    -- event_done must be exactly one cycle wide.
    wait until rising_edge(clk);
    wait for 1 ns;
    assert event_done = '0'
      report "FAIL: event_done wider than one clock cycle" severity failure;

    ---------------------------------------------------------------------
    -- Event 2: same event, but with rogue triggers injected while busy.
    -- They must vanish without a trace: correct event, single increment.
    ---------------------------------------------------------------------
    for i in 1 to 3 loop                     -- a short live gap first
      wait until rising_edge(clk);
    end loop;
    wait for 1 ns;
    run_event(expected_count => 2, rogue_triggers => true);

    -- The ignored triggers must not have queued a phantom event: watch
    -- several cycles of silence. (This loop also re-checks the width of
    -- event_done.) A real DAQ would COUNT these losses -- see exercise.
    for i in 1 to 8 loop
      wait until rising_edge(clk);
      wait for 1 ns;
      assert busy = '0' and rd_en = '0' and event_done = '0'
        report "FAIL: ignored trigger started a phantom event"
        severity failure;
    end loop;
    assert event_count = 2
      report "FAIL: ignored triggers changed event_count (got "
             & integer'image(to_integer(event_count)) & ", expected 2)"
      severity failure;

    ---------------------------------------------------------------------
    -- Events 3 and 4: back-to-back. run_event returns during the done
    -- cycle, and the machine is already idle then -- so calling it again
    -- immediately retriggers with zero live gap between the events.
    ---------------------------------------------------------------------
    run_event(expected_count => 3, rogue_triggers => false);
    run_event(expected_count => 4, rogue_triggers => false);

    -- And quiet ever after.
    for i in 1 to 4 loop
      wait until rising_edge(clk);
    end loop;
    wait for 1 ns;
    assert busy = '0' and event_count = 4
      report "FAIL: machine not quiet after final event" severity failure;

    report "ALL TESTS PASSED";
    finished <= true;   -- stop the clock; simulation ends
    wait;
  end process stimulus;

end architecture sim;
