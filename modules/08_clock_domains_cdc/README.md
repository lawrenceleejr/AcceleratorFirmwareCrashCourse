# Module 08 — Clock Domains and CDC

**Time: ~30 minutes** · Prerequisite: [Module 07](../07_memories_and_fifos/)

Every module so far has lived in a single, tidy universe: one `clk`, every
flip-flop marching to the same edge. Real DAQ firmware is not like that. In
this module you'll build the two small, boring, utterly essential circuits
that let signals cross safely between clock domains — and meet the one
hardware failure mode that **no simulation can show you**.

## The physics problem

Count the clocks in a real readout chain:

* the **ADC** ships samples on its own clock, recovered from the sampling
  clock you sent it;
* the experiment distributes a **global machine clock** — at the LHC, the
  40.079 MHz bunch clock, so trigger logic can think in bunch crossings;
* the **backend serial link** to the event builder runs at whatever rate the
  transceiver demands;
* and some signals respect no clock at all: an external trigger formed in
  another subsystem, a beam-abort line, the manual reset button on the crate.

Each clock defines a **domain**: the set of flip-flops driven by it. Inside
one domain, life is what Module 03 promised — the tools check setup and hold
for every path, and if timing closes, every flop samples clean data. The
moment a signal generated in domain A is sampled by a flop in domain B, all
of those guarantees evaporate: the edges of the two clocks have **no defined
phase relationship**, so sooner or later the data will change *exactly* as
the destination flop samples it.

Crossing domains incorrectly is the #1 source of firmware bugs that pass
every simulation and then fail on the bench **once an hour** — a nightmare
during a beam run, because "once an hour, unreproducibly" is precisely the
signature that eats a shift crew alive.

## Metastability: a flip-flop on the potential barrier

You already have the right mental picture. A flip-flop's storage node is a
**bistable element**: two cross-coupled inverters form a potential landscape
with two wells ('0' and '1') separated by a barrier. Normal clocking drops
the ball firmly into one well. But if the input changes inside the flop's
**setup/hold window** — the few tens of picoseconds around the clock edge
when it's deciding — the ball gets kicked onto the **top of the barrier**.

```
   energy
     ^         (metastable point)
     |               _*_
     |              /   \
     |         ____/     \____
     |        /               \
     |    \__/                 \__/
     |    '0'                  '1'
     +------------------------------> storage-node voltage
```

A ball balanced on a barrier top eventually falls — but *when* is random
(exponentially distributed, like a decay time) and *which way* is a coin
flip. While it hovers, the flop's output is an invalid in-between voltage.
Two consequences, both nasty:

1. **Downstream logic sees an undefined value.** Some gates read it as '0',
   others as '1', at the same instant.
2. **Fan-out disagrees.** If the metastable signal feeds two places — say,
   an FSM's next-state logic in two branches — the two copies can resolve
   *differently*. Your one-hot FSM jumps to a state that doesn't exist.

> **Software developer's note.** Nothing in software prepares you for this.
> The nearest cousin is a race condition between threads — but a race gives
> you one of the *valid* interleavings in the wrong order, and you can
> reach for a mutex. Metastability gives you a value that is *neither* 0
> nor 1, and there is no lock to take: the "shared memory" is a physical
> voltage, and the arbiter is thermodynamics.

## Why simulation can't save you

GHDL's flip-flops are ideal digital objects — they sample instantly and
never hover. A raw wire crossed between domains, a whole bus synchronized
bit-by-bit: both simulate *perfectly*. That's why CDC is taught as
**discipline and structure**, not "test until it works". You cannot test
your way out; you can only build crossings whose structure is safe by
construction, and audit every one of them.

You can't make metastability impossible — but you can make it irrelevant.
The probability that a metastable flop has *not* resolved decays
exponentially with the time you give it: **MTBF ∝ e^(t_resolve/τ)**, with τ
a device constant of a few tens of picoseconds. Granting one extra clock
period of resolution time multiplies the mean time between failures by an
astronomical factor — from "once an hour on the bench" to "longer than the
age of the universe". One extra flip-flop buys you that period.

## `sync_2ff` — the two-flop synchronizer

That insight, made hardware, is the whole of `src/sync_2ff.vhd` — THE
primitive of clock-domain crossing:

```vhdl
sync : process (clk)
begin
  if rising_edge(clk) then
    ff_meta <= async_in;  -- may sample mid-transition: metastability lands HERE
    ff_sync <= ff_meta;   -- samples a value that has had a full period to settle
  end if;
end process sync;

sync_out <= ff_sync;
```

The first flop is *allowed* to go metastable; it then gets a full clock
period to fall into a well before the second flop samples it. The rest of
the design only ever sees `sync_out` — one flop, one resolved value,
everyone agrees.

One more thing the source carries, purely for the Xilinx tools:

