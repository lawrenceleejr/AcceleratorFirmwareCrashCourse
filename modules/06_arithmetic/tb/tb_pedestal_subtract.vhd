-- tb_pedestal_subtract.vhd
--
-- Self-checking testbench for the pedestal subtractor.
--
-- Beyond the usual stimulus-and-assert pattern (Module 04), this bench makes
-- one point loudly: the DUT has ONE CLOCK CYCLE of latency, and the checks
-- are written to respect it. Checking a registered output "too early" -- on
-- the same cycle the input was applied -- is probably the single most common
-- testbench bug in existence. It produces a FAIL on a correct design (you
-- then "fix" the design and break it) or, worse, a PASS for the wrong
-- reason. Every wait below is commented with which edge does what.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_pedestal_subtract is
end entity tb_pedestal_subtract;

architecture sim of tb_pedestal_subtract is

  -- DUT hookup signals.
  signal clk        : std_logic := '0';
  signal rst        : std_logic := '1';
  signal adc_data   : unsigned(11 downto 0) := (others => '0');
  signal pedestal   : unsigned(11 downto 0) := (others => '0');
  signal sample_out : unsigned(11 downto 0);

  -- When true, the clock generator stops and the simulation ends cleanly
  -- (event-driven simulators run until no more events are scheduled; a
  -- free-running clock would keep them alive forever).
  signal sim_done : boolean := false;

begin

  dut : entity work.pedestal_subtract
    port map (
      clk        => clk,
      rst        => rst,
      adc_data   => adc_data,
      pedestal   => pedestal,
      sample_out => sample_out
    );

  -- 100 MHz clock, stoppable.
  clock_gen : process
  begin
    while not sim_done loop
      clk <= '0';
      wait for 5 ns;
      clk <= '1';
      wait for 5 ns;
    end loop;
    wait;  -- clock parked; nothing left scheduled; simulation ends
  end process clock_gen;

  stimulus : process
    -- Apply one (adc, ped) pair and check the clamped difference, honouring
    -- the one-cycle latency. Encapsulating the timing in a procedure means
    -- it is written (and debugged) exactly once.
    procedure check (adc      : in natural;
                     ped      : in natural;
                     expected : in natural;
                     msg      : in string) is
    begin
      adc_data <= to_unsigned(adc, 12);           -- natural -> 12-bit unsigned
      pedestal <= to_unsigned(ped, 12);
      wait until rising_edge(clk);  -- THIS edge captures the inputs into the
                                    -- output register (1-cycle latency)
      wait for 1 ns;                -- step past the edge so we read the
                                    -- settled post-edge value, not a
                                    -- mid-update delta-cycle value
      assert to_integer(sample_out) = expected    -- unsigned -> integer for
                                                  -- readable arithmetic/report
        report "FAIL: " & msg
             & " (adc=" & integer'image(adc)
             & " ped=" & integer'image(ped)
             & " expected " & integer'image(expected)
             & " got " & integer'image(to_integer(sample_out)) & ")"
        severity failure;
    end procedure check;
  begin
    -- Hold reset for two clocks, then release. Synchronous reset, so it
    -- must span rising edges to be seen.
    rst <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    wait for 1 ns;
    assert to_integer(sample_out) = 0
      report "FAIL: output not zero during reset" severity failure;
    rst <= '0';

    -- Case 1: normal operation -- sample well above pedestal.
    check(adc => 1000, ped => 300, expected => 700,
          msg => "normal subtraction");

    -- Case 2: LATENCY demonstration. Apply new inputs, but check BEFORE the
    -- next rising edge: the output must still show the PREVIOUS result,
    -- because nothing happens between edges in a synchronous design.
    adc_data <= to_unsigned(250, 12);
    pedestal <= to_unsigned(300, 12);
    wait for 4 ns;  -- inputs changed, but no clock edge has occurred yet
    assert to_integer(sample_out) = 700
      report "FAIL: registered output changed without a clock edge"
      severity failure;

    -- ... and only after the edge does the new (clamped) result appear.
    -- 250 - 300 would wrap to 4045 on a bare 12-bit unsigned subtract;
    -- the clamp must give 0 instead.
    wait until rising_edge(clk);
    wait for 1 ns;
    assert to_integer(sample_out) = 0
      report "FAIL: sample below pedestal was not clamped to zero (got "
           & integer'image(to_integer(sample_out)) & ")"
      severity failure;

    -- Case 3: sample exactly equal to the pedestal -> exactly zero.
    check(adc => 300, ped => 300, expected => 0,
          msg => "sample equal to pedestal");

    -- Case 4: pedestal of zero -> pass-through.
    check(adc => 1234, ped => 0, expected => 1234,
          msg => "zero pedestal pass-through");

    -- Case 5: full-scale sample (all 12 bits set) minus a typical pedestal.
    check(adc => 4095, ped => 100, expected => 3995,
          msg => "full-scale sample");

    -- Case 6: full-scale sample, zero pedestal -- the maximum possible
    -- output must survive unmangled (no accidental clamp or truncation).
    check(adc => 4095, ped => 0, expected => 4095,
          msg => "full-scale pass-through");

    report "ALL TESTS PASSED";
    sim_done <= true;  -- stop the clock -> simulation ends cleanly
    wait;
  end process stimulus;

end architecture sim;
