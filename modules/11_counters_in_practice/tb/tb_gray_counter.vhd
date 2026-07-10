-- tb_gray_counter.vhd
--
-- Self-checking testbench for the gray counter.
--
-- Two properties are checked on EVERY step, in the Module 04 style of a
-- reference model running alongside the DUT:
--
--   (a) VALUE:  gray = bin2gray(model), where the model is a plain
--       binary counter kept in the testbench;
--   (b) SAFETY: consecutive outputs differ in EXACTLY one bit.
--
-- Property (b) is the one that matters -- it is the entire reason gray
-- code exists (Module 08) -- so it is tested directly, with a Hamming-
-- distance function, rather than trusted to follow from (a). The walk
-- runs well past 16 steps so the 15 -> 0 wrap, the step most likely to
-- break the one-bit property, is exercised explicitly.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_gray_counter is
end entity tb_gray_counter;

architecture sim of tb_gray_counter is

  constant WIDTH : natural := 4;

  signal clk  : std_logic := '0';
  signal rst  : std_logic := '1';   -- start in reset
  signal en   : std_logic := '0';
  signal gray : std_logic_vector(WIDTH - 1 downto 0);

  signal finished : boolean := false;

  -- Reference conversion, same formula as the DUT. (Yes, DUT and model
  -- could share a bug in the formula -- which is why property (b) below
  -- checks the physics of the code independently of any formula.)
  function bin2gray (b : unsigned) return std_logic_vector is
  begin
    return std_logic_vector(b xor shift_right(b, 1));
  end function bin2gray;

  -- Number of differing bits between two equal-length vectors.
  function hamming (a, b : std_logic_vector) return natural is
    variable d : natural := 0;
  begin
    for i in a'range loop
      if a(i) /= b(i) then
        d := d + 1;
      end if;
    end loop;
    return d;
  end function hamming;

begin

  dut : entity work.gray_counter
    generic map (
      WIDTH => WIDTH
    )
    port map (
      clk  => clk,
      rst  => rst,
      en   => en,
      gray => gray
    );

  -- 100 MHz clock, stoppable so the simulation terminates (Module 03).
  clock_gen : process
  begin
    while not finished loop
      clk <= '0';
      wait for 5 ns;
      clk <= '1';
      wait for 5 ns;
    end loop;
    wait;
  end process clock_gen;

  stimulus : process
    -- The reference model: a free-running binary counter, wrapping mod
    -- 2**WIDTH exactly like the one inside the DUT.
    variable model     : unsigned(WIDTH - 1 downto 0) := (others => '0');
    variable prev_gray : std_logic_vector(WIDTH - 1 downto 0);
  begin
    ---------------------------------------------------------------------
    -- Reset: hold rst for two edges, then release.
    ---------------------------------------------------------------------
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst <= '0';
    wait for 1 ns;
    assert gray = (gray'range => '0')
      report "FAIL: gray not zero after reset" severity failure;

    ---------------------------------------------------------------------
    -- Test 1: 20 increments -- past the 15 -> 0 wrap at step 16. Both
    -- properties checked on every single step.
    ---------------------------------------------------------------------
    en <= '1';
    for step in 1 to 20 loop
      prev_gray := gray;               -- remember pre-edge output
      wait until rising_edge(clk);     -- DUT advances at this edge
      wait for 1 ns;
      model := model + 1;              -- model advances in lockstep (wraps mod 16)

      assert gray = bin2gray(model)
        report "FAIL: gray value wrong at step " & integer'image(step)
        severity failure;

      assert hamming(gray, prev_gray) = 1
        report "FAIL: " & integer'image(hamming(gray, prev_gray))
               & " bits changed at step " & integer'image(step)
               & " -- gray code must change exactly 1"
        severity failure;
    end loop;

    ---------------------------------------------------------------------
    -- Test 2: en = '0' freezes the output. A count that moves while
    -- nominally disabled would be sampled mid-flight by the other clock
    -- domain at exactly the wrong moment, so holding matters as much as
    -- stepping.
    ---------------------------------------------------------------------
    en <= '0';
    prev_gray := gray;
    for i in 1 to 3 loop
      wait until rising_edge(clk);
      wait for 1 ns;
      assert gray = prev_gray
        report "FAIL: gray moved while en = '0'" severity failure;
    end loop;

    ---------------------------------------------------------------------
    -- Test 3: re-enable -- it must continue from where it stopped, not
    -- from zero, and still one bit at a time. Four more steps for good
    -- measure (24 increments checked in total).
    ---------------------------------------------------------------------
    en <= '1';
    for step in 21 to 24 loop
      prev_gray := gray;
      wait until rising_edge(clk);
      wait for 1 ns;
      model := model + 1;

      assert gray = bin2gray(model)
        report "FAIL: gray value wrong after re-enable, step "
               & integer'image(step)
        severity failure;

      assert hamming(gray, prev_gray) = 1
        report "FAIL: hamming distance /= 1 after re-enable, step "
               & integer'image(step)
        severity failure;
    end loop;
    en <= '0';

    report "ALL TESTS PASSED";
    finished <= true;
    wait;
  end process stimulus;

end architecture sim;
