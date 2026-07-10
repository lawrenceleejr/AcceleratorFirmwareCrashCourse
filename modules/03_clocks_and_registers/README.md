# Module 03 — Clocks, Registers, and Counters

**Time: ~30 minutes** · Prerequisite: [Module 02](../02_combinational_logic/)

Everything you've built so far is an instantaneous function: outputs track
inputs, nothing is remembered. This module adds the missing ingredient —
**state** — and with it the three ideas that define real firmware: the
**clock**, the **flip-flop**, and the **synchronous design discipline** that
makes million-gate designs tractable. This is the pivotal module of the
course; every module after it builds clocked logic.

You'll build two designs straight out of a DAQ crate:

* `src/pulse_stretcher.vhd` — stretches a 1-cycle discriminated PMT pulse to
  a programmable coincidence window (the design Module 01 promised you);
* `src/deadtime_scaler.vhd` — the pair of counters every experiment runs to
  measure DAQ dead time for live-time correction.

## The physics problem

Module 01's coincidence unit had a flaw a physicist spots instantly: it ANDs
the *instantaneous* PMT signals. Real discriminated pulses are a few ns wide
and never arrive on exactly the same clock cycle — cable lengths, PMT
transit-time spread, and jitter guarantee that. A NIM coincidence module
solves this with a **gate width knob**: each input pulse opens a gate of,
say, 40 ns, and the coincidence is formed between the *gates*.

To open a 40 ns gate from a 10 ns pulse, the circuit must **remember** the
pulse for three more cycles after it's gone. Combinational logic — any
network of gates, however clever — cannot do that: its output is a pure
function of its *present* inputs. Memory requires a new component.

## Why clocks: the flip-flop

The memory element of all synchronous logic is the **D flip-flop**: on the
**rising edge** of the clock it samples its input, and it holds that value —
ignoring all input changes — until the next rising edge. One flip-flop is
one bit of state. A **register** is a row of them sharing a clock edge.

The clock is the experiment's metronome. At our nominal 100 MHz, every
10 ns, every flip-flop in the design samples-and-holds *simultaneously*, and
the whole design advances one step in lockstep. Between edges, the
combinational logic between registers settles toward its next value; the
edge freezes the result. Time in synchronous hardware is not continuous —
it is an integer number of ticks. (An LHC experiment literally runs its
whole trigger off the 40 MHz bunch-crossing clock: one tick, one collision.)

**Software analogy — and where it breaks.** You might think of the clock as
a `while True:` loop with the body running once per tick. The part that's
right: state updates happen once per tick. The part that's wrong: there is
no *body being executed* — every register in the chip updates in the same
instant, in parallel, ten thousand "loop iterations" wide. There is no
program counter to be somewhere else.

## The clocked process template

Here is how you ask VHDL for flip-flops. Learn it as a **fixed idiom** — the
same eight-line skeleton appears in every synchronous design in this course
and in essentially all professional code:

```vhdl
name : process (clk)
begin
  if rising_edge(clk) then
    if rst = '1' then
      -- reset values
    else
      -- what the registers do on each tick
    end if;
  end if;
end process name;
```

Every piece is load-bearing:

* **`process (clk)` — only `clk` in the sensitivity list.** The sensitivity
  list says when the simulator re-evaluates the process. A flip-flop reacts
  *only* to the clock; its data inputs (and `rst`) are merely *sampled* at
  the edge, so they don't belong in the list. Listing them wouldn't change
  the hardware but would misdescribe it — and in older VHDL styles it's a
  classic source of simulation/synthesis mismatch.
* **`rising_edge(clk)`** is a function from `std_logic_1164` that is true
  only at a `'0'`→`'1'` transition. Guarding everything with it says: these
  assignments happen at the edge *and at no other time*.
* **What about all the other times?** Nothing is assigned — and in VHDL, a
  signal that isn't assigned **holds its value**. That implicit hold is the
  memory. This is precisely how a synthesizer recognizes the template:
  "value only changes on a clock edge, otherwise holds" *is the definition
  of a flip-flop*, so every signal assigned inside the `rising_edge` block
  becomes a register.

Here is the template instantiated in the pulse stretcher — a down-counter
holding the number of window cycles remaining:

