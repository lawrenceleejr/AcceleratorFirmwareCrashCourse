-- discriminator.vhd
--
-- A digital leading-edge discriminator: the front end of every digitizer
-- trigger you will ever meet.
--
-- Physics context: a 12-bit ADC digitizes a PMT (or SiPM, or BPM pickup)
-- waveform at one sample per clock. We want a trigger that fires when a
-- pulse arrives — i.e. when the waveform CROSSES the threshold from below.
--
-- The crucial design decision is the word "crosses". A scintillator pulse
-- is tens of nanoseconds wide; at 100 MS/s it sits above threshold for
-- MANY consecutive samples. A naive comparator
--
--     fired <= '1' when adc_data > threshold else '0';        -- WRONG idea
--
-- would therefore be high for the entire pulse — and a counter downstream
-- would count one particle as five or six "triggers". What we want is one
-- clean, one-clock-wide pulse per PARTICLE, not per SAMPLE. That means
-- detecting the below-to-above EDGE of the comparison, which needs one bit
-- of memory: "was I above threshold on the previous sample?"
--
-- The DUT is deliberately small. This module is really about the
-- testbench (tb/tb_discriminator.vhd) — go read that next.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity discriminator is
  port (
    clk       : in  std_logic;
    rst       : in  std_logic;                  -- active-high, synchronous
    adc_data  : in  unsigned(11 downto 0);      -- one ADC sample per clock
    threshold : in  unsigned(11 downto 0);      -- run-time programmable level
    fired     : out std_logic                   -- ONE clock high per crossing
  );
end entity discriminator;

architecture rtl of discriminator is

  -- Combinational comparison: is the CURRENT sample above threshold?
  signal above      : std_logic;

  -- One flip-flop of memory: was the PREVIOUS sample above threshold?
  signal above_prev : std_logic := '0';

begin

  -- The comparator. numeric_std's ">" on unsigned gives a boolean, which we
  -- convert to std_logic with a conditional assignment. Note the spec is
  -- STRICTLY greater: a sample sitting exactly at threshold does not count.
  -- (The testbench pins this corner down explicitly.)
  above <= '1' when adc_data > threshold else '0';

  -- The edge detector: fire only on the below-to-above transition.
  -- Registering the output (Module 03) costs one clock of latency and buys
  -- a glitch-free, full-cycle-wide trigger pulse that downstream logic can
  -- sample safely.
  edge_detect : process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        above_prev <= '0';
        fired      <= '0';
      else
        -- "above now AND NOT above before" = rising edge of the comparison.
        -- One pulse per particle, however long the pulse tail loiters
        -- above threshold.
        fired      <= above and not above_prev;
        above_prev <= above;
      end if;
    end if;
  end process edge_detect;

end architecture rtl;
