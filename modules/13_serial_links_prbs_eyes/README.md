# Module 13 — Serial Links, PRBS, and Eye Diagrams

**Time: ~30 minutes** · Prerequisite: [Module 09](../09_vivado_xilinx_flow/) · [Module 12](../12_ila_vio_debugging/) recommended

Everything in this course so far has happened *inside* one FPGA. But your
detector is in a cavern, your event builder is in the counting room, and the
data has to physically travel between them. This is the "how does my data
actually get from the detector to the counting room" module: SFP optics,
gigabit transceivers, PRBS link testing, and eye diagrams. It is mostly
prose, on purpose — this layer is where firmware meets photons — plus one
runnable design: a fabric-side PRBS-7 generator/checker pair, the minimum
viable link tester.

## The problem: gigabytes per second, 100 meters, no PC allowed

A modern detector front end — a few hundred ADC channels sampling at tens of
MHz, or a pixel chip streaming hits at 40 MHz bunch crossings — produces
**gigabytes per second**, in a place where you cannot put a PC: there is
radiation (commodity electronics corrupt and latch up), often a strong
magnetic field (forget spinning disks and most switching supplies), and the
counting room is 50–200 m of cable tray away.

Your software instinct says "wide parallel bus" — that's what memory buses
do. Over distance, parallel copper dies three deaths at once:

* **Skew.** Thirty-two bits leave on thirty-two wires on the same clock
  edge; after 100 m of slightly different trace and cable lengths, they no
  longer arrive on the same edge. The faster the clock, the less skew you
  can tolerate, and it scales *against* you.
* **Attenuation.** Copper loses high frequencies with length; a 100 MHz
  parallel bus over 100 m arrives as mush.
* **Mass.** Thirty-two-pair cable for every front-end board is a plumbing
  nightmare — and inside a detector it's worse than that: cables are
  *material* in the acceptance, scattering the very particles you're trying
  to measure. Cable mass is a physics cost.

The answer used by every modern experiment: **serialize**. Put the data onto
one (or a few) differential pairs running at multiple gigabits per second,
and convert to **optical fiber** for the long haul — glass is nearly
lossless at these distances, immune to EMI and ground loops, and a duplex
fiber weighs grams. Names you will meet at work, so you recognize them:

* **GBT and lpGBT** — CERN's radiation-hard serializer chips, the standard
  on-detector link at LHC experiments (lpGBT: up to 10.24 Gb/s up-link).
  Your on-detector ASIC/FPGA talks to an lpGBT; the fiber goes upstairs.
* **FELIX** — ATLAS's answer to "what receives hundreds of those fibers":
  big FPGA cards in commodity servers that translate detector links to
  networks. Other experiments have equivalents.
* **10G Ethernet, Aurora** — off detector, where there's no radiation, links
  are ordinary: Ethernet into the DAQ network, or **Aurora** (a lightweight
  Xilinx FPGA-to-FPGA protocol) between boards.

> **Software vs. hardware.** Software people trust TCP to hide the physical
> layer: bytes in, bytes out, retransmission somebody else's problem. In DAQ
> **you are the physical layer's babysitter**. There is no retransmit on a
> triggered detector link — a corrupted bit is a corrupted hit, and a link
> that drops for 2 seconds is 2 seconds of dead detector in the run log.
> This module is about how to *prove* the pipe before you trust it.

## The SFP cage: the socket on every DAQ board

Look at any DAQ board and you'll find one or more metal cages on the front
panel: **SFP/SFP+ sockets** (Small Form-factor Pluggable; SFP+ is the
≥10 Gb/s generation). The pluggable module inside converts the FPGA's
electrical serial stream to optical and back — laser driver and transmitter
on one side, photodiode receiver on the other. (Or it's a **DAC** — direct
attach copper — cable with the "module" molded onto each end, fine for a few
meters within a rack.) The cage means the optics are a field-replaceable,
vendor-independent commodity: a dead transmitter is a 30-second swap, not a
board repair.

Two very different kinds of pins come out of that cage. The **high-speed TX
and RX pairs do *not* go to ordinary fabric I/O** — they route to dedicated
transceiver pins (next section), and no VHDL of yours ever touches them
directly. Everything else is slow, ordinary I/O that *your* firmware
handles:

