-- pedestal_subtract.vhd
--
-- Registered baseline (pedestal) subtraction with a clamp at zero.
--
-- Physics context: a PMT or SiPM sitting on a digitizer input never reads
-- zero between pulses. The DC operating point of the analog chain -- the
-- "pedestal" -- puts the quiet baseline somewhere in the middle of the ADC
-- range (a couple hundred counts is typical). Every downstream decision
-- (thresholds, charge integration, zero suppression) is easier if the quiet
-- baseline sits at zero, so the very first thing DAQ firmware does to a raw
-- sample is subtract the pedestal.
--
-- The subtraction is CLAMPED at zero: if noise dips the raw sample below the
-- pedestal, we output 0 rather than letting unsigned arithmetic wrap around
-- to 4095. An unsigned wraparound here would look like a gigantic pulse and
-- fire the discriminator on every downward noise fluctuation -- a classic,
-- painful bug (Module 06 covers unsigned/signed arithmetic pitfalls).
--
-- Note that the pedestal arrives on a PORT, not a generic. A generic is
-- frozen at synthesis time; a port is a wire you can drive at run time from
-- a slow-control register. Pedestals drift with temperature and HV settings,
-- and operators re-measure them between runs -- nobody wants to rebuild the
-- bitstream for that. (Compared with the Module 06 version, this one is
-- deliberately minimal: subtract, clamp, register -- no averaging.)
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity pedestal_subtract is
  port (
    clk        : in  std_logic;
    rst        : in  std_logic;                -- active-high, synchronous
    sample_in  : in  unsigned(11 downto 0);    -- raw ADC sample
    pedestal   : in  unsigned(11 downto 0);    -- baseline to subtract (slow control)
    -- max(sample_in - pedestal, 0). The default value keeps downstream
    -- comparators quiet at time zero in simulation, before the first edge.
    sample_out : out unsigned(11 downto 0) := (others => '0')
  );
end entity pedestal_subtract;

architecture rtl of pedestal_subtract is
begin

  -- One clocked process = one pipeline stage. The output is REGISTERED:
  -- the subtractor's result is captured into a flip-flop on each rising
  -- edge. That costs one clock cycle of latency (10 ns) but means the
  -- combinational path here is just a 12-bit subtract-and-compare, which
  -- closes timing easily at 100 MHz. In a DAQ pipeline, latency is almost
  -- always cheaper than a failed timing path (Module 03).
  subtract : process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        sample_out <= (others => '0');
      else
        if sample_in >= pedestal then
          sample_out <= sample_in - pedestal;
        else
          -- Clamp: never let the subtraction wrap below zero.
          sample_out <= (others => '0');
        end if;
      end if;
    end if;
  end process subtract;

end architecture rtl;
