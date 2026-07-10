-- tb_majority_trigger.vhd
--
-- Self-checking testbench for the majority trigger.
--
-- Four paddles means only 2**4 = 16 possible input patterns, so we do what
-- you should always do when the input space is small: test ALL of them,
-- exhaustively, against an independent software model computed right here
-- in the testbench. If the loop finishes, the truth table is proven - no
-- eyeballing of waveforms required.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- As always, a testbench entity has no ports: it is the whole universe.
entity tb_majority_trigger is
end entity tb_majority_trigger;

architecture sim of tb_majority_trigger is

  -- Local signals to wire up to the DUT's ports.
  signal paddles      : std_logic_vector(3 downto 0) := (others => '0');
  signal trigger      : std_logic;
  signal multiplicity : unsigned(2 downto 0);

  -- The threshold we test with. Held in a constant so the expected-value
  -- model below and the generic map stay in lockstep.
  constant TB_THRESHOLD : natural := 3;

begin

  -- Instantiate the DUT. "generic map" is to generics what "port map" is
  -- to ports: it fixes THRESHOLD for THIS copy of the hardware, at
  -- compile time. A second instance with THRESHOLD => 2 would be a
  -- different circuit.
  dut : entity work.majority_trigger
    generic map (
      THRESHOLD => TB_THRESHOLD
    )
    port map (
      paddles      => paddles,
      trigger      => trigger,
      multiplicity => multiplicity
    );

  -- Walk through all 16 paddle patterns and check both outputs against
  -- the model for each.
  stimulus : process
    variable expected_count : natural;  -- the independent software model
  begin
    for pattern in 0 to 15 loop
      -- Drive the pattern onto the bus. to_unsigned turns the loop
      -- integer into a 4-bit unsigned; the cast to std_logic_vector is
      -- legal because the two types are "closely related" (same wires,
      -- different arithmetic meaning).
      paddles <= std_logic_vector(to_unsigned(pattern, 4));
      wait for 10 ns;   -- let the combinational logic settle

      -- Expected model: count the set bits of the pattern in plain
      -- software. Deliberately the same shape as the DUT loop - but THIS
      -- one runs only in the simulator, one pattern at a time.
      expected_count := 0;
      for i in paddles'range loop
        if paddles(i) = '1' then
          expected_count := expected_count + 1;
        end if;
      end loop;

      -- Check the multiplicity output (the hit count).
      assert to_integer(multiplicity) = expected_count
        report "FAIL: pattern " & integer'image(pattern) &
               ": multiplicity = " & integer'image(to_integer(multiplicity)) &
               ", expected " & integer'image(expected_count)
        severity failure;

      -- Check the trigger decision against the same model.
      if expected_count >= TB_THRESHOLD then
        assert trigger = '1'
          report "FAIL: pattern " & integer'image(pattern) &
                 ": trigger missed a " & integer'image(expected_count) &
                 "-fold majority"
          severity failure;
      else
        assert trigger = '0'
          report "FAIL: pattern " & integer'image(pattern) &
                 ": trigger fired on only " & integer'image(expected_count) &
                 " paddle(s)"
          severity failure;
      end if;
    end loop;

    report "ALL TESTS PASSED";
    wait;  -- halt this process forever = end of test
  end process stimulus;

end architecture sim;
