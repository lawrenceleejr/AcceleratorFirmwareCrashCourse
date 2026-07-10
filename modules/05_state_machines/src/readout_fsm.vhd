-- readout_fsm.vhd
--
-- A triggered-readout controller: the beating heart of every DAQ front end.
--
-- Physics context: a waveform digitizer samples a PMT continuously into a
-- ring buffer (you'll build that buffer in Module 07). When the trigger
-- fires, the front end must perform a SEQUENCE of actions:
--
--   1. keep digitizing for a while, so the post-trigger tail of the pulse
--      lands in the buffer (CAPTURE_CYCLES clock cycles);
--   2. read the event out of the buffer, one word per clock
--      (SAMPLE_COUNT read strobes);
--   3. do one cycle of bookkeeping (bump the event counter, announce the
--      event is done);
--   4. rearm and go back to waiting.
--
-- "Do this, THEN that, THEN the other" is trivial in software: the program
-- counter walks down the page for free. Hardware has no program counter --
-- every circuit you describe runs every cycle, forever. To get sequence you
-- must BUILD your own program counter: a register that remembers "which
-- step am I on" plus logic that decides the next step. That construction is
-- a FINITE STATE MACHINE (FSM), and it is THE answer to "how do I write a
-- sequential algorithm in hardware?".
--
-- The bubble diagram (always draw this BEFORE writing any code):
--
--            trigger='1'              after CAPTURE_CYCLES cycles
--      +------+        +-----------+        +---------+
--   -->| IDLE |------->| CAPTURING |------->| READOUT |
--      +------+        +-----------+        +---------+
--        ^  |                                    |
--        |  | trigger='0'                        | after SAMPLE_COUNT
--        |  +--(stay)                            | rd_en strobes
--        |                                       v
--        |              +-------+                |
--        +--------------| REARM |<---------------+
--          always,      +-------+
--          1 cycle
--
-- Triggers that arrive while the machine is anywhere but IDLE are IGNORED:
-- only the IDLE state looks at the trigger input. That blindness is the
-- DEAD TIME of Module 03 -- which is why this design exports 'busy',
-- the exact signal the Module 03 dead-time scaler wants to count.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity readout_fsm is
  generic (
    -- Both generics must be >= 1. Sized here for a small, readable demo;
    -- a real digitizer front end might capture hundreds of cycles and read
    -- out thousands of samples -- same machine, bigger numbers.
    CAPTURE_CYCLES : natural := 8;    -- post-trigger capture window, in clocks
    SAMPLE_COUNT   : natural := 16    -- words to read out per event
  );
  port (
    clk         : in  std_logic;      -- 100 MHz system clock, rising edge
    rst         : in  std_logic;      -- active-high synchronous reset
    trigger     : in  std_logic;      -- from the trigger logic (Modules 01/02)
    rd_en       : out std_logic;      -- read strobe to the sample buffer,
                                      --   exactly one per sample
    rd_last     : out std_logic;      -- high together with the FINAL rd_en
    busy        : out std_logic;      -- high whenever not IDLE = dead time;
                                      --   feed this to Module 03's scaler
    event_done  : out std_logic;      -- 1-cycle pulse: event complete
    event_count : out unsigned(15 downto 0)  -- completed events since reset
  );
end entity readout_fsm;

architecture rtl of readout_fsm is

  -- The states, as an ENUMERATED TYPE. This is a strong-typing win you
  -- don't get in Verilog or in hand-rolled "state = 2-bit vector" code:
  --   * impossible states are unrepresentable -- 'state' can ONLY hold one
  --     of these four names, so there is no "what if state = "11" but I
  --     only defined three states?" case;
  --   * the simulator knows the names, so GTKWave displays the state
  --     signal as the WORDS idle/capturing/readout/rearm, not as bit
  --     patterns you have to decode in your head. Enormous debugging win.
  type state_t is (idle, capturing, readout, rearm);

  signal state : state_t := idle;

  -- Step counters for the two timed states. 16 bits is comfortably wide
  -- for any sensible generic value; Module 06 discusses sizing counters
  -- exactly. numeric_std lets us compare these directly against the
  -- integer generics (wait_cnt = CAPTURE_CYCLES - 1).
  signal wait_cnt   : unsigned(15 downto 0);
  signal sample_cnt : unsigned(15 downto 0);

begin

  -- The whole machine is ONE clocked process -- the same template as every
  -- register in Module 03. The state register, the counters, and all the
  -- outputs are flip-flops updated on the rising edge. This "single
  -- clocked process" style is the one to reach for by default: no latch
  -- risk, outputs come straight out of registers (glitch-free), and it's
  -- the one idiom you already know. The README shows the older two-process
  -- style you WILL meet in legacy physics codebases.
  fsm : process (clk)
  begin
    if rising_edge(clk) then

      -- Default assignments for the single-cycle strobes. Inside a process,
      -- statements execute in order and the LAST assignment wins, so a
      -- state below can override these. The payoff: a strobe is high only
      -- on cycles where some state explicitly asserts it -- it can never
      -- be left stuck high by a forgotten branch.
      rd_en      <= '0';
      rd_last    <= '0';
      event_done <= '0';

      if rst = '1' then
        state       <= idle;
        busy        <= '0';
        event_count <= (others => '0');
      else

        -- One branch per bubble in the diagram. The case statement IS the
        -- state-transition table; if the code and the diagram ever
        -- disagree, one of them is wrong.
        case state is

          when idle =>
            -- Live and waiting. This is the ONLY state that reads
            -- 'trigger' -- which is precisely why triggers during an event
            -- are ignored (= dead time). A real DAQ also counts those lost
            -- triggers; that's this module's exercise.
            if trigger = '1' then
              busy     <= '1';                -- dead time starts now
              wait_cnt <= (others => '0');
              state    <= capturing;
            end if;

          when capturing =>
            -- Sit here for CAPTURE_CYCLES cycles while the digitizer's
            -- post-trigger samples land in the buffer. This is our
            -- hand-built program counter earning its keep: "wait N steps"
            -- is a state plus a counter.
            if wait_cnt = CAPTURE_CYCLES - 1 then
              sample_cnt <= (others => '0');
              state      <= readout;
            else
              wait_cnt <= wait_cnt + 1;
            end if;

          when readout =>
            -- Stream the event out: one rd_en strobe per sample, for
            -- SAMPLE_COUNT cycles. rd_last is asserted TOGETHER WITH the
            -- final strobe so the downstream event builder can frame the
            -- event without counting samples itself.
            rd_en <= '1';
            if sample_cnt = SAMPLE_COUNT - 1 then
              rd_last <= '1';
              state   <= rearm;
            else
              sample_cnt <= sample_cnt + 1;
            end if;

          when rearm =>
            -- One cycle of bookkeeping: publish the done pulse, bump the
            -- event scaler, drop busy, rearm. No condition -- this state
            -- always lasts exactly one cycle. (Reading and incrementing
            -- the 'out' port directly is VHDL-2008, as in Module 03.)
            event_done  <= '1';
            event_count <= event_count + 1;
            busy        <= '0';               -- live again: dead time ends
            state       <= idle;

        end case;
      end if;
    end if;
  end process fsm;

  -- A note on output timing, once and for all: because every output here
  -- is a registered Moore output, it appears on the cycle AFTER the state
  -- (or transition) that computes it -- e.g. the first rd_en strobe comes
  -- CAPTURE_CYCLES + 1 cycles after the trigger is accepted, not
  -- CAPTURE_CYCLES. That one-cycle pipeline delay is the price of
  -- glitch-free outputs, and in a synchronous design nobody downstream
  -- cares -- everything they do is registered too. What matters, and what
  -- the testbench pins down exactly, is the COUNT of strobes and their
  -- alignment with rd_last, busy, and event_done.

end architecture rtl;
