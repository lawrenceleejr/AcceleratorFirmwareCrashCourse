-- pulse_cdc.vhd
--
-- Toggle-based pulse crossing: move a SINGLE-CYCLE pulse from one clock
-- domain to another, safely.
--
-- Physics context: an external trigger pulse is formed in the machine-clock
-- domain (say, the accelerator's distributed bunch clock) and must fire the
-- readout FSM that lives in the DAQ clock domain. The pulse is one clk_src
-- cycle wide. You cannot just wire it across:
--
--   * run it through a plain sync_2ff and, if clk_dst is slower, the pulse
--     can fall entirely BETWEEN two destination clock edges and vanish —
--     the same aliasing you know from the sampling theorem;
--   * even if caught, its width in the new domain would be wrong.
--
-- The classic fix is the TOGGLE trick — convert the pulse to a LEVEL,
-- because levels are the easy case for synchronizers:
--
--   1. In the source domain, flip a toggle flip-flop on every pulse.
--      Each pulse is now encoded as one EDGE of a level signal.
--   2. Synchronize that level into the destination domain with sync_2ff
--      (single bit, changes slowly: exactly what a 2FF synchronizer wants).
--   3. In the destination domain, compare the synchronized level with a
--      one-cycle-delayed copy of itself. Any difference (XOR) means "a
--      toggle happened" -> emit exactly one clk_dst-wide pulse.
--
-- LIMITATION (state it, respect it): consecutive input pulses must be
-- spaced by more than a few clk_dst periods (3-4 to be safe: two for the
-- synchronizer, one for the edge detector, plus margin). Two toggles
-- arriving within that window cancel — the level flips back before the
-- destination domain ever sees the intermediate value, and BOTH pulses are
-- lost. If your triggers can burst faster than that, you need an async
-- FIFO, not this circuit.
--
library ieee;
use ieee.std_logic_1164.all;

entity pulse_cdc is
  port (
    -- source domain -------------------------------------------------------
    clk_src   : in  std_logic;  -- clock the input pulse belongs to
    rst_src   : in  std_logic;  -- active-high synchronous reset, source domain
    pulse_in  : in  std_logic;  -- single clk_src-cycle pulse to transport
    -- destination domain --------------------------------------------------
    clk_dst   : in  std_logic;  -- clock the output pulse must belong to
    rst_dst   : in  std_logic;  -- active-high synchronous reset, destination domain
    pulse_out : out std_logic   -- single clk_dst-cycle pulse, one per pulse_in
  );
end entity pulse_cdc;

architecture rtl of pulse_cdc is

  -- Source-domain toggle: flips state once per input pulse. This is the
  -- ONLY signal that crosses the domain boundary.
  signal toggle_src : std_logic := '0';

  -- Destination-domain copies: the synchronized toggle and a one-cycle
  -- delayed version of it, for edge detection.
  signal toggle_dst      : std_logic := '0';
  signal toggle_dst_prev : std_logic := '0';

begin

  ---------------------------------------------------------------------------
  -- Source domain: pulse -> toggle
  ---------------------------------------------------------------------------
  toggler : process (clk_src)
  begin
    if rising_edge(clk_src) then
      if rst_src = '1' then
        toggle_src <= '0';
      elsif pulse_in = '1' then
        toggle_src <= not toggle_src;  -- one edge per pulse
      end if;
    end if;
  end process toggler;

  ---------------------------------------------------------------------------
  -- The crossing itself: one bit, one audited synchronizer.
  -- Instantiating sync_2ff (rather than writing the two flops inline) keeps
  -- every crossing in the design greppable by entity name — exactly what a
  -- firmware review, or Vivado's report_cdc, wants to see.
  ---------------------------------------------------------------------------
  u_sync : entity work.sync_2ff
    port map (
      clk      => clk_dst,
      async_in => toggle_src,
      sync_out => toggle_dst
    );

  ---------------------------------------------------------------------------
  -- Destination domain: toggle -> pulse (edge detection).
  -- pulse_out is REGISTERED, so it is exactly one clk_dst period wide and
  -- glitch-free — ready to feed an FSM enable directly.
  ---------------------------------------------------------------------------
  edge_detect : process (clk_dst)
  begin
    if rising_edge(clk_dst) then
      if rst_dst = '1' then
        -- Track the synchronized toggle even during reset: if the source
        -- domain toggled while we were held in reset, snapping prev to the
        -- current value swallows that stale edge instead of emitting a
        -- spurious pulse the moment reset releases.
        toggle_dst_prev <= toggle_dst;
        pulse_out       <= '0';
      else
        toggle_dst_prev <= toggle_dst;
        pulse_out       <= toggle_dst xor toggle_dst_prev;  -- '1' for one cycle per edge
      end if;
    end if;
  end process edge_detect;

end architecture rtl;
