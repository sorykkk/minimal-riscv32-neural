# Makefile for DE2 FPGA inference firmware (MAC4-accelerated)
# Builds firmware .hex and .mif files for PicoRV32 + MAC coprocessor on Cyclone II

TOOLCHAIN_PREFIX = /opt/riscv32im/bin/riscv32-unknown-elf-
PYTHON = python3

# Memory: 12288 words = 48 KB
MEM_WORDS = 12288

# Directories (relative to neural/fpga/quartus/inference/)
ROOT_DIR = ../../../..
NEURAL_DIR = $(ROOT_DIR)/neural

# -------------------------------------------------------
# Inference firmware build (MAC4-accelerated)
# -------------------------------------------------------

inference: inference_firmware.hex inference_firmware.mif
	@echo "Inference firmware ready: inference_firmware.hex / .mif"

inference_firmware.hex: inference_firmware.bin
	$(PYTHON) $(ROOT_DIR)/firmware/makehex.py $< $(MEM_WORDS) > $@

inference_firmware.mif: inference_firmware.hex
	$(PYTHON) ../hex2mif.py $< $(MEM_WORDS) > $@

inference_firmware.bin: inference_firmware.elf
	$(TOOLCHAIN_PREFIX)objcopy -O binary $< $@

inference_firmware.elf: start.o inference_mac4.o
	$(TOOLCHAIN_PREFIX)gcc -Os -mabi=ilp32 -march=rv32im -ffreestanding -nostdlib \
		-o $@ $^ -Wl,-Bstatic,-T,sections.lds,--strip-debug -lgcc
	$(TOOLCHAIN_PREFIX)objdump -d $@ > inference_firmware.lst
	$(TOOLCHAIN_PREFIX)size $@

start.o: start.S
	$(TOOLCHAIN_PREFIX)gcc -c -mabi=ilp32 -march=rv32im -o $@ $<

inference_mac4.o: $(NEURAL_DIR)/tests/inference_mac4.c $(NEURAL_DIR)/data/model_weights.h
	$(TOOLCHAIN_PREFIX)gcc -c -mabi=ilp32 -march=rv32im -Os --std=c99 \
		-ffreestanding -nostdlib -o $@ $<

# Copy firmware.hex for Quartus (it reads firmware.hex via $readmemh)
install: inference_firmware.hex
	cp inference_firmware.hex firmware.hex
	@echo "firmware.hex ready for Quartus compilation"

# -------------------------------------------------------
# Simulation (Icarus Verilog)
# -------------------------------------------------------

sim: inference_firmware.hex de2_sim.vvp
	cp inference_firmware.hex firmware.hex
	vvp de2_sim.vvp | tee sim_inference.log

de2_sim.vvp: de2_top.v de2_top_tb.v $(NEURAL_DIR)/rtl/picorv32_pcpi_mac.v $(ROOT_DIR)/picorv32.v
	iverilog -o $@ $^

# -------------------------------------------------------
# Clean
# -------------------------------------------------------

clean:
	rm -f *.o *.elf *.bin *.hex *.vvp *.vcd *.lst *.log *.mif

.PHONY: inference install sim clean
