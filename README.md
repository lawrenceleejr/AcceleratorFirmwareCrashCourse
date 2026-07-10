# Accelerator Firmware Crash Course

**VHDL and Xilinx FPGAs for physicists who already know C++ or Python.**

This is a hands-on crash course in writing firmware for the kinds of FPGAs that
live in accelerator control systems and particle-physics data acquisition (DAQ)
chains: trigger logic, waveform digitizer readout, beam gating, event building.
Every example is drawn from that world — discriminators, coincidence units,
scalers, dead-time counters, ring buffers full of ADC samples.

It assumes you can program (loops, functions, types — C++ or Python level) but
have **never written a line of VHDL** and maybe never thought hard about what
an FPGA actually is. The single most important idea in the whole course is
this:

> **VHDL is not a programming language. It is a language for *describing
> hardware* — circuits made of gates and flip-flops, all of which exist and
> operate simultaneously.** Your software instincts about "lines executing in
> order" are the main thing standing between you and competence, and each
> module works explicitly on retraining them.

## How the course works

* **10 modules + a capstone project.** Each module is designed to take about
  **30 minutes**: read the text, run the examples, do the exercise.
* **Everything is runnable.** Each module ships real VHDL source and a
  self-checking testbench. You simulate with [GHDL](https://ghdl.github.io/ghdl/)
  (free, open source, runs anywhere) and view waveforms with
  [GTKWave](https://gtkwave.sourceforge.net/). No FPGA board is required until
  you want one.
* **Xilinx-oriented.** The synthesis, constraints, and IP material targets
  AMD/Xilinx **Vivado** and 7-series/UltraScale parts (Artix/Kintex/Zynq), the
  workhorses of physics DAQ. Module 09 and the capstone cover the Vivado flow;
  everything else is vendor-neutral VHDL you'd write the same way anywhere.
* **"Why", not just "how".** Every design choice — why a synchronous reset,
  why a two-flop synchronizer, why a FIFO here — comes with the reasoning, and
  with an explicit note on how it differs from what a software developer would
  expect.

## The modules

| # | Module | You will learn | Physics example |
|---|--------|----------------|-----------------|
| 00 | [The hardware mindset](modules/00_the_hardware_mindset/) | What an FPGA is, why HDL ≠ programming, tool setup | Why a trigger decision in 25 ns is easy for hardware and impossible for a CPU |
| 01 | [Entities, signals, and your first design](modules/01_entities_and_signals/) | `entity`, `architecture`, `std_logic`, concurrent assignment | Two-detector coincidence unit |
| 02 | [Combinational logic](modules/02_combinational_logic/) | Logic without memory: `when/else`, `with/select`, processes | Majority trigger for a 4-paddle hodoscope |
| 03 | [Clocks, registers, and counters](modules/03_clocks_and_registers/) | `rising_edge`, flip-flops, synchronous design, resets | Beam-gate generator and dead-time scaler |
| 04 | [Testbenches and simulation](modules/04_testbenches/) | Writing self-checking testbenches, waveforms, `assert` | Verifying a discriminator against a software model |
| 05 | [State machines](modules/05_state_machines/) | FSM patterns, encoding, Moore vs Mealy | Readout controller for a triggered event |
| 06 | [Arithmetic and DSP](modules/06_arithmetic/) | `signed`/`unsigned`, `numeric_std`, pipelining math | Pedestal subtraction and a moving-average filter |
| 07 | [Memories and FIFOs](modules/07_memories_and_fifos/) | Inferring block RAM, ring buffers, FIFO discipline | Circular waveform-capture buffer for an ADC |
| 08 | [Clock domains and CDC](modules/08_clock_domains_cdc/) | Metastability, synchronizers, safe domain crossing | Asynchronous trigger input meets the DAQ clock |
| 09 | [The Vivado / Xilinx flow](modules/09_vivado_xilinx_flow/) | Synthesis, XDC constraints, timing closure, IP, ILA | Putting a design on a real board |
| — | [**Capstone project**](project/) | Integrating all of it | A self-triggering waveform digitizer readout |

Do them in order — each one leans on the previous.

## Quick start

Install the simulator and waveform viewer:

```bash
# Debian / Ubuntu
sudo apt-get install ghdl gtkwave

# macOS
brew install ghdl gtkwave
```

Then prove the toolchain works by running the first testbench:

```bash
cd modules/01_entities_and_signals
ghdl -a --std=08 src/coincidence.vhd tb/tb_coincidence.vhd
ghdl --elab-run --std=08 tb_coincidence --wave=coincidence.ghw
gtkwave coincidence.ghw   # optional: look at the waveforms
```

If the console prints `ALL TESTS PASSED`, you're ready for
[Module 00](modules/00_the_hardware_mindset/).

Vivado (needed only from Module 09 onward, and even then only if you want to
target real hardware) is a free download as **Vivado ML Standard Edition**
from AMD; Module 09 covers installation and project setup.

## Conventions used throughout

These are stated once here and obeyed everywhere, so the code always looks
the same:

* **VHDL-2008** (`ghdl --std=08`). It's what Vivado supports and what you
  should write today.
* `library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;` —
  and *never* the non-standard `std_logic_arith`/`std_logic_unsigned`
  libraries you'll see in old code. Module 06 explains why.
* Lowercase keywords, `snake_case` identifiers.
* One clock per design called `clk` (100 MHz nominal, 10 ns period), rising
  edge only, and an active-high synchronous reset called `rst`. Modules 03
  and 08 explain these choices.
* Testbenches are named `tb_<unit>.vhd`, are self-checking (`assert` on every
  expectation), and print `ALL TESTS PASSED` on success — a simulation you
  have to eyeball is a simulation that will eventually lie to you.

## Who this is for

Written for graduate students, postdocs, and engineers joining an accelerator
or particle-physics group who need to read, modify, and eventually design DAQ
firmware. If your mental model of "the trigger board" is currently a magic
box between the PMTs and the computer, this course is for you.
