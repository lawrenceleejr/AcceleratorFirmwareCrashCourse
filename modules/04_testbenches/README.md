# Module 04 — Testbenches and Simulation

**Time: ~30 minutes** · Prerequisite: [Module 03](../03_clocks_and_registers/)

This module is about the skill that separates firmware that works from
firmware that *mostly* works: **verification**. The design under test is
deliberately tiny — a digital leading-edge discriminator, two flip-flops and a
comparator. The testbench is ten times its size. That ratio is not a joke; it
is roughly the ratio in professional firmware, and by the end of this module
you'll understand why.

## Why simulation-first is not optional

In software, your debug loop is: add a `print()`, rerun, ten seconds, done.
Now picture the hardware version. Your discriminator misbehaves on the trigger
board. The board is in a VME crate, in a shielded enclosure, in the tunnel.
To "rerun" you need to: rebuild the bitstream (20 minutes to hours), wait for
a beam block or an access window (hours to days), walk in with a dosimeter,
reflash, walk out, wait for beam. **That is your printf loop if you skip
simulation.** And the failure you're chasing may occur once per million
events, invisible until physics data looks subtly wrong.

The discipline that follows is simple and absolute: **every behavior is
demonstrated in simulation before it goes anywhere near a bitstream.** The
simulator is where bugs cost seconds. The tunnel is where they cost beam time.
A testbench is not test bureaucracy — it *is* your debugger, your scope, and
your logic analyzer, all running on your laptop.

## The DUT: a leading-edge discriminator

`src/discriminator.vhd` is the front end of any digitizer trigger: 12-bit ADC
samples arrive one per clock on `adc_data`, and `fired` must pulse high when
the waveform crosses `threshold` from below.

The crucial word is **crosses**. A scintillator pulse is tens of nanoseconds
wide; at 100 MS/s it sits above threshold for many consecutive samples. A bare
comparator (`fired <= '1' when adc_data > threshold`) would stay high for the
whole pulse, and a scaler downstream would count one particle as six. We want
one trigger per **particle**, not per **sample** — so we detect the edge of
the comparison, which takes exactly one bit of memory (Module 03):

```vhdl
above <= '1' when adc_data > threshold else '0';   -- strictly greater!

edge_detect : process (clk)
begin
  if rising_edge(clk) then
    if rst = '1' then
      above_prev <= '0';
      fired      <= '0';
    else
      fired      <= above and not above_prev;   -- fire on below->above only
      above_prev <= above;
    end if;
  end if;
end process;
```

Fine. Now: how do you *know* that's right? Open `tb/tb_discriminator.vhd` and
read it top to bottom alongside this section — it's the real subject here.

## Anatomy of a testbench

Every serious testbench has the same skeleton, and each piece is a separate
concurrent process (Module 01: they all run simultaneously):

1. **DUT instantiation** — the design wired onto the bench, exactly like
   Module 01's testbench.
2. **Clock generator** — a process with no sensitivity list looping forever:
   ```vhdl
   clock_gen : process
   begin
     clk <= '0';
     wait for clk_period / 2;
     clk <= '1';
     wait for clk_period / 2;
   end process clock_gen;
   ```
   A free-running clock never stops on its own, so something must end the
   simulation. Two standard idioms: a `done` signal that the clock loop
   tests (`while not done loop ...`), or — what this testbench uses —
   VHDL-2008's `std.env.finish`, called from the stimulus after the last
   check. Either way: **a testbench must have a bounded runtime.** Ours also
   carries a `watchdog` process that kills the run with a failure after
   500 µs, so even a hung stimulus terminates loudly instead of spinning
   forever in a batch job.
3. **Stimulus** — the one sequential "script" that drives inputs.
4. **Monitor / checker** — an independent observer watching the outputs.
5. **Golden model** — a software-style reference computation of the right
   answer (below).

## `assert`, `report`, and severity

The workhorse of self-checking is:

```vhdl
assert fired_count = expected_count
  report "FAIL " & msg & ": DUT fired " & integer'image(fired_count)
       & " times, golden model expected " & integer'image(expected_count)
  severity failure;
```

