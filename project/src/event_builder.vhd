-- event_builder.vhd
--
-- Readout FSM: turns a frozen waveform capture into a framed event packet
-- on a ready/valid output stream.
--
-- THE HANDSHAKE IS THE HEADLINE. The output interface here --
--
--     m_data  : data word            (master -> slave)
--     m_valid : "m_data is real"     (master -> slave)
--     m_last  : "final word"         (master -> slave)
--     m_ready : "I can take it"      (slave  -> master)
--
--     a word transfers on exactly those rising edges where
--     m_valid = '1' AND m_ready = '1'
--
-- -- is, name for name, the core of AXI-Stream, the lingua franca of the
-- Xilinx IP ecosystem (Module 09). Every FIFO, DMA engine, Ethernet MAC and
-- Aurora link core you will ever wire up speaks exactly this protocol
-- (there the signals are called tdata/tvalid/tlast/tready). Master the
-- discipline here and you can bolt this channel straight onto real IP.
--
-- The discipline, concretely:
--   * Once m_valid is raised, HOLD m_valid and m_data steady until the
--     cycle where m_ready is also high. Never retract or change an offered
--     word ("no takebacks").
--   * Never advance to the next word without seeing m_ready. A slow
--     consumer (backpressure) must stall this FSM, not lose data.
--   * m_valid MAY go low between words (it does here, while fetching the
--     next sample from the ring buffer) -- just never during a stalled word.
--
-- PACKET FORMAT (16-bit words) -- the contract with offline software:
--
--   word 0        x"CAFE"  start-of-event marker
--   word 1        event number (16-bit counter)
--   word 2        trigger timestamp (low 16 bits of the cycle counter)
--   word 3        sample count = 64
--   words 4..67   the 64 samples, oldest first (12-bit, zero-padded to 16)
--   word 68       checksum = sum of words 0..67, modulo 2**16   (m_last = '1')
--
-- FSM: idle -> wait_capture -> hdr0..hdr3 -> payload (fetch/send x64)
--      -> checksum -> idle. Busy is asserted from trigger until the last
-- word is accepted; triggers arriving while busy are counted in
-- lost_trigger_count (your dead-time scaler) and otherwise dropped.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity event_builder is
  generic (
    N_SAMPLES : natural := 64                     -- must match ring buffer depth
  );
  port (
    clk       : in  std_logic;
    rst       : in  std_logic;                    -- active-high, synchronous
    -- trigger input (one-clock pulse from the discriminator)
    trig      : in  std_logic;
    -- ring-buffer interface
    captured  : in  std_logic;                    -- buffer frozen and readable
    rd_en     : out std_logic;                    -- request next sample
    rd_data   : in  unsigned(11 downto 0);        -- sample, one cycle later
    rd_valid  : in  std_logic;                    -- rd_data is good this cycle
    rearm     : out std_logic;                    -- one-clock pulse: resume capture
    -- event packet output stream (ready/valid, see header)
    m_data    : out std_logic_vector(15 downto 0);
    m_valid   : out std_logic;
    m_last    : out std_logic;
    m_ready   : in  std_logic;
    -- status / scalers
    busy      : out std_logic;                    -- trigger accepted, packet in flight
    event_count        : out unsigned(15 downto 0);  -- packets completed
    lost_trigger_count : out unsigned(15 downto 0)   -- triggers arriving while busy
  );
end entity event_builder;

architecture rtl of event_builder is

  constant start_marker : std_logic_vector(15 downto 0) := x"CAFE";

  -- One state per phase of the packet. hdrN means "header word N is on the
  -- bus"; payload_fetch/payload_send handle the ring buffer's one-cycle
  -- read latency for each of the 64 samples.
  type state_t is (s_idle, s_wait_capture,
                   s_hdr0, s_hdr1, s_hdr2, s_hdr3,
                   s_payload_fetch, s_payload_send,
                   s_checksum);
  signal state : state_t := s_idle;

  -- Free-running cycle counter: the channel's clock. 32 bits so it wraps
  -- every ~43 s at 100 MHz; the packet carries the low 16 bits.
  signal cycle_count : unsigned(31 downto 0) := (others => '0');
  signal trig_ts     : unsigned(15 downto 0) := (others => '0');  -- latched at trigger

  signal event_no    : unsigned(15 downto 0) := (others => '0');
  signal lost_count  : unsigned(15 downto 0) := (others => '0');
  signal checksum    : unsigned(15 downto 0) := (others => '0');
  signal sample_idx  : natural range 0 to N_SAMPLES - 1 := 0;

