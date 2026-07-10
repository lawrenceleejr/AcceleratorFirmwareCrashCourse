# Step 1 — The Signal Chain: Pedestal Subtraction and the Discriminator

**Time: ~30 minutes** · Files: [`src/pedestal_subtract.vhd`](../src/pedestal_subtract.vhd), [`src/discriminator.vhd`](../src/discriminator.vhd)

**Goal:** build the two blocks every sample flows through before anything
else happens — the baseline remover and the trigger decision — and
understand two ideas that make them *DAQ* firmware rather than generic
logic: the zero-clamp, and thresholds as **run-time slow control**.

## Where the concepts came from

| Concept in this step | Taught in |
|----------------------|-----------|
| entities, ports, concurrent assignment | [Module 01](../../modules/01_entities_and_signals/) |
| comparators as combinational logic | [Module 02](../../modules/02_combinational_logic/) |
| clocked processes, registered outputs, edge detection | [Module 03](../../modules/03_clocks_and_registers/) |
| `unsigned` arithmetic and its wraparound traps | [Module 06](../../modules/06_arithmetic/) |

## Pedestal subtraction

A quiet PMT channel does not digitize to zero: the analog chain's DC
operating point — the **pedestal** — puts the baseline at a couple hundred
ADC counts. Everything downstream (thresholds, charge sums, zero
suppression) is simpler if quiet means zero, so the first stage subtracts
the pedestal from every sample. The whole design is one clocked process:

```vhdl
subtract : process (clk)
begin
  if rising_edge(clk) then
    if rst = '1' then
      sample_out <= (others => '0');
    else
      if sample_in >= pedestal then
        sample_out <= sample_in - pedestal;
      else
        -- Clamp: never let the subtraction wrap below zero.
        sample_out <= (others => '0');
      end if;
    end if;
  end if;
end process subtract;
```

Two design choices to internalize:

**The clamp is not decoration.** `sample_in` and `pedestal` are `unsigned`.
Module 06's warning applies with teeth here: if a noise fluctuation dips a
sample one count below the pedestal, `sample_in - pedestal` in unsigned
arithmetic wraps to 4095 — which downstream looks like the largest pulse
your detector has ever seen, once per noise fluctuation. The one-line
comparison before the subtraction is the difference between a working
trigger and a channel that fires continuously on nothing. (C++ people: this
is exactly `unsigned` underflow, and just as silent.)

**The output is registered.** The subtractor's result lands in a flip-flop
each rising edge. That costs one clock (10 ns) of latency and buys a short,
easily-timed combinational path — the standard trade of Module 03. Watch
this latency: it shows up again in step 4, where it shifts the capture
window by a cycle.

## The discriminator

The firmware descendant of the NIM discriminator module: compare the
cleaned sample against a threshold, emit a trigger on the leading edge.

The comparator itself is one concurrent statement — combinational,
always computing, like the front-end chip it models:

```vhdl
above <= '1' when sample_in >= threshold else '0';
```

But `above` alone is not a trigger. A scintillator pulse is tens of samples
wide, so `above` stays high for tens of consecutive clock cycles — used
directly, one physical pulse would trigger the readout dozens of times. The
fix is the **one-shot**: keep one flip-flop of history and fire only on the
cycle the comparison goes from 0 to 1:

```vhdl
one_shot : process (clk)
begin
  if rising_edge(clk) then
    if rst = '1' then
      above_q <= '0';
      trig    <= '0';
    else
      above_q <= above;
      -- Fire exactly once, on the cycle the comparison goes 0 -> 1.
      trig    <= above and not above_q;
    end if;
  end if;
end process one_shot;
```

This is the rising-edge-detector idiom from Module 03, pointed at a
comparator output instead of an external signal. It also reproduces the
analog module's re-arm behavior for free: the discriminator cannot fire
again until the waveform falls back below threshold, because `above_q`
stays high until it does.

**Software vs hardware.** A software person reaches for a boolean
`already_fired` flag and an `if` to clear it — a sequence of checks. Here
there is no sequence: `above_q <= above` and `trig <= above and not above_q`
are *two flip-flops and one AND gate that exist simultaneously*, and the
"one clock ago" semantics comes from Module 03's central fact that every
signal assignment in a clocked process takes effect at the *next* edge. The
idiom costs one LUT and two registers; it evaluates every 10 ns forever.

## Why ports, not generics — the slow-control point

Both files take their tuning value (`pedestal`, `threshold`) as an **input
port**, not a generic, and this is a deeply physics-real decision:

* A **generic** is frozen when the bitstream is built. Changing it means
  re-synthesis — hours of Vivado time and a new file to version, deploy,
  and revalidate.
* A **port** is a wire. Drive it from a slow-control register (an AXI-Lite
  register bank, an IPbus/EPICS-visible node) and it becomes a *setting*:
  operators re-measure pedestals after a temperature drift, run threshold
  scans during commissioning, and raise thresholds when a channel goes
  noisy at 2 a.m. — all between runs, all without touching the firmware.

The rule of thumb: **structure** (bus widths, buffer depths, sample counts)
goes in generics; **anything an operator might ever want to tune** goes on
a port fed from slow control. When you read your experiment's firmware, the
register map document is precisely the list of such ports.

(In this project the "slow control" is simply the testbench driving the two
ports with constants — the hardware neither knows nor cares.)

## Simplifications versus the module versions

The Module 06 pedestal example includes baseline averaging; this one just
subtracts a provided value, because measuring the pedestal is a
slow-control job in this design. The discriminator has no hysteresis and no
programmable output width — a real one often has both; neither changes the
structure you see here.

## Checkpoint (~5 minutes)

From `project/`, analyze the two files:

```bash
ghdl -a --std=08 src/pedestal_subtract.vhd src/discriminator.vhd
```

Silence means success. Then test yourself before moving on — with
`threshold = 100`, and pedestal-subtracted samples arriving as

```
0, 2, 1, 3, 250, 900, 700, 400, 180, 90, 40, 10, 2, ...
```

on which *one* sample does `trig` pulse, and how many clock cycles after
that sample appears on `sample_in`? (Answers: the sample with value 250 —
the first at-or-above-threshold sample — and one cycle later, because
`trig` is registered. Add the pedestal stage's own register and the
trigger reaches the ring buffer two cycles after the crossing sample did.
Remember that number: it reappears in steps 2 and 4.)

**Next:** [Step 2 — the ring buffer](step2_ring_buffer.md), where the
trigger you just built freezes a window that reaches into the past.
