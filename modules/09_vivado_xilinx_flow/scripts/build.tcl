# build.tcl — minimal non-project-mode Vivado build for top_blinky.
#
# Run from the module directory:
#
#     vivado -mode batch -source scripts/build.tcl
#
# Non-project ("script") mode drives the tools directly, one command per
# flow stage, with no project file and no GUI. The whole build is this text
# file: it lives in git, runs identically on a laptop, a build server, or
# CI, and produces the same bitstream every time. That reproducibility is
# why physics collaborations ship their firmware this way.

# Locate the module directory relative to this script, so the build works
# no matter where vivado was launched from.
set script_dir [file dirname [file normalize [info script]]]
set module_dir [file dirname $script_dir]

# All outputs (netlists, reports, bitstream) go here. Keep it out of git.
set build_dir $module_dir/build
file mkdir $build_dir

# --- Read sources ------------------------------------------------------------
# "read" just registers the files; nothing is compiled yet. -vhdl2008
# matters: without it Vivado parses as VHDL-93 and rejects 2008 constructs.
read_vhdl -vhdl2008 $module_dir/src/top_blinky.vhd

# Constraints are read the same way and applied during synth/implementation.
read_xdc $module_dir/constraints/arty_a7.xdc

# --- Synthesis ---------------------------------------------------------------
# Elaborate + synthesize: VHDL in, technology-mapped netlist of LUTs, flip-
# flops, carry chains, BRAMs and DSPs out. -top names the top entity; -part
# pins the exact device (die, package, speed grade) — a bitstream is only
# valid for the part it was built for.
synth_design -top top_blinky -part xc7a35ticsg324-1L

# --- Implementation ----------------------------------------------------------
# Logic optimization on the post-synthesis netlist (constant propagation,
# unused-logic removal, etc.).
opt_design

# Placement: assign every cell in the netlist to a physical site on the die.
place_design

# Routing: choose the actual metal wires connecting the placed cells. After
# this step every path delay is real, and timing analysis is final.
route_design

# --- Reports -----------------------------------------------------------------
# The two reports you must actually read after every build (see README):
# timing (is WNS >= 0?) and utilization (how full is the chip?).
report_timing_summary -file $build_dir/timing_summary.rpt
report_utilization    -file $build_dir/utilization.rpt

# --- Bitstream ---------------------------------------------------------------
# Emit the configuration file to load onto the board. -force overwrites the
# previous build's output.
write_bitstream -force $build_dir/top_blinky.bit
