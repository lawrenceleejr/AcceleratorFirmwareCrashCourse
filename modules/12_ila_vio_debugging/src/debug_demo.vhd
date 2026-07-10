-- debug_demo.vhd
--
-- "The thing you'd debug": a mini trigger path, chosen to be small enough to
-- read in one sitting and rich enough to have somewhere for a real bug to
-- hide. It is the stand-in for whatever board is misbehaving in the crate.
--
-- Physics context: a trigger arrives, the front end goes BUSY while it
-- processes the event (8 cycles here), then enforces a COOLDOWN (4 cycles)
-- before it will accept another -- the dead time of Modules 03 and 05.
-- Triggers that arrive while busy are LOST, and a good DAQ counts them so you
-- know how much beam you threw away.
--
--   trig_count : every accepted trigger (events you kept)
--   lost_count : every trigger that arrived while busy (events you dropped)
--
-- The bubble diagram:
--
--            trigger_in='1'         after 8 cycles       after 4 cycles
--      +------+          +------------+          +----------+
--   -->| IDLE |--------->| PROCESSING |--------->| COOLDOWN |
--      +------+          +------------+          +----------+
--        ^                                            |
--        +--------------------------------------------+
--
-- What makes this file the LESSON is not the logic -- it is the handful of
-- `mark_debug` attributes below. They are the teaching vehicle for Module 12:
-- in simulation they do nothing (GHDL parses the attribute, sees it does not
-- recognise it, and simply carries it along), but Vivado's synthesizer reads
-- them as "keep this net and expose it for a debug core". See the README.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity debug_demo is
  generic (
    -- Sized small so the whole envelope fits in one glance and one short
    -- simulation. Real front ends use bigger numbers; same machine.
    PROCESS_CYCLES  : natural := 8;   -- busy-while-processing window, in clocks
    COOLDOWN_CYCLES : natural := 4    -- enforced dead time after processing
  );
  port (
    clk        : in  std_logic;                 -- 100 MHz system clock, rising edge
    rst        : in  std_logic;                 -- active-high synchronous reset
    trigger_in : in  std_logic;                 -- from the discriminator / cable
    busy       : out std_logic;                 -- high whenever not IDLE = dead time
    trig_count : out unsigned(15 downto 0);     -- accepted triggers since reset
    lost_count : out unsigned(15 downto 0)      -- triggers dropped while busy
  );
end entity debug_demo;

architecture rtl of debug_demo is

  -- Enumerated state type: the simulator (and, if you ask it to, Vivado's
  -- waveform viewer) can show the state by NAME. Keep the encoding mapping
  -- written down for when you read it as raw bits on an ILA -- see README.
  type state_t is (idle, processing, cooldown);
  signal state : state_t := idle;

  -- Step counter shared by the two timed states.
  signal step_cnt : unsigned(15 downto 0) := (others => '0');

  -- Internal copies of the scaler outputs. We keep the count as an internal
  -- signal (rather than reading the 'out' port back) so it is a clean net to
  -- probe, and so mark_debug has an obvious target.
  signal trig_cnt_r : unsigned(15 downto 0) := (others => '0');
  signal lost_cnt_r : unsigned(15 downto 0) := (others => '0');
  signal busy_r     : std_logic := '0';

  -- ==== THE POINT OF THE MODULE ==============================================
  -- Xilinx debug attribute. Declaring the attribute name once, then tagging
  -- the specific nets we want the ILA to reach. `mark_debug = "true"` tells
  -- synthesis: do NOT optimize this net away, do NOT merge or rename it, keep
  -- it as a real, nameable wire so the "Set Up Debug" wizard can hang a probe
  -- on it. In SIMULATION these lines are inert -- GHDL carries an unknown
  -- attribute along and changes nothing. On HARDWARE they cost you: a marked
  -- net cannot be optimized, so leaving these in a production build wastes
  -- logic and can hurt timing. Mark while debugging; strip for the run.
  attribute mark_debug : string;
  attribute mark_debug of state      : signal is "true";
  attribute mark_debug of busy_r     : signal is "true";
  attribute mark_debug of trig_cnt_r : signal is "true";
  attribute mark_debug of lost_cnt_r : signal is "true";
  attribute mark_debug of step_cnt   : signal is "true";
  -- ===========================================================================

begin

  -- One clocked process: the whole machine and both scalers are flip-flops
  -- updated on the rising edge. Single-process FSM style, exactly as Module 05.
  fsm : process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state      <= idle;
        step_cnt   <= (others => '0');
        trig_cnt_r <= (others => '0');
        lost_cnt_r <= (others => '0');
        busy_r     <= '0';
      else

        case state is

          when idle =>
            -- The only state that ACCEPTS a trigger. Count it, go busy.
            busy_r <= '0';
            if trigger_in = '1' then
              trig_cnt_r <= trig_cnt_r + 1;     -- kept event
              step_cnt   <= (others => '0');
              busy_r     <= '1';                -- dead time starts
              state      <= processing;
            end if;

          when processing =>
            -- Busy for PROCESS_CYCLES. A trigger arriving now is LOST.
            busy_r <= '1';
            if trigger_in = '1' then
              lost_cnt_r <= lost_cnt_r + 1;     -- dropped event
            end if;
            if step_cnt = PROCESS_CYCLES - 1 then
              step_cnt <= (others => '0');
              state    <= cooldown;
            else
              step_cnt <= step_cnt + 1;
            end if;

          when cooldown =>
            -- Still busy: enforced dead time. Triggers here are LOST too.
            busy_r <= '1';
            if trigger_in = '1' then
              lost_cnt_r <= lost_cnt_r + 1;
            end if;
            if step_cnt = COOLDOWN_CYCLES - 1 then
              state <= idle;                    -- rearm; busy drops next cycle
            else
              step_cnt <= step_cnt + 1;
            end if;

        end case;
      end if;
    end if;
  end process fsm;

  -- Drive the ports from the registered internal copies. Registered outputs
  -- are glitch-free; the one-cycle pipeline delay is invisible downstream in
  -- a synchronous design (Module 05 makes this argument in full).
  busy       <= busy_r;
  trig_count <= trig_cnt_r;
  lost_count <= lost_cnt_r;

end architecture rtl;
