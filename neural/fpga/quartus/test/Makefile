# Makefile for DE2 FPGA firmware preparation
# Builds firmware .hex and .mif files for PicoRV32 on Cyclone II

TOOLCHAIN_PREFIX = /opt/riscv32im/bin/riscv32-unknown-elf-
PYTHON = python3

# Memory: 12288 words = 48 KB
MEM_WORDS = 12288

# Directories (relative to neural/fpga/quartus/test/)
ROOT_DIR = ../../../..

# -------------------------------------------------------
# LED test firmware build
# -------------------------------------------------------
# Presets to upload to FPGA
# cd neural/fpga/quartus/test
# make led_test
# cp led_test_firmware.hex firmware.hex

led_test: led_test_firmware.hex led_test_firmware.mif
	@echo "LED test firmware ready: led_test_firmware.hex / .mif"

led_test_firmware.hex: led_test_firmware.bin
	$(PYTHON) $(ROOT_DIR)/firmware/makehex.py $< $(MEM_WORDS) > $@

# Quartus actually auto-converts the $readmemh to its own .mif internally.
# However, by providing an explicit .mif and using the ram_init_file
# attribute, we guarantee correct M4K initialisation on Cyclone II.
led_test_firmware.mif: led_test_firmware.hex
	$(PYTHON) ../hex2mif.py $< $(MEM_WORDS) > $@

# Install firmware files for Quartus compilation
install: led_test_firmware.hex led_test_firmware.mif
	cp led_test_firmware.hex firmware.hex
	cp led_test_firmware.mif firmware.mif
	@echo "firmware.hex + firmware.mif ready for Quartus compilation"

led_test_firmware.bin: led_test_firmware.elf
	$(TOOLCHAIN_PREFIX)objcopy -O binary $< $@

led_test_firmware.elf: start.o led_test.o
	$(TOOLCHAIN_PREFIX)gcc -Os -mabi=ilp32 -march=rv32im -ffreestanding -nostdlib \
		-o $@ $^ -Wl,-Bstatic,-T,sections.lds,--strip-debug -lgcc
	$(TOOLCHAIN_PREFIX)objdump -d $@ > led_test_firmware.lst
	$(TOOLCHAIN_PREFIX)size $@

start.o: start.S
	$(TOOLCHAIN_PREFIX)gcc -c -mabi=ilp32 -march=rv32im -o $@ $<

led_test.o: led_test.c
	$(TOOLCHAIN_PREFIX)gcc -c -mabi=ilp32 -march=rv32im -Os --std=c99 \
		-ffreestanding -nostdlib -o $@ $<

# Simulation variant with short delay loop
led_test_sim.o: led_test.c
	$(TOOLCHAIN_PREFIX)gcc -c -mabi=ilp32 -march=rv32im -Os --std=c99 \
		-ffreestanding -nostdlib -DSIM -o $@ $<

led_test_sim.elf: start.o led_test_sim.o
	$(TOOLCHAIN_PREFIX)gcc -Os -mabi=ilp32 -march=rv32im -ffreestanding -nostdlib \
		-o $@ $^ -Wl,-Bstatic,-T,sections.lds,--strip-debug -lgcc

led_test_sim.bin: led_test_sim.elf
	$(TOOLCHAIN_PREFIX)objcopy -O binary $< $@

led_test_sim.hex: led_test_sim.bin
	$(PYTHON) $(ROOT_DIR)/firmware/makehex.py $< $(MEM_WORDS) > $@

# -------------------------------------------------------
# Simulation (Icarus Verilog - test without hardware)
# -------------------------------------------------------

sim_led: led_test_sim.hex de2_sim.vvp
	cp led_test_sim.hex firmware.hex
	vvp de2_sim.vvp | tee sim_led.log

de2_sim.vvp: de2_top.v de2_top_tb.v $(ROOT_DIR)/picorv32.v
	iverilog -o $@ $^

# -------------------------------------------------------
# Clean
# -------------------------------------------------------

clean:
	rm -f *.o *.elf *.bin *.hex *.vvp *.vcd *.lst *.log *.mif

.PHONY: led_test sim_led clean
