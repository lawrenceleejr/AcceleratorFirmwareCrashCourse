# Module 07 — Memories and FIFOs

**Time: ~30 minutes** · Prerequisite: [Module 06](../06_arithmetic/)

In this module you build the single most important structure in digitizer
firmware: a **circular waveform-capture buffer** with pre-trigger memory.
Along the way you'll learn how memory actually works inside an FPGA — block
RAM, the coding template that *infers* it, the one-cycle read latency that
comes with it — and meet the FIFO, the universal shock absorber of every DAQ
chain.

## The physics problem: you can't trigger on the past

An ADC digitizes your detector signal at one sample per clock. You want the
full pulse: baseline, leading edge, peak, tail. But here's the trap — **you
cannot know a pulse happened until after its leading edge has crossed
threshold.** By the time the discriminator fires, the quiet baseline before
the pulse is already gone. A naive design that "starts recording on trigger"
records everything *except* the part you need for pedestal and pile-up
analysis.

The only solution is to have been recording all along:

> Write samples continuously into a **ring** of memory, overwriting the
> oldest. When the trigger fires, let a configurable number of
> **post-trigger** samples land, then **freeze**. The frozen ring holds a
> window straddling the trigger — including samples from *before* it.

This is why every oscilloscope has a "horizontal position" knob and every
physics digitizer (CAEN, SIS, your experiment's custom board) is built around
exactly this structure. With a 64-deep ring and 16 post-trigger samples, a
frozen capture looks like:

```
            ring of 64 samples (addresses wrap: 63 -> 0)

     ... ──────────────────── time ────────────────────►
    ┌────┬────┬────┬─────┬──────┬────┬────┬────┬────┬────┐
    │    │    │    │ ... │ trig │    │    │ .. │    │    │
    └────┴────┴────┴─────┴──────┴────┴────┴────┴────┴────┘
      ▲                     ▲                          ▲
   oldest sample        the sample that            newest sample
   (wr_ptr: 47 clocks   fired the trigger          (trig + 16)
   BEFORE the trigger)
      └────── 47 pre-trigger ──────┘└── 16 post-trigger ──┘

   readout: rd_ptr starts at the oldest sample and walks the
   ring in age order, wrapping, until all 64 are out.
```

47 + 1 + 16 = 64: the depth of the ring fixes how far into the past you can
see. Want more baseline? Deeper ring or fewer post-trigger samples.

## Memory in an FPGA: LUTs vs block RAM

Where do 64 (or 64k) samples actually live? An FPGA gives you two kinds of
memory:

* **Distributed RAM** — the same LUTs that implement your logic can each
  store a few dozen bits. Fine for tiny buffers (a 16-deep shift register),
  wasteful for anything real: your waveform would eat the logic fabric.
* **Block RAM (BRAM)** — dedicated SRAM blocks of ~36 kbit each (Xilinx
  "BRAM36"), physically separate from the logic. A mid-size Kintex has over
  a thousand of them: tens of megabits. **This is where waveforms live.**

Here's the part that surprises software people: you don't *instantiate* a
BRAM by name (no `RAMB36E2` in this course's code). You **infer** it — you
write a plain VHDL array in a specific shape, and the synthesizer recognizes
the pattern and maps it onto BRAM silicon. Portable, readable, and the shape
itself teaches you the hardware's rules.

## The inference template

From `src/ring_buffer.vhd`:

```vhdl
type ram_t is array (0 to depth - 1) of unsigned(data_bits - 1 downto 0);
signal ram : ram_t;
```

and inside the clocked process, a **synchronous write**:

```vhdl
ram(to_integer(wr_ptr)) <= sample_in;   -- lands on this rising edge
```

and — the key discipline — a **synchronous read**:

```vhdl
if rd_en = '1' then
  rd_data  <= ram(to_integer(rd_ptr));  -- appears one clock LATER
  rd_ptr   <= rd_ptr + 1;
  rd_valid <= '1';
end if;
```

Both the read and the write happen *inside* the clocked process. That means
`rd_data` is a register: you present an address on one edge, the data shows
up on the next. **BRAM reads have a one-cycle latency, always.**

**Software analogy — and where it breaks.** In C++, `x = ram[i];` is
"instant" — the memory hierarchy's latency is real but hidden from you by
the language. In hardware nothing is hidden: memory access latency is
explicit, visible in your source code, and *yours to manage*. If a block
downstream needs to know which cycle carries real data, you must send a flag
alongside — that's the `rd_valid` pattern above: a `'1'` registered on the
same edge as the read, so it arrives at the consumer in the same cycle as
the data. Latency like this propagates through designs (a filter feeding a
BRAM feeding a serializer accumulates cycles), and tracking it with valid
flags instead of counting cycles in your head is what keeps large designs
sane.

Why not just read asynchronously (`rd_data <= ram(to_integer(rd_ptr));` as a
concurrent statement)? Because BRAM silicon *physically has* a registered
output — an unregistered read is something only LUTs can do, so the
synthesizer would be forced to build your array out of distributed RAM.
For 64 × 12 bits it would even work; for a real 8k-sample buffer it would
devour the chip. Accept the one-cycle latency and get the dedicated silicon.

## Pointers that wrap for free

The ring needs a write pointer that goes 0, 1, … 62, 63, 0, 1, … forever.
In Module 06, `unsigned` wraparound was the trap that turned your pedestal
subtraction negative. Here it's the feature:

```vhdl
signal wr_ptr : unsigned(addr_bits - 1 downto 0);
...
wr_ptr <= wr_ptr + 1;   -- 63 + 1 = 0: the ring closes itself
```

A 6-bit counter *is* a mod-64 counter — no comparison, no reset-to-zero
logic, zero extra gates. This is why memory depths in firmware are almost
always powers of two: the address counter and the wraparound come for free.
(A depth-100 ring would need an explicit `if wr_ptr = 99` check on every
pointer — more logic, more bugs.)

The capture controller wrapped around these pointers is a two-state Moore
machine straight out of Module 05 — `st_armed` (writing every cycle, waiting
for the trigger, then counting down `post_trigger` more writes) and
`st_frozen` (readout, waiting for `rearm`). Open `src/ring_buffer.vhd` and
read it top to bottom; every design decision is commented.

## FIFOs: the universal decoupling element

Take the same BRAM, the same two pointers, but let *both* run continuously —
writes push, reads pop — and you have a **FIFO** (first-in, first-out
queue): the standard way to connect a producer and a consumer that don't run
in lockstep. In a DAQ chain, FIFOs are everywhere:

* the ADC produces samples at a steady 100 MHz; the event builder consumes
  them in bursts — FIFO between them;
* the front end produces events at a rate set by the beam; the backend link
  drains them at a rate set by the network — FIFO between them.

The bookkeeping is exactly the ring buffer's: `wr_ptr`, `rd_ptr`, and two
derived flags — **empty** (pointers equal, nothing to read) and **full**
(write pointer has wrapped around to one slot behind the read pointer). The
iron rule is **never write a full FIFO**: the write is silently lost, and in
DAQ terms a lost word usually means a corrupted event and a desynchronized
event stream — far worse than a cleanly dropped one. Real systems propagate
the full flag *upstream* as **backpressure**: a `busy` that vetoes new
triggers until the FIFO drains. That busy time is **dead time**, the same
quantity you already correct your cross sections for — here you're looking
at the exact flip-flop it comes from.

For real projects, don't hand-roll production FIFOs: use the vendor's. On
Xilinx that's the **XPM macros** — `xpm_fifo_sync` (one clock) and
`xpm_fifo_async` (two clocks — that one solves a genuinely hard problem
you'll meet in Module 08). They're parameterized, verified, and map
optimally onto BRAM. This course still builds the ring buffer by hand for
two reasons: you can't trust a FIFO's flags until you understand the two
pointers behind them, and the triggered ring buffer — pre-trigger freeze and
all — *is* the actual digitizer pattern, which no off-the-shelf FIFO gives
you.

## Initializing memories: ROMs

One more trick for the toolbox: give the RAM signal an initial value —
`signal rom : ram_t := init_from_constant(...);` with the contents computed
by a constant table or a function evaluated at elaboration time — and never
write to it, and the synthesizer produces a **ROM**. The contents are baked
into the **bitstream** and appear pre-loaded at configuration, no loading
logic needed. This is how lookup tables get into firmware: calibration
curves, gain corrections, sine tables for an NCO, threshold maps. (It also
explains the no-reset rule below: initialization happens at *configuration*
time, not at reset.)

## Run it

```bash
cd modules/07_memories_and_fifos

# Analyze the design and its testbench
ghdl -a --std=08 src/ring_buffer.vhd tb/tb_ring_buffer.vhd

# Elaborate and run, recording waveforms
ghdl --elab-run --std=08 tb_ring_buffer --wave=ring_buffer.ghw
```

Expected output:

```
tb/tb_ring_buffer.vhd:229:5:@3356ns:(report note): ALL TESTS PASSED
```

The testbench feeds a deterministic ramp — sample *i* has value *i* mod 4096,
so **every value encodes its own write time**. It wraps the ring, triggers on
sample 100, waits for `frozen`, then reads all 64 samples and asserts each
one: the first value out must be **53** — a sample written 47 clocks *before*
the trigger. If that assertion passes, pre-trigger capture is proven, not
eyeballed. It also pins down the one-cycle `rd_valid` latency with a
single-cycle `rd_en` pulse, checks that nothing lands in the ring while
frozen, then re-arms and captures a whole second event.

In GTKWave (`gtkwave ring_buffer.ghw`), put `sample_in`, `trigger`,
`frozen`, `rd_en`, `rd_valid`, and `rd_data` in the wave pane and set the
buses to unsigned decimal. You can watch the ramp flow in, freeze 16 samples
after the trigger, and read back out starting at 53 — and see `rd_data` lag
`rd_en` by exactly one cycle.

## Design-choice notes

* **Why synchronous read?** Because that's what BRAM silicon does. The
  registered output is not an inconvenience to code around, it's the shape
  of the hardware. Reading asynchronously demotes your array to distributed
  RAM (LUTs) — fine at 64 entries, fatal at 8k. The `rd_valid` companion
  flag is the price, paid once, that makes the latency composable.
* **Why a power-of-two depth?** So the `addr_bits`-wide unsigned pointers
  wrap by themselves — Module 06's modular arithmetic as a feature. The
  generic is `addr_bits`, not `depth`, precisely so a non-power-of-two depth
  is unrepresentable.
* **Why is the RAM array not reset?** Look at the reset branch: pointers and
  flags clear, `ram` doesn't. Fabric reset reaches flip-flops, not the BRAM
  array — there is no reset pin on 36 kbit of SRAM contents, and trying to
  reset it in logic would mean a 64-cycle clearing FSM you don't need. After
  reset the ring holds stale garbage for its first 64 writes; the design
  simply doesn't allow a trigger to be *serviced* into meaningful data until
  real samples have flowed. (BRAM contents *can* be preset — but only from
  the bitstream at configuration, as in the ROM paragraph above.)
* **Why does the trigger not stop writing immediately?** Post-trigger
  samples are physics: the pulse's peak and tail arrive *after* the leading
  edge that fired the discriminator. `POST_TRIGGER` positions the trigger
  within the window — the firmware version of the scope's horizontal knob.

## Exercise

Pick one (or both):

1. **Runtime post-trigger.** Real digitizers let you move the trigger
   position from slow control without rebuilding the bitstream. Change
   `post_trigger` from a generic into an input port
   `post_trigger : in unsigned(addr_bits - 1 downto 0)`. What changes?
   The down-counter must now be loaded from a *signal* (sample it once, on
   the trigger edge — what goes wrong if the port changes mid-countdown and
   you didn't latch it?), the `natural range` counter becomes an `unsigned`,
   and the testbench should sweep at least two settings. Note what you can
   no longer guarantee at compile time: the elaboration-time `assert` on
   `post_trigger >= 1` has to become a runtime clamp or a documented rule.
2. **A real FIFO.** Build `sync_fifo.vhd`: same BRAM template, same two
   pointers, but free-running, with `full` and `empty` outputs. The classic
   trick: make the pointers *one bit wider* than the address
   (`addr_bits downto 0`); `empty` is pointer equality, `full` is equal
   lower bits with different top bits. Write a testbench that fills it to
   the brim, asserts `full`, drains it, asserts `empty` — and checks that
   every word comes out in order. Then read the `xpm_fifo_sync` docs and
   see how many of its ports you now understand.

## Key takeaways

* You can't record the past on demand — so digitizers **record always** and
  **freeze on trigger**. The ring buffer with pre-trigger memory is the
  pattern behind every scope and every waveform digitizer.
* FPGAs store bulk data in **block RAM**, which you **infer** with the
  array-in-a-clocked-process template, never instantiate by hand.
* **BRAM reads are synchronous**: data appears one cycle after the address.
  Track the latency with a `rd_valid` flag — in hardware, memory latency is
  explicit and yours to manage, unlike a C++ array index.
* Power-of-two depths make address pointers **wrap for free** — Module 06's
  wraparound, working for you.
* A **FIFO** is two free-running pointers around the same RAM; never let it
  overflow — propagate `full` upstream as busy/backpressure (that's your
  dead time). Use `xpm_fifo_sync`/`xpm_fifo_async` in production.
* ROM contents (calibration tables, LUTs) ride into the FPGA **inside the
  bitstream** via initialized constants — and, conversely, fabric reset
  never touches memory contents.

**Next:** [Module 08 — Clock domains and CDC](../08_clock_domains_cdc/)
