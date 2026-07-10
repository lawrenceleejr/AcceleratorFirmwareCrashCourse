# Module 09 — The Vivado / Xilinx Flow

**Time: ~30 minutes** · Prerequisite: [Module 08](../08_clock_domains_cdc/)

Eight modules of simulation later, it's time for the part where the LEDs
actually blink. This module walks the full path from VHDL source to a
configured FPGA on a real board: **synthesis → placement → routing →
bitstream**, plus the constraints, reports, IP, and debug tools that surround
it. It is mostly prose, on purpose — the flow is where firmware stops being
"a language" and starts being "a manufacturing process", and understanding
*what each stage does and what can go wrong* is worth more than any single
tool command.

For concreteness, everything targets the **Digilent Arty A7-35** (Artix-7
`XC7A35TICSG324-1L`, 100 MHz oscillator on pin E3) — the standard cheap
starter board and a perfectly honest miniature of the Artix/Kintex parts on
real DAQ hardware. **Any Xilinx board works**: only the pin constraints (and
maybe the clock period) in the XDC file change. Vivado ML Standard Edition is
a free download from AMD and covers every device in this course.

The module ships:

* [`src/top_blinky.vhd`](src/top_blinky.vhd) — a "beam-gate heartbeat": a
  27-bit counter divides the 100 MHz clock and its top four bits drive the
  board's four LEDs. Button 0 is a synchronous reset — and because a button
  is an **asynchronous** input, it goes through a two-flop synchronizer
  exactly as Module 08 demands. Read the file; every choice is commented.
* [`constraints/arty_a7.xdc`](constraints/arty_a7.xdc) — real, complete
  constraints for the Arty A7-35, every line explained.
* [`scripts/build.tcl`](scripts/build.tcl) — a minimal scripted build:
  source-to-bitstream in one command.

Vivado isn't required to *read* this module, and no testbench ships with it —
by Module 04 standards you can write `tb_top_blinky` yourself (it's part of
the exercise). The design still compiles under GHDL like everything else:

```bash
cd modules/09_vivado_xilinx_flow
ghdl -a --std=08 src/top_blinky.vhd
```

## The flow, stage by stage

In software, "build" means: compiler → object code → linker → executable,
in seconds. The FPGA flow has the same shape and profoundly different
content. Here is what actually happens between `top_blinky.vhd` and a `.bit`
file.

**1. Elaboration.** Vivado parses the VHDL, resolves the design hierarchy
from the top entity down, and evaluates generics into a generic circuit
description. This is where syntax errors and missing entities die. Cheap and
fast — the closest thing to a software compile in the whole flow.

**2. Synthesis** (`synth_design`). The elaborated design is translated into
a **netlist** — a parts list plus wiring — of the target device's actual
primitives: LUTs (look-up tables, the universal logic gate of FPGAs),
flip-flops, carry chains, block RAMs, DSP slices. Your `if rising_edge(clk)`
process becomes N flip-flops; your `count + 1` becomes a LUT/carry-chain
adder; the ring buffer from Module 07 becomes a BRAM. Synthesis is a
*compiler* in the strict sense — it also does optimization: constant
propagation, dead-logic removal (an output you never connect is deleted,
along with everything that only fed it — a classic "where did my logic go?"
surprise), and retiming. But its output is not instructions. **It is a
circuit.** What can go wrong: inference misses (you wrote a memory that
can't map to BRAM and silently got 40,000 flip-flops instead — check the
utilization report), unintended latches (Module 02's incomplete-assignment
sin), and a long tail of *critical warnings* that you must actually read.

**3. Placement** (`place_design`). The netlist's cells are assigned to
physical **sites** on the die: this flip-flop goes in that slice at grid
location X47Y112, this BRAM in that column. Placement is a gigantic
optimization problem (minimize wire length on paths that matter) and is
where the tool starts fighting geometry: two flip-flops on a critical path
placed far apart cannot possibly meet timing, no matter how the wires are
routed. What can go wrong: congestion — too much logic wanting the same
region — and impossible I/O-adjacent timing when your pins (fixed by the
XDC) are on the opposite side of the die from the logic that uses them.

