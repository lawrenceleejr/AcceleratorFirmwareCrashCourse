# Module 00 — The Hardware Mindset

**Time: ~30 minutes** · Prerequisite: none

This module contains no VHDL. Before you write a single line, you need to
replace one mental model with another: the model of a *program that executes*
with the model of a *circuit that exists*. Every confusing thing about HDL —
and every bug you will ever write in it — traces back to this substitution
being incomplete. Read this module slowly; it is the foundation the other
nine stand on.

## What an FPGA physically is

An FPGA (*field-programmable gate array*) is a chip covered in a huge regular
grid of small, general-purpose digital building blocks, plus a programmable
wiring network connecting them. Nothing on the chip does anything specific
until you configure it. The building blocks, in the vocabulary of the Xilinx
7-series parts this course targets (Artix-7, Kintex-7, Zynq-7000):

| Block | Xilinx name | What it is | Roughly how many (mid-range Artix-7) |
|-------|-------------|------------|--------------------------------------|
| Lookup table | **LUT6** | A 64-bit truth table: 6 inputs in, 1 bit out. Can *be* any 6-input logic function — AND, XOR, a majority vote, anything | ~100,000 |
| Flip-flop | FF (paired with each LUT) | A 1-bit memory cell that captures its input on a clock edge | ~200,000 |
| Logic block | **CLB** | The tile that packages LUTs and flip-flops together (8 LUTs + 16 FFs per CLB in 7-series) | ~15,000 |
| Block RAM | **BRAM36** | A 36-kilobit dual-port memory block — your waveform buffers and FIFOs live here | ~300 |
| DSP slice | **DSP48** | A hardened 25×18 multiplier with a 48-bit accumulator — filters, energy sums, pedestal subtraction | ~200–700 |
| Routing | interconnect | A programmable mesh of wires and switches occupying most of the die area | — |

A LUT deserves a second look, because it is the atom of everything you will
build. It is literally a tiny 64×1 memory: the 6 input wires form an address,
and the stored bit at that address drives the output. Load it with the truth
table of AND and it *is* an AND gate. Load the truth table of "at least 3 of
my 6 inputs are high" and it *is* a majority discriminator. Every piece of
combinational logic you describe in VHDL gets chopped up by the tools into a
forest of these truth tables.

So what does it mean to "program" an FPGA? The configuration of every LUT
(which truth table), every flip-flop (used or not, reset value), every BRAM
(contents, port widths), and every routing switch (which wire connects to
which) is held in configuration memory distributed across the chip. The
**bitstream** — the file you load into the FPGA — is nothing more than the
complete contents of that configuration memory.

> **Programming an FPGA does not load instructions to be executed. It chooses
> which circuit exists.** After configuration there is no program, no
> instruction pointer, no execution — just a specific digital circuit, made
> of thousands of little truth tables and flip-flops wired together, doing
> whatever that circuit does, continuously, every clock cycle, forever.

**Software analogy — and where it breaks.** You might picture the bitstream
as a compiled binary. But a binary is a *sequence of instructions* that one
(or a few) processors step through in time. A bitstream is a *description of
a machine*. The closest software analogy is not compiling a program — it is
`make menuconfig` for the laws of physics on that chip.

## FPGA vs CPU vs GPU vs ASIC

Why does physics instrumentation lean so hard on FPGAs? Because our problems
are dominated by two requirements that commodity computers are structurally
bad at: **massive fine-grained parallelism** and **deterministic latency**.

| | CPU | GPU | FPGA | ASIC |
|---|-----|-----|------|------|
| Clock rate | ~3–5 GHz | ~1–2 GHz | ~0.1–0.5 GHz | whatever you design |
| Parallelism | a few dozen cores | thousands of identical threads | *anything you can fit* — thousands of different circuits at once | same, but fixed forever |
| Latency | µs–ms, **jittery** (caches, interrupts, OS scheduler) | high & batchy (fed over PCIe) | **fixed, to the clock cycle** — ns to µs, same every time | fixed, fastest possible |
| I/O | via OS and driver stacks | via the host CPU | pins wired *directly* into your logic: ADCs, optical links, NIM/TTL | same |
| Flexibility | reprogram in seconds | reprogram in seconds | reconfigure in seconds–minutes (new bitstream) | **none** — respin costs months and millions |
| Up-front (NRE) cost | ~zero | ~zero | board + tools, modest | enormous (masks, fab runs) |