```vhdl
attribute async_reg : string;
attribute async_reg of ff_meta : signal is "true";
attribute async_reg of ff_sync : signal is "true";
```

`ASYNC_REG` tells Vivado two things: *these flops are a synchronizer*, so
timing analysis should treat the incoming async path accordingly instead of
trying (and failing) to meet setup on it; and *place them adjacent* — same
slice, minimal wire between them — so the second flop gets the largest
possible fraction of the clock period as resolution time. GHDL just carries
the attribute along; it costs nothing in simulation.

### The rules that follow

The 2FF synchronizer is safe for **one bit**. Everything else follows from
taking that restriction seriously:

* **Never synchronize a multi-bit bus with N parallel 2FF synchronizers.**
  Each bit resolves independently, possibly on different edges — the
  destination reads a **torn value** that never existed. A binary counter
  crossing domains mid-increment from `0111` to `1000` changes all four
  bits at once; the reader can catch any of the 16 combinations. Garbage.
* **Buses cross via gray code, a handshake, or an async FIFO.** A
  gray-coded counter changes exactly **one bit per increment**, so however
  the sampling edge falls you read either the old value or the new one —
  both real. This is precisely how the read/write pointers inside every
  async FIFO cross domains, including Module 07's FIFO discipline done
  dual-clock. In real Xilinx projects you reach for the pre-audited XPM
  primitives: `xpm_cdc_*` for signals, `xpm_fifo_async` for data streams.
* **A fast pulse can be missed entirely.** A single-cycle pulse from a fast
  domain can rise and fall *between* two edges of a slower clock — the
  sampling theorem strikes again; this is aliasing, and you already know
  aliasing. Levels are safe to synchronize; pulses need the next circuit.

## `pulse_cdc` — crossing a pulse with a toggle

The physics use case: an external trigger pulse is formed in the
machine-clock domain and must fire the readout FSM in the DAQ clock domain,
as exactly one clean cycle of the DAQ clock. The trick is to convert the
pulse into the easy case — a level — and back:

```
        clk_src domain           ::          clk_dst domain
                                 ::
                +----------+     ::     +-----------------+
 pulse_in ----->| toggle FF|--------(1 bit)-->|  sync_2ff  |----+----------+
                | (T flop) |     ::     +-----------------+    |          |
                +----------+     ::                        +---v---+   +--v--+
   one EDGE per pulse            ::                        | 1-cyc |   | XOR |--> pulse_out
                                 ::                        | delay |-->|     |
                                 ::                        +-------+   +-----+
                                 ::                     edge detect: level -> pulse

 pulse_in    ___|~|_____________________|~|______________      (1 x clk_src wide)
 toggle_src  _____|~~~~~~~~~~~~~~~~~~~~~~~|______________      (a LEVEL: flips per pulse)
 toggle_dst  ________|~~~~~~~~~~~~~~~~~~~~~~~~|__________      (2FF-synced, ~2 clk_dst later)
 pulse_out   ________|~|______________________|~|________      (1 x clk_dst wide)
```

Source domain: a toggle flip-flop flips once per input pulse, so each pulse
becomes one *edge* of a slowly-changing level — exactly what a 2FF
synchronizer handles well. That level is the **only** signal crossing the
boundary. Destination domain: XOR the synchronized level with a one-cycle
delayed copy of itself; any difference means "a toggle happened", giving a
registered, glitch-free, exactly-one-`clk_dst`-cycle pulse:

```vhdl
toggle_dst_prev <= toggle_dst;
pulse_out       <= toggle_dst xor toggle_dst_prev;  -- '1' for one cycle per edge
```

`src/pulse_cdc.vhd` instantiates `sync_2ff` rather than writing the two
flops inline — your first taste of hierarchy doing policy work: every
crossing in a design becomes greppable by entity name, which is exactly what
a firmware review wants.

**The limitation, stated honestly:** consecutive pulses must be spaced by
more than a few `clk_dst` periods (3–4: two for the synchronizer, one for
the edge detector, plus margin). Two toggles inside that window cancel — the
level flips back before the destination ever samples the intermediate value,
and **both pulses vanish silently**. If your triggers can burst faster than
that, this is the wrong circuit: use an async FIFO and count them properly.

### Resets, in two sentences

Reset networks cross domains too, and the full treatment (assert a reset
asynchronously so it works even with a dead clock, but *release* it
synchronously in each domain so all flops leave reset on the same edge) is
its own classic circuit — the "async assert, sync release" reset
synchronizer. This course sidesteps the whole topic by giving every domain
its own active-high **synchronous** reset, generated and released in that
domain — which is why `pulse_cdc` has `rst_src` *and* `rst_dst`.

## Run it

