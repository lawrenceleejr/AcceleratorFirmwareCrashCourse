-- tb_ring_buffer.vhd
--
-- Self-checking testbench for the waveform-capture ring buffer.
--
-- The trick that makes this testbench airtight: the "ADC" feeds a
-- deterministic ramp, sample number i having the value i mod 4096. Every
-- sample VALUE therefore encodes its own WRITE TIME. After a capture we can
-- compute, from the trigger time alone, exactly which 64 values must come
-- out of the ring and in what order -- and the very first value read proves
-- pre-trigger capture, because it was written 47 cycles BEFORE the trigger
-- (depth 64 = 47 pre-trigger + 1 trigger sample + 16 post-trigger).
--
-- The test plan:
--   1. feed 100 samples (the 64-deep ring wraps once and then some)
--   2. fire the trigger on sample 100; the DUT must write 16 more samples
--      (101..116) and then freeze
--   3. while frozen, feed garbage -- it must NOT land in the ring
--   4. read all 64 samples and check each against the ramp: 53, 54, ... 116
--      (sample 53 = trigger - 47: the pre-trigger proof)
--   5. check the one-cycle rd_valid latency explicitly (BRAM read latency)
--   6. rearm, capture a second event, check all 64 again
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_ring_buffer is
end entity tb_ring_buffer;

architecture sim of tb_ring_buffer is

  -- Mirror the DUT generics (small enough to simulate fast, big enough
  -- to be interesting).
  constant addr_bits    : natural := 6;
  constant data_bits    : natural := 12;
  constant post_trigger : natural := 16;
  constant depth        : natural := 2 ** addr_bits;   -- 64

  constant clk_period : time := 10 ns;   -- 100 MHz

  signal clk       : std_logic := '0';
  signal rst       : std_logic := '1';
  signal sample_in : unsigned(data_bits - 1 downto 0) := (others => '0');
  signal trigger   : std_logic := '0';
  signal rd_en     : std_logic := '0';
  signal rd_data   : unsigned(data_bits - 1 downto 0);
  signal rd_valid  : std_logic;
  signal frozen    : std_logic;
  signal rearm     : std_logic := '0';

  -- When the stimulus process is done it sets this, and the clock process
  -- stops toggling -- otherwise the simulation would run forever.
  signal sim_done : boolean := false;

