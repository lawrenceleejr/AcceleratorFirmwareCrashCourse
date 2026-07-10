-- moving_average.vhd
--
-- An N-sample moving average (box filter): the simplest digital pulse
-- shaping there is, and the second thing every digitizer front end does to
-- its samples (right after pedestal subtraction).
--
-- Physics context: averaging the last N samples suppresses white noise by
-- a factor sqrt(N) at the cost of smearing the pulse in time -- exactly the
-- trade a shaping amplifier made in the analog era. Trigger filters in real
-- digitizers (trapezoidal filters, CFDs) are built from exactly the pieces
-- in this file: delay lines, running sums, and shifts.
--
-- Three hardware lessons live in here:
--
--   1. BIT GROWTH. Summing 2**k values of 12 bits needs 12+k bits -- no
--      more, no less. We size the accumulator exactly. Too narrow and it
--      wraps silently (garbage); too wide and you pay area for nothing.
--
--   2. DIVISION BY A POWER OF TWO IS FREE. Averaging divides by the window
--      length. If the window is 2**k, "dividing" is just not connecting the
--      bottom k wires -- zero gates, zero delay. A true divider is a huge,
--      slow circuit (or many pipeline stages of IP). This is why the window
--      is a GENERIC given as log2: the architecture makes non-power-of-two
--      windows unrepresentable.
--
--   3. LATENCY. The output is a registered pipeline: a given sample first
--      influences the output two clocks after it is captured, and the
--      average is "centered" half a window in the past. Fine for DAQ
--      readout; in a trigger path you must ACCOUNT for it, because every
--      trigger pipeline is a fixed-latency contract (the event buffer must
--      hold samples long enough for the delayed trigger to arrive).
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity moving_average is
  generic (
    -- log2 of the window length: window = 2**LOG2_WINDOW samples.
    -- Default 2 -> a 4-sample box filter.
    LOG2_WINDOW : natural := 2
  );
  port (
    clk        : in  std_logic;               -- 100 MHz DAQ clock
    rst        : in  std_logic;               -- active-high synchronous reset
    sample_in  : in  unsigned(11 downto 0);   -- one sample per clock
    sample_out : out unsigned(11 downto 0)    -- average of the last window
  );
end entity moving_average;

architecture rtl of moving_average is

  -- Derived constants. Naming them makes the bit-growth arithmetic visible
  -- instead of burying magic numbers in ranges.
  constant window_c    : natural := 2**LOG2_WINDOW;
  constant sum_width_c : natural := 12 + LOG2_WINDOW;  -- exact: the sum of
                                                       -- 2**k 12-bit values
                                                       -- is at most
                                                       -- 2**k * (2**12 - 1),
                                                       -- which fits in
                                                       -- 12 + k bits

  -- The delay line: the last window_c samples, taps(0) newest. In hardware
  -- this is a chain of 12-bit registers (or an SRL shift-register primitive
  -- on Xilinx parts -- the tools infer it).
  type tap_array_t is array (0 to window_c - 1) of unsigned(11 downto 0);
  signal taps : tap_array_t := (others => (others => '0'));

  -- The running sum of everything currently in the delay line. The trick
  -- that makes this filter cheap: instead of re-adding all window_c taps
  -- every clock (an adder tree that grows with the window), we ADD THE
  -- NEWEST sample and SUBTRACT THE OLDEST. Cost per clock: one adder and
  -- one subtractor, for ANY window length.
  signal running_sum : unsigned(sum_width_c - 1 downto 0) := (others => '0');

begin

  filter : process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        taps        <= (others => (others => '0'));
        running_sum <= (others => '0');
        sample_out  <= (others => '0');
      else
        -- Pipeline stage 1: shift the delay line and update the running sum.
        -- Remember Module 03: every right-hand side below reads the OLD
        -- (pre-edge) value of every signal, so taps(window_c - 1) here is
        -- the sample about to fall off the end -- exactly the one to
        -- subtract.
        taps(0)                 <= sample_in;
        taps(1 to window_c - 1) <= taps(0 to window_c - 2);

        -- numeric_std sizing rule at work: "a + b" is as wide as the WIDER
        -- operand. running_sum is already sum_width_c bits -- sized for the
        -- worst case -- so adding a 12-bit sample keeps sum_width_c bits and
        -- the carry-out has somewhere to go. Had running_sum been 12 bits,
        -- this line would compile, synthesize, and silently wrap.
        running_sum <= running_sum + sample_in - taps(window_c - 1);

        -- Pipeline stage 2: divide by the window length and register the
        -- result. Dividing by 2**k is taking a bit slice -- we simply do not
        -- connect the bottom k wires. Free. Instant. (Equivalently:
        -- resize(shift_right(running_sum, LOG2_WINDOW), 12).) Note this
        -- truncates toward zero, like integer division -- the testbench's
        -- golden model must match that, and so must yours.
        sample_out <= running_sum(sum_width_c - 1 downto LOG2_WINDOW);

        -- Because sample_out registers the OLD running_sum while the new
        -- one is computed, the two stages overlap: a new averaged sample
        -- emerges every clock (full throughput), each one 2 clocks after
        -- the newest raw sample it contains (fixed latency). Throughput
        -- and latency are different numbers -- keep them separate in your
        -- head and in your trigger timing spreadsheet.
      end if;
    end if;
  end process filter;

end architecture rtl;