`assert` checks a condition; if false, the `report` string prints with the
given **severity**. The four levels, and when to use each:

| Severity | Simulator's reaction | Use it for |
|----------|----------------------|------------|
| `note` | prints, continues | progress messages ("PASS test 3"), so a long log tells a story |
| `warning` | prints, continues | suspicious-but-legal: a coverage hole, a degenerate random draw, an unusual configuration |
| `error` | prints, continues (by default) | a real check failure you want to *collect* — some flows run on and tally errors at the end |
| `failure` | prints, **stops the simulation** | test asserts in this course |

Why `severity failure` for test checks? Because the first failure is the one
with diagnostic value: the simulation halts at the exact time of the exact
check that broke, with a precise message, and the waveform file ends right at
the crime scene. Let a broken run continue and you get a thousand cascading
errors obscuring the original cause — the hardware equivalent of ignoring the
first compiler error. A bare `report "..."` (no assert) is unconditional
printing — the testbench uses it for `"ALL TESTS PASSED"`, which is only
reachable if every assert above it held.

## Procedures: helper functions for stimulus

Driving realistic stimulus sample-by-sample gets unbearable fast. VHDL's
**procedure** is the closest thing to your helper functions, and a procedure
declared inside a process can drive that process's signals and see its
variables. The testbench builds a small vocabulary — `drive_sample`, `idle`,
`rand_int` — and then the payoff, a synthetic scintillator pulse:

```vhdl
procedure send_pulse (
  constant amplitude   : in natural;      -- peak height above baseline
  constant tau_samples : in positive      -- decay constant, in clock ticks
) is
  variable a : real;
begin
  drive_sample(baseline + amplitude / 2);      -- fast leading edge
  drive_sample(baseline + amplitude);          -- peak
  for i in 1 to 6 * tau_samples loop           -- exponential tail
    a := real(amplitude) * exp(-real(i) / real(tau_samples));
    exit when a < 1.0;
    drive_sample(baseline + integer(a));
  end loop;
  idle(5);                                     -- recover to baseline
end procedure send_pulse;
```

Fast rise, `exp(-t/τ)` decay, nonzero pedestal — a caricature of a PMT pulse,
but an honest one. This is the general pattern for testing DAQ firmware:
*encode what your detector actually outputs as a procedure*, then write tests
in physics vocabulary: `send_pulse(amplitude => 1000, tau_samples => 4)`.

Note the `use ieee.math_real.all` at the top of the testbench — that's where
`exp`, `trunc`, and `uniform` live. **Simulation-only**: floating point is not
synthesizable, and `math_real` must never appear in a file under `src/`. In a
testbench, anything goes; it will never become hardware.

## The golden model

Here is the central idea of self-checking verification. Eyeballing waveforms
does not scale and eventually lies to you; instead, the testbench computes the
expected answer *independently* and demands agreement.

Two process variables re-implement the discriminator spec in plain sequential
code — the way you'd write it in Python — and are updated inside
`drive_sample`, so the model sees literally every sample the DUT sees, noise
and all:

```vhdl
-- Golden model: the same decision the DUT makes, in software.
if rst = '1' then
  model_above := false;                 -- mirrors the DUT's reset
else
  if v > thr_value and not model_above then
    expected_count := expected_count + 1;
  end if;
  model_above := v > thr_value;
end if;
```

On the hardware side, a separate `monitor` process — an independent observer,
like a scaler NIM module cabled to the trigger output — counts actual fires
into `fired_count` and asserts the pulse is never more than one clock wide.
At every checkpoint the `check` procedure asserts
`fired_count = expected_count`. DUT and model are written independently, in
different styles, so a bug must strike both *identically* to slip through.
(For directed tests, `check` also takes the count you expect **by hand**,
which cross-checks the golden model itself — models have bugs too.)

## Random stimulus you can reproduce

Directed tests catch the bugs you thought of. Random tests catch the ones you
didn't. Test 6 fires 40 pulses with random amplitudes that deliberately
straddle the threshold, random decay constants, and ±3 LSB of noise on every
sample, using `ieee.math_real.uniform`:

