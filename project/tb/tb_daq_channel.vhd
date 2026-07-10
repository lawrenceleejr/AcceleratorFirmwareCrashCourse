-- tb_daq_channel.vhd
--
-- Full-system self-checking testbench for the capstone DAQ channel:
-- the "commissioning run". The adc_model is our test beam; this file is
-- the shift crew, checking that every packet coming off the channel is
-- exactly what the data format document promises.
--
-- Test plan:
--   (a) fire 3 above-threshold pulses, generously spaced
--         -> exactly 3 packets arrive
--   (b) for every packet, check: start marker, incrementing event number,
--       sample count = 64, checksum, pre-trigger samples are baseline
--       (proving the ring buffer really captured the PAST), and the peak
--       sample is above threshold (the pulse is inside the window)
--   (c) fire one below-threshold pulse -> no trigger, no packet
--   (d) fire a pulse while the channel is busy -> lost_trigger_count
--       increments, no extra packet (dead-time accounting works)
--   (e) backpressure: the consumer deasserts m_ready mid-payload; the
--       packet must come out intact, and a bus monitor checks the
--       ready/valid rules cycle by cycle (no word ever changed or
--       retracted while stalled)
--   plus: trigger timestamps strictly increase across events.
--
-- On success it prints ALL TESTS PASSED, stops the clock cleanly, and the
-- simulation ends. A watchdog kills the run if it ever hangs.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_daq_channel is
end entity tb_daq_channel;

architecture sim of tb_daq_channel is

  constant clk_period : time := 10 ns;   -- 100 MHz, as everywhere in the course

  -- Slow-control settings for this "run". The pedestal equals the ADC
  -- model's nominal baseline, so subtracted quiet samples sit at ~0..3
  -- counts; the threshold of 100 counts is far above the noise.
  constant pedestal_c  : unsigned(11 downto 0) := to_unsigned(200, 12);
  constant threshold_c : unsigned(11 downto 0) := to_unsigned(100, 12);

  constant n_words : natural := 69;      -- 4 header + 64 samples + checksum

  type packet_t is array (0 to n_words - 1) of std_logic_vector(15 downto 0);

  -- Infrastructure
  signal clk      : std_logic := '0';
  signal rst      : std_logic := '1';
  signal stop_sim : boolean   := false;  -- set true at the end: stops the clock

  -- ADC model control
  signal fire      : std_logic := '0';
  signal amplitude : unsigned(11 downto 0) := (others => '0');
  signal adc_data  : unsigned(11 downto 0);

  -- Slow control (signals so they could be changed mid-run, like real ones)
  signal pedestal  : unsigned(11 downto 0) := pedestal_c;
  signal threshold : unsigned(11 downto 0) := threshold_c;

  -- Output stream + status
  signal m_data  : std_logic_vector(15 downto 0);
  signal m_valid : std_logic;
  signal m_last  : std_logic;
  signal m_ready : std_logic := '0';     -- consumer "not listening" by default
  signal busy    : std_logic;
  signal event_count        : unsigned(15 downto 0);
  signal lost_trigger_count : unsigned(15 downto 0);

