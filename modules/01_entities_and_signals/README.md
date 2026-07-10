# Module 01 — Entities, Signals, and Your First Design

**Time: ~30 minutes** · Prerequisite: [Module 00](../00_the_hardware_mindset/)

In this module you will write, simulate, and fully understand your first piece
of firmware: a **two-channel coincidence unit**, the oldest trigger in
particle physics. Along the way you'll meet the fundamental vocabulary of
VHDL — *entity*, *architecture*, *signal*, *port* — and the single most
important semantic difference from software: **concurrency by default**.

## The physics problem

Two scintillator paddles sandwich a tracking chamber. A cosmic muon passing
through the whole stack fires **both** photomultipliers within nanoseconds of
each other; a background gamma typically fires only one. So the classic
cosmic-ray trigger is simply:

> trigger = (paddle A fired) AND (paddle B fired)

In the NIM-crate era this was a physical "coincidence unit" module. Today it's
one line of VHDL — but that one line teaches most of the language's core ideas.

## Entity: the black box

Every hardware unit in VHDL is described in two parts. The first, the
**entity**, is the outside view — the name and the pins:

```vhdl
library ieee;
use ieee.std_logic_1164.all;

entity coincidence is
  port (
    pmt_a   : in  std_logic;
    pmt_b   : in  std_logic;
    trigger : out std_logic
  );
end entity coincidence;
```

Read it like this:

* `library ieee; use ieee.std_logic_1164.all;` — the `#include` /
  `import` of VHDL. Almost every file starts with exactly this, because it
  brings in `std_logic`, the type used for every wire.
* `entity coincidence is ... end entity;` — declares a black box named
  `coincidence`.
* `port (...)` — the pins. Each has a **name**, a **direction** (`in`,
  `out`, or the rarely-needed `inout`), and a **type**.

**Software analogy — and where it breaks.** An entity looks like a function
signature: named inputs, named outputs. But a function is *called* and
*returns*; an entity is *instantiated* — physically stamped into the silicon —
and then exists forever, its outputs continuously tracking its inputs. If you
instantiate it twice you get two copies of the circuit, twice the chip area,
both running at the same time. There is no call stack. Nothing "returns."

### What is `std_logic`?

Your instinct says a wire is a `bool`. VHDL's standard wire type,
`std_logic`, has **nine** values, because real electrical nodes can be more
than true or false. The ones you'll actually see:

| Value | Meaning | When you'll meet it |
|-------|---------|---------------------|
| `'0'`, `'1'` | driven low / high | normal operation |
| `'U'` | uninitialized | simulation, before anything drives the wire — a *feature*: it makes "I forgot to reset this register" glaringly visible |
| `'X'` | unknown / conflict | two drivers fighting, or `'U'` propagating through logic — almost always a bug telling on itself |
| `'Z'` | high impedance | tri-state buses (rare inside modern FPGAs) |

**Why not just use `bit` (which really is 0/1)?** Because `'U'` and `'X'`
turn a whole class of silent bugs into loud red waveforms. In C++ terms:
`std_logic` is a `bool` with built-in valgrind.

## Architecture: what's in the box

The second part, the **architecture**, describes the contents:

```vhdl
architecture rtl of coincidence is
begin
  trigger <= pmt_a and pmt_b;
end architecture rtl;
```

