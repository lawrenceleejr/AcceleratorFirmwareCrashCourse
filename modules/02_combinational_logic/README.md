# Module 02 — Combinational Logic

**Time: ~30 minutes** · Prerequisite: [Module 01](../01_entities_and_signals/)

Module 01's coincidence unit was a single gate. Real trigger logic is richer:
buses of channels, configurable thresholds, decisions with several cases. In
this module you'll build a **majority trigger for a 4-paddle scintillator
hodoscope** and meet buses (`std_logic_vector`), compile-time parameters
(**generics**), the two flavors of conditional assignment, and the
**combinational `process`** — including the most infamous novice bug in all
of VHDL, the inferred latch.

Everything here is still *combinational*: outputs are pure functions of
present inputs. No clock, no memory — that's Module 03.

## The physics problem

A cosmic-ray hodoscope stacks four scintillator paddles. How many must fire
to call it a muon?

* **Require all 4** (4-fold coincidence): great background rejection, but one
  dead or sagging PMT — a Tuesday, in any real experiment — and your
  telescope is blind.
* **Require any 1**: every ambient gamma and every speck of PMT dark noise
  triggers you.

The standard compromise is the **majority trigger**:

> trigger = (number of paddles fired) ≥ 3

It tolerates one inefficient channel yet still demands three independent
detectors agree within the same instant — single-paddle background doesn't
stand a chance. NIM crates had a "majority logic unit" with a threshold knob;
we'll build one where the knob is a **generic**. We'll also export the hit
count itself (**multiplicity**) — feed it to scalers and you can watch a PMT
die long before the trigger rate tells you.

## Buses: `std_logic_vector`

Four paddles could be four separate ports, but VHDL lets you bundle wires
into a **bus**:

```vhdl
paddles : in std_logic_vector(3 downto 0);
```

This is an array of four `std_logic` wires. What you can do with it:

* **Index**: `paddles(0)` is one wire (the paddle assigned to bit 0).
* **Slice**: `paddles(3 downto 2)` is the top two wires, itself a
  2-bit vector.
* **Literals**: `paddles <= "0110";` — note **double** quotes for vectors,
  single quotes (`'1'`) for one bit.
* **Aggregates**: `(others => '0')` means "every element `'0'`, whatever the
  width" — the idiomatic all-zeros that survives a width change.

**`downto` vs `to`.** VHDL allows both `(3 downto 0)` and `(0 to 3)`. This
course — and essentially all real firmware — always uses `downto`, so that
bit *N* sits in position *N* and carries numeric weight 2^N, matching how
`unsigned`, `signed`, every datasheet, and every Xilinx IP core number their
bits. Mixing conventions in one design is a reliable source of
off-by-reversal bugs; pick `downto` and never think about it again.

## Generics: compile-time parameters

Why hard-code the threshold at 3? The entity takes it as a **generic**:

```vhdl
entity majority_trigger is
  generic (
    THRESHOLD : natural := 3   -- minimum paddle count for a trigger
  );
  port (
    paddles      : in  std_logic_vector(3 downto 0);
    trigger      : out std_logic;
    multiplicity : out unsigned(2 downto 0)
  );
end entity majority_trigger;
```

and the instantiator fixes it with a `generic map`, next to the familiar
`port map`:

```vhdl
dut : entity work.majority_trigger
  generic map ( THRESHOLD => 3 )
  port map    ( paddles => paddles, trigger => trigger,
                multiplicity => multiplicity );
```

**Software analogy — and this time it holds.** A generic is a C++ template
parameter / `constexpr`: resolved entirely at compile (here: synthesis) time,
with **zero runtime cost**. There is no register holding "3" anywhere in the
chip. An instance with `THRESHOLD => 3` and one with `THRESHOLD => 2` are
*two physically different circuits* — the comparator gates are literally
different. If you want a threshold you can change from the control system at
run time, that's a *port* (a register the software writes), not a generic —
and it costs real hardware. Generics are how one VHDL file becomes a family
of circuits.

## Two ways to write a mux

Combinational decisions between alternatives appear constantly. VHDL gives
two concurrent forms, and they imply different hardware.

**`when/else` — the priority chain.** Conditions are tested in order; the
first true one wins:

```vhdl
trigger <= '1' when hit_count >= THRESHOLD else '0';
```

A chain of `when ... else when ... else` synthesizes to a cascade of 2-to-1
multiplexers — like an `if / else if / else` ladder, and like that ladder,
the deeper cases sit behind more logic. With one condition, as here, it's
simply a comparator.

**`with/select` — the parallel decode.** One selector expression, all
choices checked simultaneously, no priority:

```vhdl
with paddles select
  trigger <= '1' when "0111" | "1011" | "1101" | "1110" | "1111",
             '0' when others;
```