**4. Routing** (`route_design`). The placed cells are connected using the
FPGA's prefabricated wire segments and programmable switch matrices. Only
after routing are path delays *real numbers* rather than estimates, so the
timing analysis that matters is the post-route one. What can go wrong: in a
full or congested device the router detours signals, delays grow, and a
design that met timing after placement fails after routing.

**5. Bitstream** (`write_bitstream`). The placed-and-routed design is
serialized into the configuration file — the exact contents of every LUT,
the state of every routing switch, the settings of every I/O pin — that
gets loaded into the device. This is the artifact you put on the board.

> **Software vs. hardware.** A software compiler must satisfy *semantics*:
> produce instructions with the meaning you wrote. Synthesis, placement and
> routing must satisfy semantics **and physics**: signals crossing the die
> as electromagnetic waves at roughly a third of the speed of light,
> arriving within the clock period, through real silicon at the worst-case
> temperature and voltage corner. That is why a build takes **minutes to
> hours, not seconds** (this blinky: ~2 minutes; a full DAQ design on a
> large Kintex: an hour or more), why the tools are seeded heuristics rather
> than deterministic translators, and why "it compiled" means far less than
> it does in software. The real pass/fail criterion comes next.

## Timing closure, for beginners

Recall the synchronous contract from Module 03: on every rising clock edge,
every flip-flop captures its input. Between two edges, the signal launched
by one flip-flop must propagate through the LUTs and wires between it and
the next flip-flop, and **settle** before that next edge. At our 100 MHz,
that budget is 10 ns. Every FF-to-FF path in the design — there can be
millions — must fit.

Static timing analysis checks all of them and summarizes the result as
**WNS, Worst Negative Slack**: the margin on the single worst path. Slack =
(time available) − (time required). **WNS ≥ 0 means every path fits: timing
is met.** WNS < 0 means at least one path misses. A timing report (the
`report_timing_summary` output from `build.tcl`) looks schematically like
this:

```
Design Timing Summary
    WNS(ns)      TNS(ns)  Failing Endpoints  Total Endpoints
    -------      -------  -----------------  ---------------
      2.145        0.000                  0             1834
       ^              ^                   ^
       |              |                   '-- paths that miss (want: 0)
       |              '-- total negative slack, summed over failing paths
       '-- worst path has 2.1 ns to spare out of 10: PASS

Worst path detail (annotated):
  Source:       heartbeat/count_reg[3]/C      <- launching flip-flop
  Destination:  heartbeat/count_reg[26]/D     <- capturing flip-flop
  Requirement:  10.000 ns                     <- one sys_clk period
  Data path:     7.855 ns  (logic 3.2 ns, route 4.6 ns, 7 levels)
  Slack:         2.145 ns                     <- requirement - path - overheads
```

Two things to internalize from that sketch: routing delay is typically
*comparable to or larger than* logic delay (wires are not free — this is the
physics the tool is fighting), and "levels of logic" — how many LUTs sit
between the two flip-flops — is the number *you* control.

> **Timing is met, or the design does not work. There is no "mostly
> works".** A path with −0.2 ns slack fails intermittently: at some
> temperatures, on some boards, for some data patterns, a flip-flop captures
> garbage. This is the hardware analogue of undefined behavior in C++ — it
> works in the lab and corrupts data during the beam run. Never deploy a
> bitstream with WNS < 0.

When timing fails, the knobs, **in order of preference**:

1. **Pipeline** — add registers to split a long logic path into shorter
   ones, exactly as Module 06 did for arithmetic. Costs latency (cycles),
   buys frequency. This is the FPGA move, and it is almost always the answer.
2. **Reduce logic depth** — rethink the failing logic: fewer levels, smaller
   comparators, precomputed terms. The timing report names the exact path;
   go read your own code on it.
