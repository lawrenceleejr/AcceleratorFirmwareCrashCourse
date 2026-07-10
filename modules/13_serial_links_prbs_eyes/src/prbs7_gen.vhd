-- prbs7_gen.vhd
--
-- PRBS-7 pattern generator: the polynomial x^7 + x^6 + 1, one bit per clock.
--
-- Physics context: before you trust ANY protocol over a serial link -- GBT
-- frames, Aurora, Ethernet -- you prove the raw physical channel by sending
-- a known pseudo-random bit sequence (PRBS) and counting errored bits at the
-- far end. This file is the "known sequence" half of that test; its partner,
-- prbs7_check.vhd, is the counting half. Together they are a minimum viable
-- link tester: what you'd put on a plain LVDS pair between two boards, and a
-- transparent model of what the PRBS hardware inside a gigabit transceiver
-- (and Vivado's IBERT core) does at 10+ Gb/s.
--
-- How it works: a 7-bit LINEAR FEEDBACK SHIFT REGISTER (LFSR). Each clock,
-- the register shifts one place and the vacated bit is filled with the XOR
-- of two "taps" -- bits 6 and 5, i.e. the polynomial x^7 + x^6 + 1. Because
-- that polynomial is PRIMITIVE, the register walks through ALL 127 nonzero
-- 7-bit states before repeating: a 127-bit sequence that passes statistical
-- randomness tests (runs of 0s and 1s of every length up to 7, balanced
-- ones-density) yet is perfectly DETERMINISTIC -- which is the whole trick:
-- the receiver can regenerate it locally and compare bit for bit.
--
library ieee;
use ieee.std_logic_1164.all;

entity prbs7_gen is
  generic (
    -- Starting state of the LFSR. ANY nonzero value works and produces the
    -- same 127-bit sequence, just entered at a different point (the states
    -- form one big cycle). All-zeros is the LFSR's DEAD STATE: 0 xor 0 = 0,
    -- so it shifts zeros forever -- which is why the default is all-ones
    -- and why the checker next door can be fooled by a stuck-low line.
    SEED : std_logic_vector(6 downto 0) := "1111111"
  );
  port (
    clk        : in  std_logic;  -- 100 MHz system clock, rising edge
    rst        : in  std_logic;  -- active-high SYNCHRONOUS reset
    -- Pulse this high for one clock cycle to XOR-flip the output bit for
    -- that cycle: a deliberately corrupted bit on an otherwise perfect
    -- link. Same idea as IBERT's "insert error" button, and it exists for
    -- the same reason: a checker that has never been SEEN to count an
    -- error is a checker you cannot trust (the Module 04 mutation-testing
    -- instinct, in hardware).
    err_inject : in  std_logic;
    prbs_out   : out std_logic   -- the serial PRBS-7 stream, 1 bit/clock
  );
end entity prbs7_gen;

architecture rtl of prbs7_gen is

  -- The LFSR state: seven flip-flops. lfsr(6) is the oldest bit (the one
  -- about to leave and appear on the output); new bits enter at lfsr(0).
  signal lfsr : std_logic_vector(6 downto 0) := SEED;

begin

  -- The shift register, in the standard clocked-process idiom of Module 03.
  shift : process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        lfsr <= SEED;
      else
        -- Shift left by one; feed back lfsr(6) xor lfsr(5) into bit 0.
        -- Those two taps ARE the polynomial x^7 + x^6 + 1: bit index 6 is
        -- the x^7 term, index 5 is x^6, and the "+ 1" is the feedback wire
        -- itself. The output bit therefore obeys the recurrence
        --   b(t) = b(t-7) xor b(t-6)
        -- and THAT is what lets the checker predict it from history alone.
        lfsr <= lfsr(5 downto 0) & (lfsr(6) xor lfsr(5));
      end if;
    end if;
  end process shift;

  -- The output: the oldest LFSR bit, optionally flipped by err_inject.
  -- XOR with a control signal is hardware's "controlled inverter": when
  -- err_inject = '0' the bit passes through untouched, when '1' it flips.
  -- This is a concurrent assignment (Module 01), so the flip applies to
  -- exactly the cycles during which err_inject is held high.
  prbs_out <= lfsr(6) xor err_inject;

end architecture rtl;
