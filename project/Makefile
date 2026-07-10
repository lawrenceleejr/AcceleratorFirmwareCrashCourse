# Makefile for the capstone project.
#
#   make test    analyze everything and run the full-system testbench
#   make waves   same, but record every signal to daq.ghw for GTKWave
#   make clean   remove everything the tools generated
#
# Files are analyzed in dependency order: leaf components first, then the
# top level that instantiates them, then the testbench units. (GHDL, like
# all VHDL tools, must see an entity before anything that instantiates it.)

GHDL      ?= ghdl
GHDLFLAGS  = --std=08

SRC = src/pedestal_subtract.vhd \
      src/discriminator.vhd \
      src/ring_buffer.vhd \
      src/event_builder.vhd \
      src/daq_channel.vhd \
      tb/adc_model.vhd \
      tb/tb_daq_channel.vhd

TB = tb_daq_channel

.PHONY: test waves analyze clean

test: analyze
	$(GHDL) --elab-run $(GHDLFLAGS) $(TB)

waves: analyze
	$(GHDL) --elab-run $(GHDLFLAGS) $(TB) --wave=daq.ghw
	@echo "Wrote daq.ghw -- open it with: gtkwave daq.ghw"

analyze:
	$(GHDL) -a $(GHDLFLAGS) $(SRC)

clean:
	rm -f *.cf *.o *.lst $(TB) daq.ghw
