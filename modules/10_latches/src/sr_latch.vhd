-- sr_latch.vhd
--
-- The SR (set/reset) latch: the simplest possible memory element.
--
-- Two NOR gates, each one's output feeding the other's input. That's it.
-- No clock, no special "storage" primitive — memory emerges purely from
-- FEEDBACK. Physics framing: this is a bistable system. The cross-coupled
-- pair creates a potential landscape with two stable wells (q='1'/q_bar='0'
-- and q='0'/q_bar='1'); a pulse on s or r tips the ball into one well, and
-- when the pulse ends the ball STAYS there. That is all "remembering a bit"
-- physically is. (Module 08 drew exactly this two-well picture for
-- metastability — same system, same physics.)
--
-- Truth table (NOR-based SR latch, both inputs active-high):
--
--   s  r  |  q        q_bar
--   0  0  |  hold     hold      <- the memory state: outputs keep whatever
--                                  they were. THIS is the interesting row.
--   1  0  |  1        0         <- set
--   0  1  |  0        1         <- reset
--   1  1  |  0        0         <- "forbidden": q and q_bar are no longer
--                                  complements, and worse, see below.
--
-- The forbidden race: if s and r are both '1' and then drop to '0' at the
-- SAME instant, both NOR outputs try to rise together, each rise drives the
-- other back down, and the pair oscillates — or, in a real chip, hangs
-- balanced on top of the potential barrier between the two wells: it is
-- kicked into METASTABILITY (Module 08). In GHDL that race becomes an
-- infinite loop of delta cycles: q and q_bar flip 0->1->0->1 forever without
-- simulated time advancing, and the simulator never returns. That's the
-- simulator's version of metastability, and it's why the testbench
-- deliberately never releases s and r simultaneously.
--
-- For all LEGAL input sequences, the feedback converges in a couple of
-- delta cycles (Module 01's "assignment takes a delta of time"), so this
-- structural description simulates fine.
--
-- NOTE: this file is here so you understand where storage COMES FROM. You
-- will never hand-instantiate an SR latch in FPGA firmware — read the
-- README for why.
--
library ieee;
use ieee.std_logic_1164.all;

entity sr_latch is
  port (
    s     : in  std_logic;  -- set   (active high): force q to '1'
    r     : in  std_logic;  -- reset (active high): force q to '0'
    q     : out std_logic;  -- the stored bit
    q_bar : out std_logic   -- its complement (comes free with the structure)
  );
end entity sr_latch;

architecture rtl of sr_latch is

  -- The two storage nodes. At time zero neither has been driven, so both
  -- are 'U' — which is honest: a real latch powers up in a RANDOM state.
  -- The 'U' clears the first time s or r is pulsed ('U' nor '1' = '0',
  -- and the feedback then resolves the other node too).
  signal q_i, qb_i : std_logic;

begin

  -- Two concurrent assignments = two physical NOR gates. Note the FEEDBACK:
  -- each gate reads the other's output. Textual order is irrelevant
  -- (Module 01) — these are two gates soldered to each other, both always
  -- computing. There is no "first line runs first"; the pair settles to a
  -- fixed point via delta cycles.
  q_i  <= r nor qb_i;   -- q     = NOR(reset, q_bar)
  qb_i <= s nor q_i;    -- q_bar = NOR(set,   q)

  q     <= q_i;
  q_bar <= qb_i;

end architecture rtl;