```vhdl
stretch : process (clk)
begin
  if rising_edge(clk) then
    if rst = '1' then
      cycles_left <= 0;
    else
      if pulse_in = '1' then
        cycles_left <= STRETCH_CYCLES;    -- (re)arm the full window
      elsif cycles_left > 0 then
        cycles_left <= cycles_left - 1;   -- tick the window down
      end if;
    end if;
  end if;
end process stretch;

pulse_out <= '1' when cycles_left > 0 else '0';
```

Checking `pulse_in` *first* makes the stretcher **retriggerable**: a second
pulse arriving mid-window reloads the counter and extends the window, like
an updating discriminator gate. And note the final line lives *outside* the
process: `pulse_out` is ordinary Module-01 combinational logic decoding the
register — registers and gates, composed. That's all RTL is.

## `<=` in a clocked process: the semantics that shock C++ programmers

Inside a clocked process, `<=` does **not** mean "assign now". It means
**"schedule this value to appear after the edge"**. Reading a signal always
gives its **pre-edge** value. So this classic:

```vhdl
if rising_edge(clk) then
  a <= b;
  b <= a;   -- reads the OLD a, not the one assigned a line above
end if;
```

is a **swap** — no temporary needed. In C++ those two lines would leave both
variables equal to `b`. In VHDL they describe two flip-flops cross-wired to
each other's *outputs*; at the edge, each samples what the other held
*before* the edge. The hardware picture makes it obvious: a flip-flop's
output doesn't change until after its input has been sampled.

Two consequences:

* **Order doesn't matter for distinct signals.** `a <= b; b <= a;` and
  `b <= a; a <= b;` are the same circuit — each signal is its own flip-flop
  with its own input wiring. (Assigning the *same* signal twice is
  different: the last assignment wins, and the earlier one is dead code.)
* **You cannot read back what you just wrote.** `count <= count + 1;` reads
  the pre-edge count — which is exactly right: the adder's input is the
  register's current output.

**Delta cycles**, briefly: the simulator implements this by splitting each
instant into micro-steps. At the clock edge it first *evaluates* every
process, collecting all scheduled assignments while every signal still
shows its old value; only then does it *commit* them all at once (one
"delta"), and re-evaluates anything affected. That evaluate-then-commit
dance is what lets thousands of concurrent processes behave like real
hardware, where every flip-flop samples the pre-edge world simultaneously.
It's also why the testbenches wait a nanosecond after an edge before
checking outputs: at the exact instant of the edge, the new values haven't
committed yet.

## Resets: synchronous, active-high — and not everywhere

Look where `rst` sits in the template: **inside** `rising_edge(clk)`. Reset
is sampled at the clock edge like any other data input — a **synchronous
reset**. The course uses active-high synchronous resets throughout, and
this is a considered position (see Design-choice notes below for the full
argument): Xilinx fabric flip-flops support it natively, it can never
glitch the design asynchronously, and it's what Xilinx's own methodology
guide (UG949) recommends.

You will, however, meet this pattern in most labs' legacy code:

```vhdl
-- ASYNCHRONOUS reset -- recognize it, don't copy it
process (clk, rst)                  -- rst in the sensitivity list...
begin
  if rst = '1' then                 -- ...checked BEFORE the clock edge
    count <= (others => '0');
  elsif rising_edge(clk) then
    count <= count + 1;
  end if;
end process;
```

The tells: `rst` appears in the sensitivity list, and it's checked *before*
`rising_edge`. Here reset acts immediately, clock or no clock — useful when
your clock might not be running yet, but it brings a hazard all of its own
(the *release* of reset can race the clock edge; Module 08's metastability
discussion will make you properly afraid of that).

**Don't reset everything.** Only registers whose start-up value carries
meaning need reset: counters, state machines, control flags — here, both
scalers and `cycles_left`. Pure datapath registers (a pipeline stage
carrying ADC samples, say) get valid data flushed through them within a few
cycles anyway; resetting them costs routing, congests timing, and buys
nothing. Reset what must be *correct at cycle zero*; let data paths flush.

## Counters: `unsigned` and the scaler

"Scaler" is physics jargon for a counter — the CAMAC modules that just
counted pulses all run long. The dead-time scaler is the counting idiom in
its purest form:

