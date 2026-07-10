-- tb_discriminator.vhd
--
-- A full-dress, self-checking testbench for the leading-edge discriminator.
-- This file is the actual subject of Module 04: it demonstrates every part
-- of the testbench anatomy you will reuse for the rest of your career.
--
--   1. DUT instantiation          - wire the design onto the "test bench"
--   2. clock generator            - a free-running 100 MHz clock
--   3. stimulus process           - the test script, with reusable
--                                   PROCEDURES that model detector pulses
--   4. monitor process            - an independent observer counting fires
--   5. golden model               - a software-style reference computation
--                                   of the expected answer, kept in lockstep
--                                   with the stimulus
--   6. watchdog                   - guarantees the simulation terminates
--
-- Why so much machinery for a two-flip-flop DUT? Because in hardware the
-- testbench IS your debugger. There is no printf on a board in a shielded
-- tunnel enclosure; there is no rerun-in-two-seconds. Simulation is where
-- bugs are cheap. Spend your effort here.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- math_real gives us uniform() for random stimulus. SIMULATION ONLY:
-- floating point is not synthesizable, and this package must never appear
-- in a file under src/. In a testbench it is fair game.
use ieee.math_real.all;

-- std.env.finish (VHDL-2008) ends the simulation cleanly from inside the
-- code — the polite alternative to letting a free-running clock spin
-- forever. (The other classic pattern is a 'done' signal that the clock
-- process tests; see the comment on clock_gen below.)
use std.env.finish;

entity tb_discriminator is
end entity tb_discriminator;

architecture sim of tb_discriminator is

  constant clk_period : time := 10 ns;   -- 100 MHz, the course standard

  -- ADC pedestal: real digitizer channels idle at some nonzero baseline
  -- (offset binary, dark current, electronics offset), not at zero.
  constant baseline  : natural := 100;
  constant thr_value : natural := 500;   -- discriminator setting for all tests
  constant adc_max   : natural := 4095;  -- 12-bit full scale

  -- Wires to the DUT.
  signal clk       : std_logic := '0';
  signal rst       : std_logic := '1';   -- start the universe in reset
  signal adc_data  : unsigned(11 downto 0) := to_unsigned(baseline, 12);
  signal threshold : unsigned(11 downto 0) := to_unsigned(thr_value, 12);
  signal fired     : std_logic;

  -- Scoreboard: how many times has the DUT actually fired? Owned by the
  -- monitor process; read by the stimulus process when it checks results.
  signal fired_count : natural := 0;

