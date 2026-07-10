-- d_latch.vhd
--
-- The D latch, a.k.a. the TRANSPARENT latch: level-sensitive storage.
--
-- Behavior:
--   * while en = '1'  ->  q FOLLOWS d continuously ("transparent": the
--                         latch is an open window, input changes — and
--                         input GLITCHES — pass straight through);
--   * when  en = '0'  ->  q HOLDS whatever d was at the moment en fell.
--
-- Contrast with the D flip-flop you've used since Module 03: a flip-flop is
-- EDGE-triggered — it samples d only in the instant of the clock's rising
-- edge and is opaque at every other time. A latch is LEVEL-sensitive — it
-- is open for the entire half of the time en is high. Internally, a real D
-- flip-flop is built as a MASTER-SLAVE PAIR of these latches on opposite
-- enable phases, so that no direct path from d to q is ever open: the
-- flip-flop you've trusted all course is made of today's subject.
--
-- Structurally, a D latch is just Module's sr_latch with input gating:
--   s = d and en,  r = (not d) and en. This file instead describes it
-- BEHAVIORALLY, using the very code pattern Module 02 taught you to fear:
--
--   *** THE MISSING else BELOW IS INTENTIONAL. ***
--
-- "if en = '1' then q <= d;" with NO else path means: when en /= '1',
-- q keeps its previous value. In a combinational process that implied
-- memory is the classic ACCIDENT (the inferred latch, demonstrated in
-- latch_trap.vhd). Here it is the entire point: we WANT a latch, so we
-- write the incomplete conditional ON PURPOSE and say so in a comment —
-- which is exactly what you must do on the (rare, reviewed, justified)
-- day you ever mean it. An unexplained incomplete conditional is a bug;
-- the comment is what makes this one a design.
--
library ieee;
use ieee.std_logic_1164.all;

entity d_latch is
  port (
    en : in  std_logic;  -- enable / "gate": '1' = transparent, '0' = hold
    d  : in  std_logic;  -- data input
    q  : out std_logic   -- follows d while en='1', frozen while en='0'
  );
end entity d_latch;

architecture rtl of d_latch is
begin

  -- Level-sensitive storage. process(all) makes this re-evaluate whenever
  -- en OR d changes — so while en='1', every wiggle of d propagates to q
  -- (transparency), and the moment en drops, updates stop (hold).
  latch : process (all)
  begin
    if en = '1' then
      q <= d;
    end if;
    -- NO else, DELIBERATELY: "when en='0', q keeps its old value" is the
    -- latch's hold state. A synthesizer maps this to a latch primitive
    -- (LDCE on Xilinx) and will still warn — see the README for the exact
    -- warning text and why, everywhere else in your code, that warning
    -- means you have a bug.
  end process latch;

end architecture rtl;