```vhdl
use ieee.numeric_std.all;           -- unsigned lives here
...
total_count : out unsigned(31 downto 0);
...
if rst = '1' then
  total_count <= (others => '0');   -- idiomatic "all zeros", any width
else
  total_count <= total_count + 1;   -- counts every cycle; wraps at 2**32
  if busy = '1' then
    busy_count <= busy_count + 1;   -- counts only busy cycles
  end if;
end if;
```

* `unsigned` (from `numeric_std`) is a vector of `std_logic` that the
  language agrees to treat as a binary number, so `+ 1` and comparisons
  with integers are defined. Never use the legacy `std_logic_unsigned`
  library you'll see in old code — Module 06 explains the mess it causes.
* **Wraparound is silent**, exactly like `uint32_t`: 2³² − 1 rolls over to
  0, no exception, no flag. At 100 MHz a 32-bit scaler wraps every ~43 s —
  size your counters, or make software read them out faster than they wrap.
* **Sizing**: to count up to N you need ⌈log₂(N+1)⌉ bits. The pulse
  stretcher's counter shows the other common style — an integer with a
  constrained range (`natural range 0 to STRETCH_CYCLES`), which the
  synthesizer packs into the minimum number of flip-flops automatically.

Why these two counters matter: while the DAQ is busy digitizing one event
it is blind to the next, and any cross section you publish is normalized by
the **live fraction** `1 − busy_count / total_count`. Two trivial registers,
and every rate measurement in the experiment depends on them.

## What a register costs — and what it buys

A register costs one cycle of **latency**: the stretcher's window opens one
tick *after* the input pulse, because the pulse must be sampled first.
Software instinct says latency is bad; hardware practice says it's cheap
currency, because of what registers buy: **speed via pipelining**.

The clock can only tick as fast as the *slowest* stretch of combinational
logic between two registers can settle. Chop a long logic path in half with
a register and each half settles in half the time — the clock can run twice
as fast. Answers come out more ticks later (latency), but a *new* answer
finishes every tick (**throughput**). An LHC first-level trigger is the
extreme case: a deep pipeline whose decision takes microseconds to emerge,
yet which accepts a new bunch crossing — and delivers a new decision —
every 25 ns. Nothing waits; everything streams. Module 06 pipelines real
arithmetic this way.

## Run it

```bash
cd modules/03_clocks_and_registers

# Pulse stretcher
ghdl -a --std=08 src/pulse_stretcher.vhd tb/tb_pulse_stretcher.vhd
ghdl --elab-run --std=08 tb_pulse_stretcher --wave=pulse_stretcher.ghw

# Dead-time scaler
ghdl -a --std=08 src/deadtime_scaler.vhd tb/tb_deadtime_scaler.vhd
ghdl --elab-run --std=08 tb_deadtime_scaler --wave=deadtime_scaler.ghw
```

Expected output:

```
tb/tb_pulse_stretcher.vhd:155:5:@206ns:(report note): ALL TESTS PASSED
tb/tb_deadtime_scaler.vhd:132:5:@146ns:(report note): ALL TESTS PASSED
```

Do open the waveforms (`gtkwave pulse_stretcher.ghw`) and put `clk`,
`pulse_in`, `pulse_out`, and the DUT's `cycles_left` in the pane. Watch the
counter reload on the retrigger and the output hold high across the gap —
that picture *is* this module. Note also the new testbench machinery: a
clock-generator process, and a `finished` flag that stops it so the
simulation actually terminates (a free-running clock means events forever,
and GHDL would never exit).

## Design-choice notes

* **Why synchronous reset?** Three reasons, in order of importance.
  (1) *It matches the fabric.* Xilinx flip-flops have a native synchronous
  set/reset pin; a sync reset costs nothing extra, while async-reset
  descriptions can force the tools into less efficient mappings and
  complicate timing analysis. (2) *It cannot glitch.* An async reset line
  acts the instant it wiggles — a noise spike, a sliver of combinational
  hazard on the reset net, and your counters clear mid-run. A sync reset is
  sampled by the same edge as everything else; between edges it can wiggle
  all it likes. (3) *It's the vendor's own recommendation* — UG949, the
  UltraFast Design Methodology guide, says: if you must reset, prefer
  synchronous, active-high. When you do meet a genuinely asynchronous reset
  requirement (Module 08), you'll synchronize its release.
* **Why active-high?** The fabric's native control inputs are active-high;
  active-low `rst_n` conventions come from the ASIC world and external
  pins. Inside the FPGA, follow the silicon.