Notice the FPGA's clock rate: a lowly 100–500 MHz, ten times *slower* than a
CPU. It wins anyway, for two reasons. First, parallelism: a CPU with 32 cores
does 32 things at once; an FPGA processing 128 detector channels instantiates
128 copies of the channel logic and does 128 things at once — plus the trigger
sum, plus the readout, plus the slow control, all simultaneously, because they
are physically separate circuits. Second, determinism: a circuit's latency is
a fixed number of clock cycles, decided at design time, identical for every
event. There is no cache to miss, no interrupt to service, no garbage
collector, no OS. The worst case *is* the typical case.

ASICs beat FPGAs on speed, power, and per-unit cost — which is why the very
front-end chips bonded to sensors (readout ASICs, TDCs) are custom silicon.
But an ASIC's logic is frozen at fabrication, and a mask set costs more than
your experiment's computing budget. FPGAs occupy the sweet spot physics needs:
hardware-grade parallelism and determinism, with firmware you can fix after
the detector is cabled up and the beam pipe is welded shut.

### The canonical example: a level-1 trigger

At the LHC, proton bunches cross every 25 ns — 40 million times per second.
The level-1 trigger must examine coarse detector data from **every single
crossing** and decide, within a fixed latency budget of a few microseconds
(set by how long the front-end pipelines can buffer data), whether to keep
the event. No crossing may be skipped; the decision may not be late, ever,
because the front-end buffers physically overflow.

Try to do that on a CPU: a 25 ns budget is ~100 clock cycles — less than one
cache miss, never mind an interrupt or a scheduler tick. And "usually fast
enough" is worthless when a single late decision loses data irrecoverably.

For an FPGA the same problem is almost boring. You build a **pipeline**: a
chain of circuit stages separated by flip-flops, each stage doing one small
step of the calculation (form tower sums, apply thresholds, count objects,
combine). On each clock tick, every stage processes a *different* bunch
crossing, and a finished decision emerges from the end of the chain — one per
tick, 40 million per second, each with *exactly* the same latency down to the
nanosecond. A new crossing enters the pipeline before the previous one has
left. That is not clever optimization; it is just what a chain of circuits
naturally does.

### The same story in accelerator controls

The trigger is the famous example, but accelerator operations run on the same
requirement — deterministic, fast, always-on reaction:

* **LLRF (low-level RF) feedback.** Regulating cavity field amplitude and
  phase to ~0.01% / 0.01° means digitizing the field, running a filter and
  PI controller, and updating the drive — a complete loop in well under a
  microsecond, continuously. The controller *is* an FPGA circuit sitting
  between ADC and DAC.
* **Machine protection interlocks.** A beam-loss monitor over threshold must
  fire the beam abort within a guaranteed few microseconds, on the shift
  when it happens, at 4 a.m., after 300 days of uptime. You do not put an
  OS between a loss monitor and a multi-megajoule beam.
* **Orbit / beam-position feedback.** Hundreds of BPMs feeding corrector
  magnets at 10 kHz+ loop rates: parallel per-channel processing plus a
  deterministic global calculation — the FPGA shape again.

If your instinct is "surely a fast PC with a real-time kernel could…" — the
operational answer, learned expensively across many labs, is: not with a
*guarantee*, and guarantees are the entire product.

## Why HDL is not programming

Now the central retraining. A hardware description language looks like code:
files, identifiers, operators, a compiler. The resemblance is a trap.

When you compile C++, the compiler emits **instructions** — a list of
operations one processor executes in sequence, in time. When you "compile"
VHDL, the synthesizer emits a **netlist** — a parts list of gates,
flip-flops, and memories with wiring instructions, which the placer and
router then map onto physical LUTs and interconnect. Nothing in the result
executes in sequence. Everything you described exists *at once* and operates
*continuously*, the way every module in a NIM crate is powered and working
whether or not anyone is looking at it.

Here is the translation table to keep taped above your desk. Every row is a
software instinct that will misfire until you replace it:

