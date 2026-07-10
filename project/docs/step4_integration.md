# Step 4 — Integration: The Top Level and the Commissioning Run

**Time: ~30 minutes** · Files: [`src/daq_channel.vhd`](../src/daq_channel.vhd), [`tb/adc_model.vhd`](../tb/adc_model.vhd), [`tb/tb_daq_channel.vhd`](../tb/tb_daq_channel.vhd)

**Goal:** wire the four blocks into the complete channel, then put it
through a full-system, self-checking testbench — a **commissioning run** in
miniature, where the testbench pulses are your test beam — and finally
*look* at your digitizer digitizing, in GTKWave.

## The top level: wiring is the design

Open `src/daq_channel.vhd`. It contains **no logic** — only four
instantiations (`entity work.<name>` style, as in every testbench in the
course) and the internal signals connecting them. That is deliberate and
typical: real DAQ tops are 90% plumbing, and a logic-free top means the
block diagram and the code are the same document. Note the small
disciplines that keep hierarchy readable at 100× this size:

* internal signals named for **what they carry** (`ped_sample`, `trig`,
  `rd_data`), not which block drives them — so the waveform viewer reads
  like the block diagram;
* generics passed explicitly (`ADDR_BITS => 6`, `POST_TRIGGER => 40`,
  `N_SAMPLES => 64`) even where defaults would do — the top level is where
  a reader looks for the numbers;
* one comment where the wiring hides physics: the trigger reaches the ring
  buffer **two cycles after** the crossing sample was written (the
  pedestal and discriminator registers from step 1), shifting the capture
  window by two samples. With 24 samples of pre-trigger depth this is
  merely a footnote — but in a tighter design it is exactly the kind of
  off-by-two that eats an afternoon, so the top level says it out loud.

## The fake beam: `adc_model`

The testbench needs a detector. `tb/adc_model.vhd` plays the PMT + ADC:
baseline ~200 counts, a few counts of uniform noise, and on `fire` a
scintillator-shaped pulse (4-sample rise to a programmable `amplitude`,
exponential tail with a ~10-sample time constant).

Three things to notice, all flagged loudly in the file header:

* **It is not synthesizable, on purpose.** It uses `ieee.math_real` —
  floating point, `exp()`, `uniform()` — which describes no hardware. This
  is the testbench privilege from Module 04: `tb/` may be software; `src/`
  may not. It lives in `tb/` and must never be handed to Vivado.
* **The noise seeds are fixed constants**, so every run sees bit-for-bit
  identical data. Reproducibility matters in verification exactly as in
  analysis: a test that only fails on Tuesdays helps no one.
* **`amplitude` is a port**, so the same "beam" delivers both triggerable
  pulses and below-threshold ones — the testbench needs both.

## The commissioning run: `tb_daq_channel`