```bash
cd modules/08_clock_domains_cdc

ghdl -a --std=08 src/sync_2ff.vhd src/pulse_cdc.vhd tb/tb_pulse_cdc.vhd
ghdl --elab-run --std=08 tb_pulse_cdc --wave=pulse_cdc.ghw
```

Expected output:

```
tb/tb_pulse_cdc.vhd:127:5:@725ns:(report note): ALL TESTS PASSED
```

The testbench is unlike every previous one in the course: it contains **two
clock processes** with periods of 10 ns and 7 ns — a deliberately
non-integer ratio, so the relative phase of the two clocks drifts every
cycle and the toggle edge sweeps across the destination clock edge instead
of landing in the same place forever. It fires five pulses in the source
domain with generous spacing, while a monitor process in the destination
domain counts arrivals and asserts each one is exactly one `clk_dst` cycle
wide.

In GTKWave, drag in `pulse_in`, `toggle_src`, `toggle_dst`, and `pulse_out`
(the DUT internals are under `tb_pulse_cdc → dut`) and watch the waveform
diagram above play out for real.

Read the header comment of the testbench carefully: it proves *functional*
behavior only. GHDL's flops never go metastable, so this test passing tells
you the toggle bookkeeping is right — the metastability safety comes from
the **structure** (2FF, single bit, ASYNC_REG), not from the green message.
A broken crossing would print `ALL TESTS PASSED` just as cheerfully. That
honesty is the point of the module.

## Design-choice notes

* **Why does everything else in this course use a single clock?** Because
  the strongest CDC strategy is to **minimize crossings** and confine the
  unavoidable ones to small, audited, named modules like these two. Real
  experiments' firmware reviews literally walk a list of every crossing in
  the design; Vivado ships `report_cdc` to generate that list. A design
  with three crossings, all instances of `sync_2ff` or an async FIFO, is
  reviewable in minutes. A design with clocks braided through every file is
  not reviewable at all.
* **Why no reset on `sync_2ff`?** It holds no state worth resetting — its
  output is undefined for the first two cycles after configuration no
  matter what, and consumers must tolerate that anyway.
* **Why is `pulse_out` registered rather than a bare XOR?** A registered
  output is glitch-free and exactly one cycle wide, so it can drive an FSM
  enable directly. It costs one flop and one cycle of latency — cheap.
* **Why does the edge detector track `toggle_dst` during reset?** So a
  toggle that arrives while the destination domain is held in reset is
  swallowed, instead of erupting as a spurious pulse the moment reset
  releases. Read the comment in `edge_detect` — that's a real field bug.
* **Why XPM in real projects?** `xpm_cdc_single`, `xpm_cdc_gray`,
  `xpm_fifo_async` are Xilinx-maintained, pre-constrained, pre-audited
  versions of exactly these structures. Writing your own (as here) is for
  understanding; instantiating theirs is for shipping. Module 09 shows how.

## Exercise

Two options, both drawn from real readout firmware:

1. **A busy-level crossing.** The readout FSM (destination domain) asserts
   `busy` while processing an event; the trigger logic (source domain) must
   see it to veto further triggers. Build `busy_cdc`: a `sync_2ff` carrying
   the level *backwards*, from `clk_dst` to `clk_src`. Write a testbench
   with both clocks. Then articulate, in one paragraph, why a **level** is
   the easy case that needs no toggle trick — what property does `busy`
   have that the trigger pulse didn't? (Think: how long does it stay valid
   relative to the sampling clock, and does missing its first cycle or two
   matter?)
2. **Gray-code a counter.** Write a function converting a 4-bit unsigned
   binary count to gray code (`gray = bin xor shift_right(bin, 1)`), and a
   testbench that walks all 16 increments (including the 15 → 0 wrap) and
   asserts that consecutive gray values differ in **exactly one bit**.
   You've just verified the property that makes async FIFO pointers safe.

## Key takeaways

* A flip-flop whose input changes in its setup/hold window is a bistable
  element kicked onto the potential barrier: it resolves after an unbounded
  random time, to a random side, and fan-out copies can disagree.
* **Simulation cannot show any of this.** CDC correctness comes from
  structure and discipline, never from a passing testbench.
* The **two-flop synchronizer** is the primitive: one full period of
  resolution time improves MTBF exponentially. Single bits only, and mark
  the flops `ASYNC_REG`.
* Never parallel-synchronize a bus — use **gray code**, a handshake, or an
  **async FIFO** (`xpm_cdc_*`, `xpm_fifo_async` in practice).
* Pulses cross via the **toggle trick** — pulse → level → sync → edge — and
  its spacing limit (a few `clk_dst` periods) is a real contract, not a
  footnote.
* Minimize crossings; confine each one to a named, audited module. Your
  future self, running `report_cdc` at 3 a.m. during a beam run, will be
  grateful.

**Next:** [Module 09 — The Vivado / Xilinx flow](../09_vivado_xilinx_flow/)