* **Why doesn't the stretcher register its output?** `pulse_out` is a
  combinational decode of `cycles_left` — a handful of gates. Registering
  it would add a cycle of latency for no benefit at this size. In a longer
  trigger path you *would* register it as a pipeline stage; that trade is
  yours to make, now that you know the price of both.
* **Why is the stretcher retriggerable?** Because a non-retriggerable gate
  silently drops pulses that arrive mid-window — a rate-dependent
  inefficiency, the nastiest kind to diagnose from data. If you want
  non-retriggerable (fixed dead time per pulse, like a discriminator's
  updating/non-updating switch), guard the reload with
  `if pulse_in = '1' and cycles_left = 0 then`.
* **Why do the scalers drive `out` ports directly?** VHDL-2008 allows
  reading an `out` port (`total_count <= total_count + 1`). Pre-2008 code
  couldn't, so legacy files keep an internal shadow signal and copy it to
  the port — recognize that pattern for what it is: a historical workaround.

## Exercise

Build the design Module 01 promised: a **stretched-coincidence trigger**,
your first *hierarchical* design. Two pulse stretchers open a window for
each PMT; Module 01's coincidence unit ANDs the windows:

```
pmt_a ──▶ pulse_stretcher ──▶ gate_a ──┐
                                       ├──▶ coincidence ──▶ trigger
pmt_b ──▶ pulse_stretcher ──▶ gate_b ──┘
```

1. Create `src/stretched_coincidence.vhd` with generic
   `WINDOW_CYCLES : natural := 4` and ports `clk`, `rst`, `pmt_a`, `pmt_b`
   (`in`), `trigger` (`out`).
2. In the architecture, declare two internal signals `gate_a`, `gate_b` and
   instantiate the pieces. You've seen instantiation in every testbench;
   inside a real design it's the same **entity instantiation** syntax:

   ```vhdl
   stretch_a : entity work.pulse_stretcher
     generic map ( STRETCH_CYCLES => WINDOW_CYCLES )
     port map ( clk => clk, rst => rst,
                pulse_in => pmt_a, pulse_out => gate_a );
   ```

   `stretch_a` is the instance label, `work.pulse_stretcher` names the
   entity in your compiled library, and `port map` solders its pins to your
   signals (`formal => actual`). Add `stretch_b`, then either instantiate
   Module 01's `coincidence` for the AND or simply write
   `trigger <= gate_a and gate_b;`. Each instance is its own copy of the
   hardware — two stretchers, two counters, silicon for both.
3. Write `tb/tb_stretched_coincidence.vhd` (copy the clocking scaffolding
   from `tb_pulse_stretcher.vhd`). Must-check cases: pulses on A and B in
   the *same* cycle (trigger); pulses 2 cycles apart (trigger — the whole
   point!); pulses `WINDOW_CYCLES + 1` cycles apart (no trigger); a pulse
   on A alone (no trigger).
4. Compile order matters now: analyze `pulse_stretcher.vhd` and
   `coincidence.vhd` (copy it in, or analyze it from the Module 01 tree)
   *before* the file that instantiates them.

## Key takeaways

* Combinational logic cannot remember; a **flip-flop** samples on the
  rising clock edge and holds. The clock advances all state in lockstep —
  10 ns per tick at 100 MHz.
* The **clocked process template** — `process (clk)` … `if rising_edge(clk)`
  … sync `rst` check — is a fixed idiom; every signal assigned inside it
  becomes a register. An unassigned signal holds: that *is* the memory.
* Inside a clocked process, `<=` schedules the post-edge value and reads
  return the pre-edge value — so `a <= b; b <= a;` swaps, and assignment
  order between distinct signals is irrelevant.
* Use **active-high synchronous resets**, and only reset registers whose
  cycle-zero value matters. Recognize the async-reset pattern
  (`process (clk, rst)` with `rst` checked first) in legacy code.
* Count with `unsigned` from `numeric_std`; wraparound is silent, so size
  counters: ⌈log₂(N+1)⌉ bits to reach N.
* Registers cost latency and buy clock speed: pipelining trades "answers
  later" for "answers every cycle" — the shape of every real trigger.

**Next:** [Module 04 — Testbenches and simulation](../04_testbenches/), where
the ad-hoc checking you've been reading gets turned into a method: stimulus
generators, reference models, and waveforms you can trust.