* The name `rtl` is conventional, short for *register-transfer level* — the
  abstraction level where you describe hardware as registers plus the logic
  between them. (An entity can have several architectures — e.g. a behavioral
  model and a synthesizable one — which is why they're named.)
* `trigger <= pmt_a and pmt_b;` is a **concurrent signal assignment**. The
  `<=` operator reads as "is driven by", not "gets assigned".

This line does **not** execute. It *describes an AND gate*: a physical object
whose inputs are permanently connected to `pmt_a` and `pmt_b` and whose
output permanently drives `trigger`. The gate computes continuously, whether
you're "using" it or not — the same way a NIM coincidence module ANDs its
inputs whether or not anyone is looking at the output.

### Concurrency by default

This is the mindset moment of the module. In an architecture body, statement
order is **meaningless**. These two architectures are *identical hardware*:

```vhdl
-- version 1                      -- version 2
y <= a and b;                     z <= y or c;
z <= y or c;                      y <= a and b;
```

Both describe an AND gate feeding an OR gate. The text is a *netlist* — a
parts list with wiring instructions — not a recipe. A Python function with the
lines swapped would crash (`y` not defined yet); the VHDL doesn't care,
because both gates simply *exist*, side by side, from power-on.

> **Rule of thumb:** every concurrent statement in an architecture is another
> piece of hardware running in parallel with all the others. Ten thousand
> lines of VHDL = ten thousand circuits all operating at once. This — not
> clock speed — is why an FPGA can form a trigger decision for every LHC
> bunch crossing at 40 MHz while a CPU cannot.

### Signals are wires, not variables

A `signal` (ports are signals too) is a physical wire.
Three consequences that ambush software people:

1. **A wire has exactly one driver.** Writing to the same signal from two
   concurrent statements is a short circuit — two gates fighting over one
   node. Simulation shows `'X'`; synthesis errors out. (A variable in C++
   can be assigned from anywhere, whenever.)
2. **There is no "current thread's view" of a signal.** Everything reading
   `trigger` sees the same wire at the same time.
3. **Assignment takes (a tiny amount of) time.** `<=` schedules the new
   value; it doesn't take effect *within* the current instant. This models
   real gate delay, and Module 03 shows why it's exactly what makes
   flip-flops describable. For now: don't expect C-style "read it right back
   on the next line" semantics.

## Run it

The module ships a self-checking testbench (`tb/tb_coincidence.vhd`) that
walks the coincidence unit through all four input combinations — no pulses,
each paddle alone (a gamma), both paddles (a muon!) — and `assert`s the
expected trigger output for each. Open the file and read it; every line is
commented. Testbenches get their own deep dive in Module 04.

```bash
cd modules/01_entities_and_signals

# Analyze (= compile) the design and its testbench
ghdl -a --std=08 src/coincidence.vhd tb/tb_coincidence.vhd

# Elaborate and run, recording every signal to a waveform file
ghdl --elab-run --std=08 tb_coincidence --wave=coincidence.ghw
```

Expected output:

```
tb/tb_coincidence.vhd:64:5:@40ns:(report note): ALL TESTS PASSED
```

Now look at the waveforms — get used to doing this early, because waveforms
are to firmware what `print()` is to Python:

```bash
gtkwave coincidence.ghw
```

Select `tb_coincidence` in the tree, drag `pmt_a`, `pmt_b`, and `trigger`
into the wave pane. You'll see `trigger` go high only in the final 10 ns,
when both PMT inputs are high. That's your muon.

## Design-choice notes

Choices made in this tiny design that you'll see justified throughout the
course:

* **Why `std_logic` for single wires, always?** Uniformity (everything
  connects to everything without conversions) and the debugging value of
  `'U'`/`'X'`. The entire Xilinx ecosystem — IP cores, primitives — speaks
  `std_logic`.
* **Why is the architecture named `rtl`?** Convention: it tells the reader
  "this is synthesizable hardware description", as opposed to `sim` or
  `behav` for simulation-only models. Consistent naming is cheap and
  helps in codebases with hundreds of files.
* **Why is there no clock?** This is *combinational* logic — output is a pure
  function of present inputs, no memory, no clock needed. Real trigger paths
  often start like this. But the moment you need to *count* muons or remember
  that a trigger happened, you need state, and state needs a clock — that's
  Modules 02 and 03.

## What could go wrong (a preview of real life)

A physicist would immediately ask: *what if the two PMT pulses don't overlap
exactly?* Real discriminated pulses are a few ns wide and arrive with jitter;
an AND of two 5 ns pulses misses coincidences that a NIM module with a 20 ns
gate would catch. Real trigger firmware first *stretches* each pulse to a
defined coincidence window, then ANDs. Stretching a pulse requires remembering
it for N clock cycles — state again. You'll build exactly this in the Module
03 exercise.

## Exercise

Extend the design to a **three-fold coincidence with a veto**: paddles `a`,
`b`, `c` must all fire while veto counter `v` (e.g. a paddle above the roof,
tagging air-shower events you *don't* want) is quiet:

```
trigger = a and b and c and (not v)
```

1. Copy `src/coincidence.vhd` to `src/coincidence3v.vhd`; rename the entity,
   add the ports, write the expression.
2. Extend the testbench to cover at least: all quiet, all three fire (trigger),
   all three fire but veto also fires (no trigger), two of three fire (no
   trigger). That's the muon-telescope logic used in real cosmic-ray arrays.

## Key takeaways

* An **entity** is the pinout; an **architecture** is the contents. `<=`
  means "is driven by".
* Concurrent statements describe hardware that all exists and operates
  **simultaneously**; their textual order is irrelevant.
* **Signals are wires**: one driver, visible to all, updated after a delta of
  time — not variables in memory.
* `std_logic`'s extra values (`'U'`, `'X'`) are a debugging gift; use it for
  every wire.
* Instantiating an entity twice costs twice the silicon. Parallelism is free
  at run time but paid for in area — the fundamental economics of FPGAs.

**Next:** [Module 02 — Combinational logic](../02_combinational_logic/), where
the majority vote of a 4-paddle hodoscope introduces richer logic and the
`process` statement.