begin

  ---------------------------------------------------------------------------
  -- 1. The DUT, wired onto the bench.
  ---------------------------------------------------------------------------
  dut : entity work.discriminator
    port map (
      clk       => clk,
      rst       => rst,
      adc_data  => adc_data,
      threshold => threshold,
      fired     => fired
    );

  ---------------------------------------------------------------------------
  -- 2. Clock generator. A process with no sensitivity list loops forever,
  --    so this describes a free-running square wave. It never stops on its
  --    own — the stimulus process ends the simulation with finish, which
  --    kills every process at once. (Alternative idiom: declare
  --    "signal done : boolean := false", loop "while not done", and have
  --    the stimulus set done <= true; the clock then starves and the
  --    simulator exits because no events remain. Both are standard.)
  ---------------------------------------------------------------------------
  clock_gen : process
  begin
    clk <= '0';
    wait for clk_period / 2;
    clk <= '1';
    wait for clk_period / 2;
  end process clock_gen;

  ---------------------------------------------------------------------------
  -- 4. Monitor: an INDEPENDENT observer. It knows nothing about what the
  --    stimulus is doing; it just watches the DUT output on every clock,
  --    like a scaler NIM module cabled to the trigger output. Keeping the
  --    checker separate from the stimulus is a habit that scales all the
  --    way up to real verification environments.
  ---------------------------------------------------------------------------
  monitor : process (clk)
    variable fired_last : std_logic := '0';
  begin
    if rising_edge(clk) then
      if fired = '1' then
        fired_count <= fired_count + 1;
        -- Protocol check: the spec says ONE clock per crossing. Two highs
        -- in a row can only mean a broken one-shot.
        assert fired_last = '0'
          report "FAIL: fired stayed high for more than one clock"
          severity failure;
      end if;
      fired_last := fired;
    end if;
  end process monitor;

  ---------------------------------------------------------------------------
  -- 6. Watchdog: if a bug ever makes the stimulus hang (e.g. waiting on a
  --    condition that never comes), this guarantees the simulation still
  --    terminates — with a loud failure instead of an eternal silent spin.
  --    Every testbench you write should have a bounded runtime.
  ---------------------------------------------------------------------------
  watchdog : process
  begin
    wait for 500 us;
    report "TIMEOUT: testbench did not finish - stimulus is stuck"
      severity failure;
  end process watchdog;

  ---------------------------------------------------------------------------
  -- 3 + 5. Stimulus and golden model. This one process is the test script.
  -- Its declarative region holds VARIABLES (the model state, the random
  -- seeds) and PROCEDURES — the closest thing VHDL has to your helper
  -- functions. A procedure declared inside a process may drive the
  -- process's signals and see its variables, which makes this the natural
  -- home for stimulus helpers.
  ---------------------------------------------------------------------------
  stimulus : process

    -- Random seeds for ieee.math_real.uniform. FIXED on purpose: given the
    -- same seeds, uniform() produces the same sequence every run, so a
    -- "random" test that fails tonight fails identically tomorrow morning
    -- when you debug it. Irreproducible tests are worse than no tests.
    -- (To explore new stimulus, change the seeds — deliberately.)
    variable seed1 : positive := 42;
    variable seed2 : positive := 4242;

    -- THE GOLDEN MODEL. Two variables re-implement the discriminator spec
    -- in plain sequential code — the way you would in Python — and are
    -- updated for every single sample we drive. At checkpoints we demand
    -- that the hardware's fired_count equals the model's expected_count.
    -- DUT and model are written independently (different author mindset,
    -- different style), so a bug must strike both identically to slip by.
    variable expected_count : natural := 0;
    variable model_above    : boolean := false;

    -- When true, drive_sample adds a few LSB of random noise to every
    -- sample — a crude but honest model of baseline noise on a real ADC.
    variable noise_on : boolean := false;

    -- rand_int: uniform random integer in [lo, hi]. uniform() yields a
    -- real in (0,1); we scale it. Note seeds are 'inout': each call
    -- advances the generator state.
    procedure rand_int (
      constant lo, hi : in  integer;
      variable result : out integer
    ) is
      variable r : real;
    begin
      uniform(seed1, seed2, r);
      result := lo + integer(trunc(r * real(hi - lo + 1)));
    end procedure rand_int;

    -- drive_sample: put ONE sample on the ADC bus and let one clock pass.
    -- Every sample in the whole test flows through here, and the golden
    -- model is updated in the same breath — so model and DUT literally see
    -- identical data, noise and all.
    procedure drive_sample (constant value : in integer) is
      variable v : integer := value;
      variable n : integer;
    begin
      if noise_on then
        rand_int(-3, 3, n);          -- +/-3 LSB of baseline noise
        v := v + n;
      end if;
      v := maximum(0, minimum(v, adc_max));   -- clamp to the 12-bit range
      adc_data <= to_unsigned(v, adc_data'length);

      -- Golden model: the same decision the DUT makes, in software.
      if rst = '1' then
        model_above := false;                 -- mirrors the DUT's reset
      else
        if v > thr_value and not model_above then
          expected_count := expected_count + 1;
        end if;
        model_above := v > thr_value;
      end if;

      wait until rising_edge(clk);            -- the DUT samples it here
    end procedure drive_sample;

    -- idle: n clocks of quiet baseline between pulses.
    procedure idle (constant n : in positive) is
    begin
      for i in 1 to n loop
        drive_sample(baseline);
      end loop;
    end procedure idle;

    -- send_pulse: a synthetic scintillator-ish pulse. Real PMT pulses rise
    -- in a nanosecond or two and decay with the scintillator + anode-circuit
    -- time constant, so we model: half-amplitude sample, peak sample, then
    -- an exponential tail exp(-t/tau) — again math_real, again sim-only.
    -- 'amplitude' is the peak height ABOVE baseline; 'tau_samples' is the
    -- decay constant in clock ticks. This is how you turn "what does my
    -- detector actually output?" into testbench stimulus.
    procedure send_pulse (
      constant amplitude   : in natural;
      constant tau_samples : in positive
    ) is
      variable a : real;
    begin
      drive_sample(baseline + amplitude / 2);      -- fast leading edge
      drive_sample(baseline + amplitude);          -- peak
      for i in 1 to 6 * tau_samples loop           -- exponential tail
        a := real(amplitude) * exp(-real(i) / real(tau_samples));
        exit when a < 1.0;
        drive_sample(baseline + integer(a));
      end loop;
      idle(5);                                     -- recover to baseline
    end procedure send_pulse;

    -- check: the scoreboard comparison. Waits a few clocks so the last
    -- sample has flushed through the DUT register and the monitor, then
    -- asserts DUT == model. For directed tests we also pass the count we
    -- expect BY HAND ('total'), which cross-checks the golden model itself;
    -- for random tests total is unknowable in advance, so it defaults off.
    procedure check (
      constant msg   : in string;
      constant total : in integer := -1
    ) is
    begin
      wait for 5 * clk_period;
      if total >= 0 then
        assert expected_count = total
          report "FAIL " & msg & ": golden model expected "
               & integer'image(expected_count) & " but hand count says "
               & integer'image(total) & " - the MODEL is wrong"
          severity failure;
      end if;
      assert fired_count = expected_count
        report "FAIL " & msg & ": DUT fired " & integer'image(fired_count)
             & " times, golden model expected "
             & integer'image(expected_count)
        severity failure;
      report "PASS " & msg & " (running total: "
           & integer'image(fired_count) & " fires)" severity note;
    end procedure check;

    -- Bookkeeping for the random test's coverage sanity check.
    variable count_before : natural;
    variable amp, tau     : integer;

  begin
    ---------------------------------------------------------------------
    -- Test 0: reset behaviour. A huge pulse arrives WHILE rst is high;
    -- the discriminator must stay silent. (A trigger that fires during a
    -- run-control reset would inject fake events into your first spill.)
    ---------------------------------------------------------------------
    rst <= '1';
    idle(3);
    send_pulse(amplitude => 2000, tau_samples => 3);   -- ignored: in reset
    rst <= '0';
    idle(3);
    check("test 0: pulse during reset is ignored", total => 0);

    ---------------------------------------------------------------------
    -- Test 1: the bread and butter. One clean pulse well above threshold
    -- sits above it for many samples — and must fire exactly ONCE.
    ---------------------------------------------------------------------
    send_pulse(amplitude => 1000, tau_samples => 4);
    check("test 1: clean pulse fires exactly once", total => 1);

    ---------------------------------------------------------------------
    -- Tests 2 and 3: the threshold corner, pinned from both sides. The
    -- spec says STRICTLY greater, so a peak exactly AT threshold must not
    -- fire, and threshold+1 must. Off-by-one bugs live and die right here;
    -- a test plan that never lands on the boundary will never catch them.
    -- (Peak = baseline + amplitude, so amplitude = thr_value - baseline
    -- puts the peak exactly on the threshold.)
    ---------------------------------------------------------------------
    send_pulse(amplitude => thr_value - baseline, tau_samples => 4);
    check("test 2: peak exactly at threshold does NOT fire", total => 1);

    send_pulse(amplitude => thr_value - baseline + 1, tau_samples => 4);
    check("test 3: peak at threshold+1 fires", total => 2);

    ---------------------------------------------------------------------
    -- Test 4: a long flat-top pulse (e.g. a saturated PMT) above threshold
    -- for 10 straight samples. One particle, one fire — this is the whole
    -- reason the DUT is an edge detector and not a bare comparator.
    ---------------------------------------------------------------------
    for i in 1 to 10 loop
      drive_sample(baseline + 2000);
    end loop;
    idle(5);
    check("test 4: 10-sample flat top fires exactly once", total => 3);

    ---------------------------------------------------------------------
    -- Test 5: pile-up. Two pulses separated by a SINGLE below-threshold
    -- sample must be resolved as two triggers. Driven by hand rather than
    -- with send_pulse, because we need exact sample-level control here.
    ---------------------------------------------------------------------
    drive_sample(baseline + 900);   -- pulse 1: above
    drive_sample(baseline + 700);   --          still above
    drive_sample(baseline + 200);   -- one sample below threshold...
    drive_sample(baseline + 900);   -- pulse 2: above again
    drive_sample(baseline + 700);
    idle(5);
    check("test 5: back-to-back pulses resolved as two", total => 5);

    ---------------------------------------------------------------------
    -- Test 6: randomized stimulus. 40 pulses with random amplitudes that
    -- deliberately STRADDLE the threshold (peaks from below it to well
    -- above), random decay constants, and noise switched on. We cannot
    -- hand-count the answer — that is the golden model's job: it saw every
    -- noisy sample and kept score. Directed tests catch the bugs you
    -- thought of; random tests catch the ones you didn't.
    ---------------------------------------------------------------------
    noise_on := true;
    count_before := expected_count;
    for i in 1 to 40 loop
      rand_int(200, 800, amp);   -- peak = 300..900 counts vs threshold 500
      rand_int(2, 6, tau);
      send_pulse(amplitude => amp, tau_samples => tau);
    end loop;
    noise_on := false;

    -- Coverage sanity check: a random test that happened to generate only
    -- sub-threshold pulses would "pass" while exercising nothing. That
    -- deserves a WARNING — the test is not wrong, but it proved nothing.
    if expected_count = count_before then
      report "random test produced zero above-threshold pulses - "
           & "coverage hole, consider different seeds"
        severity warning;
    end if;
    check("test 6: 40 random noisy pulses match golden model");

    ---------------------------------------------------------------------
    -- The line every testbench in this course must print on success —
    -- and only reachable if every assert above held.
    ---------------------------------------------------------------------
    report "ALL TESTS PASSED";
    finish;   -- stop the clock, end the simulation, exit cleanly
  end process stimulus;

end architecture sim;
