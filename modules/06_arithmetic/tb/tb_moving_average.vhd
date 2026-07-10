-- tb_moving_average.vhd
--
-- Self-checking testbench for the 4-sample moving average.
--
-- Verification strategy: a GOLDEN MODEL. Instead of hand-computing a few
-- expected values, the testbench re-implements the filter with plain
-- integers -- same delay line, same running sum, same TRUNCATING division --
-- and compares the DUT against it on EVERY clock cycle. This is the standard
-- way to verify DSP: the golden model is trivially readable (it looks like
-- the Python you'd prototype the filter with), and any divergence, on any
-- sample, fails immediately.
--
-- The one subtlety is matching semantics exactly:
--   * the hardware divides by slicing bits, which truncates toward zero --
--     the model must use integer division, not rounding;
--   * the hardware updates on clock edges from PRE-edge values -- the model
--     must update in the same order, or it drifts one cycle out of step
--     (the moving-average version of the classic latency bug).
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_moving_average is
end entity tb_moving_average;

architecture sim of tb_moving_average is

  -- Keep the TB's window parameters in constants so changing LOG2_WINDOW
  -- here re-verifies the DUT at a different window length with no other
  -- edits (try it: set it to 3).
  constant log2_window_c : natural := 2;
  constant window_c      : natural := 2**log2_window_c;

  signal clk        : std_logic := '0';
  signal rst        : std_logic := '1';
  signal sample_in  : unsigned(11 downto 0) := (others => '0');
  signal sample_out : unsigned(11 downto 0);

  signal sim_done : boolean := false;

  -- The stimulus: a realistic little waveform.
  --   * constant baseline (filter must reproduce it exactly once full),
  --   * a step (filter must ramp over one window, then settle),
  --   * a synthetic pulse riding on the baseline, with values chosen NOT
  --     divisible by 4 so the truncating division is actually exercised
  --     (all-round-number stimulus is how truncation bugs survive).
  type stim_array_t is array (natural range <>) of natural;
  constant stim_c : stim_array_t := (
    100, 100, 100, 100, 100, 100,                    -- baseline
    1000, 1000, 1000, 1000, 1000, 1000,              -- step
    101, 149, 407, 903, 1501, 902, 401, 150, 101,    -- pulse over baseline
    100, 100, 100, 100, 100, 100                     -- back to baseline; long
                                                     -- enough that the LAST
                                                     -- CHECKED window (which,
                                                     -- with 2 cycles of
                                                     -- latency, ends 2 samples
                                                     -- before the final input)
                                                     -- is purely baseline
  );

begin

  dut : entity work.moving_average
    generic map (
      LOG2_WINDOW => log2_window_c
    )
    port map (
      clk        => clk,
      rst        => rst,
      sample_in  => sample_in,
      sample_out => sample_out
    );

  -- 100 MHz clock, stoppable for a clean end of simulation.
  clock_gen : process
  begin
    while not sim_done loop
      clk <= '0';
      wait for 5 ns;
      clk <= '1';
      wait for 5 ns;
    end loop;
    wait;
  end process clock_gen;

  stimulus : process
    -- Golden model state: mirrors the DUT's registers exactly. Variables,
    -- not signals -- this is bookkeeping, not hardware (Module 04).
    variable gold_taps : stim_array_t(0 to window_c - 1) := (others => 0);
    variable gold_sum  : natural := 0;
    variable gold_out  : natural := 0;
  begin
    -- Reset for two clocks. The golden model's zero-initialised state
    -- matches the DUT's reset state, so checking can start from the very
    -- first sample -- the "pipeline fill" cycles (output still dominated by
    -- reset zeros) are verified too, not skipped.
    rst <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst <= '0';
    wait for 1 ns;

    for i in stim_c'range loop
      -- Drive the next sample; it will be captured at the coming edge.
      sample_in <= to_unsigned(stim_c(i), 12);

      wait until rising_edge(clk);

      -- Update the golden model IN THE SAME ORDER as the hardware. At this
      -- edge the DUT (a) registers old_sum / window into sample_out, and
      -- (b) computes new_sum from the old sum, the new sample, and the
      -- oldest tap -- all from pre-edge values. So: output first, from the
      -- OLD sum...
      gold_out := gold_sum / window_c;  -- '/' on integers truncates, exactly
                                        -- like the DUT's bit slice
      -- ...then the sum and delay line.
      gold_sum := gold_sum + stim_c(i) - gold_taps(window_c - 1);
      for j in window_c - 1 downto 1 loop
        gold_taps(j) := gold_taps(j - 1);
      end loop;
      gold_taps(0) := stim_c(i);

      -- Step past the edge, then compare DUT and model.
      wait for 1 ns;
      assert to_integer(sample_out) = gold_out
        report "FAIL at stimulus index " & integer'image(i)
             & ": expected " & integer'image(gold_out)
             & " got " & integer'image(to_integer(sample_out))
        severity failure;
    end loop;

    -- Spot-check the physics on top of the sample-by-sample comparison:
    -- after four trailing baseline samples the filter must have settled
    -- back to the baseline exactly. (Belt and braces: if the golden model
    -- itself were wrong, this independent check would catch it.)
    assert to_integer(sample_out) = 100
      report "FAIL: filter did not settle back to the 100-count baseline (got "
           & integer'image(to_integer(sample_out)) & ")"
      severity failure;

    report "ALL TESTS PASSED";
    sim_done <= true;
    wait;
  end process stimulus;

end architecture sim;