Read the test plan at the top of the file; it is a genuine checkout
sequence. With pedestal = 200 (the model's baseline) and threshold = 100:

| Test | Beam | Must observe |
|------|------|--------------|
| (a) | 3 big pulses (800, 1500, 1000 counts), well spaced | exactly 3 packets |
| (b) | — | per packet: marker, event numbers 0/1/2, count = 64, checksum; **first samples ≈ baseline** (the past was captured); **peak ≥ threshold** (the pulse is in the window); timestamps strictly increasing |
| (c) | 1 small pulse (50 counts) | nothing: no busy, no packet, event count unchanged |
| (d) | a pulse *while busy* with another | `lost_trigger_count` = 1, no extra packet |
| (e) | consumer stalls `m_ready` mid-header and twice mid-payload | packet arrives intact; the protocol monitor sees no violation on any edge |

Test (b)'s baseline check is quietly the deepest one in the run: the first
payload samples *predate the trigger*, so only a working pre-trigger
capture can make them baseline. Test (e) plus the always-on **protocol
monitor** (a separate process asserting, every edge, that a stalled word is
never changed or retracted) is what actually certifies the handshake — on
an always-ready bench, rule-2 violations from step 3 are invisible.

Testbench craft worth stealing: one sequential stimulus process with
`procedure`s (`fire_pulse`, `receive_packet`, `check_packet`) for the
repetitive parts; a consumer that keeps `m_ready` **low except while
deliberately receiving**, so no word can sneak by unwatched; a global
watchdog that kills a hung run — handshake bugs *hang*, and a bounded
simulation is a feature; and a clock generator that stops when `stop_sim`
goes true, so the simulator terminates by itself, cleanly, when the last
check passes.

Run it:

```bash
cd project
make test
```

Expected final line: `ALL TESTS PASSED` (at ~36 µs of simulated time).

## Looking at it: waveforms in GTKWave

Numbers passing checks is proof; a waveform is *understanding*. Record and
open one:

```bash
make waves
gtkwave daq.ghw
```

Then build yourself the digitizer's commissioning display:

1. In the tree pane expand `tb_daq_channel` → `dut`.
2. **The analog view** — the star of the show. Insert `adc_data` (from
   `tb_daq_channel`), then right-click it in the signal list → **Data
   Format → Analog → Step**, and again → **Analog Resizing → All Data**.
   The digital bus becomes an oscilloscope trace: flat baseline at ~200,
   then three scintillator pulses. Do the same for `dut.ped_sample` to see
   the baseline sitting at ~0 after subtraction.
3. Under `dut`, add `trig`, `busy`, `m_valid`, `m_ready`, `m_data`, and
   from `dut.u_event_builder` the `state` signal (GTKWave prints the state
   *names* — `s_hdr0`, `s_payload_send`, ... — a running commentary on the
   FSM). From `dut.u_ring_buffer` add its `state` and `captured` too.
4. Zoom to the first pulse (around 4 µs; `m_data` is easiest to read as
   hex via Data Format → Hex). Now read the story left to right: the
   analog pulse rises — `trig` fires one clock pulse on the leading edge —
   the ring buffer's state steps `armed → capturing` for exactly 40 clocks
   `→ frozen` — the builder walks `wait_capture → hdr0 ... → payload_fetch
   ⇄ payload_send` 64 times → `checksum → idle` — `busy` drops, `captured`
   clears on `rearm`, and `0xCAFE` leads the words marching across
   `m_data`.
5. Find the third packet (~12 µs) and look at the gaps where `m_ready`
   drops: `m_valid` stays high, `m_data` holds rock-steady, the FSM state
   freezes mid-name. That picture *is* backpressure discipline.

## Scalers and dead time

At the end of the run the channel reports `event_count = 4` and
`lost_trigger_count = 1` — the pulse fired during test (d) while the
channel was busy. These two counters are the channel's **scalers**, and
their ratio is your measured dead-time correction (step 3). In a real
system they'd be slow-control-readable and the control room would plot
them per spill; here the testbench asserts on them, which is the same act
with less ceremony: *the rate books must balance*.

The dead time itself is visible in the waveform: `busy` is high from
trigger to final handshake, ~2.5 µs per event. Everything in that stretch
is uncounted beam. Want it smaller? Stream the payload at one word per
cycle (prefetch), or double-buffer the ring buffer so capture re-arms
while readout drains — both are real digitizer features, and both are now
within your ability to write.

## You now know enough to read your experiment's firmware

Seriously. Open your experiment's digitizer or trigger firmware repository
and you will find:

* a top level that is wiring, hierarchy, and generics — `daq_channel.vhd`,
  larger;
* per-channel signal conditioning and discriminators with slow-control
  thresholds — step 1, with more taps;
* circular capture buffers in BRAM with pre-trigger depth as a setting —
  step 2, deeper;
* readout FSMs producing framed, checksummed events onto AXI-Stream, into
  arbiters, async FIFOs (Module 08), and link cores (Module 09) — step 3,
  wider;
* scalers for everything, because physicists correct rates for a living.

The names will differ and the widths will be bigger, but you have now
*built* every load-bearing idea in that repository, and — more valuable —
you know **why** each one is there. When something in it puzzles you, it
will puzzle you in a well-posed way: "where's the one-shot?", "who honors
`tready` here?", "what rearms this buffer?" Those are firmware engineer
questions. Welcome to the club — and to the README's
[where this goes next](../README.md#where-this-goes-next) when you're
ready to make this channel sixteen channels wide and put it on a board.