```vhdl
variable seed1 : positive := 42;
variable seed2 : positive := 4242;
...
uniform(seed1, seed2, r);   -- r in (0,1); seeds advance on every call
```

The seeds are **fixed on purpose**. `uniform` is a deterministic
pseudo-random generator: same seeds, same sequence, every run. So a "random"
test that fails tonight fails *identically* tomorrow morning when you debug
it. An irreproducible test failure is worse than no test at all. When you
want genuinely new stimulus, change the seeds — deliberately, and record what
you changed them to. (You've met this before if you've ever set a seed in
`numpy.random` to make an analysis reproducible. Same discipline.)

## Coverage thinking: hunt the corners

A test plan is only as good as the corners it lands on. The bugs are never in
the middle of the range; they're at the boundaries and in the interactions.
This testbench's plan:

| Test | Case | Why it's there |
|------|------|----------------|
| 0 | huge pulse **during reset** | reset must win; a trigger during a run-control reset injects fake events |
| 1 | clean pulse well above threshold | the bread and butter — fires exactly once |
| 2 | peak **exactly at** threshold | spec says *strictly* greater → must NOT fire; off-by-one bugs live here |
| 3 | peak at threshold **+1** | the other side of the same boundary → must fire |
| 4 | 10-sample flat top | one particle, one fire — the entire point of the edge detector |
| 5 | two pulses one sample apart | pile-up must resolve as two triggers |
| 6 | 40 random noisy pulses | the bugs you didn't think of; scored by the golden model |

Notice tests 2 and 3 pin the same boundary from both sides. Whenever a spec
contains a comparison, test *at* it, *just above* it, and *just below* it.

## Run it

```bash
cd modules/04_testbenches

# Analyze (= compile) the design and its testbench
ghdl -a --std=08 src/discriminator.vhd tb/tb_discriminator.vhd

# Elaborate and run, recording every signal to a waveform file
ghdl --elab-run --std=08 tb_discriminator --wave=discriminator.ghw
```

Expected output — one `PASS` line per test, then:

```
tb/tb_discriminator.vhd:351:5:@13855ns:(report note): ALL TESTS PASSED
simulation finished @13855ns
```

Want proof the checks have teeth? Break the DUT on purpose: change `>` to
`>=` in `src/discriminator.vhd`, re-run, and watch test 2 halt the simulation
with a precise message. A testbench that has never failed has never been
tested.

## Reading waveforms like a scope trace

Physicists have a superpower here: you already know what a discriminator
firing on a pulse should *look* like. GTKWave can show it to you exactly like
a scope trace:

```bash
gtkwave discriminator.ghw
```

1. In the tree pane (top left), expand and select `tb_discriminator`.
2. Drag `adc_data`, `threshold`, and `fired` into the wave pane. Add `clk`
   and `rst` too.
3. `adc_data` first appears as a hex bus — useless for a waveform. Right-click
   it → **Data Format → Decimal**, then right-click again →
   **Data Format → Analog → Step**. The bus becomes an analog trace.
4. It will be one pixel tall. Right-click once more →
   **Insert Analog Height Extension** (repeat a few times to taste), and do
   the same Decimal + Analog for `threshold`.
5. Zoom out (`Ctrl -` or **Time → Zoom → Zoom Full**).

Now you're looking at a digitized scintillator trace: pedestal at 100 counts,
pulses rising sharply and decaying exponentially, the threshold as a flat line
at 500 — and `fired` ticking exactly one clock at each upward crossing, and
*not* on the pulse at test 2 that only kisses the threshold. Around 2 µs into
the run the noisy random pulses start, some clearing the line and some
falling short. This picture is worth the whole module: simulation gives you a
scope trace of a board that doesn't exist yet.

## Design-choice notes

* **Why a one-shot edge detector rather than a level comparator?** Because
  the physics quantity is *particles*, not *samples above threshold*. A
  1 GHz-bandwidth scintillator pulse digitized at 100 MS/s spans many
  samples; counting samples would make your rate depend on pulse width,
  amplitude, and threshold in an unphysical way. One crossing, one trigger —
  same reason NIM discriminators are one-shots.
