# arty_a7.xdc — timing and pin constraints for top_blinky on the Digilent
# Arty A7-35 (Artix-7 XC7A35TICSG324-1L).
#
# An XDC file is not configuration syntax — it is a sequence of Tcl commands
# that Vivado evaluates IN ORDER during synthesis and implementation. Every
# line below is a real command; each one is explained, because a missing or
# wrong constraint is the classic way a design that simulates perfectly
# fails (or dies) on the bench.
#
# Targeting a different board? Only the PACKAGE_PIN values (and possibly the
# IOSTANDARDs and clock period) change — look them up in your board's
# reference manual or master XDC.

## ---------------------------------------------------------------------------
## Clock: 100 MHz oscillator on pin E3
## ---------------------------------------------------------------------------

# Physically connect the top-level port `clk` to package pin E3, where the
# Arty's 100 MHz oscillator enters the FPGA. Without an explicit pin, Vivado
# picks pins ARBITRARILY — the bitstream would drive whatever pin it chose,
# which on a real board can fight another chip's output and damage hardware.
set_property PACKAGE_PIN E3 [get_ports clk]

# Set the I/O voltage standard for that pin: 3.3 V CMOS, matching the bank
# supply on the Arty. A wrong IOSTANDARD means wrong switching thresholds at
# best and overstressed I/O transistors at worst. Vivado refuses to write a
# bitstream while any used pin lacks one — deliberately.
set_property IOSTANDARD LVCMOS33 [get_ports clk]

# Declare that the signal on `clk` is a clock with a 10.000 ns period
# (100 MHz), named sys_clk in reports. THIS LINE IS THE WHOLE TIMING
# CONTRACT: it is what makes Vivado check every flip-flop-to-flip-flop path
# against 10 ns. An unconstrained clock means NO timing analysis at all —
# the tool optimizes for nothing, reports "timing met" vacuously, and the
# design fails on the board in ways simulation never shows.
create_clock -period 10.000 -name sys_clk [get_ports clk]

## ---------------------------------------------------------------------------
## LEDs LD4..LD7 -> led(0)..led(3)
## ---------------------------------------------------------------------------

# led[0] -> LD4 on pin H5. Note the braces: led[0] is Tcl-special syntax
# (square brackets normally mean "run a command"), so bus bits are always
# written {led[0]}.
set_property PACKAGE_PIN H5 [get_ports {led[0]}]

# led[1] -> LD5 on pin J5.
set_property PACKAGE_PIN J5 [get_ports {led[1]}]

# led[2] -> LD6 on pin T9.
set_property PACKAGE_PIN T9 [get_ports {led[2]}]

# led[3] -> LD7 on pin T10.
set_property PACKAGE_PIN T10 [get_ports {led[3]}]

# All four LED pins sit on 3.3 V banks; one command can set a whole bus.
set_property IOSTANDARD LVCMOS33 [get_ports {led[*]}]

## ---------------------------------------------------------------------------
## Button BTN0 -> btn(0)
## ---------------------------------------------------------------------------

# btn[0] -> BTN0 on pin D9. Active-high (pressing drives '1'). This input is
# asynchronous to sys_clk — which is exactly why top_blinky.vhd runs it
# through a two-flop synchronizer before using it (Module 08).
set_property PACKAGE_PIN D9 [get_ports {btn[0]}]

# BTN0 is also on a 3.3 V bank.
set_property IOSTANDARD LVCMOS33 [get_ports {btn[0]}]

## ---------------------------------------------------------------------------
## Configuration-bank settings (chip-level, not per-pin)
## ---------------------------------------------------------------------------

# Tell the tools the dedicated configuration bank is powered at 3.3 V, so
# the bitstream sets the correct I/O behavior for the config pins.
set_property CONFIG_VOLTAGE 3.3 [current_design]

# CFGBVS = configuration-bank voltage select: on the Arty the CFGBVS pin is
# tied to VCCO (i.e. 3.3 V operation). Without this pair of lines Vivado
# emits a critical warning at bitstream time — heed it; on boards where the
# values are genuinely wrong, configuration simply fails.
set_property CFGBVS VCCO [current_design]
