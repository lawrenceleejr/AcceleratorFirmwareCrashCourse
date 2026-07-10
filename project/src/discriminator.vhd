-- discriminator.vhd
--
-- Leading-edge threshold discriminator with one-shot edge detection.
--
-- Physics context: this is the firmware version of the NIM discriminator
-- module that every counting experiment starts with. The analog original
-- compares the PMT signal against a threshold voltage and emits a logic
-- pulse on the leading edge. Here the comparison happens on digitized,
-- pedestal-subtracted samples instead of an analog waveform.
--
-- The crucial detail is the ONE-SHOT: a scintillator pulse is tens of
-- samples wide, so "sample >= threshold" stays true for many consecutive
-- clock cycles. If we used that comparison directly as the trigger, one
-- physical pulse would trigger the readout dozens of times. What we want is
-- a single one-clock pulse at the moment the waveform CROSSES the threshold
-- going up. The standard idiom: remember whether we were above threshold on
-- the previous cycle, and fire only on the 0 -> 1 transition:
--
--     trig = above_now and not above_previously
--
-- This is the same rising-edge-detector pattern from Module 03, applied to
-- a comparator output instead of an external signal. The discriminator
-- cannot re-fire until the waveform falls back below threshold -- exactly
-- the behavior of the analog module it replaces.
--
-- As with the pedestal, the threshold is a PORT (run-time slow control),
-- not a generic: threshold scans are a standard commissioning procedure and
-- must not require a rebuild.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity discriminator is
  port (
    clk       : in  std_logic;
    rst       : in  std_logic;                 -- active-high, synchronous
    sample_in : in  unsigned(11 downto 0);     -- pedestal-subtracted sample
    threshold : in  unsigned(11 downto 0);     -- firing threshold (slow control)
    trig      : out std_logic                  -- one-clock pulse per crossing
  );
end entity discriminator;

architecture rtl of discriminator is

  -- Comparator output: are we at or above threshold right now?
  signal above   : std_logic;
  -- The same, one clock ago (a single flip-flop of history).
  signal above_q : std_logic;

begin

  -- The comparator itself is combinational: a 12-bit magnitude compare,
  -- always computing, like the front-end comparator chip it models.
  above <= '1' when sample_in >= threshold else '0';

  -- Register the history bit and the output. Registering trig means the
  -- trigger is a clean, glitch-free synchronous pulse -- important, because
  -- three separate downstream blocks (ring buffer, event builder) act on it
  -- and they must all see exactly the same one-cycle pulse.
  one_shot : process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        above_q <= '0';
        trig    <= '0';
      else
        above_q <= above;
        -- Fire exactly once, on the cycle the comparison goes 0 -> 1.
        trig    <= above and not above_q;
      end if;
    end if;
  end process one_shot;

end architecture rtl;
