# Module 12 — ILA and VIO: Seeing Inside a Running FPGA

**Time: ~30 minutes** · Prerequisite: [Module 09](../09_vivado_xilinx_flow/)

The firmware simulates perfectly. Every testbench prints `ALL TESTS PASSED`.
You built the bitstream, screwed the board into the crate, and started the
beam study — and the scaler readback is wrong, or events stop coming out
after a few seconds, or the trigger rate is half what the counting-house
expects. Nothing in your simulation reproduces it, because the bug is not in
the logic you simulated: it is in the collision between your logic and the
*real world* the simulator never saw.

This module is the hands-on expansion of the short ILA/VIO overview in
[Module 09](../09_vivado_xilinx_flow/#ila-the-scope-probe-inside-the-chip).
That section told you *what* these cores are; this one puts you at the Vivado
Hardware Manager and walks you through actually using them. It ships a small
DUT — [`src/debug_demo.vhd`](src/debug_demo.vhd) — decorated with the
`mark_debug` attribute that is the whole teaching vehicle, plus a self-checking
testbench, because even a design that exists to be debugged on hardware gets
simulated first.

> **Software vs. hardware.** In software you sprinkle `printf`, re-run, read
> the log. On an FPGA there is no `printf`: the value you care about is a
> voltage on a metal trace inside a BGA package, driven and consumed entirely
> on-chip, that never reaches a pin you could probe. `printf` debugging does
> not exist here. The ILA and VIO are what replaced it — and this module is
> how you use them.

## 1. When you actually need in-hardware debug

Be honest about the hierarchy, because on-hardware debugging is *slow* — a
rebuild per hypothesis, minutes to hours each — and the whole rest of this
course exists to keep you off it:

* **Simulation (Modules 04–08) catches ~95% of bugs.** Every signal, at every
  time, infinite rerun, zero rebuild. If a bug *can* be reproduced in
  simulation, reproduce it there. It is the cheapest debugger you will ever
  have.
* **The bugs that reach hardware are the ones simulation structurally cannot
  see:**
  * **Clock-domain crossings** (Module 08) — metastability is a
    probabilistic, temperature-dependent physical effect; a functional
    simulation runs in a world without setup/hold windows and cheerfully
    shows you clean edges.
  * **Constraints** (Module 09) — a mis-constrained or unconstrained clock, a
    false path that isn't really false. The XDC is not part of the simulation
    at all.
  * **External-signal reality** — the trigger cable that bounces, the ADC
    that sends data one clock later than the datasheet claims, the timing
    system that glitches. Your testbench fed the design *your idea* of the
    input; the tunnel feeds it the truth.
  * **Config / integration** — wrong bitstream in flash, a block-design
    connection you thought you made, a PLL that never locked.
* **ILA/VIO is how you look.** They are the tools for exactly the layer
  between "the logic is correct" and "the system is correct".

> **Physics framing.** An ILA is the oscilloscope you can clip onto *any
> internal net* of a board that is already screwed into a crate in the tunnel
> — without pulling the board, without a pin, without a scope cart. You
> pre-decide which nets to expose, rebuild once, and thereafter watch them
> over the same USB/JTAG cable you program with. It is the scope you wish you
> had on a NIM module, except it reaches inside the chip.

## 2. What an ILA physically is

An **Integrated Logic Analyzer** is not a tool that connects *to* your design
from outside. It is **logic synthesized INTO your design**:

* a **BRAM sample buffer** (Module 07's block RAM — the same resource),
* a set of **trigger comparators** that watch your probed nets,
* a small controller and the **`dbg_hub`**, read out over **JTAG** by
  Vivado's **Hardware Manager** on your PC.

Three consequences you must internalise, because they are where beginners get
fooled:

* **It samples on YOUR clock.** The ILA registers each probed net on a clock
  edge and stores that registered value. You are seeing what a flip-flop in
  your design would see — *not* analog reality. A 5 ns glitch that lives and
  dies between two edges of a 100 MHz clock is **invisible** to the ILA, the
  same way it is invisible to your logic. If you suspect sub-clock glitches
  or analog integrity, you need a real scope on a real pin, not an ILA.
* **Capture depth costs BRAM.** 1024 samples × 64 signals is real memory off
  Module 09's utilization budget; 131072 samples × 512 bits eats a large
  fraction of an Artix-7's block RAM. Depth × width is a resource you spend.
* **It changes placement and timing slightly.** Adding an ILA adds logic and
  routing load, so the placed-and-routed design is not bit-identical to the
  one without it — timing can shift by tens of picoseconds, occasionally
  enough to matter.

> **Physics framing (the fun one).** The act of measurement disturbs the
> system. Inserting the ILA to observe the design changes the design you are
> observing — a genuine observer effect. Usually negligible; occasionally the
> bug hides when the ILA is present and returns when you remove it, which is
> itself a strong clue (it points at timing or a race, not functional logic).

## 3. The two insertion flows

There are two ways to get an ILA into your design. Do the first one.

### (a) Recommended for beginners: `mark_debug` in HDL, then the wizard

You have already done the hard part — it is in
[`src/debug_demo.vhd`](src/debug_demo.vhd):

```vhdl
attribute mark_debug : string;
attribute mark_debug of state      : signal is "true";
attribute mark_debug of busy_r     : signal is "true";
attribute mark_debug of trig_cnt_r : signal is "true";
attribute mark_debug of lost_cnt_r : signal is "true";
```

These lines do **nothing in simulation** — GHDL parses an attribute it does
not recognise and simply carries it along, which is why the testbench runs
untouched. Their entire job is to speak to **Vivado's synthesizer**: *keep
this net, do not optimize it away, do not merge or rename it, expose it by
name so a debug core can be hung on it later.* That preservation is a real
cost — a `mark_debug` net cannot be optimized, so it burns logic and can
nudge timing (Section 6). Mark while debugging; strip for the run.

With the nets marked, the flow:

1. **Synthesize.** Flow Navigator → *Run Synthesis*. The marked nets survive
   into the synthesized netlist.
2. **Open the synthesized design.** Flow Navigator → *Open Synthesized
   Design*.
3. **Set Up Debug.** Flow Navigator (or the *Tools* menu) → **Set Up Debug**.
   A wizard opens.
4. **Pick nets.** The wizard pre-populates the list with every `mark_debug`
   net it found — `state`, `busy_r`, the two counters. You can add or remove
   more here by right-clicking nets in the netlist. Each net you keep becomes
   an ILA **probe**.
5. **Assign the debug clock.** The wizard asks which clock samples these
   nets. Choose the clock domain the nets live in — here, `clk`. (If you
   probe nets from two domains, each needs its own clock; mixing them is a
   common first mistake.)
6. **Choose sample depth.** The dialog asks how many samples deep the capture
   buffer is (e.g. 1024). This is the BRAM spend of Section 2 — the window
   length you will get to see. Also choose **capture control** and **advanced
   trigger** if you want them (Section 4).
7. **Finish.** The wizard inserts the ILA core and the `dbg_hub`, writes the
   generated debug constraints into an `.xdc`, and you re-run
   implementation → bitstream.

That is the whole loop. Nets marked in HDL, wizard inserts the core, rebuild
once.

### (b) Explicit ILA IP instantiation

When you want the debug core to be **permanent and scripted** — part of a
board's standing "debug build", instantiated deterministically rather than
discovered by a wizard — you instantiate the **ILA IP from the IP catalog**
directly, wire your signals to its `probe0`, `probe1`, … ports in HDL, and
configure depth/width in the `.xci`. This is more work and more explicit; it
is what you graduate to when the debug instrumentation is a designed-in
feature rather than a one-off hunt. Beginners: use flow (a).

## 4. Using it: the Hardware Manager

Bitstream built with the ILA in it, board on JTAG:

1. Open **Hardware Manager**, *Open target → Auto Connect*, **program the
   device**. Vivado detects the `dbg_hub` and shows your ILA with a
   waveform-like window — the same look as GTKWave, but the samples are
   coming off a running chip.
2. **Refresh the device** if the ILA does not appear; the hub enumerates over
   JTAG.

**Trigger setup.** You tell the ILA what to wait for, exactly like arming a
scope — but on internal nets and on patterns, not just an edge on one channel:

* `busy == R` (rising) — catch the moment the machine goes busy.
* `lost_count != 0` — catch the **first** dropped trigger, the instant the
  loss counter leaves zero. This is the killer feature: you trigger on the
  onset of a rare fault and capture the cycles around it.
* Conditions combine (AND/OR across probes), just like a scope's logic
  trigger but with as many bits as you probed.

**Trigger position (pre-trigger capture).** You choose *where in the capture
window the trigger sits*: put it at the far right and the whole buffer is the
history **before** the event; put it in the middle and you see both sides.
You have built this exact machine already — Module 07's **ring buffer**
continuously overwrites the oldest sample until a trigger freezes it. **An ILA
*is* a ring buffer with a trigger comparator bolted on.** Pre-trigger capture
is why: the buffer was already recording; the trigger just decides when to
stop.

**Single vs. repetitive trigger.** Single arms once and freezes on the first
match (use this to catch a specific fault). Repetitive re-arms after each
capture (use this to watch a recurring pattern live).

**Capture control.** Beyond the trigger, you can tell the ILA to **store only
samples matching a condition** — e.g. store a sample only when `busy = '1'` —
so a shallow buffer spans a long, sparse span of interesting activity instead
of filling with idle cycles. Depth is precious; spend it on the cycles that
matter.

> **A concrete debugging story.** The counting house reports: `trig_count`
> climbs happily, but events stop coming out of the board after a moment. In
> simulation everything passes. You set an ILA trigger on **`busy` rising**,
> centre the trigger, and capture. The waveform shows `busy` go high on a
> trigger and then **never fall** — the machine is wedged busy, silently
> eating every subsequent trigger as a loss. You widen the window and watch
> `state` and `step_cnt`: the cooldown counter is counting *up* but never
> reaching its terminal value, because the terminal comparison was against a
> constant that a last-minute generic change left too large. Simulation
> passed because the testbench used the *matching* generic. The ILA showed
> you, in ten seconds on the real board, the one net (`step_cnt` never
> equalling its target) that pinned it down.

**Reading FSM states.** Your `state` signal is an enumerated type in VHDL, but
by the time it is a net on silicon it is **encoded bits** — the ILA shows you
`00`/`01`/`10`, not `idle`/`processing`/`cooldown`. Two defences, both worth
having:

* **Keep a mapping comment in your HDL** next to the type declaration, so
  when you read `10` on the ILA you know it means `cooldown`. (This module's
  DUT does exactly this.)
* **Force a readable encoding while debugging** with the `fsm_encoding`
  attribute (e.g. one-hot, or a fixed binary order) so the bits are
  predictable and each state is easy to recognise on the waveform. Set it
  back to `auto` for the production build and let the tool optimize.

## 5. VIO: the other direction

The ILA is fast capture *out* of the chip. The **VIO (Virtual
Input/Output)** is slow interaction *both ways*, at roughly human (~Hz)
rates, straight from the Hardware Manager GUI:

* **Virtual outputs** — buttons and registers you *poke*: drive `trigger_in`
  high to inject a trigger by clicking, flip an enable, set a threshold —
  without a physical button or a slow-control bus.
* **Virtual inputs** — values you *probe*: read `trig_count` and `lost_count`
  live as they climb, watch a status word, confirm a `locked` flag.

**Contrast to hold in your head:** **ILA = fast capture of waveforms** (what
happened, cycle by cycle, around an event); **VIO = slow read/write of
levels** (poke a control, read a scaler, right now). During bring-up a VIO
lets you exercise a design interactively — force a trigger, watch the counter
increment — before any real trigger cable is connected.

> **Honest note.** A VIO is a **bring-up** tool, not an operations tool. Real
> experiments do slow control and monitoring over a proper bus — **AXI** on
> Zynq, or **IPbus** (the physics community's standard: register access over
> Ethernet/UDP, with a software control layer), or EPICS on top of those. You
> do not run a beam experiment by clicking VIO buttons in Vivado. Use the VIO
> to prove a block works on the bench, then wire it to the real control path.

## 6. Costs and etiquette

* **Do not leave ILAs in production bitstreams.** They cost BRAM, they cost a
  little timing, and — importantly in a radiation environment — **more
  configuration bits means a larger SEU cross-section**: every extra
  configured cell is another target for a single-event upset to flip. Debug
  cores are pure downside once the bug is found.
* **Keep a "debug build" variant.** The clean way: one build with the debug
  cores (for the bench and for chasing a specific fault) and one production
  build without them, ideally selected by a build flag in your `build.tcl` so
  the difference is one reproducible switch, not a hand-edit. `mark_debug`
  attributes can stay in the HDL harmlessly — they only cost you when the
  Set Up Debug flow actually inserts a core.
* **Mind the `dbg_hub` clock.** The debug hub needs a free-running clock; if
  the clock you assigned it can stop or is gated, the hub goes unreachable and
  the Hardware Manager cannot talk to your ILA. Give it a always-on clock.
* **The ILA needs a free JTAG connection.** On the bench that is the
  programming USB cable. In a crate it may mean a front-panel USB/JTAG
  header, or — on a Zynq board — routing through the processor's internal
  JTAG. If the board is deep in a rack with no accessible JTAG, the ILA
  cannot be read: plan the debug access at board-design time, not during the
  run.

## Run it

The DUT and its testbench simulate under GHDL exactly like every other module.
The ILA/VIO parts of this lesson **only come alive in Vivado, on real
hardware** — there is nothing to simulate about a JTAG readout — but the
design itself, `mark_debug` attributes and all, compiles and runs here:

```bash
cd modules/12_ila_vio_debugging

# Analyze the design (the mark_debug attributes are carried along, inert)
# and its self-checking smoke test.
ghdl -a --std=08 src/debug_demo.vhd tb/tb_debug_demo.vhd

# Elaborate and run.
ghdl --elab-run --std=08 tb_debug_demo
```

Expected output:

```
tb/tb_debug_demo.vhd:188:5:@396ns:(report note): ALL TESTS PASSED
```

If you want a waveform, add `--wave=debug_demo.ghw` and open it in GTKWave —
and notice that you get *every* signal, for free, with no rebuild. That is
precisely the luxury the ILA does not have, and precisely why simulation comes
first.

## Design-choice notes

* **Why is the `mark_debug` flow recommended over IP instantiation?** For a
  beginner chasing a bug, marking a handful of nets and running the Set Up
  Debug wizard is the shortest path from "something is wrong" to "I am
  watching the suspect nets on the real board". Explicit ILA IP is better when
  the instrumentation is permanent and scripted, but that is a later concern;
  start with the wizard.
* **Why does the debug demo still ship a testbench?** Because the module's own
  thesis is that simulation comes first. A design whose stated purpose is
  "the thing you debug on hardware" would be a hypocritical place to skip the
  testbench. The smoke test also pins down the exact behaviour — the busy
  envelope, the loss counting — that you would later confirm on the ILA, so
  you know what "correct" looks like before you go looking.
* **Why keep the state encoding as a comment in the HDL?** Because on the ILA
  the enumerated `state` is raw bits. The mapping comment (and, optionally,
  `fsm_encoding`) is the difference between reading a waveform fluently and
  decoding it in your head under pressure during a run.

## Exercise

A thinking exercise — **no board required**, which is the point: most of
learning to debug hardware is deciding *what to look at* before you spend a
rebuild.

1. **Add a `mark_debug`'d heartbeat.** Add a free-running counter to
   `debug_demo.vhd` (e.g. `heartbeat : unsigned(23 downto 0)` incrementing
   every clock, reset-cleared), tag it with `mark_debug`, and re-run the GHDL
   analysis to confirm it still compiles. On real hardware a heartbeat net on
   the ILA instantly answers "is this clock even running?" — the first
   question when a board looks dead.
2. **Match failures to trigger conditions.** For each hypothetical field
   failure below, write down the single ILA **trigger condition** you would
   arm to catch it, and which probed net would confirm the diagnosis:
   * (a) "Events stop coming out after a few seconds." *(Hint: what net,
     rising or stuck, marks the machine wedged?)*
   * (b) "We are losing ~10% of triggers even at low rate." *(Hint: trigger
     on the onset of the loss.)*
   * (c) "The board comes up but never responds to any trigger at all."
     *(Hint: is the problem in the FSM, or upstream of it — what would the
     heartbeat and `trigger_in` tell you?)*
3. **Optional, on a board:** instrument Module 09's `top_blinky`. Add
   `mark_debug` to the divider counter, run Set Up Debug, and trigger the ILA
   on a chosen bit of the counter rising. You will watch the same blink you
   see on the LEDs, but sampled off the internal net — proof the ILA sees what
   the fabric sees.

## Key takeaways

* **On-hardware debug is the last resort, not the first.** Simulation catches
  ~95% of bugs cheaply; the ILA/VIO exist for what simulation structurally
  cannot see — CDC, constraints, external-signal reality, integration.
* An **ILA** is a logic analyzer synthesized *into* your design: BRAM buffer +
  trigger comparators, read over JTAG. It samples on **your clock** (glitches
  between edges are invisible), costs **BRAM** (depth × width), and slightly
  perturbs timing (a real observer effect).
* **An ILA is Module 07's ring buffer with a trigger** — which is why
  pre-trigger capture works: the buffer was always recording; the trigger
  decides when to freeze.
* The **recommended flow**: `mark_debug` in HDL → synthesize → *Set Up Debug*
  wizard → pick nets, clock, depth → rebuild. `mark_debug` is inert in
  simulation and tells Vivado to keep and expose a net (at the cost of not
  optimizing it).
* **VIO** is the slow, two-way, human-rate sibling: poke controls, read
  scalers, no slow-control bus needed — a **bring-up** tool. Real operations
  use AXI / **IPbus** / EPICS.
* **Strip debug cores from production builds**: they cost BRAM, timing, and —
  in radiation — SEU cross-section. Keep a debug-build variant, mind the
  `dbg_hub` clock, and make sure JTAG is physically reachable in the crate.

**Next:** [Module 13 — Serial links, PRBS, and eye diagrams](../13_serial_links_prbs_eyes/)
