-- adc_model.vhd
--
-- ============================================================
--  SIMULATION-ONLY fake ADC.  *** NOT SYNTHESIZABLE. ***
--  It uses ieee.math_real (floating point, random numbers) --
--  none of which exists as hardware. It lives in tb/, never
--  in src/, and must never be handed to Vivado.
-- ============================================================
--
-- This entity plays the role of the physical digitizer chip in front of the
-- DAQ channel: one 12-bit sample per clock, forever. Between pulses it
-- produces a quiet baseline of ~BASELINE counts with a few counts of
-- uniform noise. When `fire` is pulsed high for one clock, it superimposes
-- a scintillator-like pulse: a fast rise over ~4 samples up to `amplitude`
-- counts, then an exponential decay with a ~10-sample time constant --
-- roughly what a PMT-on-plastic-scintillator signal looks like after a
-- 100 MS/s digitizer.
--
-- The amplitude is a PORT so the testbench can shoot both large pulses
-- (above the discriminator threshold) and small ones (below it, like a
-- gamma or a dark count) at the same channel.
--
-- Reproducibility matters in verification just as in analysis: the noise
-- generator seeds are FIXED constants, so every run of the testbench sees
-- bit-for-bit identical data. A test that only fails on Tuesdays helps
-- no one.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;   -- SIMULATION ONLY: reals, exp(), uniform()

entity adc_model is
  generic (
    BASELINE   : natural := 200;  -- quiet-baseline level, ADC counts
    NOISE_SPAN : natural := 3     -- noise is uniform in [-NOISE_SPAN, +NOISE_SPAN]
  );
  port (
    clk       : in  std_logic;
    fire      : in  std_logic;                 -- one-clock pulse: emit a pulse
    amplitude : in  unsigned(11 downto 0);     -- peak height above baseline
    adc_data  : out unsigned(11 downto 0)      -- one sample per rising edge
  );
end entity adc_model;

architecture sim of adc_model is
begin

  -- Everything lives in process VARIABLES: this is a behavioral model, a
  -- little simulation script that happens to run once per clock edge --
  -- exactly the software-style code that is illegal in synthesizable RTL.
  sample_gen : process (clk)
    -- Fixed seeds => identical "noise" every run (see header).
    variable seed1   : positive := 42;
    variable seed2   : positive := 12345;
    variable rand    : real;
    variable noise   : real;
    variable pulsing : boolean := false;   -- a pulse is in progress
    variable t       : natural := 0;       -- samples since the pulse started
    variable amp     : real    := 0.0;     -- latched pulse amplitude
    variable pulse   : real;
    variable total   : real;
  begin
    if rising_edge(clk) then

      -- Baseline noise: uniform() returns rand in [0,1); map it to
      -- an integer-ish offset in [-NOISE_SPAN, +NOISE_SPAN].
      uniform(seed1, seed2, rand);
      noise := round(rand * real(2 * NOISE_SPAN)) - real(NOISE_SPAN);

      -- A fire request (re)starts the pulse and latches its amplitude,
      -- so back-to-back fires model pile-up crudely but adequately.
      if fire = '1' then
        pulsing := true;
        t       := 0;
        amp     := real(to_integer(amplitude));
      end if;

      -- The pulse shape. Not a precision detector model -- just the right
      -- topology: fast leading edge, slow exponential tail.
      pulse := 0.0;
      if pulsing then
        if t < 4 then
          pulse := amp * real(t + 1) / 4.0;        -- fast rise: 4 samples to peak
        else
          pulse := amp * exp(-real(t - 3) / 10.0); -- decay, tau ~ 10 samples
          if pulse < 1.0 then
            pulsing := false;                      -- tail below 1 count: done
          end if;
        end if;
        t := t + 1;
      end if;

      -- Sum, clamp to the 12-bit ADC range, and "digitize".
      total := real(BASELINE) + noise + pulse;
      if total < 0.0 then
        total := 0.0;
      elsif total > 4095.0 then
        total := 4095.0;                           -- ADC saturation
      end if;
      adc_data <= to_unsigned(integer(round(total)), 12);

    end if;
  end process sample_gen;

end architecture sim;
