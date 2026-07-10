# Module 11 — Counters in Practice

**Time: ~30 minutes** · Prerequisite: [Module 03](../03_clocks_and_registers/) · builds on [Module 08](../08_clock_domains_cdc/)

Open up any DAQ firmware repository and count what the code is made of. It's
counters. Scalers on every trigger line, a timestamp counter, an event-number
counter, prescale counters on the high-rate triggers, error counters on every
serial link, dead-time counters (Module 03), FIFO occupancy counters, watchdog
counters. A trigger crate is, to first order, **a box of counters with some
logic deciding which ones to increment**.

Module 03 taught you the counting idiom — a register plus `+ 1` inside the
clocked-process template. This module teaches the part that experience
usually teaches painfully: **counters come in distinct species, and picking
the wrong one produces data that is wrong in quiet, physics-corrupting
ways** — rates off by an integer factor, error counts that shrink as things
get worse, cross-domain reads that are pure garbage. You'll build the three
species that cover most of DAQ life:

* `src/prescaler.vhd` — a **modulo-N** counter: keep 1 of every N trigger
  pulses;
* `src/saturating_counter.vhd` — a **saturating** counter: an error counter
  that pegs at max instead of wrapping into a lie;
* `src/gray_counter.vhd` — a **gray-coded** counter: one bit changes per
  step, the only kind you may hand to another clock domain.

Each is a few lines different from Module 03's scaler. Those few lines are
the whole module.

## One contract before anything: count *events*, not cycles

All three designs share Module 03's mechanics: counting is **state**, so
every counter lives inside the clocked-process template, advancing at most
once per 10 ns tick. Which raises the question the hardware cannot answer
for you: *what is "once"?*

A counter with an enable input (`pulse_in`, `inc`) increments on **every
cycle the input is high**. If your "pulse" is actually a level that stays
high for three cycles — a raw comparator output, an unsynchronized
front-panel signal — you count three. The prescaler below therefore states
a contract: **inputs are 1-cycle pulses, synchronous to `clk`** — exactly
what Module 04's one-shot discriminator emits (that's *why* it was built as
a one-shot). If what you have is a level, put an edge detector in front.
Miscounting by pulse width is the classic scaler bug, and it's
rate-dependent and width-dependent — the kind you find months later, in the
data.

## Species 1: the prescaler — a counter with a systematic attached

Minimum-bias triggers, singles rates, calibration pulsers: some triggers
fire far too often to read out, but you still want an unbiased sample.
The fix is as old as counting experiments — **keep exactly 1 of every N**:

```vhdl
pulse_out <= '0';                     -- default: makes a 1-cycle pulse

if pulse_in = '1' then
  if count = PRESCALE - 1 then
    count     <= 0;                   -- wrap...
    pulse_out <= '1';                 -- ...and fire: this is pulse N
  else
    count <= count + 1;
  end if;
end if;
```

Three things to read out of this excerpt:

* **The wrap is the mechanism.** Module 06 warned you about silent
  wraparound as a bug; here the counter is deliberately a *modulo-N
  machine* and the wrap **is** the output event. Same behaviour, opposite
  moral — wrap semantics are a design decision, not a property of counters.
