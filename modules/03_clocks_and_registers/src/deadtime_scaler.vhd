-- deadtime_scaler.vhd
--
-- Dead-time accounting for a DAQ system: two free-running scalers.
--
-- Physics context: "scaler" is physics jargon for a counter -- the NIM/CAMAC
-- modules that just counted pulses. Every DAQ has dead time: while the
-- readout is busy digitizing and shipping one event, it is blind to the
-- next. If you don't measure that blindness you cannot normalize anything:
--
--     cross section  ~  N_observed / (integrated luminosity x LIVE fraction)
--
--     live fraction  =  1 - busy_count / total_count
--
-- So every experiment runs a pair of scalers exactly like this one: count
-- ALL clock cycles, and count the cycles during which the DAQ was busy.
-- The ratio is the dead-time correction that turns raw event counts into
-- physics. Losing these two numbers ruins a run; the firmware is trivial.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;   -- unsigned and its arithmetic live here

entity deadtime_scaler is
  port (
    clk         : in  std_logic;  -- 100 MHz system clock, rising edge
    rst         : in  std_logic;  -- active-high synchronous reset (run start)
    busy        : in  std_logic;  -- '1' while the DAQ cannot accept triggers
    total_count : out unsigned(31 downto 0);  -- clock cycles since reset
    busy_count  : out unsigned(31 downto 0)   -- of which, cycles spent busy
  );
end entity deadtime_scaler;

architecture rtl of deadtime_scaler is
begin

  -- Same clocked-process template as pulse_stretcher.vhd -- it never changes.
  --
  -- One VHDL-2008 note: we read and increment the OUT ports directly
  -- (total_count <= total_count + 1). Pre-2008 VHDL forbade reading an out
  -- port, so legacy code keeps an internal copy ("signal total_int : ...")
  -- and adds "total_count <= total_int;" at the end. You'll see that
  -- pattern everywhere in older lab codebases; in 2008 it's unnecessary.
  count : process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        -- (others => '0') fills every bit with '0', whatever the width --
        -- the idiomatic "zero" for vectors. Scalers ARE reset at run start:
        -- a counter that wakes up as 'U...U' would poison every sum.
        total_count <= (others => '0');
        busy_count  <= (others => '0');
      else
        -- unsigned + integer is defined by numeric_std; the result wraps
        -- silently at 2**32, like uint32_t in C -- no exception, no flag.
        -- At 100 MHz a 32-bit scaler wraps after ~43 s, so real DAQs
        -- either use 64 bits or have software read and latch fast enough.
        total_count <= total_count + 1;

        -- Two assignments to two DIFFERENT signals in one process are two
        -- independent banks of flip-flops updating on the same edge. Their
        -- textual order is irrelevant -- see the module text on <= inside
        -- clocked processes.
        if busy = '1' then
          busy_count <= busy_count + 1;
        end if;
      end if;
    end if;
  end process count;

end architecture rtl;
