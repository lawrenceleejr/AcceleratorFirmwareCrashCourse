-- tb_latches.vhd
--
-- One self-checking testbench for all three units of Module 10:
--
--   1. sr_latch         — set / hold / reset / hold: memory from feedback;
--   2. d_latch          — transparency while en='1', hold while en='0';
--   3. latch_trap(+fix) — the inferred-latch bug caught red-handed: the
--                         buggy mux "remembers" a stale gain code, the
--                         fixed one doesn't.
--
-- No clock anywhere: everything here is level-sensitive, so plain
-- "wait for 10 ns" steps (as in Module 01's testbench) are all we need.
--
library ieee;
use ieee.std_logic_1164.all;

entity tb_latches is
end entity tb_latches;

architecture sim of tb_latches is

  -- sr_latch wiring. s and r start '0' (both inactive = the hold state),
  -- so until the first set pulse both outputs sit at 'U' — honest
  -- simulation of a latch's random power-up state.
  signal s, r, q_sr, q_bar_sr : std_logic := '0';

  -- d_latch wiring.
  signal en, d, q_d : std_logic := '0';

  -- latch_trap wiring: ONE set of inputs drives BOTH the buggy and the
  -- fixed mux, so any difference between their outputs is pure bug.
  signal sel                  : std_logic := '0';
  signal gain_low, gain_high  : std_logic_vector(3 downto 0) := x"0";
  signal gain_buggy, gain_ok  : std_logic_vector(3 downto 0);

begin

  dut_sr : entity work.sr_latch
    port map ( s => s, r => r, q => q_sr, q_bar => q_bar_sr );

  dut_d : entity work.d_latch
    port map ( en => en, d => d, q => q_d );

  dut_buggy : entity work.latch_trap
    port map ( sel => sel, gain_low => gain_low,
               gain_high => gain_high, gain => gain_buggy );

  dut_fixed : entity work.latch_trap_fixed
    port map ( sel => sel, gain_low => gain_low,
               gain_high => gain_high, gain => gain_ok );

  stimulus : process
  begin

    ------------------------------------------------------------------
    -- Part 1: the SR latch — watch memory emerge from two NOR gates.
    --
    -- We step through set / hold / reset / hold. Note what we do NOT do:
    -- we never drive s=r='1' and then drop both at once. That forbidden
    -- race would kick the feedback pair onto the potential barrier —
    -- in GHDL, an infinite delta-cycle oscillation (q and q_bar flipping
    -- forever with simulated time frozen; the run would simply hang).
    -- Metastability, as rendered by a simulator.
    ------------------------------------------------------------------

    -- Set: pulse s. The 'U' power-up state resolves here too.
    s <= '1';  r <= '0';
    wait for 10 ns;
    assert q_sr = '1' and q_bar_sr = '0'
      report "FAIL: SR latch did not set" severity failure;

    -- Release s: both inputs now inactive, yet q stays '1'. Nothing is
    -- driving this value anymore — the feedback loop alone holds it.
    -- This is the moment "memory" happens.
    s <= '0';
    wait for 10 ns;
    assert q_sr = '1' and q_bar_sr = '0'
      report "FAIL: SR latch forgot the set (hold state broken)" severity failure;

    -- Reset: pulse r. The ball is tipped into the other well.
    r <= '1';
    wait for 10 ns;
    assert q_sr = '0' and q_bar_sr = '1'
      report "FAIL: SR latch did not reset" severity failure;

    -- Release r: holds the '0' just as faithfully.
    r <= '0';
    wait for 10 ns;
    assert q_sr = '0' and q_bar_sr = '1'
      report "FAIL: SR latch forgot the reset (hold state broken)" severity failure;

    ------------------------------------------------------------------
    -- Part 2: the D latch — transparent, then frozen.
    ------------------------------------------------------------------

    -- Open the latch and change d twice: q must follow each change,
    -- because a transparent latch is an open window, not a sampler.
    -- (A D flip-flop given the same stimulus would update only at clock
    -- edges — this continuous following is exactly what "level-sensitive
    -- vs edge-triggered" means.)
    en <= '1';  d <= '1';
    wait for 10 ns;
    assert q_d = '1'
      report "FAIL: D latch not transparent (missed d rising)" severity failure;

    d <= '0';
    wait for 10 ns;
    assert q_d = '0'
      report "FAIL: D latch not transparent (missed d falling)" severity failure;

    d <= '1';
    wait for 10 ns;
    assert q_d = '1'
      report "FAIL: D latch not transparent (missed second d rising)" severity failure;

    -- Close the latch: q freezes at the value d had when en fell ('1').
    en <= '0';
    wait for 10 ns;
    assert q_d = '1'
      report "FAIL: D latch did not hold when en fell" severity failure;

    -- Wiggle d with the latch closed: q must not move.
    d <= '0';
    wait for 10 ns;
    assert q_d = '1'
      report "FAIL: D latch leaked d='0' while closed" severity failure;

    d <= '1';  -- wiggle back up too, for good measure
    wait for 10 ns;
    assert q_d = '1'
      report "FAIL: D latch changed while closed" severity failure;

    ------------------------------------------------------------------
    -- Part 3: the inferred-latch bug, live.
    --
    -- Same inputs into the buggy mux and the fixed mux; watch them
    -- disagree the moment history starts to matter.
    ------------------------------------------------------------------

    -- Select high gain. Both muxes agree — the bug is invisible here,
    -- which is precisely what makes it dangerous: the sel='1' path was
    -- written, so while sel='1' everything looks fine.
    gain_low  <= x"1";
    gain_high <= x"8";
    sel       <= '1';
    wait for 10 ns;
    assert gain_ok = x"8"
      report "FAIL: fixed mux wrong for sel='1'" severity failure;
    assert gain_buggy = x"8"
      report "FAIL: buggy mux wrong even on its written path" severity failure;

    -- Now select low gain. The fixed mux switches to x"1". The buggy one
    -- has NO assignment on the sel='0' path, so its inferred latch closes
    -- and 'gain' stays frozen at the STALE high-gain code x"8".
    -- (Yes, we assert the WRONG value on purpose — this check proves the
    -- unintended memory exists.)
    sel <= '0';
    wait for 10 ns;
    assert gain_ok = x"1"
      report "FAIL: fixed mux did not switch to low gain" severity failure;
    assert gain_buggy = x"8"
      report "FAIL: expected buggy mux to hold stale x8 (did someone fix the bug?)"
      severity failure;

    -- Rub it in: change the low-gain code while sel='0'. The fixed mux
    -- tracks its selected input, as a mux must. The buggy one doesn't
    -- even read gain_low on this path — still stuck at x"8". Your
    -- physics run is now silently taking data at calibration gain.
    gain_low <= x"2";
    wait for 10 ns;
    assert gain_ok = x"2"
      report "FAIL: fixed mux did not track gain_low" severity failure;
    assert gain_buggy = x"8"
      report "FAIL: expected buggy mux still stuck at stale x8" severity failure;

    report "ALL TESTS PASSED";
    wait;  -- halt this process forever = end of test
  end process stimulus;

end architecture sim;
