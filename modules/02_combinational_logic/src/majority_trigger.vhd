-- majority_trigger.vhd
--
-- A majority trigger for a 4-paddle scintillator hodoscope.
--
-- Physics context: four scintillator paddles are stacked in a cosmic-ray
-- hodoscope. Demanding all four fire (a 4-fold coincidence) is efficient
-- physics but fragile hardware: one dead or sagging PMT kills the whole
-- telescope. Demanding only one paddle lets every background gamma through.
-- The classic compromise is the MAJORITY trigger: fire when at least N of
-- the 4 paddles fire (here N = 3). It tolerates one inefficient channel
-- while still crushing single-paddle background.
--
-- This file introduces:
--   * std_logic_vector      - a bus: many wires handled as one object
--   * generics              - compile-time parameters (think C++ templates
--                             or constexpr: resolved before hardware exists)
--   * the combinational process, process(all), and variables
--   * a for-loop that is UNROLLED into parallel hardware at synthesis
--   * conditional assignment (when/else) and how to avoid the latch trap
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;   -- for the unsigned type used by multiplicity

entity majority_trigger is
  -- GENERICS are compile-time parameters, fixed when the entity is
  -- instantiated. Like a C++ template argument or constexpr, THRESHOLD has
  -- zero runtime cost: a copy built with THRESHOLD => 3 and one with
  -- THRESHOLD => 2 are two physically different circuits. There is no
  -- register holding "3" anywhere, and nothing can change it after
  -- synthesis - the comparison below is baked into the gates.
  generic (
    THRESHOLD : natural := 3  -- minimum paddle count for a trigger
  );
  port (
    -- A std_logic_vector is a BUS: four std_logic wires bundled into one
    -- named object, indexed paddles(3) down to paddles(0). We write
    -- "3 downto 0" (not "0 to 3") so that bit N always has numeric weight
    -- 2**N - the convention used by every arithmetic type, every Xilinx IP
    -- core, and every module in this course.
    paddles      : in  std_logic_vector(3 downto 0);  -- one discriminated PMT pulse per paddle

    trigger      : out std_logic;           -- high when >= THRESHOLD paddles fire
    -- The hit count itself, 0..4, needs 3 bits. Exporting it costs nothing
    -- (the adder tree below exists anyway) and is gold for monitoring:
    -- feed it to scalers and you get the singles/doubles/triples rates
    -- that tell you a PMT is dying long before the trigger rate does.
    multiplicity : out unsigned(2 downto 0)
  );
end entity majority_trigger;

architecture rtl of majority_trigger is

  -- Internal signal: the wire between the counting logic and the two
  -- outputs. Declared here, between "architecture" and "begin", exactly
  -- where C would put file-scope declarations. The ":= (others => '0')"
  -- initial value only matters for the first instants of SIMULATION
  -- (before the process below first drives the wire, it would read 'U'
  -- and the comparator would complain); in hardware this wire is always
  -- driven, so the initializer costs nothing.
  signal hit_count : unsigned(2 downto 0) := (others => '0');

begin

  -- ---------------------------------------------------------------------
  -- Count the set bits of the paddle bus: a COMBINATIONAL PROCESS.
  --
  -- A process is a block of sequential-LOOKING code that, taken as a
  -- whole, acts as ONE concurrent statement: a lump of logic sitting in
  -- the architecture alongside the assignments below it.
  --
  -- process(all) is VHDL-2008 for "re-evaluate whenever ANY signal read
  -- inside changes". Pre-2008 you listed the signals by hand -
  -- process(paddles) - and forgetting one gave you simulation that
  -- silently disagreed with the synthesized hardware, a classic bug class
  -- that process(all) eliminates. Always use it for combinational
  -- processes.
  -- ---------------------------------------------------------------------
  count_hits : process(all)
    -- A VARIABLE, not a signal. Variables live only inside a process,
    -- update IMMEDIATELY with := (unlike the scheduled <= of signals),
    -- and here describe the intermediate taps of a chain of logic - not
    -- storage.
    variable count : unsigned(2 downto 0);
  begin
    -- Default assignment FIRST. Every path through this process now
    -- assigns count, so the logic is pure combinational - see the latch
    -- trap note below. "(others => '0')" is an AGGREGATE: every element
    -- '0', whatever the width - the idiomatic "all zeros".
    count := (others => '0');

    -- This loop looks like software but is NOT executed at run time.
    -- Synthesis UNROLLS it: four conditional +1 stages become a small
    -- tree of adders (a "population count") through which all four
    -- paddle bits propagate SIMULTANEOUSLY. paddles'range means
    -- "3 downto 0" - always loop over 'range so the code survives a
    -- change of bus width.
    for i in paddles'range loop
      if paddles(i) = '1' then
        count := count + 1;   -- immediate: the next iteration sees it
      end if;
    end loop;

    -- Hand the result out of the process on a signal.
    hit_count <= count;
  end process count_hits;

  -- The count is directly useful downstream: publish it.
  multiplicity <= hit_count;

  -- ---------------------------------------------------------------------
  -- The trigger decision: a CONDITIONAL assignment (when/else).
  --
  -- when/else is evaluated in priority order (first true condition wins),
  -- so a chain of them synthesizes to a cascade of 2-to-1 multiplexers.
  -- With a single condition, as here, it is just a comparator: hit_count
  -- is compared against the constant THRESHOLD, and because THRESHOLD is
  -- a generic the comparator is hard-wired at synthesis - for
  -- THRESHOLD = 3 it reduces to a handful of gates checking
  -- "count is 3 or 4".
  --
  -- Note the latch trap does NOT exist here: when/else forces you to
  -- supply the else, so trigger is defined for every input. Inside a
  -- process, an if without an else assigning an output would make the
  -- synthesizer infer a LATCH - see the README.
  -- ---------------------------------------------------------------------
  trigger <= '1' when hit_count >= THRESHOLD else '0';

  -- An equivalent SELECTED assignment (with/select) on the raw bus, for
  -- THRESHOLD = 3, would read:
  --
  --   with paddles select
  --     trigger <= '1' when "0111" | "1011" | "1101" | "1110" | "1111",
  --                '0' when others;
  --
  -- with/select has no priority: all choices are compared in parallel
  -- (one wide one-hot multiplexer), and "when others" guarantees
  -- completeness. It is the right tool for decoders and lookup tables;
  -- here it would hard-code the threshold, losing the generic - which is
  -- why the design uses the counter + comparator instead.

end architecture rtl;
