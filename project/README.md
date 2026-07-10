# Capstone Project — A Self-Triggering Waveform Digitizer Readout

**Time: ~2 hours in four ~30-minute steps** · Prerequisite: Modules 00–09

This is the finale. You will build, from parts you now know how to write, a
complete **single-channel waveform digitizer readout**: the miniature but
honest version of what sits in front of every PMT and SiPM in a modern
experiment. It digitizes continuously, triggers itself when a pulse crosses
threshold, captures a waveform window that extends into the *past*, and ships
each event out as a framed, checksummed packet on an industry-standard
stream interface — while keeping the dead-time books that your offline rate
corrections will depend on.

If you can read this design fluently, you can read your experiment's
digitizer firmware. That is the goal.

## Why this design is *the* canonical DAQ front end

Every self-triggered digitizer — CAEN or SP Devices modules, the boards
inside LZ, IceCube, DUNE, your beamline's BPM electronics — is a variation
on the same four-stage theme:

1. **Condition the samples** (pedestal subtraction) so decisions are simple.
2. **Decide** (discriminator) with a one-shot so one pulse means one trigger.
3. **Capture around the trigger** (ring buffer) including pre-trigger
   history, which only hardware writing continuously into a circular buffer
   can provide.
4. **Format and ship** (event builder) as a self-describing packet with
   markers and a checksum, because links flip bits and offline software
   needs a contract it can verify.

You built each stage's concepts in Modules 01–07. Here they meet.

## Architecture

One clock domain (100 MHz `clk`), 12-bit samples, one sample per clock:

```
tb: adc_model  ──►  pedestal_subtract ──► discriminator ──► trigger
        │                  │                                   │
        └──────────────────┴──► ring_buffer (pre/post trig) ◄──┤
                                     │                         │
                                  event_builder FSM ◄──────────┘
                                     │ (ready/valid stream)
                                  tb: packet checker
```

The fake ADC and the packet checker live in the testbench; everything
between them is synthesizable RTL in `src/`.

All source here is written fresh and self-contained — the components are
**deliberately simplified** relative to their module cousins (the ring
buffer has no FIFO full/empty machinery, the pedestal stage does not
average, and so on). Each file's header says what was trimmed and why a
digitizer channel doesn't need it.

## The event packet format

The event builder emits 69 sixteen-bit words per trigger. This table is the
**contract between firmware and offline software** — step 3 discusses why
every DAQ has a document exactly like it:

| Word(s) | Contents | Notes |
|---------|----------|-------|
| 0 | `0xCAFE` | start-of-event marker |
| 1 | event number | 16-bit counter, starts at 0 |
| 2 | trigger timestamp | low 16 bits of the free-running cycle counter |
| 3 | sample count = 64 | window length |
| 4 … 67 | the 64 samples | oldest first; 12-bit values zero-padded to 16 |
| 68 | checksum | sum of words 0–67, modulo 2¹⁶ · `m_last` = '1' |

The window is **24 pre-trigger + 40 post-trigger samples** (ring buffer
depth 64, `POST_TRIGGER` generic = 40): the baseline before the pulse and
the full pulse tail, both delivered for every event.

## Interface convention: ready/valid **is** AXI-Stream

The packet leaves the channel on a stream with four signals:

| Signal | Direction | Meaning |
|--------|-----------|---------|
| `m_data` | master → slave | the 16-bit word |
| `m_valid` | master → slave | "`m_data` is real" |
| `m_last` | master → slave | "this is the final word of the packet" |
| `m_ready` | slave → master | "I can accept a word this cycle" |

A word transfers on exactly those rising clock edges where **`m_valid` and
`m_ready` are both high**. That handshake, name for name, is the core of
**AXI-Stream** (`tdata`/`tvalid`/`tlast`/`tready`), the lingua franca of the
Xilinx IP ecosystem: FIFOs, DMA engines, Ethernet MACs, Aurora link cores
all speak it. Learn the discipline here (step 3 lists the classic bugs) and
this channel bolts directly onto real IP in Vivado.

## The four build steps

| Step | You build / study | Doc |
|------|-------------------|-----|
| 1 | Signal conditioning + trigger: `pedestal_subtract`, `discriminator` | [docs/step1_signal_chain.md](docs/step1_signal_chain.md) |
| 2 | Pre-trigger capture: `ring_buffer` | [docs/step2_ring_buffer.md](docs/step2_ring_buffer.md) |
| 3 | Packets and handshakes: `event_builder` | [docs/step3_event_builder.md](docs/step3_event_builder.md) |
| 4 | Integration + the commissioning run: `daq_channel`, full-system testbench, waveforms | [docs/step4_integration.md](docs/step4_integration.md) |

Each step is ~30 minutes: read the doc alongside the source file, then run
the checkpoint at the end.

## Quick start

```bash
cd project
make test     # analyze everything, run the full-system testbench
```

Expected final line:

```
tb/tb_daq_channel.vhd:382:5:@36415ns:(report note): ALL TESTS PASSED
```

Other targets:

```bash
make waves    # same run, recording daq.ghw for GTKWave (step 4 has the recipe)
make clean    # remove all generated files
```

## Files

```
project/
├── Makefile
├── README.md                  <- you are here
├── docs/
│   ├── step1_signal_chain.md
│   ├── step2_ring_buffer.md
│   ├── step3_event_builder.md
│   └── step4_integration.md
├── src/                       <- synthesizable RTL
│   ├── pedestal_subtract.vhd
│   ├── discriminator.vhd
│   ├── ring_buffer.vhd
│   ├── event_builder.vhd
│   └── daq_channel.vhd        <- top level (wiring only)
└── tb/                        <- simulation only, never synthesized
    ├── adc_model.vhd          <- fake ADC (uses math_real: NOT synthesizable)
    └── tb_daq_channel.vhd     <- the self-checking "commissioning run"
```

## Where this goes next

This channel is honest but miniature. The road from here to a production
digitizer board is made of steps you have already met:

* **Multi-channel.** Instantiate `daq_channel` once per input — remember
  from Module 01 that instantiation stamps out real silicon, so 16 channels
  are 16 concurrent copies, each with its own `pedestal`/`threshold` wires.
  Their packet streams then meet in an **arbiter / event merger** (an FSM
  that grants one channel's stream at a time — round-robin plus the
  ready/valid handshake you already have) so events from all channels share
  one output link.
* **Off-chip on a different clock.** The output link (optical transceiver,
  Ethernet, PCIe) runs on its own clock. Push the packet stream through the
  **asynchronous FIFO of Module 08** — the ready/valid interface maps
  directly onto FIFO write/full and read/empty — and never let the link
  clock touch the DAQ domain directly.
* **Onto a board.** Run the `src/` files through the **Vivado flow of
  Module 09**: constrain `clk`, synthesize, and note that `ring_buffer`
  becomes a block RAM primitive (check the utilization report). Drop an ILA
  on the trigger and you have a logic analyzer on your own trigger logic.
* **A real ADC.** `adc_model` is a simulation stand-in. Real digitizer
  chips deliver samples over **LVDS DDR** lanes (needing `IDDR` primitives
  and careful constraints) or, at high speed, **JESD204B/C** serial links —
  both firmly IP-core territory (Module 09's message: don't hand-roll what
  AMD ships and supports). The moment those samples land in your clock
  domain as `unsigned(11 downto 0)`, everything in this project applies
  unchanged.

That is, in outline, the block diagram of every digitizer board in your
counting house. Welcome to firmware.
