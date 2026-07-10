-- coincidence.vhd
--
-- A two-channel coincidence unit: the "hello world" of trigger logic.
--
-- Physics context: two scintillator paddles sit above and below a tracking
-- chamber. A cosmic muon passing through the apparatus fires BOTH
-- photomultipliers within the same clock cycle; ambient gamma background
-- usually fires only one. Requiring the coincidence (AND) of the two
-- discriminated PMT signals is the oldest trigger in the book.
--
-- This file demonstrates the two halves of every VHDL design unit:
--   * the ENTITY      - the black-box view: name + ports (like a function
--                       signature, or a chip's pinout)
--   * the ARCHITECTURE - what's inside the box
--
library ieee;
use ieee.std_logic_1164.all;

entity coincidence is
  port (
    pmt_a   : in  std_logic;  -- discriminated pulse from the top paddle
    pmt_b   : in  std_logic;  -- discriminated pulse from the bottom paddle
    trigger : out std_logic   -- high when both fire together
  );
end entity coincidence;

architecture rtl of coincidence is
begin

  -- A CONCURRENT SIGNAL ASSIGNMENT. This is not a statement that "runs";
  -- it describes a physical AND gate whose inputs are permanently soldered
  -- to pmt_a and pmt_b. The gate is always there, always computing.
  trigger <= pmt_a and pmt_b;

end architecture rtl;
