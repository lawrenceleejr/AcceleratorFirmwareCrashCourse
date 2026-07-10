-- sync_2ff.vhd
--
-- The two-flop synchronizer: THE primitive of clock-domain crossing.
--
-- Physics context: an asynchronous signal — an external trigger from another
-- subsystem, a beam-abort line, a manual reset button — arrives with no
-- relationship whatsoever to your clock. Sooner or later it will change
-- exactly inside a flip-flop's setup/hold window, and that flop can go
-- METASTABLE: like a ball kicked onto the top of the potential barrier
-- between two wells, it hovers at an invalid voltage for an unbounded
-- (exponentially distributed) time before falling into '0' or '1' — and
-- which side it falls to is anyone's guess.
--
-- The cure is not cleverness, it is structure: pass the signal through TWO
-- cascaded flip-flops in the destination domain.
--
--   * The FIRST flop takes the metastability hit. It may output garbage.
--   * It then gets a FULL clock period to resolve before the SECOND flop
--     samples it. Because resolution probability improves exponentially
--     with time, one clock period is (almost always) astronomically enough:
--     the mean time between failures goes from "hourly" to "age of the
--     universe" per extra flop.
--
-- RULES (violate these and no simulation will ever warn you):
--   1. Single BITS only. Never put N of these in parallel on a bus — the
--      bits resolve on different edges and you read torn values.
--   2. The async input must be a LEVEL (or a pulse much longer than the
--      destination clock period), or it can be missed entirely.
--   3. Nothing else may read async_in inside this domain. All consumers
--      use sync_out, so everyone agrees on the (single) resolved value.
--
-- No reset port: the synchronizer carries no state worth resetting, and
-- its first two output cycles after power-up are undefined anyway.
--
library ieee;
use ieee.std_logic_1164.all;

entity sync_2ff is
  port (
    clk      : in  std_logic;  -- DESTINATION-domain clock
    async_in : in  std_logic;  -- signal from another domain (or no domain at all)
    sync_out : out std_logic   -- safe to use anywhere in the clk domain
  );
end entity sync_2ff;

architecture rtl of sync_2ff is

  -- The two synchronizer flops. ff_meta is the one allowed to go metastable;
  -- ff_sync is the clean copy the rest of the design sees.
  signal ff_meta : std_logic := '0';
  signal ff_sync : std_logic := '0';

  -- The ASYNC_REG attribute is a message to the Xilinx tools (Vivado):
  --   * "these flops form a synchronizer" — timing analysis stops treating
  --     the async path as a normal timing path to be met;
  --   * place the two flops physically ADJACENT (same slice), so the wire
  --     between them is as short as possible and the second flop gets the
  --     maximum possible fraction of the clock period as resolution time.
  -- GHDL simply carries the attribute along; it only matters at synthesis.
  attribute async_reg : string;
  attribute async_reg of ff_meta : signal is "true";
  attribute async_reg of ff_sync : signal is "true";

begin

  sync : process (clk)
  begin
    if rising_edge(clk) then
      ff_meta <= async_in;  -- may sample mid-transition: metastability lands HERE
      ff_sync <= ff_meta;   -- samples a value that has had a full period to settle
    end if;
  end process sync;

  sync_out <= ff_sync;

end architecture rtl;
