-- pedestal_subtract.vhd
--
-- Pedestal (baseline) subtraction with clamp-at-zero: the first arithmetic
-- stage in essentially every waveform digitizer front end.
--
-- Physics context: an ADC never reads zero for "no signal". The analog chain
-- sits at some DC offset -- the PEDESTAL -- typically a few hundred counts,
-- chosen so that noise and slight undershoot don't clip at the bottom of the
-- ADC range. Before you can integrate charge, discriminate, or histogram
-- energies, you subtract that baseline from every sample. At 100 MHz sample
-- rate that is a subtraction every 10 ns, forever: a job for hardware, not
-- for the DAQ PC.
--
-- The interesting part of this module is not the subtraction -- it's the
-- UNDERFLOW. `adc_data - pedestal` on unsigned values goes "negative" the
-- moment noise dips one count below the pedestal, and hardware arithmetic
-- does not throw an exception or promote to a bigger type. It WRAPS,
-- silently, by construction: 250 - 300 on a 12-bit unsigned is 4045. In a
-- physics DAQ that wrap turns a baseline noise dip into a full-scale fake
-- pulse -- a spectacular, hard-to-diagnose artifact. So we compare first and
-- clamp at zero explicitly. Overflow and underflow are ALWAYS your problem
-- in hardware; no language runtime is coming to save you.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;   -- unsigned/signed and their arithmetic. This is
                            -- the ONLY arithmetic library you may use; see
                            -- the module text for why std_logic_arith and
                            -- std_logic_unsigned are banned.

entity pedestal_subtract is
  port (
    clk        : in  std_logic;               -- 100 MHz DAQ clock
    rst        : in  std_logic;               -- active-high synchronous reset
    adc_data   : in  unsigned(11 downto 0);   -- raw ADC sample, one per clock
    pedestal   : in  unsigned(11 downto 0);   -- baseline to remove (from a
                                              -- control register or a
                                              -- baseline-follower circuit)
    sample_out : out unsigned(11 downto 0)    -- max(adc_data - pedestal, 0),
                                              -- one clock cycle late
  );
end entity pedestal_subtract;

architecture rtl of pedestal_subtract is
begin

  -- One register on the output = one cycle of latency. Registering the
  -- result means the comparator and subtractor have a full 10 ns clock
  -- period to settle before anything downstream looks at them -- the basic
  -- move that lets arithmetic run fast (Module 03's register discipline,
  -- applied to math).
  subtract_and_clamp : process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        sample_out <= (others => '0');
      else
        -- Compare-then-subtract. The comparison guarantees the subtraction
        -- can never underflow, so the wrap-around behaviour of unsigned
        -- arithmetic is never exercised. Comparators on unsigned are cheap
        -- (a thin slice of carry-chain logic) -- never hesitate to guard
        -- arithmetic with one.
        if adc_data >= pedestal then
          sample_out <= adc_data - pedestal;   -- result fits: it is <= adc_data
        else
          -- Sample below baseline: negative charge is not physical here,
          -- clamp to zero. (Downward noise fluctuations land in this branch
          -- half the time -- this is the common case, not a corner case.)
          sample_out <= (others => '0');
        end if;

        -- ALTERNATIVE you will meet in real code: widen both operands to
        -- 13-bit SIGNED, subtract, and clamp on the sign bit:
        --
        --   diff := resize(signed('0' & adc_data), 13)
        --         - resize(signed('0' & pedestal), 13);
        --   if diff(12) = '1' then zero else unsigned(diff(11 downto 0));
        --
        -- Same hardware cost to first order (the tools usually merge the
        -- compare and the subtract into one carry chain either way). Prefer
        -- whichever reads more clearly; here the compare-and-clamp states
        -- the physics intent ("no negative samples") directly.
      end if;
    end if;
  end process subtract_and_clamp;

end architecture rtl;