3. **Floorplanning and tool options last** — placement constraints, synthesis
   strategies, extra implementation runs. These squeeze out the final few
   percent and are fragile; if you're reaching for them early, the design
   itself is the problem.

**Setup vs. hold, in two sentences each.** A *setup* violation means data
arrived too **late** — the path is too slow for the clock period; it's fixed
by the knobs above, and it gets worse the faster you clock. A *hold*
violation means data arrived too **early** — a too-short path lets the *new*
value race in before the flip-flop has safely captured the old one;
it is independent of clock frequency, the router fixes it automatically by
padding delay, and if one survives to the final report something is
genuinely wrong (almost always bad CDC or a bad constraint).

## Constraints: the XDC file

Synthesis knows your VHDL; it knows *nothing* about your board. Which
package pin is the clock on? How fast is it? Which pins are the LEDs?
That knowledge lives in the **XDC file** — and an XDC file is not passive
configuration: it is a sequence of **Tcl commands evaluated in order**
against the design. Later commands can override earlier ones; typos fail at
build time (if you're lucky) or silently match nothing (if you're not —
watch for "no ports matched" critical warnings).

The three constraint families you'll use constantly:

* **Clock definitions** — `create_clock -period 10.000 -name sys_clk
  [get_ports clk]`. This single line is the entire timing contract: it is
  what makes every FF-to-FF check in the previous section exist.
  **An unconstrained clock means no timing analysis at all** — Vivado
  optimizes for nothing, reports success vacuously, and the board misbehaves
  in ways simulation never shows. First thing to check in any inherited
  design: `report_clocks` — is every clock constrained?
* **Pin assignments** — `set_property PACKAGE_PIN E3 [get_ports clk]` plus
  an `IOSTANDARD` for the electrical standard. Unassigned pins get placed
  *arbitrarily*: the bitstream then drives voltages onto whatever pins the
  tool picked, which on a populated board can fight other chips' outputs or
  put 3.3 V logic thresholds on a 1.8 V bank — real hardware damage, not a
  metaphor. Vivado refuses to write a bitstream while used pins lack
  standards, deliberately.
* **Timing exceptions** (mention only, for now) — `set_false_path` and
  `set_max_delay` tell the analyzer that certain paths are *not* ordinary
  synchronous paths, most importantly CDC crossings like Module 08's
  two-flop synchronizers (which also carry the `ASYNC_REG` attribute you saw
  there and in `top_blinky.vhd`). Wrongly declaring a real path false is the
  classic way to make timing "pass" while the hardware fails — treat
  exceptions as sharp tools.

Open [`constraints/arty_a7.xdc`](constraints/arty_a7.xdc) now — it's short
and every line explains itself. Note that it constrains *this* design's
ports; the XDC and the entity port names must agree exactly.

## Two ways to drive Vivado — and why scripts win

Vivado has a GUI **project mode**: click New Project, add sources, add
constraints, press the green arrow through synthesis → implementation →
bitstream, browse reports in the IDE. It is genuinely good for exploring —
cross-probing from a timing path to the schematic to your source line is
excellent — and nothing is wrong with using it while you learn.

But the flow this module ships is **non-project (scripted) mode**:

```bash
cd modules/09_vivado_xilinx_flow
vivado -mode batch -source scripts/build.tcl
# outputs: build/top_blinky.bit, build/timing_summary.rpt, build/utilization.rpt
```

Read [`scripts/build.tcl`](scripts/build.tcl) — it is the five flow stages
of this README, one command each, plus the two reports. Why this matters for
a physics collaboration specifically:

* **The build lives in git.** A Vivado project directory is a thicket of
  machine-generated state that diffs meaninglessly; a Tcl script plus VHDL
  plus XDC is the *complete, reviewable* definition of the firmware. "Which
  bitstream is on the north-hall digitizer?" must have an answer of the form
  *commit `a3f91c2`*, not *whatever was in Dave's home directory*.
* **CI can run it.** `vivado -mode batch` on a build server after every
  merge catches the broken build *before* the accelerator study that needed
  it. Simulation (GHDL, also scriptable) runs on every commit; a bitstream
  build nightly.
