# Step 2 — The Ring Buffer: Capturing the Past

**Time: ~30 minutes** · File: [`src/ring_buffer.vhd`](../src/ring_buffer.vhd)

**Goal:** build the block that makes a *self*-triggering digitizer possible
at all — a circular buffer that writes continuously so that, when the
trigger finally arrives, the samples from *before* the trigger already
exist. Along the way: pointer arithmetic that wraps for free, the access
pattern that makes synthesis infer block RAM, and why reads take a cycle.

## Where the concepts came from

| Concept in this step | Taught in |
|----------------------|-----------|
| counters and wrap-around arithmetic | [Module 03](../../modules/03_clocks_and_registers/) |
| small control FSMs | [Module 05](../../modules/05_state_machines/) |
| block RAM inference, ring buffers, read latency | [Module 07](../../modules/07_memories_and_fifos/) |

## The pre-trigger story

Here is the problem no software system can solve after the fact: the
discriminator fires *on the leading edge* of the pulse — which means that
by the time you know you want the waveform, its beginning (and the baseline
just before it, which offline analysis needs for pedestal checks and
pile-up rejection) is already in the past.

The solution, used by every waveform digitizer ever built: **never stop
writing**. Samples stream into a 64-deep circular buffer on every clock,
each new one overwriting the oldest. The buffer permanently holds the last
64 samples of history. When the trigger arrives, the block writes
`POST_TRIGGER = 40` *more* samples and then freezes. The frozen buffer
holds:

```
   24 pre-trigger samples  (64 - 40: history that predates the trigger)
 + 40 post-trigger samples (the pulse and its tail)
 = 64 samples, a window straddling the trigger
```

The capture life cycle is a three-state Moore FSM (Module 05):

```
 armed ──trig──► capturing ──40 writes──► frozen ──rearm──► armed
 (writing        (still                   (readable,
  forever)        writing)                 not writing)
```

**Software vs hardware.** In software you'd buffer recent samples with a
deque and prune it — work proportional to the data rate, competing for CPU.
Here the "buffering" is a RAM write that happens *every 10 ns, forever,
with zero involvement from anything else*. It is not a task that runs; it
is a structure that exists. This is Module 00's point in its purest form:
continuous, unconditional parallel work is what hardware is *made of*.

## Pointer arithmetic: overflow as a feature

```vhdl
signal wr_ptr : unsigned(ADDR_BITS - 1 downto 0) := (others => '0');
...
ram(to_integer(wr_ptr)) <= wr_data;
wr_ptr                  <= wr_ptr + 1;   -- wraps at 64: the "ring"
```

There is no `if wr_ptr = 63 then wr_ptr <= 0` and no modulo operator. The
pointer is exactly `ADDR_BITS = 6` bits wide, so `63 + 1 = 0` *by
construction* — a 6-bit adder physically has nowhere to put the carry. The
wraparound that step 1 treated as a trap (the pedestal clamp!) is here the
entire mechanism. Same silicon behavior, opposite moral: unsigned wrap is
neither good nor bad, it is a fact about fixed-width adders that you either
guard against or build upon — deliberately, in both cases.

The same trick locates the oldest sample. When the buffer freezes, the
next location that *would* have been written holds the oldest surviving
sample, so readout simply starts there:

```vhdl
if post_count = 1 then
  state  <= frozen;
  rd_ptr <= wr_ptr + 1;   -- oldest sample = next write location
```

(`wr_ptr + 1` rather than `wr_ptr` because `wr_ptr` itself is still being
incremented on this same edge — Module 03's "assignments take effect at the
next edge" rule, biting exactly where you'd expect it to.) From there
`rd_ptr` increments per read, wraps the same way, and delivers all 64
samples **oldest-first** — time-ordered, which is what the packet format
promises offline.

## Block RAM inference

64 × 12 bits could live in flip-flops, but a real digitizer window (16k
samples × 14 bits × 16 channels) cannot — it lives in the FPGA's dedicated
**block RAM**, and Module 07's rule is that you don't instantiate BRAM, you
*describe a pattern synthesis recognizes*:

```vhdl
type ram_t is array (0 to depth - 1) of unsigned(11 downto 0);
signal ram : ram_t := (others => (others => '0'));
```

with all access inside the clocked process — write when armed/capturing,
and a **registered read** when frozen:

```vhdl
if rd_en = '1' then
  rd_data  <= ram(to_integer(rd_ptr));
  rd_ptr   <= rd_ptr + 1;
  rd_valid <= '1';
end if;
```

Because `rd_data` is assigned inside `rising_edge(clk)`, the read is
*synchronous*: address presented on one edge, data available after the
next. That matches the physical BRAM primitive, which has a mandatory
output register — an *asynchronous* read (`rd_data <= ram(...)` as a
concurrent statement) would force synthesis into distributed LUT-RAM
instead, fine at 64 entries and impossible at 16k.

**Read latency is therefore one cycle, and it is not negotiable.** The
interface makes it explicit: pulse `rd_en`, and *one cycle later* the
sample appears with `rd_valid = '1'`. The `rd_valid` strobe is a small
kindness to the reader (step 3's FSM) — it never has to count cycles, just
wait for the flag. Get used to this pattern; every memory interface you
will ever meet, from BRAM to DDR4, is "request now, data later, qualified
by a valid".

Two more BRAM realities encoded in this file:

* **The RAM contents are not reset.** Look at the reset branch: pointers
  and state reset, `ram` does not. BRAM storage has no reset input; after
  power-up or `rst`, the buffer holds garbage until 64 fresh samples have
  been written. That is why the step-4 testbench "warms up" for 200 samples
  before the first trigger — and why real digitizers specify a minimum
  arming time.
* **Rearm does not erase.** After `rearm`, writing resumes where it froze;
  for the next 64 samples the buffer contains a mix of old event and new
  baseline. Trigger again too soon and your "pre-trigger" samples are the
  previous event's tail. Real systems enforce a minimum retrigger spacing;
  ours relies on the event builder's readout time plus generous testbench
  spacing — an honest simplification, noted here so you know it's there.

## Simplifications versus the module version

Module 07's FIFO tracks full/empty and guards against overrun and
underrun. A digitizer capture buffer needs none of that: overwriting old
data is the *point* while armed, and readout happens only when frozen, when
exactly 64 valid samples exist by construction. Capture → freeze → drain →
rearm is the whole contract. One clock domain, too — the dual-clock version
is Module 08's problem (and the README's "where next").

## Checkpoint (~5 minutes)

```bash
ghdl -a --std=08 src/pedestal_subtract.vhd src/discriminator.vhd src/ring_buffer.vhd
```

Silence means success. Then, on paper: the trigger reaches the ring buffer
**two cycles after** the crossing sample was written (step 1's checkpoint).
At which index (0–63) of the read-out, oldest-first window does the
crossing sample therefore land? (Answer: the window holds the 24 samples
written up to and including the trigger cycle, then 40 more; the crossing
sample was written 2 cycles before the trigger arrived, so it sits at index
24 − 1 − 2 = **21**. Step 4's testbench quietly depends on this: it checks
that the first samples of every packet are baseline and that the peak —
near index 24 — is inside the window.)

**Next:** [Step 3 — the event builder](step3_event_builder.md), which
drains this buffer into a packet the outside world can trust.
