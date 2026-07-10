# Module 06 — Arithmetic and DSP

**Time: ~30 minutes** · Prerequisite: [Module 05](../05_state_machines/)

So far the course has moved bits around. This module does *math* with them —
and hardware math plays by rules that will feel alien after Python and C++:
there are no exceptions, values silently wrap, every bit of width is a design
decision with an area cost, and division is something you engineer your way
*around*, not call. You'll build the two arithmetic stages that sit at the
front of essentially every waveform digitizer: **pedestal subtraction** and a
**moving-average filter**.

## The physics problem

A 12-bit ADC digitizes a detector signal at 100 MSa/s — one sample per tick
of our 100 MHz clock, forever. Before anything downstream (trigger, charge
integration, energy histogram) can use those samples, the front end must:

1. **Subtract the pedestal.** The analog chain sits at a DC baseline of a few
   hundred counts (deliberately, so noise doesn't clip at zero). Every sample
   needs that baseline removed — and when a downward noise fluctuation dips
   *below* the pedestal, the result must clamp at zero, not wrap around to
   full scale.
2. **Filter the noise.** Averaging the last N samples suppresses white noise
   by √N — the digital descendant of the analog shaping amplifier. A 4-sample
   box filter is the simplest pulse shaping there is, and it contains every
   idea in a real trapezoidal trigger filter.

Both operations happen on every sample, every 10 ns. A CPU can't be in the
loop; this *is* firmware's home turf.

## `numeric_std`: vectors that know arithmetic

A `std_logic_vector` is just a bundle of wires — asking for `a + b` on one is
like asking C++ to add two `struct`s: what would it even mean? The IEEE
`numeric_std` package defines two types that are the *same wires* with an
arithmetic interpretation attached:

* `unsigned(11 downto 0)` — 12 wires read as a non-negative binary number,
  0 to 4095;
* `signed(11 downto 0)` — 12 wires read as two's complement, −2048 to +2047.

Because the bits are identical and only the *interpretation* differs,
converting between them is a **cast** — a `reinterpret_cast`, costing zero
gates:

```vhdl
signal slv : std_logic_vector(11 downto 0);
signal u   : unsigned(11 downto 0);

u   <= unsigned(slv);         -- same wires, now "a number"
slv <= std_logic_vector(u);   -- same wires, back to "a bundle"
```

Actual *conversions* (which may cost logic or lose information) have function
names:

```vhdl
u16 <= to_unsigned(1234, 16);    -- integer literal -> 16-bit unsigned
n   := to_integer(u16);          -- unsigned -> integer (for TBs, indices)
u16 <= resize(u12, 16);          -- widen (zero-extends; sign-extends signed)
u8  <= resize(u16, 8);           -- narrow (silently drops the top bits!)
```

> **Banned: `std_logic_arith` and `std_logic_unsigned`.** Old physics
> firmware is full of `use ieee.std_logic_arith.all;` and
> `use ieee.std_logic_unsigned.all;` — you'll recognize legacy code by those
> two lines, and by arithmetic done directly on `std_logic_vector`
> (`slv <= slv + 1;`). Despite living in the `ieee` library namespace they
> were never IEEE standards — they're Synopsys inventions, with vendor
> variants that disagree with each other, and the pair can't even be used
> together (each tries to define what a bare `std_logic_vector` "means"
> numerically, and they conflict). `numeric_std` *is* the standard, does
> everything they did, and forces you to say whether your vector is signed —
> which, as the pedestal subtractor is about to show, is exactly the thing
> you must never be vague about. When you inherit code that uses them: don't
> imitate it, and budget time to port it.

## Sizing rules: where the carry bit goes to die

`numeric_std` sizing rules are few and strict — learn these two and you know
the package:

* **`a + b` (and `a - b`) is as wide as the *wider* operand.** There is no
  automatic growth: adding two 12-bit numbers gives a 12-bit result, and
  4000 + 200 = 4200 doesn't fit, so you get 4200 − 4096 = **104**. The
  carry-out is simply *lost* — unless you make room first. Hence the
  **resize-then-add idiom**:

  ```vhdl
  -- WRONG: 12-bit + 12-bit -> 12-bit, carry-out lost, silent wrap
  sum12 <= a + b;

  -- RIGHT: widen first, THEN add; the result keeps the wider width (13)
  sum13 <= resize(a, 13) + b;
  ```

* **`a * b` gives the full `a'length + b'length` bits.** Multiplication is
  the one operation that *does* grow automatically, because the worst case
  genuinely needs 2N bits — a 12×12 multiply yields 24 bits, and you `resize`
  (i.e., consciously choose what to keep) afterwards.

**Software people, brace:** in Python, integers grow without bound; in C++,
signed overflow is undefined behaviour and unsigned wraps — but at least the
width was fixed at 32 or 64 bits by someone else. In hardware **every wrap is
silent, by construction** (an adder is a ring of carry logic; wrapping is
what the circuit *does*), and **the width is yours to choose**, per signal.
That's not a burden, it's the product: a 13-bit adder is half the area of a
26-bit one, and area is money, power, and timing slack. Sizing the arithmetic
*exactly* is the craft.

## Integers in VHDL — and where they belong

VHDL does have `integer` (and `natural`, its non-negative subtype). They're
ideal where a *number* is meant rather than *wires*: generics, constants,
loop indices, testbench bookkeeping — you've been using them that way since
Module 03. Ranged integer *signals* (`signal x : integer range 0 to 4095;`)
are legal and synthesizable, and you'll meet them in the wild. Course
convention, though: **datapath signals are `unsigned`/`signed` with explicit
widths.** Explicit widths mean explicit hardware — `unsigned(11 downto 0)`
tells every reader "12 wires, 12 flip-flops per register" at a glance, and
makes you *write down* the bit-growth decision at every arithmetic step
instead of letting a range bound imply it.

## Design A: pedestal subtraction, or, underflow is your problem

The whole design is one guarded subtraction ([src/pedestal_subtract.vhd](src/pedestal_subtract.vhd)):

```vhdl
if rising_edge(clk) then
  if rst = '1' then
    sample_out <= (others => '0');
  else
    if adc_data >= pedestal then
      sample_out <= adc_data - pedestal;   -- can't underflow: guarded
    else
      sample_out <= (others => '0');       -- clamp: no negative samples
    end if;
  end if;
end if;
```

Why the guard? Because `adc_data - pedestal` on `unsigned` values, with the
sample one count *below* the baseline, doesn't raise anything — it wraps:
250 − 300 = **4045**. In a DAQ that means every downward noise fluctuation
(half of them!) becomes a fake full-scale pulse. No exception, no sanitizer,
no crash — just wrong physics, at 100 MHz. So we compare first (comparators
on `unsigned` are cheap) and clamp.

The alternative you'll see in real code: widen both operands to 13-bit
`signed`, subtract, and clamp when the sign bit says negative. Same hardware
to first order — synthesis typically merges the compare and subtract into a
single carry chain either way — so pick the one that reads best. Here the
explicit clamp states the physics intent directly. The source file shows the
signed variant in a comment.

The output is **registered: one cycle of latency**, giving the logic a full
10 ns to settle before anything downstream samples it — Module 03's register
discipline applied to arithmetic, and a first taste of pipelining (below).

## Design B: the moving average — bit growth, free division, latency

[src/moving_average.vhd](src/moving_average.vhd) keeps the last
`2**LOG2_WINDOW` samples in a little shift register and maintains a running
sum by **adding the newest sample and subtracting the oldest** — one adder
and one subtractor per clock, for *any* window length, instead of an adder
tree over the whole window:

```vhdl
taps(0)                 <= sample_in;
taps(1 to window_c - 1) <= taps(0 to window_c - 2);

running_sum <= running_sum + sample_in - taps(window_c - 1);

sample_out  <= running_sum(sum_width_c - 1 downto LOG2_WINDOW);
```

Three lessons packed into those four lines:

* **Bit growth, sized exactly.** The sum of 2^k 12-bit values needs at most
  12 + k bits: the worst case is 2^k · (2^12 − 1) < 2^(12+k). So
  `sum_width_c = 12 + LOG2_WINDOW` — for the 4-sample filter, a 14-bit
  accumulator. One bit narrower and it wraps silently; one bit wider and
  you're paying for a flip-flop that can never be set. Do this arithmetic in
  a comment next to the constant, every time.
* **Division by 2^k is free.** The last line divides by the window length —
  by *not connecting the bottom k wires*. A bit slice: zero gates, zero
  delay. This is why the generic is `LOG2_WINDOW` and not `WINDOW`: the
  interface makes non-power-of-two windows unrepresentable, because a *true*
  division would need a large, slow divider circuit or a many-cycle pipelined
  IP core. **Never divide in hardware if you can help it** — restructure to a
  shift, a multiply-by-precomputed-reciprocal, or a lookup table. (Note the
  slice *truncates* toward zero, like integer division — the testbench's
  golden model must match that.)
* **Latency.** A sample first influences the output **two clocks** after it's
  captured (one for the sum update, one for the output register), and a box
  average is inherently centered half a window in the past. For DAQ readout,
  irrelevant. In a **trigger path, latency is a contract**: the event buffer
  must hold raw samples exactly long enough for the (fixed-latency) trigger
  decision to come back and claim them. A filter whose latency you didn't
  put in the timing budget means triggers that point at the wrong samples —
  events that are subtly, irreproducibly wrong. Count every register.

### What arithmetic costs on the FPGA

* **Comparisons** (`<`, `>=`, `=`) on `unsigned`/`signed` — essentially free
  and fast: a slice of the same carry chain an adder uses. Guard arithmetic
  with them liberally, as the pedestal subtractor does.
* **Multiplication** — Xilinx parts have **DSP48 slices**: hard (silicon, not
  LUT) multiplier blocks, 25×18-bit signed, with built-in accumulators.
  Write `a * b` and synthesis targets them automatically; a Kintex-7 has
  hundreds. Multiplies are cheap on FPGAs *because* of these — but they're a
  countable resource, budgeted like block RAM.
* **Division and modulo** — no hard block exists. `/` and `mod` by a
  non-constant will either fail synthesis or infer something huge and slow.
  Restructure: shift (power of two), multiply by a scaled reciprocal
  constant, or a lookup table.

### The fixed-point mindset

A physicist's reflex for `energy = raw * gain` is a `float`. FPGAs do
integers. The firmware idiom is **fixed-point**: scale your calibration
constants into integers *offline* — e.g. store `gain` as a 16-bit integer in
units of 1/65536, compute `raw * gain` (a single DSP48 multiply, 28 bits
out), and take the top bits, which *is* multiplication by the fractional gain
with the divide done by wire-slicing. Where the binary point sits lives in
your head and your comments, not in the hardware. Floating point does exist
(Xilinx Floating-Point IP), but costs multiple DSP slices and many cycles of
latency per operation — in a front end that mostly adds, compares, and scales
12-bit samples, it's almost never the right answer.

### Pipelining arithmetic

Why register between arithmetic stages at all? Because the clock period must
cover the *longest* logic path between any two registers (Module 03). One
giant expression = one long path = a slow clock for the *whole design*.
Cutting the expression with registers shortens every path; each stage then
works on a different sample in the same cycle — like the segments of a linac,
every stage busy at once. The moving average is naturally pipelined:
sum-update and divide-and-register overlap, so **throughput** stays at one
sample per clock while **latency** is two clocks. Keep those two numbers
separate — throughput is how fast data flows, latency is how stale it is —
and record both for every block in a trigger chain.

## Run it

Both designs come with self-checking testbenches. `tb_pedestal_subtract`
walks the clamp logic through its corners *and* explicitly demonstrates the
one-cycle latency (checking a registered output on the wrong cycle is the
classic testbench bug — the waits are commented edge by edge).
`tb_moving_average` drives a baseline, a step, and a synthetic pulse through
the filter and compares **every output sample** against a golden model — the
same filter re-implemented with plain integers and the same truncating
division — from the very first cycle, reset state and pipeline fill included.

```bash
cd modules/06_arithmetic

ghdl -a --std=08 src/pedestal_subtract.vhd tb/tb_pedestal_subtract.vhd
ghdl --elab-run --std=08 tb_pedestal_subtract

ghdl -a --std=08 src/moving_average.vhd tb/tb_moving_average.vhd
ghdl --elab-run --std=08 tb_moving_average
```

Expected output:

```
tb/tb_pedestal_subtract.vhd:134:5:@76ns:(report note): ALL TESTS PASSED
tb/tb_moving_average.vhd:142:5:@286ns:(report note): ALL TESTS PASSED
```

Worth seeing in waveforms (add `--wave=avg.ghw` to the elab-run line and open
it in GTKWave): drag `sample_in` and `sample_out` of `tb_moving_average` into
the wave pane and set their data format to *unsigned decimal*. You'll see the
step smeared over four samples and the pulse smoothed and delayed — pulse
shaping, live.

## Design-choice notes

* **Why compare-and-clamp instead of signed subtraction?** Equivalent
  hardware; the clamp states the intent ("no negative samples") in one
  glance. What matters is that *one of them* is there — the unguarded
  `adc_data - pedestal` is the bug.
* **Why is the window generic `LOG2_WINDOW` and not `WINDOW`?** So that
  illegal (non-power-of-two) windows can't even be *expressed*. Encoding
  constraints in the interface beats documenting them.
* **Why size the accumulator to exactly 12 + k bits?** Narrower wraps;
  wider wastes area. More important than the flip-flops saved is the habit:
  every width in a datapath should have a one-line justification you could
  write in a comment.
* **Why unsigned datapath signals rather than ranged integers?**
  `unsigned(13 downto 0)` shows the hardware (14 wires) at the declaration
  and makes every resize a visible, deliberate act. Ranged integers hide the
  width in arithmetic on the bounds.
* **Why is the pedestal a port rather than a generic?** Baselines drift with
  temperature and rate; real systems measure the pedestal periodically (or
  track it continuously) and update a register. A generic is frozen at
  synthesis time — right for structure (window length), wrong for
  calibration.

## Exercise

Build a **gated charge integrator** — `src/charge_integrator.vhd` — which is
literally a QDC (charge-to-digital converter, the classic beam-instrumentation
module):

* Ports: `clk`, `rst`, `sample_in : in unsigned(11 downto 0)` (assume already
  pedestal-subtracted), `gate : in std_logic`, and
  `charge : out unsigned(?? downto 0)`.
* While `gate` is high, accumulate `sample_in` into a running sum each clock;
  when `gate` falls, hold the total; when the next gate rises, clear and
  start again.
* **Size the accumulator so it cannot overflow** for a maximum gate length of
  1024 clocks (a 10.24 µs gate). Work it out the way this module sized the
  moving-average sum: 1024 = 2^10 samples of 12 bits each → how many bits?
  Put the arithmetic in a comment above the constant.
* Extend a copy of `tb_pedestal_subtract.vhd`: check a gate over a known
  pulse gives the pulse's exact sum, a zero-length gate gives zero, and —
  the case your accumulator width exists for — a full-length gate of
  all-full-scale samples gives exactly `1024 × 4095` with no wrap.

## Key takeaways

* `unsigned`/`signed` are **wires with an arithmetic interpretation**;
  casting to/from `std_logic_vector` is free reinterpretation, while
  `to_unsigned`/`to_integer`/`resize` are the real conversions. Use
  `numeric_std` only — `std_logic_arith`/`std_logic_unsigned` are
  non-standard relics.
* `a + b` keeps the width of the wider operand — **resize before adding** or
  lose the carry silently. `a * b` grows to the full 2N bits.
* Hardware arithmetic **wraps silently; there are no exceptions**. Bit width
  is a per-signal design decision with an area cost — size accumulators
  exactly (2^k values of N bits → N + k bits) and justify every width.
* Comparisons are cheap; multiplies map to hard **DSP48** blocks; **division
  is to be designed away** — shift by powers of two, multiply by reciprocals,
  or look it up.
* Physicists' floats become **fixed-point integers**, scaled offline.
* Registers between arithmetic stages buy clock speed; pipelining preserves
  **throughput** at the price of **latency** — and in a trigger path, latency
  is a contract you must keep on paper.

**Next:** [Module 07 — Memories and FIFOs](../07_memories_and_fifos/), where
those streams of filtered samples finally land somewhere: inferred block RAM,
a circular capture buffer, and the discipline of FIFOs.
