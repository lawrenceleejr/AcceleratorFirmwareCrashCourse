-- gray_counter.vhd
--
-- A counter whose output changes exactly ONE bit per increment -- the
-- safe way to pass a count across clock domains.
--
-- Why it exists (Module 08 recap): a binary counter going 7 -> 8 flips
-- four bits, 0111 -> 1000. If another clock domain samples that bus
-- through N parallel two-flop synchronizers, each bit resolves
-- independently -- some synchronizers catch the old value, some the new --
-- and the reader can see 0000, 1111, or any other tearing of the two.
-- A gray-coded counter changes ONE bit per step, so however unlucky the
-- sampling, the reader sees either the old value or the new value:
-- off by at most one step, never garbage.
--
-- This is exactly how asynchronous FIFO read/write pointers work -- the
-- xpm_fifo_async macro you used in Module 07 gray-codes its pointers
-- internally before passing them between the two clock domains.
--
-- The conversions (bin and gray both WIDTH bits):
--
--   bin -> gray :  gray = bin xor (bin srl 1)        -- one XOR row, cheap
--   gray -> bin :  bin(i) = gray(W-1) xor ... xor gray(i)
--                  i.e. each binary bit is the XOR of all gray bits at or
--                  above it -- a chain, done in the DESTINATION domain
--                  (or offline) when someone needs the number back.
--
-- Sequence for WIDTH = 4:  bin 0000 0001 0010 0011 0100 ...
--                         gray 0000 0001 0011 0010 0110 ...
-- Note the wrap is safe too: bin 1111 -> 0000 flips four bits, but
-- gray 1000 -> 0000 flips only the MSB. One bit per step, all the way
-- around the circle -- that closure is the whole reason the code exists.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gray_counter is
  generic (
    WIDTH : natural := 4
  );
  port (
    clk  : in  std_logic;
    rst  : in  std_logic;
    en   : in  std_logic;   -- advance one step when '1'
    gray : out std_logic_vector(WIDTH - 1 downto 0)
  );
end entity gray_counter;

architecture rtl of gray_counter is

  -- Internal binary counter: counting stays trivial in binary (+ 1), and
  -- we convert to gray on the way out. Trying to increment directly in
  -- gray code is a puzzle; nobody does it.
  signal bin      : unsigned(WIDTH - 1 downto 0) := (others => '0');
  signal bin_next : unsigned(WIDTH - 1 downto 0);

begin

  -- The next binary value, combinational. Both registers below load from
  -- this same wire, which is what keeps them in lockstep. Free-running
  -- wrap at 2**WIDTH is intended (this is a bookkeeping counter).
  bin_next <= bin + 1;

  count : process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        bin  <= (others => '0');
        gray <= (others => '0');   -- gray code of 0 is 0
      elsif en = '1' then
        bin  <= bin_next;
        -- bin -> gray of the NEXT value, registered alongside it, so
        -- gray always equals bin2gray(bin). shift_right on unsigned is
        -- numeric_std's logical shift; the xor is one gate per bit.
        gray <= std_logic_vector(bin_next xor shift_right(bin_next, 1));
      end if;
    end if;
  end process count;

  -- Design point that is easy to miss: gray MUST be a register, not a
  -- combinational decode of bin. Combinational logic can glitch while it
  -- settles (Module 02), and a glitch on a wire that another clock domain
  -- samples defeats the entire one-bit-per-step guarantee. A flip-flop
  -- output is glitch-free by construction: it moves once per edge, from
  -- one valid gray value to the next.

end architecture rtl;