| Signal | Dir (FPGA view) | What it is |
|---|---|---|
| `TX_DISABLE` | out | **Drive LOW to turn the laser ON.** Boards commonly power up with it pulled high (laser off, an eye-safety default) — this is the #1 item on the "why is my link dead" checklist. |
| `MOD_ABS` (`MOD_DEF0`) | in | Module-absent detect: high = empty cage. Poll it before believing any other status. |
| `TX_FAULT` | in | Transmitter hardware fault (e.g. laser failure). Latched; cleared by toggling `TX_DISABLE`. |
| `RX_LOS` | in | Loss of signal: **no light arriving**. Distinguishes "fiber unplugged / far end dark" from "light arrives but bits are garbage" (which needs the PRBS tools below). |
| `RATE_SELECT` (`RS0/RS1`) | out | Receiver/transmitter bandwidth select on multi-rate modules. Often hardwired; check the module datasheet. |
| `MOD_DEF1/MOD_DEF2` | inout | **Two-wire I2C bus** (clock/data) to the module's internal EEPROM — see below. |

That I2C interface deserves its own paragraph, because it's a small
firmware task you may actually be handed. The layout is standardized
(**SFF-8472**), so one I2C master design works for every vendor's module:

* At I2C address **A0h**: identification — vendor, part number, serial
  number, wavelength, supported rates. Read this at startup and *log it*;
  "which transceiver is in slot 3 of the crate" should never be a mystery.
* At address **A2h**: **Digital Diagnostics Monitoring (DDM)** — live,
  calibrated measurements of module temperature, supply voltage, laser bias
  current, transmitted optical power, and **received optical power**.

The physics angle: DDM belongs in your **detector-control-system archive**
alongside the HV and temperatures. A slowly dying laser shows up as a
months-long downward trend in TX power — visible in the archive *weeks*
before the link finally drops during a run. Received power trending down
after a shutdown means someone bent a fiber. Trending sensors that predict
failures are home turf for accelerator people; treat optical power exactly
like a vacuum gauge.

## Gigabit transceivers: the hard SERDES in the silicon corners

How does an FPGA whose fabric struggles past a few hundred MHz drive a
10 Gb/s serial pair? It doesn't — not with fabric. Xilinx parts include
dedicated, hardened **gigabit transceivers**: full-custom serializer/
deserializer (SERDES) blocks placed in the corners and edges of the die,
grouped in **quads** of four channels sharing reference-clock PLLs. By
family you'll hear them called **GTP** (Artix-7, to ~6.6 Gb/s), **GTX**
(Kintex-7, ~12.5), **GTH** and **GTY** (UltraScale/+, ~16 and ~32). They are
silicon you already paid for, sitting dark until configured.

Each transceiver contains, in hardware:

* a **PLL** multiplying a clean reference clock up to the line rate;
* the serializer (parallel words in, bits out) and deserializer;
* **CDR — clock-data recovery** — the conceptual heart: *no clock is sent
  with the data*. The receiver recovers the clock **from the data's own
  transitions**, a PLL continuously servoing its phase onto the edges of
  the incoming bit stream. One pair carries everything;
* analog **equalization** on both ends, pre-distorting and un-distorting
  the signal to fight the channel's frequency-dependent loss.

CDR explains a rule that otherwise looks arbitrary: **you cannot recover a
clock from a signal that never changes**. Send a megabyte of zeros and the
CDR has no edges to lock to; it drifts, then the link is lost. And an
AC-coupled optical receiver also can't pass DC — a long run of ones charges
the coupling capacitor and the decision threshold walks away. Hence **line
codes**: **8b/10b** maps every byte to a 10-bit symbol chosen to guarantee
frequent transitions and equal numbers of ones and zeros (DC balance), at
the cost of 25% overhead — that's why "3.125 Gb/s line rate" carries only
2.5 Gb/s of data. At 10 Gb/s and up, **64b/66b** does the same job with 3%
overhead. When a datasheet says "the link runs 8b/10b encoded", it is
feeding the CDR, not being fancy.

