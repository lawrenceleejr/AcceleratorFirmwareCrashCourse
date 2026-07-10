# Module 05 — State Machines

**Time: ~30 minutes** · Prerequisite: [Module 04](../04_testbenches/)

Everything you've built so far reacts *instantly*: a coincidence fires the
moment both inputs are high, a scaler counts every edge. But real DAQ
firmware constantly needs to do things **in sequence** — first this, then
that, then the other. In this module you build the canonical example, a
**triggered-readout controller**, and meet the pattern that makes sequence
possible in hardware: the **finite state machine (FSM)**. It is easily the
most important design pattern in this course.

## The physics problem

A waveform digitizer samples a PMT continuously into a ring buffer (you'll
build the buffer itself in Module 07). When the trigger fires, the front end
must:

1. **keep capturing** for a while, so the post-trigger tail of the pulse
   lands in the buffer;
2. **read the event out**, one sample per clock, to whatever comes next
   (an event builder, a FIFO to the host);
3. **do the bookkeeping** — bump the event counter, announce completion;
4. **rearm** and wait for the next trigger.

While all that is happening the front end is *blind*: a second muon during
readout is simply lost. That blindness is exactly the **dead time** of
Module 03 — which is why this controller exports a `busy` output that is,
literally, the signal the Module 03 dead-time scaler integrates. Feed
`busy` into `deadtime_scaler` and you have the live-fraction measurement
that turns raw event counts into cross sections.

## Sequence is free in software — in hardware you build it

Steps 1–4 above are the most natural thing in the world in Python:

```python
def handle_event():
    wait_capture_window()     # step 1
    read_out_samples()        # step 2
    event_count += 1          # step 3
    # step 4: just return; the loop calls us again
```

Sequence is free in software because the CPU has a **program counter** — a
register that remembers which line you're on, advanced automatically. An
FPGA has no program counter. Every circuit you describe runs every cycle,
forever, all at once (Module 01). To get "first this, then that" you must
**build your own program counter**: a register that remembers *which step
am I on*, plus logic that decides the next step. That construction has a
name — a finite state machine — and it is THE answer to the question every
software person asks in week one: *"how do I write a sequential algorithm
in hardware?"*

## Draw the bubbles first

Never start an FSM in the editor. Draw the **state diagram** first: one
bubble per state, one arrow per transition, each arrow labelled with its
condition. Here is ours:

```
           trigger='1'              after CAPTURE_CYCLES cycles
     +------+        +-----------+        +---------+
  -->| IDLE |------->| CAPTURING |------->| READOUT |
     +------+        +-----------+        +---------+
       ^  |                                    |
       |  | trigger='0'                        |  after SAMPLE_COUNT
       |  +--(stay)                            |  rd_en strobes
       |                                       v
       |              +-------+                |
       +--------------| REARM |<---------------+
         always,      +-------+
         1 cycle
```

