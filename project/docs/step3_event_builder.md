# Step 3 — The Event Builder: Packets, Handshakes, and Dead Time

**Time: ~30 minutes** · File: [`src/event_builder.vhd`](../src/event_builder.vhd)

**Goal:** build the FSM that turns a frozen waveform into a **framed,
checksummed event packet** on a **ready/valid stream** — and absorb the two
pieces of culture this step carries: packet formats as contracts, and the
handshake discipline that makes independently-designed blocks composable.
This is the longest file in the project and the one that most resembles
firmware you'll be handed at work.

## Where the concepts came from

| Concept in this step | Taught in |
|----------------------|-----------|
| FSM structure, one state per phase | [Module 05](../../modules/05_state_machines/) |
| counters, latching a timestamp | [Module 03](../../modules/03_clocks_and_registers/) |
| `unsigned` sums that wrap (the checksum) | [Module 06](../../modules/06_arithmetic/) |
| consuming a registered-read memory | Step 2 / [Module 07](../../modules/07_memories_and_fifos/) |

## Packet formats are contracts

The packet layout (README table: `0xCAFE` marker, event number, timestamp,
sample count, 64 samples, checksum) is not firmware's private business. It
is a **contract between firmware and offline software**, honored by both
sides forever, and every real DAQ has a document specifying exactly this.
Why each ingredient exists:

* **Start marker.** Links lose words. If the consumer ever de-synchronizes
  — a dropped word, a truncated packet after a link reset — a recognizable
  constant lets the decoder *re-find* packet boundaries by scanning for
  `0xCAFE` instead of misparsing samples as headers forever. (A marker can
  also occur in payload by chance — a sample can't reach `0xCAFE` = 51966
  in 12 bits, but the checksum word can — which is why resync uses the
  marker as a *candidate* to be confirmed by the checksum.)
* **Event number and timestamp.** The event number lets offline detect a
  *missing* event (a gap in the sequence); the timestamp lets it correlate
  this channel with others and with the accelerator clock. Ours is the low
  16 bits of a free-running cycle counter — fine for a tutorial, and the
  packet has room to widen it when 655 µs of unambiguous range stops being
  funny.
* **Sample count.** Self-describing length: the decoder needn't hardcode
  64, and multi-window-size systems become possible without a new format.