You do not program transceivers in raw VHDL. You configure them through the
**Transceiver Wizard** in Vivado's IP catalog (Module 09), which asks for
line rate, reference clock, and encoding, and generates a wrapper exposing
a parallel data interface at fabric-friendly speed — 10 Gb/s becomes "64
bits at 156.25 MHz", which is just Module 07 FIFOs and Module 05 state
machines again. Easier still: **protocol IP**. For FPGA-to-FPGA links,
**Aurora** is the path of least resistance — it owns the transceiver,
handles encoding and channel bring-up, and hands you an AXI-Stream of
words. Recommended first link.

## PRBS and BER: prove the pipe before the protocol

Here is the discipline this module exists to teach: **before trusting any
protocol over a link, prove the raw physical channel.** If Aurora won't come
up, is it your logic, the transceiver settings, the board layout, a dirty
fiber connector, or a dying SFP? Protocol debugging cannot tell these apart.
Physical-layer testing can.

The tool is a **PRBS — pseudo-random bit sequence** — generated by a linear
feedback shift register (LFSR, a shift register whose input is the XOR of a
couple of its own bits). A PRBS is the best of both worlds:

* **Statistically white**: runs of ones and zeros of every length, flat
  spectrum — it stresses the CDR, the equalizers, and the channel like real
  data, including the worst-case patterns.
* **Deterministic**: the receiver can regenerate the identical sequence
  locally and compare **bit for bit**. Every mismatch is one errored bit.

Two standard flavors: **PRBS-7** (polynomial x⁷+x⁶+1, period 127 bits — the
one we build below, short enough to see whole periods in a waveform) and
**PRBS-31** (x³¹+x²⁸+1, period ~2.1×10⁹ bits — the standard for serious
qualification, because its long runs of identical bits are the hardest
stress). The figure of merit is the **BER, bit error ratio**:

> BER = errored bits / total bits transmitted

A healthy modern link runs at BER < 10⁻¹². Now the statistics — and this
part is *your* home turf. Bit errors arrive (to an excellent approximation)
independently at random: a Poisson process. Run the tester for N bits and
observe **zero** errors; what have you proven? The expected count is
μ = N·BER, and P(0 observed) = e^(−μ). Demanding this be ≤ 5% gives μ ≥ 3,
i.e. the classic rule:

> **Zero errors in N bits ⇒ BER < 3/N at 95% confidence.**

Run the numbers before you believe anyone's link test, including your own:

* To claim **BER < 10⁻¹²** you need N ≥ 3×10¹² bits. At 10 Gb/s that is
  **300 seconds — five minutes minimum**, and an hour is more convincing.
* "We ran it for 10 seconds and it was fine" is 10¹¹ bits: it bounds BER
  below 3×10⁻¹¹ and nothing more. That is not a qualification, it's a
  smoke test.
* At 100 Mb/s over your bench LVDS pair, the same 3×10¹² bits take
  **8.3 hours** — leave it running overnight and read the counter at
  coffee time.

Counting statistics don't care that the counter is made of flip-flops.

## IBERT: the canned link tester

You don't have to build any of this for transceiver links: the PRBS
machinery is *hard-wired into every GT* and Vivado ships a canned core to
drive it. **IBERT** (Integrated Bit Error Ratio Tester) instantiates the
pattern generators/checkers inside the transceivers of your chosen quads,
plus JTAG plumbing to the **Serial I/O Analyzer** GUI in the Hardware
Manager — the same last-resort-on-real-hardware philosophy as the ILA and
VIO of Module 12, but for links.

You need a loopback — the TX must somehow reach an RX. Know the difference:

* **External loopback**: a fiber patch cord from TX to RX (or to the far
  board and back). Tests the *entire* channel: transceiver, board traces,
  connectors, SFP, fiber.
* **Internal loopback**: every GT has built-in near-end and far-end
  loopback modes that short TX to RX *inside the silicon*. Tests the
  transceiver configuration only — nothing off-chip. If internal loopback
  is clean and external is dirty, the problem is on the board, in the SFP,
  or in the fiber, and no firmware change will fix it. That bisection is
  the single most useful trick in link bring-up.