Then *enumerate every transition in prose* ("from IDLE, on trigger, go to
CAPTURING; otherwise stay") and only then transcribe it into VHDL. The
diagram is not scaffolding to throw away — it **is** the documentation. Six
months from now, nobody (including you) will reverse-engineer the intent
from the code; they'll ask for the bubble diagram. Keep it in the file
header, as `src/readout_fsm.vhd` does.

Note what the diagram already tells you about the physics: only IDLE has a
trigger arrow. A trigger arriving in any other state falls on deaf ears —
dead time, by construction. Real DAQs *count* those lost triggers too;
that's this module's exercise.

## States as an enumerated type

```vhdl
type state_t is (idle, capturing, readout, rearm);
signal state : state_t := idle;
```

This is a strong-typing win that deserves a moment of appreciation:

* **Impossible states are unrepresentable.** `state` can hold these four
  values and nothing else. With the hand-rolled alternative you'll see in
  old code — `signal state : std_logic_vector(1 downto 0)` plus a comment
  block explaining that `"10"` means readout — every undefined bit pattern
  is a lurking bug. Here the *type system* rules them out, like an `enum
  class` in C++ instead of bare `int` constants.
* **Waveforms show state NAMES.** Load the wave file into GTKWave, drag in
  `state`, and the trace reads `idle → capturing → readout → rearm` in
  actual words, not bit patterns you decode by hand. When you're debugging
  a stuck readout at 2 a.m. during a beam test, this is a very big deal.

## The whole machine is one clocked process

The recommended pattern — use it until you have a reason not to — is a
**single clocked process** holding the state register, the counters, and
the outputs. It's the same template as every register in Module 03; the
only new ingredient is a `case` on the state:

```vhdl
fsm : process (clk)
begin
  if rising_edge(clk) then
    -- defaults for the 1-cycle strobes; a state below can override,
    -- because inside a process the LAST assignment wins
    rd_en      <= '0';
    rd_last    <= '0';
    event_done <= '0';

    if rst = '1' then
      state <= idle;
      ...
    else
      case state is
        when idle =>
          if trigger = '1' then          -- the ONLY place trigger is read
            busy     <= '1';
            wait_cnt <= (others => '0');
            state    <= capturing;
          end if;
        when capturing =>
          if wait_cnt = CAPTURE_CYCLES - 1 then ...
        ...
      end case;
    end if;
  end if;
end process fsm;
```

The `case` statement *is* the state-transition table — one branch per
bubble, one `if` per arrow. If the code and the diagram disagree, one of
them is wrong.

Why this style for beginners (and honestly, for most experts):

* **No latch risk.** Everything is inside `rising_edge(clk)`, so everything
  is a flip-flop. There is no way to accidentally describe a latch (the
  classic combinational-process bug you were warned about in Module 02).
* **Outputs are registered** — they come straight out of flip-flops,
  glitch-free, ready to leave the chip or cross the design.
* **One idiom.** It's the Module 03 clocked-process template. Nothing new
  to hold in your head.

### The two-process style you'll meet in old code

Legacy physics codebases are full of the older **two-process** FSM: a tiny
clocked process for the state register, plus a *combinational* process
computing the next state and the outputs:

```vhdl
-- process 1: the state register (sequential)
state_reg : process (clk)
begin
  if rising_edge(clk) then
    if rst = '1' then state <= idle;
    else              state <= state_next;
    end if;
  end if;
end process;

-- process 2: next-state and output logic (combinational!)
next_state : process (all)          -- VHDL-2008 'all': see Module 02
begin
  state_next <= state;              -- MANDATORY default, or you get latches
  case state is
    when idle =>
      if trigger = '1' then state_next <= capturing; end if;
    ...
  end case;
end process;
```

It separates "the flip-flops" from "the logic", which some people find
maps more directly onto the bubble diagram. The costs: outputs computed in
process 2 are **unregistered** (they can glitch), and forgetting a single
default assignment infers a latch. You must be able to *read* this style —
you will meet it — but write the single-process form.

## Moore vs Mealy

Textbook vocabulary you'll hear in design reviews:

* A **Moore** output depends on the *state only*. It changes at most once
  per clock, when the state changes.
* A **Mealy** output depends on *state and current inputs*. It can react a
  cycle earlier, but it can also glitch when the inputs do, and it couples
  your output timing to someone else's signal quality.

`busy` here is a Moore output — it tells you *which state the machine is
in* (`'1'` whenever not IDLE) and nothing about the inputs. Prefer Moore,
and register the outputs, unless you have a measured reason to shave the
one cycle a Mealy output saves.

One consequence of registered outputs, stated once so it never surprises
you: each output appears **one cycle after** the state that computes it —
the first `rd_en` strobe comes `CAPTURE_CYCLES + 1` cycles after the
trigger, not `CAPTURE_CYCLES`. That's an ordinary pipeline delay, and in a
synchronous design nobody downstream cares — everything they do is
registered too. What matters is what the testbench pins down: the *count*
of strobes and their alignment with `rd_last`, `busy`, and `event_done`.

## State encoding (and radiation)

Four states need at least two flip-flops (`00, 01, 10, 11` — **binary**
encoding). But nothing says the encoding must be minimal:

* **One-hot**: one flip-flop per state, exactly one high at a time
  (`0001, 0010, 0100, 1000`). More flip-flops, but "am I in READOUT?"
  becomes reading a single bit instead of decoding a pattern.
* **Gray**: successive states differ in one bit — useful in special
  situations you'll meet in Module 08.

You don't choose — you wrote an abstract enumerated type, and the
synthesizer picks the encoding. In FPGAs, Vivado usually picks **one-hot**,
because flip-flops are abundant (every logic cell has them, most sit
unused) while decode logic costs LUTs and delay — the opposite trade-off
from ASICs. If you ever need to force it, the `fsm_encoding` attribute
exists (`attribute fsm_encoding of state : signal is "one_hot";`), but the
default is right far more often than not.

One paragraph physicists specifically should hear: accelerator tunnels and
detector halls are **radiation environments**, and a single-event upset can
flip a state-register bit, landing a one-hot machine in a state that
doesn't exist (two bits set, or none). By default the synthesizer *removes*
the unreachable-state recovery logic as an optimization — the machine can
lock up until reconfiguration. Vivado's `fsm_safe_state` attribute adds
logic that detects an illegal encoding and forces a safe state instead.
For firmware that lives in a tunnel, ask your radiation-effects people;
"the FSM jammed and we lost the rest of the fill" is a real failure mode
with a one-attribute mitigation.

## Run it

```bash
cd modules/05_state_machines

ghdl -a --std=08 src/readout_fsm.vhd tb/tb_readout_fsm.vhd
ghdl --elab-run --std=08 tb_readout_fsm --wave=readout_fsm.ghw
```

Expected output:

```
tb/tb_readout_fsm.vhd:257:5:@766ns:(report note): ALL TESTS PASSED
```

The testbench (read it — it's the Module 04 discipline applied to an FSM)
runs four complete events and does cycle-exact bookkeeping on each: it
counts the `rd_en` strobes one by one, checks the first strobe lands
exactly where the capture window ends, checks `rd_last` rides on the final
strobe, checks the `busy` envelope, injects **rogue triggers mid-event**
and proves they vanish without a trace, and runs two events back-to-back
with the retrigger arriving on the first event's `event_done` cycle.

Then look at the payoff in the waveforms:

```bash
gtkwave readout_fsm.ghw
```

Drag in `state`, `trigger`, `busy`, `rd_en`, `rd_last`, and `event_done`
from `tb_readout_fsm/dut`. The `state` trace reads
`idle → capturing → readout → rearm` **in words** — find the second event
and watch the rogue trigger pulses bounce off `capturing` and `readout`
without leaving a mark.

## Design-choice notes

* **Why does only IDLE read `trigger`?** So that "busy means blind" is true
  *by construction*, not by convention. The dead time is a property you can
  point to in the code: no other state has a trigger arrow. If you need
  triggers-during-busy to be remembered instead of dropped, that's a
  derandomizer FIFO — Module 07.
* **Why a separate REARM state for one cycle of bookkeeping?** It gives the
  counter increment and the done pulse a single, unambiguous home, and it's
  the natural place to grow cleanup work later — the exercise extends
  exactly this state into a trigger-holdoff window.
* **Why `CAPTURE_CYCLES` and `SAMPLE_COUNT` as generics?** Window lengths
  are physics parameters (pulse width, buffer depth), not logic. The
  testbench maps them smaller (4 and 8) so an event is hand-checkable —
  and that also proves the design honours its generics.
* **Why 16-bit counters for small generics?** Laziness with a comment.
  Right-sizing counters from generics is a Module 06 topic; 16 bits is
  safely wide for anything sensible here.
* **Reading `out` ports** (`event_count <= event_count + 1`) is VHDL-2008,
  exactly as in Module 03's scaler — legacy code keeps a shadow signal.

## Exercise

Real triggers don't politely wait for `event_done`. Two upgrades, in
increasing order of realism:

1. **Trigger holdoff.** Add a generic `HOLDOFF_CYCLES : natural := 4` and a
   fifth state `holdoff` between `rearm` and `idle` that enforces a minimum
   dead time between events (detectors need recovery time; downstream
   links need breathing room). Draw the new bubble diagram *first*, then:
   add the state to `state_t`, reuse `wait_cnt`, and extend the testbench —
   fire a trigger during holdoff and assert it is ignored, then check the
   busy envelope grew by exactly `HOLDOFF_CYCLES`.
2. **Count what you lose.** Add an output
   `lost_triggers : out unsigned(15 downto 0)` that increments whenever
   `trigger = '1'` is sampled in any state other than `idle` — the
   companion number to Module 03's dead-time fraction (careful: which
   states need the extra `if`? The bubble diagram won't show it, because
   it's an *action*, not a transition). Verify: the testbench's two rogue
   triggers should make it read 2.

## Key takeaways

* Hardware has no program counter; an **FSM is the one you build
  yourself** — a state register plus next-step logic. It is the standard
  answer to "how do I do things in sequence?"
* **Draw the state diagram before writing code.** One bubble per state,
  one labelled arrow per transition; the `case` statement is its
  transcription, and the diagram is the lasting documentation.
* Use an **enumerated type** for states: illegal states become
  unrepresentable, and GTKWave shows state *names*.
* Default pattern: **one clocked process**, strobe defaults at the top,
  one `case` branch per state. Read the two-process style in old code;
  don't start new designs with it.
* Prefer **Moore, registered outputs** — glitch-free, at the cost of one
  pipeline cycle that a synchronous design doesn't feel.
* The synthesizer picks the **encoding** (usually one-hot in FPGAs); in
  radiation environments, ask about `fsm_safe_state` recovery.
* An FSM that ignores inputs while busy is *dead time by construction* —
  export `busy` and measure it (Module 03), and count what you drop.

**Next:** [Module 06 — Arithmetic and DSP](../06_arithmetic/), where
pedestal subtraction forces the question every physicist eventually asks
VHDL: "why won't it just let me add two vectors?"
