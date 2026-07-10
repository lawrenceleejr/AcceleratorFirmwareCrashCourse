-- ring_buffer.vhd
--
-- Circular waveform-capture buffer with pre-trigger history.
--
-- Physics context: the whole point of a self-triggering digitizer is that
-- you cannot know a pulse is coming until it has already started. By the
-- time the discriminator fires, the leading edge -- and the baseline just
-- before it, which offline analysis needs for pedestal and pile-up checks --
-- is in the past. The trick used by every waveform digitizer ever built:
-- write samples into a circular buffer CONTINUOUSLY, wrapping around
-- forever, and when the trigger arrives, keep writing for POST_TRIGGER more
-- samples and then freeze. The frozen buffer then holds
--
--     (2**ADDR_BITS - POST_TRIGGER) pre-trigger samples   (here 64-40 = 24)
--   +  POST_TRIGGER                post-trigger samples   (here 40)
--
-- i.e. a window around the trigger that extends into the PAST. No software
-- system can do this after the fact; the hardware ring buffer is why.
--
-- Implementation notes:
--   * The storage is described so that synthesis infers BLOCK RAM (Module
--     07): an array signal, written and read inside a clocked process, with
--     a REGISTERED read port. That registered read is why readout has one
--     cycle of latency (rd_en now -> rd_data + rd_valid next cycle).
--   * Wrap-around is free: wr_ptr is a 6-bit unsigned, and 6-bit arithmetic
--     wraps at 64 by construction. No modulo operator, no comparison --
--     the pointer IS the address, and overflow is the feature.
--   * The RAM contents are NOT reset. Block RAM has no reset input for its
--     storage; only the pointers and control state reset. The buffer's
--     contents are garbage until 64 samples have been written -- which is
--     why real systems (and our testbench) allow a warm-up period after
--     arming before accepting the first trigger.
--
-- (Compared with the Module 07 version this one is simplified: one write
-- clock, one read clock, same domain, and no full/empty FIFO semantics --
-- capture, freeze, drain, rearm is all a digitizer channel needs.)
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ring_buffer is
  generic (
    ADDR_BITS    : natural := 6;    -- buffer depth = 2**6 = 64 samples
    POST_TRIGGER : natural := 40    -- samples recorded AFTER the trigger
  );
  port (
    clk      : in  std_logic;
    rst      : in  std_logic;                    -- active-high, synchronous
    -- capture side
    wr_data  : in  unsigned(11 downto 0);        -- one sample every clock
    trig     : in  std_logic;                    -- one-clock trigger pulse
    rearm    : in  std_logic;                    -- return to continuous writing
    captured : out std_logic;                    -- buffer frozen, ready to read
    -- readout side (valid only while captured = '1')
    rd_en    : in  std_logic;                    -- request next sample
    rd_data  : out unsigned(11 downto 0);        -- sample, one cycle after rd_en
    rd_valid : out std_logic                     -- flags the cycle rd_data is good
  );
end entity ring_buffer;

architecture rtl of ring_buffer is

  constant depth : natural := 2**ADDR_BITS;

  -- The sample memory. Written every clock while armed; synthesis maps this
  -- to a block RAM primitive because of the clocked, registered access
  -- pattern below. (Initialised to zero for simulation hygiene; on a real
  -- FPGA the bitstream can preload BRAM contents too.)
  type ram_t is array (0 to depth - 1) of unsigned(11 downto 0);
  signal ram : ram_t := (others => (others => '0'));

  -- Write and read pointers. ADDR_BITS wide on purpose: incrementing past
  -- the last address wraps to zero automatically. That wrap IS the ring.
  signal wr_ptr : unsigned(ADDR_BITS - 1 downto 0) := (others => '0');
  signal rd_ptr : unsigned(ADDR_BITS - 1 downto 0) := (others => '0');

  -- The capture life cycle (a small Moore FSM, Module 05):
  --   armed     : writing every clock, waiting for a trigger
  --   capturing : trigger seen, writing POST_TRIGGER more samples
  --   frozen    : writing stopped, buffer readable, waiting for rearm
  type state_t is (armed, capturing, frozen);
  signal state : state_t := armed;

  -- Countdown of post-trigger samples still to write.
  signal post_count : natural range 0 to POST_TRIGGER := 0;

begin

  captured <= '1' when state = frozen else '0';

  main : process (clk)
  begin
    if rising_edge(clk) then
      -- Default: rd_valid is a single-cycle strobe, low unless set below.
      rd_valid <= '0';

      if rst = '1' then
        state  <= armed;
        wr_ptr <= (others => '0');
        rd_ptr <= (others => '0');
        -- Note: the RAM contents are deliberately NOT reset (see header).
      else
        case state is

          when armed =>
            -- Continuous circular capture: one sample per clock, forever.
            ram(to_integer(wr_ptr)) <= wr_data;
            wr_ptr                  <= wr_ptr + 1;   -- wraps at 64: the "ring"
            if trig = '1' then
              state      <= capturing;
              post_count <= POST_TRIGGER;
            end if;

          when capturing =>
            -- Keep writing so the window extends PAST the trigger.
            ram(to_integer(wr_ptr)) <= wr_data;
            wr_ptr                  <= wr_ptr + 1;
            if post_count = 1 then
              -- That was the last post-trigger sample. Freeze. The OLDEST
              -- sample in the buffer is at the location we would have
              -- written next (wr_ptr + 1, since wr_ptr itself is still
              -- being incremented this cycle) -- start reading there so
              -- readout is oldest-first, i.e. in time order.
              state  <= frozen;
              rd_ptr <= wr_ptr + 1;
            else
              post_count <= post_count - 1;
            end if;
            -- Triggers arriving while already capturing are ignored here;
            -- the event builder counts them as lost (dead time).

          when frozen =>
            -- Registered RAM read: address in this cycle, data on the next.
            -- This one-cycle read latency is intrinsic to block RAM -- the
            -- rd_valid strobe tells the reader when rd_data is real.
            if rd_en = '1' then
              rd_data  <= ram(to_integer(rd_ptr));
              rd_ptr   <= rd_ptr + 1;
              rd_valid <= '1';
            end if;
            if rearm = '1' then
              -- Back to continuous capture. wr_ptr resumes where it froze,
              -- so pre-trigger history rebuilds over the next 64 samples.
              state <= armed;
            end if;

        end case;
      end if;
    end if;
  end process main;

end architecture rtl;