Typical bring-up of a new board or a new fiber plant:

1. Create an IBERT design for the quad(s) under test (an IP-example-design
   flow: pick quads, reference clock, line rate), build, program the FPGA.
2. Start with **internal loopback**, PRBS-7: confirms the transceiver and
   reference clock are alive at all.
3. Move to **external loopback** through the real SFP and fiber. Check the
   slow signals first: module present, `TX_DISABLE` driven low, `RX_LOS`
   clear. (No light = no test.)
4. Select the same PRBS pattern on TX and RX ends, reset the error
   counters, confirm the checker reports **link/lock**.
5. Press **"insert error"** and watch the counter increment — *never trust
   an error counter you haven't seen count*. A miswired setup happily shows
   zero errors forever. (This is Module 04's mutation-testing instinct
   pointed at test equipment.)
6. Switch to **PRBS-31**, reset counters, and run for the N your target
   BER demands (see the arithmetic above). Zero errors ⇒ BER < 3/N.
7. Run an **eye scan** per link (next section) and file it in the
   commissioning records.
8. **Only then** load your real firmware. If the protocol now misbehaves,
   you have proven the physical layer and may suspect your own logic —
   which was always the likelier culprit anyway.

## Eye diagrams: seeing the analog truth

Error counters give you one number. The **eye diagram** shows you *why*.
Take the received analog waveform, chop it into unit intervals (UI — one
bit period), and overlay thousands of them on the same axes. All the
possible trajectories — 0→0, 0→1, 1→0, 1→1 — superimpose, and an
eye-shaped opening appears in the middle:

```
     healthy link: eye wide open       marginal link: eye closing

   ==\        /==========\        /   =~\~\     /~/=~=\~\     /~/=
      \      /            \      /       \~\   /~/     \~\   /~/
       \    /              \    /         \~\ /~/       \~\ /~/
        \  /     sample      \  /            X~X           X~X
         \/       here        \/            /~/ \~\       /~/ \~\
         /\        *          /\           /~/   \~\     /~/   \~\
        /  \                  /  \        /~/     \~\   /~/     \~\
       /    \                /    \      ~/~       ~\~ ~/~       ~\~
   ==/        \==========/        \== ==/=~=~\====~=\=/=~====/~=~\==

   lots of margin around the          traces smeared by jitter (left-
   sampling point in BOTH time        right) and noise/attenuation
   and voltage                        (up-down); the receiver samples
                                      inside a shrinking safe zone
```

The receiver decides each bit by sampling once per UI, in the middle. The
**open area is your margin**: horizontal closure is **jitter** (edges
arriving early/late — bad reference clock, crosstalk) and **ISI**
(inter-symbol interference: the channel smearing one bit into the next),
vertical closure is **attenuation and noise** (long fiber, dirty connector,
weak laser). A link can show zero errors *today* with a nearly-closed eye —
and fail next week when the temperature shifts. The eye is the early
warning the error counter can't give.