* **Control-room machines have no place for GUI archaeology.** Rebuilding
  firmware during a run, over SSH, at 3 a.m., is a one-command operation or
  it is a disaster.

Use the GUI to explore and debug; keep the build in a script. (You can even
have both: `vivado -mode gui`, then `source scripts/build.tcl` in its Tcl
console, and inspect the result interactively.)

## Reading the utilization report

The second report every build must produce (`report_utilization`) says how
much of the chip you used:

```
+-------------------------+------+-----------+-------+
| Site Type               | Used | Available | Util% |
+-------------------------+------+-----------+-------+
| Slice LUTs              |   31 |     20800 |  0.15 |
| Slice Registers (FF)    |   29 |     41600 |  0.07 |
| Block RAM Tile          |    0 |        50 |  0.00 |
| DSPs                    |    0 |        90 |  0.00 |
+-------------------------+------+-----------+-------+
```

(That's roughly what this blinky costs: a 27-bit counter, an adder's worth
of LUTs, two synchronizer flops. The XC7A35T could hold about six hundred of
them.)

The four numbers to watch: **LUTs** (general logic), **FFs** (registers),
**BRAM** (Module 07's memories, and — foreshadowing — the ILA's capture
buffer), **DSPs** (Module 06's multipliers). Two practical rules:

* **Sanity-check against your mental model.** If you inferred a 4096-sample
  ring buffer and BRAM says 0, synthesis mapped it to LUTs/FFs and something
  in your description blocked BRAM inference. The report catches this;
  nothing else will.
* **"Fits" is not the bar — above ~80% LUT utilization, routing starts to
  hurt.** The router needs slack space the way a crowded lab needs empty
  bench; past ~80% the detours lengthen, timing degrades nonlinearly, and
  build times balloon. If the physics needs more logic than that, you need a
  bigger part — a decision better made at board-design time than the week
  before a run.

## The IP catalog

Not everything is hand-written VHDL. Vivado ships an **IP catalog**:
parameterizable, pre-verified blocks that you configure in a dialog (or
script) and instantiate like any entity. The ones physicists use constantly:

* **Clocking Wizard (MMCM/PLL).** You rarely run logic straight off the raw
  board oscillator. The FPGA's clock-management tiles multiply, divide, and
  phase-shift: 100 MHz in, and out come, say, 250 MHz for the ADC interface,
  125 MHz for the processing pipeline, and a phase-shifted copy for a
  source-synchronous capture — all with defined phase relationships and a
  `locked` output that belongs in your reset logic. The wizard writes the
  MMCM/PLL configuration for you and automatically constrains the generated
  clocks.
* **FIFO Generator / XPM macros.** Module 07's FIFO discipline and Module
  08's CDC, productized: dual-clock FIFOs with correct gray-coded pointers
  and built-in constraints. The modern, preferred form is the **XPM macros**
  (`xpm_fifo_async`, `xpm_cdc_*`) — instantiated directly from HDL, no
  generated core files at all. Never hand-roll an async FIFO when these
  exist.
* **ILA and VIO** — the debug cores; next section.

Version-control rule: the **`.xci` file** (the IP's configuration, small
XML) goes **in git**; the generated output products (synthesized netlists,
simulation models — regenerable, large) do **not**. Same logic as committing
source but not build artifacts.

## ILA: the scope probe inside the chip

> **Software vs. hardware.** There is no `printf` on a board. The signal you
> care about is a voltage on a metal trace inside a BGA package; no debugger
> attaches, no log file appears. The FPGA answer is to synthesize the test
> equipment *into the design*.

An **ILA (Integrated Logic Analyzer)** is an IP core you attach to signals
you want to watch. It continuously samples them **at full clock speed into
on-chip BRAM**, waits for a **trigger condition** you set (this signal
rising, that bus equal to a value — combinable, just like a scope), then
freezes and ships the capture buffer to your PC **over the same JTAG/USB
cable used for programming**. Vivado's Hardware Manager draws the result as
a waveform. It is the firmware equivalent of hanging a scope on a NIM
module's output — except the "scope" is made of the same fabric as your
design, sees signals that never reach a pin, and can trigger on a 128-bit
pattern.

The costs and knobs: capture depth × probe width consumes **BRAM** (1024
samples of a 64-bit bus is cheap; 131072 samples of 512 bits eats a large
slice of an Artix-7's memory), probes add routing load, and adding/removing
an ILA means a **rebuild** — minutes to hours per iteration, which is
exactly why the debug loop feels so slow. Its sibling **VIO (Virtual
Input/Output)** is the other direction: virtual buttons and registers you
poke from the PC — force a trigger, flip an enable, read a status word —
without a rebuild for each experiment.

One honest paragraph: **on-hardware debugging is the last resort, not the
first.** A simulation gives you every signal, at every time, with infinite
rerun and zero rebuild; an ILA gives you a handful of pre-chosen signals, a
finite window, and a rebuild per hypothesis. The Module 04 discipline —
self-checking testbenches, simulate before synthesizing — is precisely what
keeps you off this slow path. Reach for the ILA for the things simulation
genuinely can't reach: real ADC data, real optical links, real timing-system
inputs, the actual board misbehaving in the actual crate.

## Programming the board

With `build/top_blinky.bit` in hand: connect the Arty by USB (the same cable
powers it, carries JTAG, and carries ILA data), open Vivado's **Hardware
Manager** (GUI, or `open_hw_manager` in Tcl), *Open target → Auto connect*,
then *Program device* with the `.bit` file. Two seconds later the LEDs count
in slow binary; hold BTN0 and they freeze dark. That's the heartbeat — and
the entire course, physically real for the first time.

Know the two persistence modes:

* **JTAG → SRAM (what you just did):** the bitstream goes into the FPGA's
  configuration SRAM. **It is volatile** — power-cycle the board and the
  FPGA wakes up blank. Perfect for development.
* **QSPI flash (standalone operation):** for a board that must come up by
  itself — every deployed DAQ board — you convert the bitstream to a flash
  image (`write_cfgmem`) and program the board's QSPI flash chip via
  Hardware Manager (*Add Configuration Memory Device*). At power-on the FPGA
  loads itself from flash, no PC attached. Field rule: label which firmware
  version is in flash; "what's actually running in the tunnel" ambiguity has
  burned every collaboration at least once.

## Zynq, in one paragraph

Many modern DAQ and control boards are not plain FPGAs but **Zynq** (or Zynq
UltraScale+) devices: full ARM processor cores (**PS**, processing system —
runs Linux, EPICS IOCs, slow control, Ethernet) and FPGA fabric (**PL**,
programmable logic) **on one die**, connected by wide internal buses.
Everything in this course is the **PL side** — the part that meets the
detector at nanosecond timescales. Vivado's **block-design** flow (a
graphical canvas of IP blocks) exists largely to stitch the PS to peripherals
and IP, and you'll meet it on any Zynq project; but the physics logic inside
— triggers, pipelines, buffers — is still HDL written exactly as you've
learned here, dropped into the block design as your own IP.

## Design-choice notes

* **Why does even a blinky synchronize its button?** Because Module 08 is
  not optional where an async input meets a clocked design, and the habit
  must be unconditional. `btn(0)` can change in a flip-flop's setup window;
  two flops (marked `ASYNC_REG`) make the failure probability negligible.
  The cost is two registers. There is no design too small to do this right.
* **Why a 27-bit counter and the top 4 bits?** 100 MHz / 2²⁷ ≈ 0.75 Hz on
  the slowest bit — the LEDs count in binary at human speed, so one glance
  verifies both clock and pinout. A divider to "exactly 1 Hz" needs a
  comparator; a power-of-two tap needs nothing. First designs should be
  minimal.
* **Why `btn : in std_logic_vector(0 downto 0)` instead of a plain
  `std_logic`?** So the port name matches the board's button *bus* and the
  XDC's `{btn[0]}`, and so adding buttons later changes one range instead of
  the port list. A one-element vector is a common top-level idiom.
* **Why no testbench in this module?** Deliberately: by now writing one is
  routine, not new material — it's in the exercise. The point of Module 09
  is everything that happens *after* simulation passes.

## Exercise

1. **Change the heartbeat rate.** Retap the counter — drive `led` from
   `count(23 downto 20)` for a 8× faster count (does it need more counter
   bits? why not?). Re-run the GHDL analysis to check syntax.
2. **Write `tb_top_blinky`** — you have all the tools from Module 04. Check
   that the LED vector advances: hold `btn(0)` low, clock for 2²³ + a few
   cycles, and `assert` that `led` has changed from its initial value; then
   assert reset and check `led` returns to `"0000"` (remember the two-cycle
   synchronizer latency). Tip: simulating 8 million clocks takes a few
   seconds — or add a generic to shrink the counter width in simulation,
   a trick real designs use constantly.
3. **If you have Vivado installed:** run `vivado -mode batch -source
   scripts/build.tcl`, then open `build/timing_summary.rpt` (find the WNS —
   with 10 ns for a 27-bit counter, expect huge positive slack) and
   `build/utilization.rpt` (find the LUT/FF/BRAM counts and check them
   against your mental model of the design).
4. **If you have a board:** program it over Hardware Manager, watch the
   count, hold BTN0. Then change the tap from step 1, rebuild, reprogram,
   and *see* your edit at the speed of blinking lights.

## Further reading

* **UG949** — *UltraFast Design Methodology Guide*: AMD's own "how to not
  suffer" manual; the timing-closure chapters are the canonical treatment.
* **UG901** — *Vivado Synthesis*: what HDL patterns infer what hardware —
  the definitive answer to "why didn't this become a BRAM?".
* **Arty A7 Reference Manual** (Digilent) — every pin, every peripheral on
  this module's board, plus the master XDC to crib constraints from.
* **Board files**: Digilent publishes Vivado board files (install into
  Vivado's `data/boards` directory or via the Vivado Store) that let the GUI
  and IP wizards know the Arty's pinout and peripherals automatically.

## Key takeaways

* The flow is **synthesis → placement → routing → bitstream**: VHDL becomes
  a netlist of LUTs/FFs/BRAM/DSP, the netlist gets physical locations, then
  wires, then a configuration file. The tools must satisfy **physics**, not
  just semantics — that's why builds take minutes to hours.
* **WNS ≥ 0 or the design does not work.** Fix timing by pipelining first,
  reducing logic depth second, tool heroics last. Setup = too slow for the
  clock; hold = clock-independent and usually a symptom of something worse.
* The **XDC** is ordered Tcl: an unconstrained clock means no timing
  analysis; an unassigned pin can damage hardware. Constraints are part of
  the design, in git, reviewed like code.
* Read **both reports** after every build: timing summary and utilization.
  Above ~80% LUTs, routing pain begins.
* **Scripted builds** (`vivado -mode batch -source build.tcl`) make firmware
  reproducible: git-tracked, CI-runnable, one command on a control-room
  machine. GUI for exploring, script for building.
* **ILA/VIO** are your eyes on live hardware — a logic analyzer synthesized
  into the design, read over JTAG — but simulation remains the first tool;
  hardware debug is the expensive last resort.
* JTAG-loaded bitstreams are **volatile**; deployed boards boot from **QSPI
  flash**. Zynq parts add ARM cores (PS) beside the fabric (PL) — your
  physics logic is the PL, written exactly as in this course.

**Next:** the short lab-topics lessons — [Module 10 — Latches](../10_latches/),
[Module 11 — Counters in practice](../11_counters_in_practice/),
[Module 12 — ILA and VIO](../12_ila_vio_debugging/), and
[Module 13 — Serial links, PRBS, and eye diagrams](../13_serial_links_prbs_eyes/) —
or go straight to the [Capstone project](../../project/), a self-triggering
waveform digitizer readout that integrates every module, this one included.