begin

  event_count        <= event_no;
  lost_trigger_count <= lost_count;

  builder : process (clk)
    -- A process VARIABLE (not a signal): updated immediately, used within
    -- this cycle only. Handy for "compute then use" inside one clock edge
    -- (Module 03 discusses signal vs variable semantics).
    variable word_v : std_logic_vector(15 downto 0);
  begin
    if rising_edge(clk) then
      -- Single-cycle strobes default low each clock; states pulse them high.
      rd_en <= '0';
      rearm <= '0';

      if rst = '1' then
        state       <= s_idle;
        cycle_count <= (others => '0');
        event_no    <= (others => '0');
        lost_count  <= (others => '0');
        m_valid     <= '0';
        m_last      <= '0';
        busy        <= '0';
      else
        -- The timestamp source never stops: a free-running counter.
        cycle_count <= cycle_count + 1;

        -- Dead-time accounting: any trigger that arrives while we are NOT
        -- idle cannot start a readout -- the ring buffer is capturing or
        -- frozen. Count it. This scaler is how you measure dead time, and
        -- dead time is how you correct your rates offline.
        if trig = '1' and state /= s_idle then
          lost_count <= lost_count + 1;
        end if;

        case state is

          when s_idle =>
            if trig = '1' then
              trig_ts <= cycle_count(15 downto 0);  -- stamp the trigger NOW
              busy    <= '1';
              state   <= s_wait_capture;
            end if;

          when s_wait_capture =>
            -- The ring buffer is still writing its 40 post-trigger samples.
            -- When it freezes, put the start marker on the bus and begin
            -- accumulating the checksum.
            if captured = '1' then
              m_data   <= start_marker;
              m_valid  <= '1';
              checksum <= unsigned(start_marker);
              state    <= s_hdr0;
            end if;

          -- In each header state the current word sits on the bus, held
          -- steady, until the consumer takes it (m_ready = '1'). Only THEN
          -- do we load the next word. Note that nothing here ever changes
          -- m_data while m_ready is low: that is the handshake discipline.

          when s_hdr0 =>                       -- word 0 (marker) on the bus
            if m_ready = '1' then
              m_data   <= std_logic_vector(event_no);
              checksum <= checksum + event_no;
              state    <= s_hdr1;
            end if;

          when s_hdr1 =>                       -- word 1 (event number) on the bus
            if m_ready = '1' then
              m_data   <= std_logic_vector(trig_ts);
              checksum <= checksum + trig_ts;
              state    <= s_hdr2;
            end if;

          when s_hdr2 =>                       -- word 2 (timestamp) on the bus
            if m_ready = '1' then
              m_data   <= std_logic_vector(to_unsigned(N_SAMPLES, 16));
              checksum <= checksum + to_unsigned(N_SAMPLES, 16);
              state    <= s_hdr3;
            end if;

          when s_hdr3 =>                       -- word 3 (sample count) on the bus
            if m_ready = '1' then
              -- Header done. Drop m_valid (legal BETWEEN words) and go
              -- fetch the first sample from the ring buffer.
              m_valid    <= '0';
              rd_en      <= '1';
              sample_idx <= 0;
              state      <= s_payload_fetch;
            end if;

          when s_payload_fetch =>
            -- rd_en was pulsed on the way in; the BRAM answers one cycle
            -- later with rd_valid. Zero-pad the 12-bit sample to a 16-bit
            -- word and offer it on the stream.
            if rd_valid = '1' then
              word_v   := std_logic_vector(resize(rd_data, 16));
              m_data   <= word_v;
              m_valid  <= '1';
              checksum <= checksum + unsigned(word_v);
              state    <= s_payload_send;
            end if;

          when s_payload_send =>               -- sample word on the bus
            if m_ready = '1' then
              if sample_idx = N_SAMPLES - 1 then
                -- Last sample accepted. The checksum register already
                -- includes every word 0..67 (each was added when loaded),
                -- so it goes straight onto the bus, flagged as the final
                -- word of the packet.
                m_data <= std_logic_vector(checksum);
                m_last <= '1';
                state  <= s_checksum;
              else
                sample_idx <= sample_idx + 1;
                m_valid    <= '0';             -- gap between words: allowed
                rd_en      <= '1';             -- fetch the next sample
                state      <= s_payload_fetch;
              end if;
            end if;
            -- If m_ready = '0' we do NOTHING: m_data/m_valid hold, the
            -- FSM stalls. Backpressure handled by simply not moving.

          when s_checksum =>                   -- word 68 (checksum) on the bus
            if m_ready = '1' then
              m_valid  <= '0';
              m_last   <= '0';
              rearm    <= '1';                 -- ring buffer: resume capture
              event_no <= event_no + 1;
              busy     <= '0';
              state    <= s_idle;
            end if;

        end case;
      end if;
    end if;
  end process builder;

end architecture rtl;