* **The default-then-override idiom** (`pulse_out <= '0';` first, override
  on fire) is *the* way to emit a clean **one-cycle pulse**: the override
  lasts one tick, the default reasserts on the next. Pulses trigger things
  once; levels (like Module 03's stretcher output) hold gates open. Know
  which one each signal in your design is.
* **Sizing costs nothing here**: `count` is a constrained integer
  (`natural range 0 to PRESCALE - 1`), so the synthesizer allocates
  ⌈log₂ PRESCALE⌉ flip-flops — Module 03's sizing rule, automated.

And the physics point, which outranks all three: **the prescale factor is a
systematic**. Every rate computed from prescaled data must be multiplied
back up by N offline, so real experiments record N in the run database and
event headers next to the data. A prescaler is the rare piece of firmware
whose *generic* appears in the analysis paper. Change `PRESCALE`, and you
change every downstream cross section — which is why real trigger systems
make it a run-controlled register, logged on every change.

**The same counter, aimed at the clock**: count `clk` cycles instead of
input pulses and the wrap pulse becomes a periodic **tick** — a *clock
enable* that lets slow logic (a 1 Hz heartbeat LED, a once-per-millisecond
readout strobe) live on the one fast clock. You enable slowly; you never
clock slowly. Module 09's blinky was the special case N = 2^k, done by
tapping bit k of a free-running counter; this structure is the general
divide-by-*any*-N.

## Species 2: wrap or saturate — will this counter be asked to tell the truth?

Module 03's scaler wraps silently, like `uint32_t`. Whether that's fine
depends entirely on what the counter is *for*, and the boundary is sharp:

**Free-running bookkeeping wraps — and should.** Timestamps and event
numbers count monotonically forever; no finite register can hold "forever",
so consumers are built to unwrap: *whenever the value goes down, add
2^WIDTH* (rollover correction). The capstone's event header carries exactly
such a counter — the low 16 bits of a free-running cycle counter as a
timestamp — and offline event-building code unwraps it as a matter of
course. Wrap is fine when it is **part of the interface contract**.

**Diagnostic counters must never wrap.** Picture an 8-bit CRC-error counter
on a serial link, read once a spill. It reads 3. Three errors — or 259?
A wrapped error counter reports its *smallest* numbers in the *worst*
conditions, which is precisely backwards. The fix costs one comparison:

```vhdl
if inc = '1' and count /= MAX_COUNT then
  count <= count + 1;
end if;
-- once at MAX_COUNT it stops: an unassigned signal holds (Module 03)

saturated <= and count;   -- VHDL-2008 reduction: AND of all bits
```

Pegged at 255 means, unambiguously, **"at least 255 — investigate"**: the
only honest statement a too-narrow counter can make. The `saturated` flag
is a combinational decode of the register (same registers-plus-gates
pattern as the stretcher's output in Module 03) — and that reduction `and`
is new syntax worth meeting: applied to a whole vector it ANDs the bits
together, which *is* the all-ones detector, one WIDTH-input AND gate.

> **Software callout.** In C++, signed overflow is undefined behaviour you
> hope never happens, and unsigned wrap is legal but silent — either way,
> overflow is something that happens *to* you. In hardware, wrap-vs-saturate
> is a decision you make **per counter**, each costing about one comparator.
> Nothing is undefined. Everything is exactly what you wrote — including
> the lies.

**Rule of thumb: monotonic bookkeeping wraps; alarm/diagnostic counters
saturate.** If a human or an alarm system will read the value and act on
it, saturate. If software unwraps it in a pipeline, wrap — and document
the width.

## Species 3: the gray counter — the only count you may show another clock domain

Module 08 left you with a rule: never parallel-synchronize a bus. A binary
counter going 7 → 8 flips four bits at once (`0111` → `1000`); sample that
through N independent two-flop synchronizers and some bits resolve to the
old value, some to the new — the reader can see `0000`, `1111`, any tearing
of the two. Not off by one. *Garbage.*

The cure, from Module 08's exercise, becomes a real component here: encode
the count so that **exactly one bit changes per increment** — gray code.
Then however unlucky the sampling instant, the reader gets either the old
value or the new one: off by at most one step, never garbage.

```vhdl
bin_next <= bin + 1;                  -- count in binary (easy)
...
elsif en = '1' then
  bin  <= bin_next;
  gray <= std_logic_vector(bin_next xor shift_right(bin_next, 1));
end if;
```

* **Count in binary, convert on the way out.** `gray = bin xor (bin srl 1)`
  is one XOR per bit. (Incrementing *directly* in gray code is a puzzle;
  nobody does it.) Going back is a chain the *destination* domain — or
  offline software — computes when it needs the number:
  `bin(i) = gray(W-1) xor gray(W-2) xor ... xor gray(i)`.
* **The output is a register, not a decode.** This is the line easy to get
  wrong: a combinational bin-to-gray decode can glitch while it settles
  (Module 02), and a glitch on a wire another domain samples destroys the
  one-bit guarantee. A flip-flop output moves once per edge, from one valid
  gray value to the next — glitch-free by construction. That's why `gray`
  is assigned inside the process, from `bin_next`, in lockstep with `bin`.
* **The wrap is safe too**: binary `1111 → 0000` flips four bits, but gray
  `1000 → 0000` flips only the MSB. One bit per step *all the way around
  the circle* — that closure is the reason the code exists.

This is not an exotic trick — it is how **every asynchronous FIFO works**.
The `xpm_fifo_async` macro from Module 07 gray-codes its read and write
pointers internally before passing them between the two clock domains;
you've been shipping gray counters since that module without knowing it.
Build one yourself once, and the XPM documentation stops being magic.

## Which counter, when

| You are counting... | Species | Wrap? | Example |
|---|---|---|---|
| pulses, to keep 1 in N | modulo-N (prescaler) | wrap **is** the output | min-bias trigger prescale |
| cycles, to make slow ticks | modulo-N clock enable | wrap is the tick | heartbeat LED, 1 kHz strobe |
| time / event ordinals | free-running wrapping | yes — consumers unwrap | capstone's 16-bit timestamp |
| errors, alarms, overflows | saturating | **never** — peg at max | link CRC errors, FIFO overflows |
| anything read by another clock domain | gray-coded | yes (safely, 1 bit/step) | async FIFO pointers |

## Run it

```bash
cd modules/11_counters_in_practice

# Prescaler: 12 pulses in, exactly 3 out
ghdl -a --std=08 src/prescaler.vhd tb/tb_prescaler.vhd
ghdl --elab-run --std=08 tb_prescaler --wave=prescaler.ghw

# Saturating counter: to the ceiling and refusing to wrap
ghdl -a --std=08 src/saturating_counter.vhd tb/tb_saturating_counter.vhd
ghdl --elab-run --std=08 tb_saturating_counter --wave=saturating_counter.ghw

# Gray counter: one bit per step, including the wrap
ghdl -a --std=08 src/gray_counter.vhd tb/tb_gray_counter.vhd
ghdl --elab-run --std=08 tb_gray_counter --wave=gray_counter.ghw
```

Expected output:

```
tb/tb_prescaler.vhd:181:5:@366ns:(report note): ALL TESTS PASSED
tb/tb_saturating_counter.vhd:144:5:@256ns:(report note): ALL TESTS PASSED
tb/tb_gray_counter.vhd:158:5:@286ns:(report note): ALL TESTS PASSED
```

Worth a minute in the waveforms (`gtkwave prescaler.ghw`): put `pulse_in`,
`pulse_out`, and the DUT's `count` in the pane and watch the count climb on
each input pulse and fire-on-wrap — including inside the back-to-back
bursts, where `pulse_in` stays high across consecutive edges and each cycle
counts as a pulse (the contract from the top of this page, visible). In
`gray_counter.ghw`, display `gray` and step through the 15 → 0 wrap: one
bit moves.

The testbenches themselves are worth reading as testbenches: `tb_gray_counter`
runs a reference model alongside the DUT (Module 04's method) but *also*
asserts the Hamming-distance-equals-1 property directly — because DUT and
model share the bin-to-gray formula, a bug in the formula would pass check
(a) and be caught only by check (b). Test the property you actually need.

## Design-choice notes

* **Why does the prescaler register `pulse_out` instead of decoding it
  combinationally?** The output leaves this block and goes to trigger
  logic; a registered output is glitch-free and starts the downstream
  timing path fresh from a flip-flop. Cost: the output fires one cycle
  after the Nth pulse is sampled — one tick of latency, invisible to
  physics, and the testbench pins it down exactly.
* **Why fire on the Nth pulse rather than the first?** Both are "1 in N";
  firing on wrap means the count register reads "pulses since last accept",
  which is what a shifter expects a scaler tap to show. Firing on
  `count = 0` would accept the *first* pulse after reset — a subtle bias
  at run start when prescales are large.
* **Why doesn't the saturating counter register its `saturated` flag?**
  Same trade as Module 03's stretcher output: it's one AND gate off a
  register, and registering it would delay the alarm a cycle for nothing.
  If it fed a long timing path you'd register it — now you know the price
  of both.
* **Why does the gray counter keep a binary register at all?** Because
  increment is trivial in binary and awkward in gray. The pair
  (`bin` private, `gray` public) is the standard shape: compute in the
  convenient encoding, publish in the safe one. The XPM FIFOs do the same.
* **Why no `saturated`-style flag on the prescaler or gray counter?**
  Nothing to flag: their wraps are correct behaviour. A flag is an
  interface for a *reader who might be misled* — only the saturating
  counter has one of those.

## Exercise

Build the standard beam-monitor pattern: a **rate meter** — a scaler with a
gate.

1. Create `src/rate_meter.vhd` with generic `WINDOW_CYCLES : natural :=
   100_000` (1 ms at 100 MHz) and ports `clk`, `rst`, `pulse_in : in
   std_logic`, `rate : out unsigned(15 downto 0)`.
2. Inside: one counter counts *cycles* 0 to `WINDOW_CYCLES - 1` (a modulo-N
   machine — you just built one); a second counts *pulses* (mind the
   contract). When the window counter wraps, **latch** the pulse count into
   `rate`, clear the pulse counter, and start the next window. `rate` then
   updates once per millisecond and holds steady between updates — exactly
   what a control-room display or an EPICS record wants to read.
3. Testbench: with a shortened window (say `WINDOW_CYCLES => 50`), send a
   known number of pulses in the first window, a different number in the
   second, and assert `rate` shows each count after each latch — and
   *doesn't change* mid-window.
4. Think it through: should the pulse counter saturate? (What does a
   wrapped rate reading do to a beam-loss interlock that watches it?
   You know the rule of thumb.)

## Key takeaways

* DAQ firmware is mostly counters, and they come in **species**: modulo-N
  (prescalers, clock enables), free-running wrapping (timestamps, event
  numbers), saturating (errors, alarms), gray-coded (anything crossing
  clock domains). Pick deliberately.
* **Wrap semantics are a design decision.** The prescaler's wrap is its
  output; the timestamp's wrap is in the interface contract (consumers
  unwrap); the error counter's wrap would be a lie, so it saturates.
  Monotonic bookkeeping wraps; diagnostics saturate.
* A **prescale factor is a physics systematic** — record it with the data,
  because every downstream rate gets multiplied by it.
* **Count events, not cycles**: enable-style inputs count every high cycle,
  so the interface contract is 1-cycle synchronous pulses (Module 04's
  one-shot). Emit 1-cycle pulses with the default-then-override idiom.
* A count crossing clock domains must be **gray-coded and registered** —
  one bit per step, glitch-free, off by at most one increment at the
  reader. Async FIFO pointers work exactly this way.
* Test the **property**, not just the value: the gray testbench asserts
  Hamming distance = 1 directly, independent of the conversion formula.

**Next:** [Module 12 — ILA and VIO: seeing inside a running FPGA](../12_ila_vio_debugging/)