That's the same trigger for THRESHOLD = 3, written as an explicit truth
table: one wide multiplexer, all choices decoded in parallel, `when others`
guaranteeing every input is covered (with 9-valued `std_logic` there are far
more than 16 cases, so `others` is effectively mandatory). `with/select` is
the natural fit for decoders and lookup tables — but notice it *hard-codes
the threshold*, which is why the shipped design counts hits and compares
instead. C++ reflex: `when/else` is `if/else if`, `with/select` is `switch`.

## The combinational `process`

Some logic is awkward as one expression — like "count the set bits of a
bus". For that, VHDL provides the `process`: a block of sequential-*looking*
code that, viewed from outside, is **one concurrent statement** — a single
lump of logic sitting in the architecture alongside everything else.

```vhdl
count_hits : process(all)
  variable count : unsigned(2 downto 0);
begin
  count := (others => '0');            -- default: assigned on EVERY path
  for i in paddles'range loop          -- unrolled at synthesis!
    if paddles(i) = '1' then
      count := count + 1;
    end if;
  end loop;
  hit_count <= count;
end process count_hits;
```

Three things to understand, in increasing order of importance:

**1. `process(all)` and sensitivity lists.** A combinational process must
re-evaluate whenever any input changes. Pre-2008 you listed those inputs by
hand — `process(paddles)` — and if you later added an input but forgot to
extend the list, the *simulation* stopped reacting to it while the
*synthesized hardware* (which ignores the list) reacted fine. Simulation
passing, hardware differing: the worst kind of bug. VHDL-2008's
`process(all)` means "sensitive to everything I read" and kills that entire
bug class. Use it for every combinational process, always.

**2. Variables.** `count` is a **variable**: it lives only inside the
process and updates *immediately* with `:=` (unlike a signal's scheduled
`<=`, which you met in Module 01). Inside a combinational process a variable
is not storage — it names the intermediate taps of a chain of logic, the way
a temporary names a subexpression in C++.

**3. The loop does not loop.** This is the mindset moment of the module.
The `for` loop looks like software, but **synthesis unrolls it completely**:
four conditional "+1" stages become a small tree of adders (a population
count) through which all four paddle bits propagate *simultaneously*. There
is no loop counter in the chip, no iteration, no run time proportional to
the number of paddles — just gates. Corollary: a loop whose trip count isn't
known at synthesis time (`while pressure > threshold loop ...`) cannot become
hardware at all. Loops are a *text-generation* convenience — write four
similar things once — not a control-flow construct.

## THE LATCH TRAP

Here is the classic novice bug. Suppose you wrote the trigger inside a
process and forgot the `else`:

```vhdl
-- WRONG — do not do this
bad : process(all)
begin
  if hit_count >= THRESHOLD then
    trigger <= '1';
  end if;                -- ...and when the condition is false? Nothing.
end process bad;
```

In software, "don't update the output" is fine — the old value just sits in
memory. But combinational logic **has no memory**. If your description says
"when the condition is false, `trigger` keeps its previous value", the
synthesizer must *build* something that remembers a previous value: it
infers a **latch** — a level-sensitive storage element that is transparent
while an enable is high and freezes when it goes low.

Why is that almost always wrong in an FPGA?

* You asked for logic and got **unintended memory** — the design's behavior
  now depends on history you never meant to keep.
* FPGAs are built around edge-triggered flip-flops; latches are implemented
  awkwardly, and the timing tools can't properly analyze paths through
  them. Glitches on the data while the latch is transparent get captured.
* It's silent: simulation may look fine, and the only hint is a synthesis
  warning ("latch inferred for signal `trigger`") scrolling past in the log.
  **Treat every inferred-latch warning as an error.**

Two habits make latches impossible, and the shipped code uses both:

1. **Default assignments at the top of the process** — `count :=
   (others => '0');` before the loop means every output is assigned on
   every path, no matter what the branches do afterwards.
2. **Complete conditionals** — every `if` that assigns an output gets an
   `else`; every case is covered. (`when/else` and `with/select ... when
   others` outside a process are complete by construction, which is one
   reason to like them.)

## Propagation delay: nothing is instant

"Combinational" does not mean "instantaneous". Every gate takes real time
(tens to hundreds of picoseconds in an FPGA, plus routing), and signals
ripple through the logic level by level: paddle inputs → adder tree →
comparator → trigger. The **depth** of that chain sets how fast the circuit
can possibly react — and, once a clock is involved (Module 03), how fast the
whole design can be clocked. Our 4-input majority is a few levels deep and
trivially fast; a 64-channel majority with an 8-bit threshold comparator is
noticeably deeper. Deep combinational logic is the root cause of the timing
failures you'll learn to diagnose and fix in Module 09 — the standard cure,
*pipelining* (chopping long logic into stages separated by registers),
arrives with Module 06. For now, cultivate the instinct: **every level of
logic you describe is delay you will someday have to pay for.**