begin

  dut : entity work.ring_buffer
    generic map (
      addr_bits    => addr_bits,
      data_bits    => data_bits,
      post_trigger => post_trigger
    )
    port map (
      clk       => clk,
      rst       => rst,
      sample_in => sample_in,
      trigger   => trigger,
      rd_en     => rd_en,
      rd_data   => rd_data,
      rd_valid  => rd_valid,
      frozen    => frozen,
      rearm     => rearm
    );

  -- Clock generator with a clean stop: no `after`-loops left running.
  clk_gen : process
  begin
    while not sim_done loop
      clk <= '0';
      wait for clk_period / 2;
      clk <= '1';
      wait for clk_period / 2;
    end loop;
    wait;
  end process clk_gen;

  stimulus : process
    -- Global sample counter: the "ADC sample number" i. Only incremented
    -- while the DUT is armed and actually writing.
    variable sample_idx : natural := 0;

    -- Feed the ramp for `n` armed cycles, then fire the trigger together
    -- with one more ramp sample, wait out the post-trigger phase, verify
    -- the freeze, read the whole ring back and check every value, then
    -- re-arm. Called once per simulated event.
    procedure capture_event(constant pre_samples : in natural) is
      variable trig_idx   : natural;   -- sample number of the trigger sample
      variable last_idx   : natural;   -- last sample written before freezing
      variable oldest_idx : natural;   -- first sample expected on readout
      variable expected   : natural;
    begin
      assert frozen = '0'
        report "FAIL: DUT not armed at start of event" severity failure;

      -- 1. Armed phase: one ramp sample per clock, always writing.
      for i in 1 to pre_samples loop
        sample_in <= to_unsigned(sample_idx mod 4096, data_bits);
        wait until rising_edge(clk);
        sample_idx := sample_idx + 1;
      end loop;

      assert frozen = '0'
        report "FAIL: DUT froze without a trigger" severity failure;
      assert rd_valid = '0'
        report "FAIL: rd_valid asserted while armed" severity failure;

      -- 2. Trigger cycle: the trigger arrives together with a sample.
      trig_idx := sample_idx;
      sample_in <= to_unsigned(sample_idx mod 4096, data_bits);
      trigger   <= '1';
      wait until rising_edge(clk);
      sample_idx := sample_idx + 1;
      trigger   <= '0';

      -- Post-trigger phase: the DUT must keep writing exactly this many.
      for i in 1 to post_trigger loop
        sample_in <= to_unsigned(sample_idx mod 4096, data_bits);
        wait until rising_edge(clk);
        sample_idx := sample_idx + 1;
      end loop;
      last_idx := sample_idx - 1;   -- = trig_idx + post_trigger

      -- The freezing edge has just passed; give the state a moment to
      -- settle (signals update a delta after the edge) and check it.
      wait for 1 ns;
      assert frozen = '1'
        report "FAIL: frozen not asserted after " &
               integer'image(post_trigger) & " post-trigger samples"
        severity failure;

      -- 3. While frozen, the ADC keeps talking but nothing must land in
      -- the ring: feed garbage for a few cycles.
      sample_in <= (others => '1');
      for i in 1 to 3 loop
        wait until rising_edge(clk);
      end loop;

      -- 4./5. Readout. The oldest surviving sample is the one written
      -- depth-1 cycles before the last write:
      --   oldest = last - 63 = trig - (63 - post_trigger) = trig - 47.
      -- That is 47 samples BEFORE the trigger: pre-trigger capture.
      oldest_idx := last_idx - (depth - 1);

      assert rd_valid = '0'
        report "FAIL: rd_valid high before any read request" severity failure;

      -- First read as a single-cycle rd_en pulse, to pin down the BRAM
      -- read latency exactly: data must appear ONE cycle after rd_en,
      -- flagged by rd_valid, and rd_valid must drop again right after.
      rd_en <= '1';
      wait until rising_edge(clk);   -- read request accepted at this edge
      rd_en <= '0';
      wait for 1 ns;
      assert rd_valid = '1'
        report "FAIL: rd_valid did not appear one cycle after rd_en"
        severity failure;
      expected := oldest_idx mod 4096;
      assert to_integer(rd_data) = expected
        report "FAIL: oldest sample: expected " & integer'image(expected) &
               " (written " & integer'image(trig_idx - oldest_idx) &
               " cycles before the trigger), got " &
               integer'image(to_integer(rd_data))
        severity failure;
      wait until rising_edge(clk);
      wait for 1 ns;
      assert rd_valid = '0'
        report "FAIL: rd_valid stuck high after a one-cycle read"
        severity failure;

      -- Stream out the remaining 63 samples with rd_en held high; one
      -- sample per clock must emerge, in strict age order.
      rd_en <= '1';
      for k in 1 to depth - 1 loop
        wait until rising_edge(clk);
        wait for 1 ns;
        assert rd_valid = '1'
          report "FAIL: rd_valid low during streaming read, sample " &
                 integer'image(k)
          severity failure;
        expected := (oldest_idx + k) mod 4096;
        assert to_integer(rd_data) = expected
          report "FAIL: readout sample " & integer'image(k) &
                 ": expected " & integer'image(expected) &
                 ", got " & integer'image(to_integer(rd_data))
          severity failure;
      end loop;
      rd_en <= '0';
      wait until rising_edge(clk);
      wait for 1 ns;
      assert rd_valid = '0'
        report "FAIL: rd_valid did not drop after readout" severity failure;

      -- 6. Rearm: back to armed, writing resumes on the next edge.
      rearm <= '1';
      wait until rising_edge(clk);
      rearm <= '0';
      wait for 1 ns;
      assert frozen = '0'
        report "FAIL: rearm did not return the DUT to armed" severity failure;
    end procedure capture_event;

  begin
    -- Synchronous reset: hold rst over two rising edges, then release.
    rst <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst <= '0';

    -- Event 1: 100 pre-trigger samples -- the 64-deep ring wraps once
    -- before the trigger, proving that overwriting the oldest is harmless.
    -- Expected readout: samples 53..116 (trigger was sample 100).
    capture_event(pre_samples => 100);

    -- Event 2: prove re-arming works. 60 more pre-trigger samples means
    -- 77 total writes since rearm, so the whole ring holds event-2 data.
    -- Expected readout: samples 130..193 (trigger is sample 177).
    capture_event(pre_samples => 60);

    report "ALL TESTS PASSED";
    sim_done <= true;   -- stop the clock; simulation ends cleanly
    wait;
  end process stimulus;

end architecture sim;