* **Why a registered output?** Module 03's rule: outputs that cross module
  boundaries come from flip-flops. It costs one clock of latency and buys a
  clean, glitch-free, exactly-one-cycle pulse that downstream logic (a
  scaler, a coincidence unit, a readout FSM) can sample safely.
* **Why is `threshold` a port and not a generic?** A generic is baked in at
  synthesis time; changing it means a rebuild. A port can be wired to a
  slow-control register and adjusted at run time — and re-tuning
  discriminator thresholds between runs is routine detector operations, not
  a firmware release.
* **Why does the monitor duplicate work the stimulus could do?** Separation
  of concerns: the stimulus *drives*, the monitor *observes*, the model
  *predicts*. Three independent agents that must agree. This structure is
  exactly what industrial verification frameworks formalize.

## Beyond hand-rolled testbenches

Everything in this module scales up. Three names to know:

* **OSVVM** (Open Source VHDL Verification Methodology) is a set of VHDL
  packages that industrialize what we hand-rolled: constrained-random
  generation, functional-coverage collection ("have I actually hit every
  corner?"), scoreboards, and logging — all in plain VHDL, so it drops
  straight into a GHDL flow.
* **VUnit** is a Python-driven test *runner* for VHDL: it discovers your
  testbenches, compiles only what changed, runs tests in parallel, and
  reports pass/fail per test case — `pytest` for HDL. The
  testbench-writing skills from this module carry over unchanged; VUnit
  manages the running of them.
* **cocotb** lets you write the entire testbench in **Python**: coroutines
  drive and sample the DUT's ports directly while the simulator (GHDL
  included) runs the VHDL. For a physics audience this is the natural
  endpoint — your golden model becomes real NumPy, and you can compare the
  DUT against the same analysis code you'll run offline.

For this course we stay with plain VHDL testbenches — you must be able to read
and write them regardless, because every codebase has them.

## Exercise

Real baselines aren't quiet: noise ripple near threshold makes a plain
leading-edge discriminator double-count, as a slow pulse's noisy tail
re-crosses the line. (Our random test tolerates this only because the golden
model faithfully double-counts too — both agree, both are "wrong" physics.)
The classic fix is **hysteresis**, exactly like a Schmitt trigger:

1. Copy `src/discriminator.vhd` to `src/discriminator_hyst.vhd`; rename the
   entity and give it two levels: `fire_threshold` and a lower
   `release_threshold`. The discriminator arms only after the signal falls
   below `release_threshold`, and fires only on a crossing of
   `fire_threshold` while armed.
2. Extend the testbench: write a `send_rippling_pulse` procedure whose tail
   hovers around `fire_threshold` with ±10 LSB of noise, and a golden model
   with the same two-threshold rule. Prove the plain discriminator
   double-counts this stimulus (expect its count to be higher) and the
   hysteresis version fires exactly once per pulse.
3. Corner cases, as always: what should happen when
   `release_threshold >= fire_threshold`? Decide, document, and test it.

## Key takeaways

* Your debug loop on real hardware is measured in **days**; in simulation
  it's seconds. Simulation-first is the discipline — nothing goes on a board
  undemonstrated.
* Testbench anatomy: DUT + clock generator + stimulus + independent monitor
  + golden model + watchdog, all as concurrent processes. Bounded runtime,
  always.
* `assert`/`report` with the right severity: `note` for progress, `warning`
  for suspicious-but-legal, `failure` to stop dead at the first broken check
  with a precise message.
* **Procedures** turn stimulus into vocabulary: model what your detector
  actually outputs, then write tests in physics terms.
* The **golden model** — an independent software-style reference fed the
  identical stimulus — is what makes a testbench self-checking at scale.
* Randomize with `uniform`, but **fix the seeds**: a failure you can't
  reproduce is a failure you can't fix.
* Coverage means hunting corners: at the threshold, one over, during reset,
  back-to-back. Boundaries, not midpoints.

**Next:** [Module 05 — State machines](../05_state_machines/), where a
readout controller introduces the FSM patterns that run every triggered
event, and the testbench techniques from this module start pulling their
weight.
