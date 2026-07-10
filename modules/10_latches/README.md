# Module 10 — Latches: Memory Without a Clock

**Time: ~30 minutes** · Prerequisite: [Module 03](../03_clocks_and_registers/)
(and the latch-trap warning in [Module 02](../02_combinational_logic/))

Module 02 told you the inferred latch was "the most infamous novice bug in
all of VHDL" and moved on. This module stops and looks the animal in the eye:
what a latch physically *is*, how it differs from the flip-flop you've
clocked everything with since Module 03, why FPGA design methodology treats
it as a pest — and then you'll **simulate the accident live**, watching a
buggy mux quietly remember a stale gain setting the way a real one would in
your digitizer.

## Storage from feedback: the SR latch

Where does memory come from? Not from a special "memory atom" — from
**feedback**. Take two NOR gates and cross-couple them, each output feeding
the other's input:

```vhdl
q_i  <= r nor qb_i;   -- q     = NOR(reset, q_bar)
qb_i <= s nor q_i;    -- q_bar = NOR(set,   q)
```

Two concurrent assignments (`src/sr_latch.vhd`) — the same kind of statement
as Module 01's AND gate — and yet this circuit *remembers*. Pulse `s` and
`q` goes to `'1'`; release `s` and `q` **stays** at `'1'`, held up by nothing
but the loop chasing its own tail. Pulse `r` and it flips to `'0'` and stays
there.

You already have the right physical picture, because Module 08 drew it: a
cross-coupled pair is a **bistable system** — a potential landscape with two
wells (`q='1'` and `q='0'`) separated by a barrier. `s` and `r` tip the ball
into one well or the other; with both released, the ball simply sits where
it was left. "One bit of memory" *is* a two-well potential. Every register,
every block RAM cell, every bit of state in your DAQ ultimately bottoms out
in a loop like this one.

And the forbidden row of the truth table is Module 08's physics again:
drive `s = r = '1'` (both outputs forced low) and then drop both at the
*same instant*, and the two gates try to rise together, each rise choking
the other — the ball is kicked squarely **onto the barrier top**. Real
silicon hangs metastable and falls off after a random time in a random
direction. GHDL renders the same event its own way: the two signals
oscillate `0→1→0→1` in an **infinite loop of delta cycles**, simulated time
frozen forever, the run never returning. The testbench deliberately never
performs that release (read the comment in Part 1) — same physics, same
respect.

## The D latch: transparent, then frozen

Nobody wants separate set and reset wires; wrap the SR core in input gating
and you get the **D latch** (`src/d_latch.vhd`), with a data input `d` and
an enable `en`:

* while `en = '1'` the latch is **transparent**: `q` *follows* `d`,
  continuously, glitches and all — an open window, not a sampler;
* when `en` falls, `q` **holds** whatever `d` was at that moment.

That word — *level*-sensitive — is the whole contrast with the **D
flip-flop** you've used since Module 03, which is *edge*-triggered: it looks
at `d` only in the instant of the clock's rising edge and is opaque the rest
of the time. A latch is open for an entire half of its enable's cycle; a
flip-flop is open for (ideally) zero time.

They're not strangers, though. A real D flip-flop is internally a
**master–slave pair of D latches** on opposite enable phases: while the
clock is low the master is transparent and the slave holds; the rising edge
closes the master (sampling `d`) and opens the slave (publishing it). At no
instant is a direct path open from `d` to `q` — that's what manufactures
"edge-triggered" behavior out of level-sensitive parts. The flip-flop you've
trusted all course is *built from* today's subject.

The VHDL is short and should make you flinch:

```vhdl
latch : process (all)
begin
  if en = '1' then
    q <= d;
  end if;
  -- NO else, DELIBERATELY: "when en='0', q keeps its old value."
end process latch;
```

An incomplete conditional — Module 02's cardinal sin — committed **on
purpose**, with a comment saying so. That comment is the difference between
a design and a bug, and `src/d_latch.vhd` shouts it in three places.

## Why synchronous FPGA design avoids latches

If a latch is legitimate memory, why has every module since 03 insisted on
flip-flops? Four compounding reasons:

* **The transparent window passes glitches.** Combinational logic glitches
  while it settles (Module 02: nothing is instant). A flip-flop ignores all
  of that and samples one clean instant; a latch that's open while its data
  input is still rippling **captures whatever garbage is passing by** when
  the enable finally falls.
