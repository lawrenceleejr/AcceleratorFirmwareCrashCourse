-- ring_buffer.vhd
--
-- A circular waveform-capture buffer with pre-trigger memory: the heart of
-- every digitizer and every oscilloscope you have ever used.
--
-- Physics context: an ADC digitizes a detector signal at one sample per
-- clock. You cannot know a pulse happened until AFTER its leading edge has
-- crossed the discriminator threshold -- by which time the baseline before
-- the pulse is already history. The only way to capture it is to have been
-- recording all along: write samples continuously into a ring of memory,
-- overwriting the oldest, and when the trigger finally fires, let a few
-- more POST_TRIGGER samples land and then FREEZE. The frozen ring now holds
-- a window of samples that straddles the trigger -- including samples from
-- BEFORE it. A naive "start recording on trigger" design can never do this.
--
-- Firmware lessons in this file:
--   * inferring block RAM (BRAM) from a plain VHDL array + a coding template
--   * SYNCHRONOUS read: BRAM data appears one clock after the address,
--     and that latency must be tracked (the rd_valid pattern)
--   * pointer arithmetic that wraps for free (power-of-two depth)
--   * a small two-state controller (armed/frozen), as built in Module 05
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ring_buffer is
  generic (
    addr_bits    : natural := 6;    -- ring depth = 2**addr_bits samples (64)
    data_bits    : natural := 12;   -- ADC resolution
    post_trigger : natural := 16    -- samples still written after the trigger
  );
  port (
    clk       : in  std_logic;
    rst       : in  std_logic;                            -- sync, active high
    sample_in : in  unsigned(data_bits - 1 downto 0);     -- one ADC sample per clock
    trigger   : in  std_logic;                            -- discriminator fired
    rd_en     : in  std_logic;                            -- readout: give me the next sample
    rd_data   : out unsigned(data_bits - 1 downto 0);     -- ...arrives ONE CYCLE later
    rd_valid  : out std_logic;                            -- rd_data is a real sample now
    frozen    : out std_logic;                            -- capture done, ready for readout
    rearm     : in  std_logic                             -- back to armed/writing
  );
end entity ring_buffer;

architecture rtl of ring_buffer is

  constant depth : natural := 2 ** addr_bits;

  -- THE BRAM INFERENCE TEMPLATE. You do not instantiate a Xilinx RAMB36
  -- primitive by name; you declare an array type and a signal of it, then
  -- read and write it synchronously inside the clocked process below. The
  -- synthesizer recognizes this shape and maps it onto dedicated block-RAM
  -- silicon. 64 x 12 bits easily fits one BRAM36 (36 kbit).
  type ram_t is array (0 to depth - 1) of unsigned(data_bits - 1 downto 0);
  signal ram : ram_t;
  -- Note: the array has NO reset and no initial value. Fabric reset cannot
  -- clear a block RAM's contents -- only our pointers and flags get reset.

  -- The capture controller: a two-state Moore machine (Module 05).
  type state_t is (st_armed, st_frozen);
  signal state : state_t := st_armed;

  -- Address pointers. Because depth is a power of two, "+ 1" on these
  -- unsigned counters wraps from depth-1 back to 0 automatically -- the
  -- modular arithmetic of Module 06 working FOR us this time.
  signal wr_ptr : unsigned(addr_bits - 1 downto 0) := (others => '0');
  signal rd_ptr : unsigned(addr_bits - 1 downto 0) := (others => '0');

  -- Post-trigger down-counter: after the trigger we keep writing until
  -- exactly post_trigger more samples have landed.
  signal counting   : std_logic := '0';
  signal post_count : natural range 0 to post_trigger := 0;

begin

  -- This design assumes at least one post-trigger sample; post_trigger = 0
  -- would need an extra "freeze on the trigger cycle itself" branch.
  assert post_trigger >= 1
    report "ring_buffer: post_trigger must be >= 1"
    severity failure;

  capture : process (clk)
  begin
    if rising_edge(clk) then

      -- Default: rd_valid pulses high only on the cycle after a read.
      rd_valid <= '0';

      if rst = '1' then
        -- Reset the CONTROL, not the memory. BRAM contents cannot be
        -- reset by logic; they simply hold stale samples until the ring
        -- has been written all the way around once.
        state      <= st_armed;
        wr_ptr     <= (others => '0');
        rd_ptr     <= (others => '0');
        counting   <= '0';
        post_count <= 0;

      else
        case state is

          ------------------------------------------------------------------
          -- ARMED: the ADC is live. Write every cycle, forever, wrapping.
          ------------------------------------------------------------------
          when st_armed =>
            -- SYNCHRONOUS WRITE: one sample lands per rising edge. The
            -- ring is always full of the most recent `depth` samples --
            -- that standing history is the pre-trigger memory.
            ram(to_integer(wr_ptr)) <= sample_in;
            wr_ptr <= wr_ptr + 1;          -- wraps for free at depth-1

            if counting = '1' then
              if post_count = 1 then
                -- This edge wrote the last post-trigger sample: freeze.
                -- wr_ptr is about to advance to the slot holding the
                -- OLDEST sample in the ring, so that is where readout
                -- starts -- samples come out oldest-first (age order).
                state    <= st_frozen;
                counting <= '0';
                rd_ptr   <= wr_ptr + 1;
              else
                post_count <= post_count - 1;
              end if;
            elsif trigger = '1' then
              -- Trigger! The sample written this very cycle is the
              -- "trigger sample"; now count down post_trigger more.
              counting   <= '1';
              post_count <= post_trigger;
            end if;

          ------------------------------------------------------------------
          -- FROZEN: writing has stopped; the event is safe. Hand samples
          -- out one per rd_en, oldest first, until someone re-arms us.
          ------------------------------------------------------------------
          when st_frozen =>
            if rd_en = '1' then
              -- SYNCHRONOUS READ -- the whole point of the BRAM template.
              -- rd_data is a register: the value at address rd_ptr shows
              -- up on rd_data one clock AFTER this edge. An asynchronous
              -- read (outside the clocked process) would force the tools
              -- to build the array from LUTs (distributed RAM) instead.
              rd_data  <= ram(to_integer(rd_ptr));
              rd_ptr   <= rd_ptr + 1;
              rd_valid <= '1';   -- pipelined alongside rd_data: this flag
                                 -- IS the latency bookkeeping.
            end if;

            if rearm = '1' then
              -- Event shipped -- go live again. Writing resumes where it
              -- left off; the old event gets overwritten sample by sample.
              state <= st_armed;
            end if;

        end case;
      end if;
    end if;
  end process capture;

  -- Moore output: purely a function of the state.
  frozen <= '1' when state = st_frozen else '0';

end architecture rtl;