* **Checksum.** Bit errors on real links are not hypothetical — optical
  links quote bit-error rates because the rate is *not zero*. A 16-bit
  modular sum is the cheapest possible integrity check: one adder in
  firmware. Note there is no "modulo" code anywhere — the checksum
  accumulator is a 16-bit `unsigned`, so it wraps at 2¹⁶ by construction
  (step 2's lesson working for us again). Real systems often use CRCs
  (better error detection, still cheap in hardware); the *role* is
  identical.

Endianness deserves one paragraph of paranoia: the moment these 16-bit
words are serialized onto a byte-oriented link, *somebody* decides whether
`0xCAFE` goes out as `CA FE` or `FE CA` — and the offline decoder must
agree. Firmware-side we deal in whole words and stay out of it, but when
your Python unpacker shows `0xFECA`, you'll know exactly what happened
(and why format documents always specify byte order).

## The ready/valid handshake — this IS AXI-Stream

The packet leaves on `m_data`/`m_valid`/`m_last` with `m_ready` flowing
back. **A word transfers exactly when `m_valid` and `m_ready` are both high
on a rising edge.** As the README says: this is the core of AXI-Stream,
verbatim — master the discipline and every Xilinx IP stream port will feel
familiar.

Why so much ceremony for "send a word"? Because the consumer is *not
always ready* — the merger downstream is servicing another channel, the
output FIFO is nearly full, the link is in flow control. `m_ready` going
low is **backpressure**, and the producer must *stall without losing
data*. The rules, and the classic bugs that violate them:

1. **Never drop `m_valid` mid-word.** Once a word is offered, hold
   `m_valid` high and `m_data` frozen until the cycle `m_ready` accepts
   it. The bug: treating `m_valid` as "I feel like sending" and retracting
   the word when the FSM moves on. (Dropping `m_valid` *between* words is
   fine — this builder does, while fetching the next sample.)
2. **Never advance without `m_ready`.** The bug: incrementing the sample
   index, or changing `m_data`, on a cycle where `m_ready` was low —
   silently skipping or corrupting a word. It works flawlessly on the
   bench where the consumer is always ready, and corrupts data in
   production where it isn't. Step 4's testbench deliberately creates that
   production condition, and its protocol monitor checks these two rules
   on *every clock edge* of the run.
3. **Never wait for `m_ready` before raising `m_valid`.** Deadlock by
   politeness: AXI-Stream permits a slave to wait for `m_valid` before
   raising `m_ready`; if the master also waits, nobody moves, forever.
   Offer first, then wait for acceptance.

In the code the discipline compresses to one shape, used in every sending
state — *the only path that changes the bus is guarded by `m_ready`*:

```vhdl
when s_payload_send =>               -- sample word on the bus
  if m_ready = '1' then
    ...load next word, or move on...
  end if;
  -- If m_ready = '0' we do NOTHING: m_data/m_valid hold, the
  -- FSM stalls. Backpressure handled by simply not moving.
```

Doing nothing is the correct behavior, and hardware is good at it: "stall"
is not an exception path, it is the absence of the enable.

## The FSM

```
 idle ──trig──► wait_capture ──captured──► hdr0 ► hdr1 ► hdr2 ► hdr3
                                                                 │
        ┌── 64 samples ──►  payload_fetch ◄──────────────────────┘
        │                        │ rd_valid
        │                   payload_send ──last sample──► checksum ──► idle
        └────────────────────────┘                          (rearm,
                                                             event_no++)
```

Module 05's pattern, one state per phase, with two workhorse details:

* **`hdrN` means "header word N is on the bus."** Each header state holds
  its word until accepted, then loads the next — the handshake shape above,
  four times.
* **`payload_fetch`/`payload_send`** exists because of step 2's read
  latency: pulse `rd_en`, wait for `rd_valid`, put the sample on the bus
  (`payload_fetch`), then hold it until accepted (`payload_send`), 64
  times. Three cycles per sample when unstalled — a real design might
  prefetch to stream one word per cycle, at the price of the FSM's
  clarity; at 69 words per event, nobody is waiting on us.

The checksum rides along for free: each word is added to the accumulator
*at the moment it is loaded onto the bus*, so when the last sample is
accepted the accumulator already equals the sum of words 0–67 and goes
straight out as word 68 with `m_last = '1'`.

The timestamp is latched in `s_idle` the cycle the trigger arrives —
stamping the *trigger*, not the readout, whose timing varies with
backpressure.

## Busy, lost triggers, and the dead-time books

From trigger acceptance to final-word handshake the builder asserts
`busy` — and a trigger that arrives while busy **cannot** start a readout
(the ring buffer is capturing or frozen). It is not an error; it is **dead
time**, and the one unforgivable sin is failing to *count* it:

```vhdl
if trig = '1' and state /= s_idle then
  lost_count <= lost_count + 1;
end if;
```

`event_count` and `lost_trigger_count` are this channel's **scalers**. Your
measured rate is wrong by exactly the dead-time fraction, and
`lost / (lost + accepted)` is how offline corrects it — every real trigger
system keeps precisely these books. This channel's dead time per event is
~40 cycles of capture plus ~210 of readout: about 2.5 µs, a perfectly
respectable number for a tutorial digitizer.

## Checkpoint (~5 minutes)

```bash
ghdl -a --std=08 src/pedestal_subtract.vhd src/discriminator.vhd \
                 src/ring_buffer.vhd src/event_builder.vhd
```

Silence means success. Then convince yourself of rule 2 the hard way: in
`s_hdr1`, mentally replace `if m_ready = '1' then` with `if true then` and
walk one stalled cycle — which word never reaches the consumer, and which
testbench check in step 4 catches it first? (Answer: the event number is
overwritten by the timestamp while stalled; the protocol monitor's
"`m_data` changed while a word was stalled" fires — during the
*backpressured* packet only. On an always-ready bench the bug is
invisible, which is the whole point of testing with backpressure.)

**Next:** [Step 4 — integration](step4_integration.md): wire the four
blocks, run the commissioning testbench, and look at your digitizer
working in GTKWave.