begin

  -- Clock generator with a clean stop: when stop_sim goes true the loop
  -- exits, no more edges are produced, and with no events left the
  -- simulator terminates by itself -- no brute-force "run for N ms".
  clk_gen : process
  begin
    while not stop_sim loop
      clk <= '0';
      wait for clk_period / 2;
      clk <= '1';
      wait for clk_period / 2;
    end loop;
    wait;
  end process clk_gen;

  -- Watchdog: if the test logic ever deadlocks (a handshake bug is exactly
  -- the kind of thing that hangs forever), fail loudly instead of silently
  -- burning CPU. Checks once per microsecond, gives up after 500.
  watchdog : process
  begin
    for i in 1 to 500 loop
      exit when stop_sim;
      wait for 1 us;
    end loop;
    assert stop_sim
      report "GLOBAL TIMEOUT: testbench did not finish within 500 us"
      severity failure;
    wait;
  end process watchdog;

  -- The fake detector + digitizer (simulation-only model, see adc_model.vhd).
  u_adc : entity work.adc_model
    generic map (
      BASELINE   => 200,
      NOISE_SPAN => 3
    )
    port map (
      clk       => clk,
      fire      => fire,
      amplitude => amplitude,
      adc_data  => adc_data
    );

  -- The design under test: the entire channel.
  dut : entity work.daq_channel
    port map (
      clk                => clk,
      rst                => rst,
      adc_data           => adc_data,
      pedestal           => pedestal,
      threshold          => threshold,
      m_data             => m_data,
      m_valid            => m_valid,
      m_last             => m_last,
      m_ready            => m_ready,
      busy               => busy,
      event_count        => event_count,
      lost_trigger_count => lost_trigger_count
    );

  -- Ready/valid PROTOCOL MONITOR (test e, the strict half). Runs every
  -- cycle, independent of the packet checks below. The rule: once a word
  -- is offered (m_valid = '1') and not yet accepted (m_ready = '0'), the
  -- master must hold m_valid high and m_data unchanged until the transfer
  -- happens. Retracting or swapping a stalled word is the classic
  -- stream-master bug, and it corrupts data only when the consumer is slow
  -- -- i.e. rarely in the lab, constantly in production.
  protocol_monitor : process (clk)
    variable holding   : boolean := false;
    variable held_data : std_logic_vector(15 downto 0);
    variable held_last : std_logic;
  begin
    if rising_edge(clk) then
      if holding then
        assert m_valid = '1'
          report "PROTOCOL: m_valid dropped while a word was stalled"
          severity failure;
        assert m_data = held_data
          report "PROTOCOL: m_data changed while a word was stalled"
          severity failure;
        assert m_last = held_last
          report "PROTOCOL: m_last changed while a word was stalled"
          severity failure;
      end if;
      if m_valid = '1' and m_ready = '0' then
        holding   := true;             -- word offered, not taken: must hold
        held_data := m_data;
        held_last := m_last;
      else
        holding   := false;            -- transferred (or idle): free to move on
      end if;
    end if;
  end process protocol_monitor;

  -- The commissioning script. ONE sequential process, like the exemplar
  -- testbenches, with helper procedures for the repetitive parts.
  stimulus : process

    -- Wait for n rising clock edges.
    procedure tick(constant n : in natural) is
    begin
      for i in 1 to n loop
        wait until rising_edge(clk);
      end loop;
    end procedure tick;

    -- Ask the ADC model for one pulse of the given amplitude.
    procedure fire_pulse(constant amp : in natural) is
    begin
      wait until rising_edge(clk);
      amplitude <= to_unsigned(amp, 12);
      fire      <= '1';
      wait until rising_edge(clk);
      fire      <= '0';
    end procedure fire_pulse;

    -- Act as the stream consumer: accept exactly one packet (n_words
    -- words) into pkt. If backpressure is requested, stall the stream for
    -- 15 cycles before word 1 (in the header) and words 10 and 40 (both
    -- mid-payload) to prove the builder survives a slow consumer at every
    -- phase of the packet. m_ready is left low afterwards, so nothing can
    -- transfer while the testbench isn't watching.
    procedure receive_packet(variable pkt          : out packet_t;
                             constant backpressure : in  boolean) is
      variable timeout : natural;
    begin
      m_ready <= '1';
      for i in 0 to n_words - 1 loop
        if backpressure and (i = 1 or i = 10 or i = 40) then
          m_ready <= '0';              -- consumer stops taking data...
          tick(15);                    -- ...for a while (word i may be
          m_ready <= '1';              --    stalled on the bus: monitor checks)
        end if;
        timeout := 0;
        word_wait : loop
          wait until rising_edge(clk);
          exit word_wait when m_valid = '1' and m_ready = '1';  -- the handshake
          timeout := timeout + 1;
          assert timeout < 2000
            report "TIMEOUT: no handshake for word " & integer'image(i)
            severity failure;
        end loop word_wait;
        pkt(i) := m_data;
        -- m_last must be set on the final word and only there.
        if i = n_words - 1 then
          assert m_last = '1'
            report "FAIL: m_last not asserted on final word" severity failure;
        else
          assert m_last = '0'
            report "FAIL: m_last asserted early, at word " & integer'image(i)
            severity failure;
        end if;
      end loop;
      m_ready <= '0';
    end procedure receive_packet;

    -- Check one packet against the format contract (test b).
    procedure check_packet(variable pkt           : in packet_t;
                           constant expected_evno : in natural) is
      variable sum  : unsigned(15 downto 0);
      variable v    : natural;
      variable peak : natural;
    begin
      -- Start marker.
      assert pkt(0) = x"CAFE"
        report "FAIL: bad start marker in event " & integer'image(expected_evno)
        severity failure;
      -- Event numbers increment from 0.
      assert to_integer(unsigned(pkt(1))) = expected_evno
        report "FAIL: expected event number " & integer'image(expected_evno)
             & ", got " & integer'image(to_integer(unsigned(pkt(1))))
        severity failure;
      -- Sample count.
      assert to_integer(unsigned(pkt(3))) = 64
        report "FAIL: sample count is not 64" severity failure;
      -- Pre-trigger proof: the FIRST samples of the window predate the
      -- pulse, so they must be quiet baseline (~0..3 counts after pedestal
      -- subtraction; 16 allows lots of margin). If the ring buffer failed
      -- to capture the past, the window would start on the pulse instead.
      for k in 0 to 3 loop
        assert to_integer(unsigned(pkt(4 + k))) <= 16
          report "FAIL: pre-trigger sample " & integer'image(k)
               & " not at baseline (event " & integer'image(expected_evno) & ")"
          severity failure;
      end loop;
      -- The pulse itself must be in the window, above threshold.
      peak := 0;
      for k in 4 to 67 loop
        v := to_integer(unsigned(pkt(k)));
        if v > peak then
          peak := v;
        end if;
      end loop;
      assert peak >= to_integer(threshold_c)
        report "FAIL: no above-threshold sample in event "
             & integer'image(expected_evno)
        severity failure;
      -- Checksum: 16-bit sum of words 0..67 (wraps mod 2**16 by itself,
      -- because that is what 16-bit unsigned addition does).
      sum := (others => '0');
      for k in 0 to 67 loop
        sum := sum + unsigned(pkt(k));
      end loop;
      assert pkt(68) = std_logic_vector(sum)
        report "FAIL: bad checksum in event " & integer'image(expected_evno)
        severity failure;
    end procedure check_packet;

    variable pkt     : packet_t;
    variable prev_ts : unsigned(15 downto 0);
    variable this_ts : unsigned(15 downto 0);
    variable amp     : natural;
    variable timeout : natural;

  begin
    -- Reset, then let the channel warm up: ~200 samples of baseline so the
    -- ring buffer holds real history before the first trigger (its RAM
    -- contents are undefined before 64 writes -- see ring_buffer.vhd).
    rst <= '1';
    tick(5);
    rst <= '0';
    tick(200);

    ----------------------------------------------------------------------
    -- Tests (a), (b), (e): three good pulses -> three checked packets.
    -- The third packet is read with heavy consumer backpressure.
    ----------------------------------------------------------------------
    prev_ts := (others => '0');
    for ev in 0 to 2 loop
      case ev is
        when 0      => amp := 800;
        when 1      => amp := 1500;
        when others => amp := 1000;
      end case;
      fire_pulse(amp);
      receive_packet(pkt, backpressure => (ev = 2));   -- test (e) on event 2
      check_packet(pkt, ev);
      -- Timestamps must strictly increase from event to event.
      this_ts := unsigned(pkt(2));
      if ev > 0 then
        assert this_ts > prev_ts
          report "FAIL: trigger timestamps not monotonic" severity failure;
      end if;
      prev_ts := this_ts;
      -- Generous spacing: let the channel rearm and rebuild its 24 samples
      -- of pre-trigger history before the next pulse.
      tick(300);
    end loop;

    assert to_integer(event_count) = 3
      report "FAIL: expected 3 events after 3 good pulses" severity failure;
    assert to_integer(lost_trigger_count) = 0
      report "FAIL: lost triggers counted during clean running" severity failure;

    ----------------------------------------------------------------------
    -- Test (c): a below-threshold pulse (amplitude 50 < threshold 100).
    -- The discriminator must stay quiet: no busy, no packet, no event.
    ----------------------------------------------------------------------
    fire_pulse(50);
    tick(500);
    assert busy = '0'
      report "FAIL: channel went busy on a below-threshold pulse"
      severity failure;
    assert m_valid = '0'
      report "FAIL: stream data offered after a below-threshold pulse"
      severity failure;
    assert to_integer(event_count) = 3
      report "FAIL: below-threshold pulse produced an event" severity failure;

    ----------------------------------------------------------------------
    -- Test (d): dead time. Fire a good pulse, then a second one while the
    -- channel is still busy with the first. The second must be counted as
    -- lost and must NOT produce a packet.
    ----------------------------------------------------------------------
    fire_pulse(800);
    timeout := 0;
    busy_wait : loop
      wait until rising_edge(clk);
      exit busy_wait when busy = '1';
      timeout := timeout + 1;
      assert timeout < 100
        report "TIMEOUT: channel never went busy after a good pulse"
        severity failure;
    end loop busy_wait;
    -- 60 cycles later the first waveform has decayed below threshold (so
    -- the second pulse produces a real new crossing) but the channel is
    -- mid-packet: a genuine while-busy trigger.
    tick(60);
    fire_pulse(900);
    receive_packet(pkt, backpressure => false);
    check_packet(pkt, 3);
    this_ts := unsigned(pkt(2));
    assert this_ts > prev_ts
      report "FAIL: trigger timestamps not monotonic (event 3)"
      severity failure;

    -- Long quiet period: if the lost trigger wrongly produced a fourth
    -- readout, busy/m_valid/event_count would betray it here.
    tick(1000);
    assert to_integer(event_count) = 4
      report "FAIL: expected exactly 4 events at end of run" severity failure;
    assert to_integer(lost_trigger_count) = 1
      report "FAIL: expected exactly 1 lost trigger, got "
           & integer'image(to_integer(lost_trigger_count))
      severity failure;
    assert busy = '0'
      report "FAIL: channel stuck busy at end of run" severity failure;
    assert m_valid = '0'
      report "FAIL: unexpected stream data at end of run" severity failure;

    report "ALL TESTS PASSED";
    stop_sim <= true;   -- stops the clock generator: simulation ends cleanly
    wait;
  end process stimulus;

end architecture sim;