The trick that makes this measurable *inside* the FPGA — with no 50 GHz
oscilloscope, on a BGA ball you could never probe: the GT receiver contains
a **second, offset sampler** in addition to the one recovering data. Eye
scan (IBERT's 2D scan) sweeps that extra sampler across time offsets and
voltage thresholds, and at each (t, V) point counts disagreements with the
data sampler — **while live traffic flows, without disturbing it**. The
result is a *statistical* eye: a 2D BER map, drawn by the Serial I/O
Analyzer as an open (typically blue) center surrounded by nested **BER
contours** (the 10⁻⁶ contour, 10⁻⁹, …). Reading one: the bigger the open
area at your target BER, the more margin; many standards define a **mask**
— a keep-out polygon the eye must clear — so "mask test passed" is the
formal version of "eye looks open".

Practical rules for a physics collaboration: an **eye scan per link belongs
in your commissioning records** — it is the baseline that makes "the link
got worse" a measurement instead of a feeling. **Re-scan after every fiber
re-route**, connector cleaning, or SFP swap, and diff against the baseline.
Optics degrade gradually; archived eyes and archived DDM power trends are
how you schedule the fix for a technical stop instead of losing a fill.

## The runnable part: a fabric-side PRBS-7 generator and checker

Transceivers and IBERT need real hardware, but the *ideas* — LFSR pattern,
self-synchronizing checker, error counting — are plain synchronous logic
you can build and simulate today. This module ships the pair you'd use to
qualify a plain LVDS pair between two boards (at fabric speeds, one bit per
clock), which is simultaneously a transparent model of what IBERT
instantiates inside every GT:

* [`src/prbs7_gen.vhd`](src/prbs7_gen.vhd) — a 7-bit LFSR implementing
  x⁷+x⁶+1: shift left each clock, feed back `lfsr(6) xor lfsr(5)`, output
  the outgoing bit. Generic `SEED` (any **nonzero** value — all-zeros is
  the LFSR's dead state, from which it emits zeros forever). An
  `err_inject` input XOR-flips the output for exactly the cycles it is
  held high: our "insert error" button.
* [`src/prbs7_check.vhd`](src/prbs7_check.vhd) — the self-synchronizing
  checker. It shares *nothing* with the generator — no seed, no start
  signal — because the PRBS recurrence `b(t) = b(t−7) xor b(t−6)` means
  the last 7 received bits predict the next one. It shifts 7 received bits
  into a mirror LFSR (seeding **from the stream itself**), asserts
  `locked`, then free-runs the mirror and counts every received bit that
  disagrees with the prediction into a **saturating** 16-bit `err_count`.
* [`tb/tb_prbs7.vhd`](tb/tb_prbs7.vhd) — generator wired straight into
  checker (a perfect, zero-length fiber) and four tests: bounded-time
  lock, 300 clean bits with zero errors, one injected error counted
  **exactly once with lock retained**, then three more for a total of
  exactly 4.

All three files are heavily commented — read them in that order; the
comments carry the second half of this lesson.

## Run it

```bash
cd modules/13_serial_links_prbs_eyes

# Analyze the generator, the checker, and the testbench
ghdl -a --std=08 src/prbs7_gen.vhd src/prbs7_check.vhd tb/tb_prbs7.vhd

# Elaborate and run
ghdl --elab-run --std=08 tb_prbs7 --wave=prbs7.ghw
```

Expected output:

```
tb/tb_prbs7.vhd:157:5:@3345ns:(report note): ALL TESTS PASSED
```

Worth a look in GTKWave (`gtkwave prbs7.ghw`): put `serial_bit`, `locked`,
`err_inject`, and `err_count` in the wave pane. The stream looks like noise
— until you notice it repeating every 127 bits (1270 ns). Watch `locked`
rise 8 cycles after reset, and `err_count` step by one at each `err_inject`
pulse while `locked` never so much as blinks.

## Design-choice notes

* **Why PRBS-7 for teaching (and PRBS-31 for qualification)?** The 127-bit
  period fits several times into one waveform window, so you can *see* the
  structure, and the whole state is 7 flip-flops you can follow by hand.
  The structure is identical for PRBS-31 — change the register width and
  tap positions and you have the qualification-grade pattern; but its
  2×10⁹-bit period and 31-bit runs are stress features for real channels,
  not for learning.
* **Why does the checker tolerate errors without unlocking?** Two reasons,
  one per phase. After lock, the mirror LFSR shifts in its own *predicted*
  bit rather than the received one — otherwise a single flipped bit would
  sit in the register for 7 cycles and be counted ~3 times as it passed
  the taps (error multiplication), ruining the BER arithmetic. And lock is
  deliberately *not* dropped on a mismatch: errors are the measurement,
  not an alarm. A checker that re-seeded on every hit could never measure
  a marginal link — it would spend its life resynchronizing. Loss of lock
  should mean something categorically worse than a bit error; making that
  distinction automatic is the exercise.
* **Why does `err_count` saturate instead of wrapping?** A wrapping 16-bit
  counter on a dead link reads some small arbitrary number — 65539 errors
  displays as 3, and the shift crew logs a healthy link. Pegged at 65535
  it unambiguously reads "off scale, do not trust". Same reason lab
  scalers and ADCs saturate. (The width is a teaching size; IBERT uses
  much wider counters plus a bits-transmitted counter, because BER needs
  the denominator too.)
* **Why is the checker fooled by a stuck-at-zero line?** All-zeros is a
  fixed point of the LFSR: seed the mirror from a dead line and it
  "predicts" the zeros perfectly — locked, zero errors, no data. A real
  checker refuses to lock on an all-zeros/all-ones seed. We left the trap
  in (documented in the source) because meeting it once in a simulator is
  cheaper than meeting it once in a beam run: **"zero errors" only means
  something if you have also seen the checker count.**

## Exercise

1. **Add automatic resync — real checker behavior.** Extend
   `prbs7_check.vhd`: if errors come too fast (say, 16 mismatches within a
   127-bit window — a genuine bad seed or lost sequence, not a marginal
   link), drop `locked`, clear the seed counter, and re-seed from the
   stream. Add a `resync_count` output so the DCS can tell "one glitch"
   from "relocking every millisecond". Test it: in the testbench, pulse
   `rst` on the *generator only* mid-run (give it a separate reset signal)
   so the sequence breaks; assert that the checker drops lock, re-locks
   within a bound, and that `err_count` stops climbing after re-lock. Keep
   the existing four tests passing — single errors must still *not* cause
   a resync.
2. **Thought exercise — read the eye.** During commissioning you eye-scan
   two supposedly identical fibers from the same front-end crate. Link A:
   wide blue opening, the 10⁻⁹ BER contour hugging the edges of the UI.
   Link B: opening squeezed to ~35% of the UI in time (but nearly full
   height in voltage), 10⁻⁹ contour close to the sampling point — yet its
   PRBS counter shows zero errors over a 10-second test. Questions: What
   physical difference do the two scans suggest (vertical vs. horizontal
   closure — which one is B's problem)? Why is B's "zero errors" not
   reassuring (what BER bound do 10 seconds at 10 Gb/s actually give)?
   What would you check and clean first, and what goes in the
   commissioning log before you're allowed to call link B "fixed"?

## Key takeaways

* Detector-to-counting-room data travels on a few **multi-gigabit serial
  pairs**, almost always converted to **optical fiber**: parallel copper
  loses to skew, attenuation, and cable mass (which is also material in
  the physics acceptance). Recognize **GBT/lpGBT** (rad-hard, on-detector),
  **FELIX**, **Aurora**, and 10G Ethernet.
* The **SFP cage** is a replaceable electrical↔optical converter. Its
  slow pins are *your* firmware's job — `TX_DISABLE` low or no laser (the
  #1 dead-link cause), `RX_LOS`, `MOD_ABS` — and its **SFF-8472 I2C
  EEPROM** serves vendor ID (A0h) and live **DDM** optics diagnostics
  (A2h) that belong in the detector-control archive.
* **Gigabit transceivers** (GTP/GTX/GTH/GTY) are hard SERDES blocks, not
  fabric: PLLs, equalization, and **CDR** — the clock is recovered *from
  the data*, which is why **8b/10b / 64b/66b line codes** exist (transition
  density and DC balance).
* **PRBS testing proves the physical link before any protocol.** Zero
  errors in N bits ⇒ **BER < 3/N at 95% CL**: proving 10⁻¹² takes ≥3×10¹²
  bits ≈ 5 minutes at 10 Gb/s. A 10-second test is a smoke test, not a
  measurement.
* **IBERT** is the canned in-transceiver PRBS tester. Internal loopback
  isolates the transceiver; external loopback tests board + SFP + fiber.
  Always press **insert error** — never trust a counter you haven't seen
  count. PRBS clean first, *then* load real firmware.
* **Eye diagrams** show margin, not just errors: horizontal closure =
  jitter/ISI, vertical = attenuation/noise. The GT's offset sampler draws
  a statistical eye on live data. One scan per link in the commissioning
  records; re-scan after every fiber change.
* The shipped **PRBS-7 generator/checker** pair is a minimum viable link
  tester: LFSR pattern, self-synchronizing lock from the received stream,
  saturating error counter — the same anatomy as the hardware inside
  every 25 Gb/s transceiver.

**Next:** [Capstone project](../../project/) — or straight to your
experiment's link firmware.
