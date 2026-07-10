-- latch_trap.vhd
--
-- *** INTENTIONALLY WRONG TEACHING CODE — DO NOT COPY latch_trap ***
--
-- Module 02 warned you about the inferred latch. This file lets you CATCH
-- one alive. It contains two entities:
--
--   * latch_trap       — a deliberately buggy "combinational" mux that
--                        infers a latch (the accident, preserved in amber);
--   * latch_trap_fixed — the same intent written correctly, using the
--                        default-assignment habit from Module 02.
--
-- The scenario: a digitizer front-end has a programmable amplifier, and a
-- control bit selects between a low-gain code (for big calorimeter pulses)
-- and a high-gain code (for single-photoelectron calibration runs). A
-- 2-to-1 mux. Four lines of code. What could go wrong?
--
library ieee;
use ieee.std_logic_1164.all;

entity latch_trap is
  port (
    sel       : in  std_logic;                     -- '1' = high gain
    gain_low  : in  std_logic_vector(3 downto 0);  -- gain code, physics runs
    gain_high : in  std_logic_vector(3 downto 0);  -- gain code, SPE calib
    gain      : out std_logic_vector(3 downto 0)   -- code sent to the amp
  );
end entity latch_trap;

architecture rtl of latch_trap is
begin

  -- THE BUG. The author meant "gain = gain_high when sel else gain_low"
  -- and wrote the sel='1' branch... then got called away to fix the beam.
  bad_mux : process (all)
  begin
    if sel = '1' then
      gain <= gain_high;
    end if;
    -- Missing: what is 'gain' when sel = '0'?  The author never says.
    -- VHDL's answer: "then it keeps its previous value." But combinational
    -- logic HAS no previous value — so the synthesizer must build storage
    -- to honor the description, and it infers a LATCH on 'gain', enabled
    -- by sel. Vivado buries this in the log as:
    --
    --   WARNING: [Synth 8-327] inferring latch(es) for signal or variable
    --   'gain', which holds its previous value in one or more paths...
    --
    -- The result: while sel='1' the mux seems fine (transparent), but the
    -- instant sel drops to '0', 'gain' FREEZES at the last high-gain code
    -- instead of switching to gain_low. Your physics run silently proceeds
    -- at calibration gain. The testbench demonstrates exactly this.
  end process bad_mux;

end architecture rtl;


-- The fix: same ports, same intent, ZERO storage. One habit change.
library ieee;
use ieee.std_logic_1164.all;

entity latch_trap_fixed is
  port (
    sel       : in  std_logic;
    gain_low  : in  std_logic_vector(3 downto 0);
    gain_high : in  std_logic_vector(3 downto 0);
    gain      : out std_logic_vector(3 downto 0)
  );
end entity latch_trap_fixed;

architecture rtl of latch_trap_fixed is
begin

  good_mux : process (all)
  begin
    -- DEFAULT ASSIGNMENT FIRST (Module 02, habit #1): 'gain' now has a
    -- value on EVERY path through this process, no matter what the
    -- branches below do or forget to do. No path without an assignment =
    -- no implied memory = no latch. This one line is the whole fix.
    gain <= gain_low;

    if sel = '1' then
      gain <= gain_high;   -- overrides the default; last assignment wins
    end if;
  end process good_mux;

  -- (Outside a process, "gain <= gain_high when sel = '1' else gain_low;"
  -- is complete by construction and equally latch-proof — Module 02's
  -- other reason to like the concurrent forms.)

end architecture rtl;
