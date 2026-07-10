-- prbs7_check.vhd
--
-- Self-synchronizing PRBS-7 checker: locks onto the incoming stream, then
-- counts every bit that disagrees with the prediction.
--
-- The receiving half of the minimum viable link tester (see prbs7_gen.vhd).
-- The clever part is that it needs NO side channel, no shared seed, no
-- "start now" signal -- everything it needs to know is in the received bits
-- themselves. This is the property that makes PRBS testing practical over a
-- real link where the two ends share nothing but the fiber:
--
--   * The generator's output obeys b(t) = b(t-7) xor b(t-6). So if I have
--     seen the last 7 received bits, I can PREDICT the next one.
--   * LOCK phase: shift 7 received bits into a mirror LFSR -- the seed is
--     taken FROM the stream itself, whatever state the generator happens
--     to be in. After 7 clean bits the mirror holds a copy of the far-end
--     generator's state.
--   * COUNT phase: from then on the mirror FREE-RUNS (it feeds back its
--     own prediction, exactly like the generator), and every received bit
--     is compared against the predicted one. Each mismatch is one bit
--     error on the link.
--
-- Design choice worth dwelling on: after lock, the mirror shifts in its own
-- PREDICTED bit, NOT the received bit. If it shifted in received bits, one
-- flipped bit would sit in the register for 7 cycles, corrupt two later
-- predictions as it passed the taps, and a single line error would be
-- counted three times (real PRBS checkers call this error multiplication).
-- Free-running instead means one line error = exactly one count, and the
-- checker STAYS locked -- errors are the measurement, not a reason to
-- panic. The price: if the link is so bad that the 7 seed bits themselves
-- were corrupted, we lock onto garbage and count ~50% errors forever. The
-- exercise in the README adds the real-world fix (automatic resync).
--
-- Honest limitation, worth knowing: a line stuck at '0' seeds the mirror
-- with the LFSR's all-zeros dead state, which "predicts" an endless run of
-- zeros -- and matches. Locked, zero errors, dead link. Production checkers
-- refuse to lock on a seed of all-zeros / all-ones; here we keep the code
-- minimal and note the trap.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity prbs7_check is
  port (
    clk       : in  std_logic;   -- 100 MHz system clock, rising edge
    rst       : in  std_logic;   -- active-high SYNCHRONOUS reset
    rx_bit    : in  std_logic;   -- the received serial stream, 1 bit/clock
    locked    : out std_logic;   -- '1' once the mirror LFSR is seeded
    -- Errored bits seen since lock. SATURATES at 65535 instead of wrapping:
    -- a wrapped counter on a terrible link reads "3" and looks healthy,
    -- while a pegged 65535 unambiguously reads "off scale" -- the same
    -- reason lab scalers saturate. Cleared only by reset.
    err_count : out unsigned(15 downto 0)
  );
end entity prbs7_check;

architecture rtl of prbs7_check is

  -- The mirror LFSR. During lock it is a plain shift register capturing
  -- received bits (hist(0) = newest, hist(6) = oldest); after lock it is a
  -- free-running twin of the far-end generator.
  signal hist : std_logic_vector(6 downto 0) := (others => '0');

  -- How many seed bits have been shifted in so far (0..7).
  signal seed_cnt : natural range 0 to 7 := 0;

  -- Internal copies of the outputs, so the logic below can read them.
  signal locked_i : std_logic := '0';
  signal err_i    : unsigned(15 downto 0) := (others => '0');

  -- The predicted next bit, from the recurrence b(t) = b(t-7) xor b(t-6):
  -- hist(6) holds the bit from 7 cycles ago, hist(5) from 6 cycles ago.
  -- Combinational (concurrent) -- it tracks hist continuously.
  signal predicted : std_logic;

begin

  predicted <= hist(6) xor hist(5);

  check : process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        hist     <= (others => '0');
        seed_cnt <= 0;
        locked_i <= '0';
        err_i    <= (others => '0');
      else
        if locked_i = '0' then
          -- LOCK phase: seed the mirror from the stream itself.
          hist <= hist(5 downto 0) & rx_bit;
          if seed_cnt = 6 then
            -- This edge shifts in the 7th received bit: the mirror now
            -- holds the generator's state and predictions are valid from
            -- the next cycle on.
            locked_i <= '1';
          else
            seed_cnt <= seed_cnt + 1;
          end if;
        else
          -- COUNT phase: free-run the mirror (identical feedback to the
          -- generator) and score each received bit against the prediction.
          hist <= hist(5 downto 0) & predicted;
          if predicted /= rx_bit then
            if err_i /= to_unsigned(65535, 16) then
              err_i <= err_i + 1;    -- one mismatch = one errored bit
            end if;
            -- else: pegged at 65535 -- saturate, never wrap.
          end if;
        end if;
      end if;
    end if;
  end process check;

  locked    <= locked_i;
  err_count <= err_i;

end architecture rtl;