| Software concept | Hardware reality |
|------------------|------------------|
| A function | A **circuit instance**. "Calling" it twice in parallel means physically stamping two copies into the silicon — twice the area. There is no reuse-in-time by default. |
| A variable | A **wire** (if it just carries a value) or a **register** (a flip-flop, if the value must survive to the next clock cycle). It does not live in RAM. It has a physical location. |
| A statement executes | A statement **describes a piece of hardware** that operates continuously. Statement order in concurrent code is meaningless. |
| A `for` loop | Either **replicated hardware** (N copies of the circuit, all working simultaneously — a loop unrolled into space) or, if you truly need one-step-per-clock-cycle, a **state machine** you design explicitly (Module 05). Nothing iterates on its own. |
| `if`/`else` | A **multiplexer** — a physical selector circuit. Both branches' logic exists and computes; the condition only selects which result is used. |
| A call stack | **Does not exist.** No recursion, no dynamic dispatch, no stack frames. The complete structure of the circuit is fixed when the bitstream is built. |
| `new` / `malloc` | **Does not exist.** Every register, every RAM bit is allocated at synthesis time. Total memory usage is known before power-on. |
| Threads (rare, explicit, hazardous) | **Everything is parallel by default.** Ten thousand lines of VHDL is ten thousand circuits running at once. The hard part is the opposite of software: making things happen *in order* takes deliberate effort. |
| Execution time (data-dependent, variable) | **Latency in clock cycles** — a structural property of the pipeline you designed, identical for every input. |
| The compiler (emits instructions) | The **synthesizer** (emits a netlist of gates). Then place-and-route decides which physical LUT each gate becomes and which wires connect them. |

> **Rule of thumb:** when reading or writing VHDL, never ask "what does this
> line do when it runs?" Ask **"what hardware does this line describe?"** If
> you can't answer with a picture — a gate, a mux, a register, a memory — you
> don't understand the line yet.

One corollary worth internalizing now, because it inverts a deep software
instinct: in software, parallelism is expensive and sequencing is free. In
hardware, **parallelism is free and sequencing is expensive** — doing things
one after another requires you to build a state machine that remembers where
it is. That inversion is the hardware mindset in one sentence.

## Why VHDL (and not Verilog)?

There are two mainstream HDLs — **VHDL** and **Verilog/SystemVerilog** — and
you will eventually read both. They describe the same hardware; the concepts
in this course transfer 1:1, and no serious engineer is monolingual forever.
This course teaches VHDL, for two honest reasons:

* **Strong typing.** VHDL is Ada-flavored: a 12-bit ADC bus and a 16-bit
  accumulator are different types, and connecting them without an explicit
  conversion is a compile-time error, not a silent truncation at 2 a.m.
  during a beam study. Verilog will cheerfully wire mismatched widths
  together. Physicists — who mostly came up on typed languages and error
  bars — tend to find VHDL's pedantry comfortable rather than annoying.
* **It's what your lab speaks.** VHDL is the dominant HDL in European physics
  labs — CERN's trigger and accelerator firmware is overwhelmingly VHDL —
  and it's ubiquitous in accelerator controls generally. The firmware you'll
  be asked to read, fix, and extend is very likely VHDL.

The version matters: this course uses **VHDL-2008** throughout (`ghdl
--std=08`), which is well supported by both GHDL and Vivado and removes the
worst annoyances of older revisions. When you see crusty VHDL-93 in a
20-year-old repository, it will still be readable — just clunkier.

## The two worlds: simulation and synthesis

Every design in this course lives a double life, and knowing which world
you're in at any moment is a core professional skill.