* **Static timing analysis gets much harder.** The synchronous discipline —
  logic must settle between two clock edges, full stop — is what lets the
  tools *prove* your timing (Module 09). A latch-based path can legally keep
  computing into the transparent window of the next stage ("time
  borrowing"), so slack stops being a per-stage property and starts
  depending on chains of neighboring stages. ASIC teams exploit this with
  specialist tooling; for FPGA flows it mostly means weaker analysis and
  warnings you can't cleanly close.
* **The fabric isn't built for them.** Xilinx slices are FF farms: each has
  a handful of edge-triggered flip-flops sitting right after the LUTs, with
  dedicated clock routing. A latch primitive (`LDCE`) exists, but it's the
  odd resource out — scarce, awkwardly placed, and its enable travels on
  general routing rather than the clock network. You pay in routing and
  timing for a component the architecture merely tolerates.
* **So in practice, a latch in a synthesis report is an accident.** Since
  deliberate latches are vanishingly rare in FPGA firmware, an inferred
  latch is a nearly perfect bug detector: it almost always means someone
  described memory *without meaning to*.

## The accident, caught live

Module 02 showed you the trap in the abstract; `src/latch_trap.vhd` springs
it. The scenario: a control bit selects a digitizer's amplifier gain code —
low gain for physics, high gain for single-photoelectron calibration. The
author writes the mux, handles the `sel='1'` branch, and gets called away
to fix the beam:

```vhdl
bad_mux : process (all)
begin
  if sel = '1' then
    gain <= gain_high;
  end if;
  -- Missing: what is 'gain' when sel = '0'?
end process bad_mux;
```

The description now *says*: "when `sel='0'`, `gain` keeps its previous
value." Combinational logic has no previous value — so the synthesizer,
faithful to a fault, builds storage: a latch on `gain`, enabled by `sel`.
Vivado will tell you, once, in the middle of a scrolling log:

```
WARNING: [Synth 8-327] inferring latch(es) for signal or variable 'gain',
which holds its previous value in one or more paths, add a default or
complete case statement to fix this
```

**The rule: treat every inferred-latch warning as a bug.** Not a style nit —
a functional defect with a repro you may not find for months. And note the
failure mode: while `sel='1'` the circuit is *perfectly correct*, because
that branch was written. Only when the run coordinator flips back to physics
gain does `gain` freeze at the stale calibration code — and your spectra
quietly saturate.

> **Software developer's note.** An uninitialized variable in C++ is garbage
> once, at a definite place, and valgrind will name the line. An accidental
> latch is wrong *forever*, glitch-sensitively, and only under the right
> input history — correct on every path the author thought about, stale on
> the one they didn't. It is the heisenbug of hardware, with no stack trace
> and no sanitizer, which is why the synthesis warning is treated as the
> whole trial: verdict at first mention.

The same file contains `latch_trap_fixed`: identical ports, identical
intent, plus one line — Module 02's habit #1, the **default assignment at
the top of the process**:

```vhdl
good_mux : process (all)
begin
  gain <= gain_low;        -- every path now assigns 'gain': no latch
  if sel = '1' then
    gain <= gain_high;     -- overrides the default; last assignment wins
  end if;
end process good_mux;
```

The testbench drives both muxes from the same inputs and asserts that the
buggy one *does* hold the stale value while the fixed one tracks its
selected input — asserting the wrong answer on purpose, to prove the
unintended memory exists.

## Where latches are legitimate (for culture)

So that you don't leave thinking latches are simply evil: ASIC designers use
intentional latch pipelines precisely *for* time borrowing, letting slow and
fast stages average out against a brutal clock; the standard clock-gating
cell that saves power in every phone SoC has a latch inside (to stop the
gate enable from glitching the clock); and — the physics wink — a delay-line
**TDC** is a row of latches strobed by the hit signal, freezing the state of
a fast tapped delay chain to timestamp a PMT pulse to a few picoseconds:
literally *latching* time itself. All of these are deliberate, reviewed,
tool-supported uses. None of them look like a forgotten `else`.

## Run it

```bash
cd modules/10_latches
ghdl -a --std=08 src/sr_latch.vhd src/d_latch.vhd src/latch_trap.vhd tb/tb_latches.vhd
ghdl --elab-run --std=08 tb_latches
```

Expected output:

```
tb/tb_latches.vhd:176:5:@130ns:(report note): ALL TESTS PASSED
```

Worth a waveform look (add `--wave=latches.ghw` to the second command, then
`gtkwave latches.ghw`): watch `q_sr` hold after `s` releases; watch `q_d`
wiggle with `d` while `en` is high and freeze when it drops; and put
`gain_buggy` and `gain_ok` side by side to see them agree, then split the
instant `sel` drops at 110 ns — history-dependence, visible. Also notice `q_sr` starting as a red `'U'` —
the honest random power-up state of a real latch — until the first set pulse
resolves it.

## Design-choice notes

* **Why does `sr_latch` use internal signals (`q_i`, `qb_i`) and copy them
  to the ports?** Clarity: the feedback loop is between two named nodes you
  can drag into GTKWave, and the port drivers stay trivially simple.
  (VHDL-2008 would let the loop read the `out` ports directly.)
* **Why no initializers on the SR storage nodes?** Deliberate honesty: a
  real cross-coupled pair powers up in a random well, and the `'U'` you see
  before the first set pulse tells that truth. The first `s` pulse resolves
  it (`'1' nor 'U'` is a hard `'0'`), so the testbench needs no special
  handling — it just sets before it checks.
* **Why does the buggy entity ship at all?** For the same reason Module 08
  ships a two-flop synchronizer instead of just describing one: reading
  about a failure mode and *watching it in a waveform* build different
  reflexes. The file is fenced with INTENTIONALLY WRONG banners so it can't
  be copied innocently.
* **Why does the testbench assert the buggy value?** A self-checking test
  must pin down *all* behavior it demonstrates, including bad behavior —
  otherwise a future edit could silently break the demonstration. If someone
  "fixes" `latch_trap`, the testbench fails and tells them the bug is
  load-bearing.
* **Why no clock in this module?** Latches are level-sensitive; there is no
  edge to wait for. The testbench uses Module 01's plain
  `wait for 10 ns` stepping — the last clockless module in the course.

## Exercise

Build a **gated trigger veto** both ways and race them:

1. `src/veto_latch.vhd` — a latch ON PURPOSE: while `gate = '1'`, output
   `veto` follows the (noisy) veto-paddle input `paddle`; while
   `gate = '0'`, it holds. Write it like `d_latch` — incomplete conditional
   plus the mandatory "intentional latch" comment.
2. `src/veto_ff.vhd` — the synchronous version from Module 03's template:
   a clocked process that samples `paddle` on `rising_edge(clk)` when
   `gate = '1'` and otherwise holds the register.
3. In the testbench, drive both with the same stimulus, including a **2 ns
   glitch** on `paddle` while the gate is open (`paddle <= '1'; wait for
   2 ns; paddle <= '0';` between clock edges). Assert what each version
   does with it. You should find the latch faithfully passes the glitch to
   its output (and will hold it forever if the gate closes at the wrong
   moment), while the flip-flop never even sees it unless it straddles a
   clock edge. That asymmetry — in the FF's favor for noisy detector
   signals — is Reason 1 above, felt in your own waveforms.

## Key takeaways

* **Memory is feedback**: two cross-coupled NOR gates form a bistable
  two-well system — the SR latch, the atom of storage. The forbidden
  simultaneous release of `s = r = '1'` kicks it onto the barrier:
  metastability on silicon, an endless delta-cycle oscillation in GHDL.
* A **D latch is level-sensitive**: transparent (output follows input,
  glitches included) while the enable is high, holding when it's low. A
  **flip-flop is edge-triggered** — and is internally a master–slave pair
  of latches.
* FPGA methodology avoids latches: the transparent window passes glitches,
  timing analysis loses the clean per-stage story (time borrowing), and
  Xilinx fabric offers FFs everywhere but latches (`LDCE`) only grudgingly.
* Latches are **inferred by incomplete assignment**: any path through a
  combinational process that fails to assign an output describes memory.
  Default assignments at the top + complete conditionals make it
  impossible; `[Synth 8-327] inferring latch(es)` in a log is a bug until
  proven otherwise — and the proof is a comment saying "intentional".
* Deliberate latches exist (ASIC time borrowing, clock gating, delay-line
  TDCs) — always announced, never accidental.

**Next:** [Module 11 — Counters in practice](../11_counters_in_practice/)