## Run it

The testbench does what you should always do when the input space is small:
tests **all 16 paddle patterns exhaustively** against an independent
software model computed in the testbench itself, checking both the trigger
decision and the multiplicity count. Open it and read it — every line is
commented.

```bash
cd modules/02_combinational_logic
ghdl -a --std=08 src/majority_trigger.vhd tb/tb_majority_trigger.vhd
ghdl --elab-run --std=08 tb_majority_trigger
```

Expected output:

```
tb/tb_majority_trigger.vhd:92:5:@160ns:(report note): ALL TESTS PASSED
```

To look at the waveforms, add `--wave=majority.ghw` to the second command
and open the file with `gtkwave majority.ghw`: drag in `paddles`,
`multiplicity`, and `trigger` and watch the count ramp through the 16
patterns, with `trigger` high exactly when `multiplicity` reaches 3.

## Design-choice notes

* **Why is `multiplicity` an output at all?** The adder tree exists anyway;
  bringing its result to a port is free. In a real DAQ you'd feed it to
  scalers and histogram it — the singles/doubles/triples rates are your
  detector's health monitor. Exposing internal quantities that are cheap to
  export is a habit worth forming early.
* **Why `unsigned` and not `std_logic_vector` for the count?** The count is
  a *number* — you compare it, you'd add to it. `unsigned` (from
  `numeric_std`) is a vector that additionally carries arithmetic meaning.
  Module 06 covers the numeric types properly; the rule until then:
  `std_logic_vector` for "just wires", `unsigned`/`signed` for quantities.
  And never the old `std_logic_arith`/`std_logic_unsigned` libraries.
* **Why count-and-compare instead of the 16-row truth table?** The
  `with/select` truth table is arguably *smaller* hardware for 4 paddles —
  but it hard-codes both the width and the threshold. The counter +
  comparator keeps `THRESHOLD` generic and survives the growth to 8 or 64
  channels untouched. Writing for the design you'll have next year is
  usually worth a gate or two.
* **Why initialize `hit_count`?** Purely cosmetic, purely simulation: for
  the first delta cycle of time zero the comparator would see `'U'` and
  `numeric_std` would warn about it. In hardware the wire is always driven
  and the initializer is meaningless.

## Exercise

1. **Grow the hodoscope.** Add a second generic, `WIDTH : natural := 4`,
   and change the port to `paddles : in std_logic_vector(WIDTH-1 downto
   0)`. Because the process loops over `paddles'range` and uses
   `(others => '0')`, almost nothing else needs to change — check what
   *does* (hint: how many bits does the count of 8 paddles need?).
   Instantiate it in the testbench with `WIDTH => 8, THRESHOLD => 5` and
   extend the exhaustive loop to all 256 patterns.
2. **Add a prescale select.** Give the entity a `prescale_sel : in
   std_logic_vector(1 downto 0)` input and, using `with/select`, drive a
   new output `min_mult : out unsigned(2 downto 0)` with 1, 2, 3, or 4 —
   then use `min_mult` in place of `THRESHOLD`. You've just built the
   majority-logic knob as run-time-selectable hardware, and felt the
   difference between a generic and a port.

## Key takeaways

* `std_logic_vector` is a bus; always declare `(N-1 downto 0)` so bit *N*
  has weight 2^N. `(others => '0')` is the width-proof all-zeros.
* **Generics** are compile-time parameters — C++ templates for hardware.
  Different generic values produce physically different circuits at zero
  runtime cost; run-time configurability needs a port instead.
* `when/else` builds a priority mux chain; `with/select` builds one
  parallel decode. Both are complete by construction — a virtue.
* A `process(all)` is one concurrent statement that lets you *describe*
  logic with sequential-looking code; variables (`:=`) name intermediate
  logic taps, and **for-loops are unrolled into parallel hardware at
  synthesis** — nothing loops at run time.
* **Assign every output on every path** of a combinational process
  (defaults at the top, complete if/else), or the synthesizer infers a
  latch — unintended memory, and almost always a bug. Treat inferred-latch
  warnings as errors.
* Combinational logic takes real time, level by level. Depth is delay —
  the currency of timing closure (Module 09).

**Next:** [Module 03 — Clocks, registers, and counters](../03_clocks_and_registers/),
where the clock finally arrives — flip-flops give your designs *state and
memory on purpose* (unlike the accidental latch!), and with them the
ability to count triggers, stretch pulses, and gate the beam.