**Simulation** is where you will spend ~90% of your time. A simulator —
we use [GHDL](https://ghdl.github.io/ghdl/), free and open source — reads
your VHDL plus a **testbench** (VHDL that generates stimuli and checks
outputs, Module 04) and computes what the described circuit *would* do,
nanosecond by nanosecond, recording every signal. It runs in seconds on your
laptop, can pause anything, sees everything, and costs nothing. Waveforms
viewed in [GTKWave](https://gtkwave.sourceforge.net/) are your `print()`,
your debugger, and your oscilloscope, all at once.

**Synthesis** is where VHDL becomes hardware. AMD/Xilinx **Vivado** reads
your VHDL, produces a netlist, maps it onto the LUTs/FFs/BRAMs/DSPs of a
specific part, places and routes it, verifies **timing closure** (that every
signal makes it between flip-flops within one clock period — Module 09), and
emits the bitstream. This takes minutes to hours, and debugging on the real
chip means recompiling for every hypothesis and squinting at a handful of
signals through a logic analyzer core.

The discipline that follows from that asymmetry:

> **Simulation-first, always. Never debug on hardware what you could have
> caught in simulation.** A bug found in simulation costs a minute. The same
> bug found on a board in the tunnel costs a day — or an access request, an
> RP survey, and a shift you owe someone. Experienced firmware engineers are
> not people who debug on hardware well; they are people who almost never
> have to.

This is why the course runs on GHDL from Module 01 and doesn't touch Vivado
until Module 09: the habit you're building is *prove it in simulation, then
synthesize*.

One warning for later: not everything simulatable is synthesizable. A
testbench can say "wait 17 ns" or read a file of ADC samples from disk;
no circuit can. The synthesizable subset of VHDL is what Modules 01–08
teach; testbench-only constructs are clearly flagged when they appear.

## Tool setup

**Now (Modules 01–08):** GHDL + GTKWave, installed in one line as shown in
the [top-level README](../../README.md#quick-start):

```bash
# Debian / Ubuntu
sudo apt-get install ghdl gtkwave

# macOS
brew install ghdl gtkwave
```

Run the [quick-start test](../../README.md#quick-start) from the top README
to confirm the toolchain works. That's everything you need for the next
eight modules.

**Later (Module 09 and the capstone):** **Vivado ML Standard Edition**, AMD's
free tier, downloadable from amd.com after registration. Fair warning so you
can plan: the installer is a very large download (tens of GB) and wants
~100+ GB of disk; it officially supports Windows and specific Linux
distributions (Ubuntu/RHEL families — no native macOS; Mac users run it in a
Linux VM). The free Standard edition covers the WebPACK-class devices —
including all of Artix-7 and the smaller Kintex-7 and Zynq parts — which is
exactly the class of chip on the hobbyist and lab boards this course has in
mind. You do not need it, or a board, until Module 09, and even then only if
you want to target real hardware. Don't install it today; there's a module's
worth of instructions waiting for you when it's time.

## Glossary you'll hear in the counting room

Terms that will be thrown around in your group's meetings, defined once:

| Term | Meaning |
|------|---------|
| **Firmware** | In this context: the FPGA design — the VHDL and the bitstream built from it. (Confusingly, embedded C on a microcontroller is also called firmware; context disambiguates.) |
| **Bitstream** | The configuration file loaded into the FPGA; the complete specification of which circuit exists. Rebuilt by Vivado after every design change. |
| **Netlist** | The output of synthesis: a list of gates/primitives and the wires between them. The circuit as a graph, before placement onto physical locations. |
| **RTL** | Register-transfer level — the abstraction you write at: registers, plus the combinational logic between them. "The RTL" = the human-written HDL source, as opposed to netlists or bitstreams. |
| **LUT** | Lookup table, the small truth-table memory that implements all combinational logic. Also the unit of "how full is the chip" ("we're at 70% LUTs"). |
| **BRAM** | Block RAM — the dedicated on-chip memory blocks (36 kb each in 7-series). Where buffers and FIFOs live. |
| **Timing closure** | The state of a design in which every signal path provably completes within its clock period. "It doesn't close timing" = the design is currently too slow for its clock, and someone's week just got worse. Module 09. |
| **Testbench** | Non-synthesizable VHDL that instantiates your design, feeds it stimuli, and checks its outputs in simulation. Module 04. |
| **IP core** | A pre-packaged design block (FIFO, memory controller, gigabit transceiver wrapper) dropped into your design — from the vendor, from OpenCores, or from the group's shared repository. Module 09. |

## Key takeaways

* An FPGA is a configurable sea of LUTs (truth tables), flip-flops, block
  RAMs, and DSP slices in a programmable routing mesh. The bitstream doesn't
  contain instructions — it **chooses which circuit exists**.
* FPGAs win in physics not on clock speed but on **arbitrary parallelism**
  and **cycle-deterministic latency** — a decision for every 25 ns bunch
  crossing, an interlock that fires in a guaranteed microsecond. CPUs/GPUs
  cannot promise either; ASICs can, but are frozen at fabrication.
* HDL describes hardware that all exists and operates **simultaneously**.
  Function → circuit instance, variable → wire/register, loop → replicated
  hardware or an explicit state machine, call stack → doesn't exist. Always
  ask *"what hardware does this describe?"*, never *"what does this do when
  it runs?"*
* In hardware, **parallelism is free and sequencing is expensive** — the
  exact inverse of software.
* **VHDL** because it's strongly typed and it's what physics labs (CERN
  included) overwhelmingly use; the concepts transfer directly to Verilog.
  This course is VHDL-2008.
* Two worlds: **simulation** (GHDL — free, fast, where you live) and
  **synthesis** (Vivado — VHDL → bitstream, from Module 09). Simulation
  first, always: never debug on hardware what simulation could have caught.

**Next:** [Module 01 — Entities, signals, and your first design](../01_entities_and_signals/)
