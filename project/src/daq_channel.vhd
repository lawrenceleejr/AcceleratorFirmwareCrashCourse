-- daq_channel.vhd
--
-- Top level of the capstone: one complete self-triggering digitizer channel.
--
-- This file contains NO logic of its own -- only instantiation and wiring.
-- That is deliberate, and typical: real DAQ firmware tops are 90% plumbing,
-- and keeping them logic-free makes the block diagram and the code the same
-- document. The structure:
--
--   adc_data ──► pedestal_subtract ──► discriminator ──► trig
--                       │                                  │
--                       └────────► ring_buffer ◄───────────┤
--                                      │                   │
--                                 event_builder ◄──────────┘
--                                      │
--                              m_data/m_valid/m_last  (ready/valid stream)
--
-- One clock (100 MHz), one synchronous reset, single clock domain
-- throughout. Getting this stream across to a different clock (an optical
-- link, a soft CPU) is exactly what the async FIFO of Module 08 is for --
-- see "where this goes next" in the project README.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity daq_channel is
  port (
    clk       : in  std_logic;
    rst       : in  std_logic;                    -- active-high, synchronous
    -- ADC input: one 12-bit sample per clock
    adc_data  : in  unsigned(11 downto 0);
    -- slow-control settings (run-time, no rebuild needed)
    pedestal  : in  unsigned(11 downto 0);
    threshold : in  unsigned(11 downto 0);
    -- event packet output stream (ready/valid == AXI-Stream discipline)
    m_data    : out std_logic_vector(15 downto 0);
    m_valid   : out std_logic;
    m_last    : out std_logic;
    m_ready   : in  std_logic;
    -- status / scalers
    busy      : out std_logic;
    event_count        : out unsigned(15 downto 0);
    lost_trigger_count : out unsigned(15 downto 0)
  );
end entity daq_channel;

architecture rtl of daq_channel is

  -- Internal nets: the "wires on the block diagram". Naming them after
  -- what they carry (not after the blocks) keeps waveforms readable.
  signal ped_sample : unsigned(11 downto 0);   -- pedestal-subtracted sample
  signal trig       : std_logic;               -- one-clock trigger pulse
  signal captured   : std_logic;               -- ring buffer frozen
  signal rd_en      : std_logic;               -- builder -> buffer: next sample
  signal rd_data    : unsigned(11 downto 0);   -- buffer -> builder: the sample
  signal rd_valid   : std_logic;               -- rd_data qualifier
  signal rearm      : std_logic;               -- builder -> buffer: resume

begin

  -- Stage 1: remove the baseline so downstream logic sees pulses on ~zero.
  u_pedestal : entity work.pedestal_subtract
    port map (
      clk        => clk,
      rst        => rst,
      sample_in  => adc_data,
      pedestal   => pedestal,
      sample_out => ped_sample
    );

  -- Stage 2: leading-edge trigger on the cleaned samples.
  u_discriminator : entity work.discriminator
    port map (
      clk       => clk,
      rst       => rst,
      sample_in => ped_sample,
      threshold => threshold,
      trig      => trig
    );

  -- Stage 3: continuous circular capture of the SAME cleaned samples the
  -- discriminator looks at, frozen POST_TRIGGER samples after each trigger.
  -- (The trigger reaches the buffer two clocks after the crossing sample
  -- was written -- the discriminator's pipeline latency -- which just
  -- shifts the capture window by two samples. With 24 samples of
  -- pre-trigger history, nobody notices; see docs/step4_integration.md.)
  u_ring_buffer : entity work.ring_buffer
    generic map (
      ADDR_BITS    => 6,       -- 64-sample window
      POST_TRIGGER => 40       -- => 24 pre-trigger + 40 post-trigger
    )
    port map (
      clk      => clk,
      rst      => rst,
      wr_data  => ped_sample,
      trig     => trig,
      rearm    => rearm,
      captured => captured,
      rd_en    => rd_en,
      rd_data  => rd_data,
      rd_valid => rd_valid
    );

  -- Stage 4: drain the frozen buffer into a framed packet on the stream.
  u_event_builder : entity work.event_builder
    generic map (
      N_SAMPLES => 64          -- = 2**ADDR_BITS of the ring buffer
    )
    port map (
      clk                => clk,
      rst                => rst,
      trig               => trig,
      captured           => captured,
      rd_en              => rd_en,
      rd_data            => rd_data,
      rd_valid           => rd_valid,
      rearm              => rearm,
      m_data             => m_data,
      m_valid            => m_valid,
      m_last             => m_last,
      m_ready            => m_ready,
      busy               => busy,
      event_count        => event_count,
      lost_trigger_count => lost_trigger_count
    );

end architecture rtl;
