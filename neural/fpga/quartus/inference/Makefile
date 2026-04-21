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
# Default target: interactive inference demo
# -------------------------------------------------------

demo: demo_firmware.hex demo_firmware.mif
	@echo "Demo firmware ready: demo_firmware.hex / .mif"

demo_firmware.hex: demo_firmware.bin
	$(PYTHON) $(ROOT_DIR)/firmware/makehex.py $< $(MEM_WORDS) > $@

demo_firmware.mif: demo_firmware.hex
	$(PYTHON) ../hex2mif.py $< $(MEM_WORDS) > $@

demo_firmware.bin: demo_firmware.elf
	$(TOOLCHAIN_PREFIX)objcopy -O binary $< $@

demo_firmware.elf: start.o inference_demo.o
	$(TOOLCHAIN_PREFIX)gcc -Os -mabi=ilp32 -march=rv32im -ffreestanding -nostdlib \
		-o $@ $^ -Wl,-Bstatic,-T,sections.lds,--strip-debug -lgcc
	$(TOOLCHAIN_PREFIX)objdump -d $@ > demo_firmware.lst
	$(TOOLCHAIN_PREFIX)size $@

inference_demo.o: inference_demo.c $(NEURAL_DIR)/data/model_weights.h
	$(TOOLCHAIN_PREFIX)gcc -c -mabi=ilp32 -march=rv32im -Os --std=c99 \
		-ffreestanding -nostdlib -o $@ $<

# -------------------------------------------------------
# Batch inference (original: runs all 10 images sequentially)
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

# Copy firmware.hex and firmware.mif for Quartus (it reads firmware.mif via ram_init_file)
install: demo_firmware.hex demo_firmware.mif
	cp demo_firmware.hex firmware.hex
	cp demo_firmware.mif firmware.mif
	@echo "firmware.hex + firmware.mif ready for Quartus compilation"

install_batch: inference_firmware.hex inference_firmware.mif
	cp inference_firmware.hex firmware.hex
	cp inference_firmware.mif firmware.mif
	@echo "firmware.hex + firmware.mif (batch) ready for Quartus compilation"

# -------------------------------------------------------
# Simulation (Icarus Verilog)
# -------------------------------------------------------

sim: demo_firmware.hex de2_sim.vvp
	cp demo_firmware.hex firmware.hex
	cp demo_firmware.mif firmware.mif
	vvp de2_sim.vvp | tee sim_demo.log

sim_batch: inference_firmware.hex de2_sim.vvp
	cp inference_firmware.hex firmware.hex
	cp inference_firmware.mif firmware.mif
	vvp de2_sim.vvp | tee sim_inference.log

de2_sim.vvp: de2_top.v de2_top_tb.v $(NEURAL_DIR)/rtl/picorv32_pcpi_mac.v $(ROOT_DIR)/picorv32.v
	iverilog -o $@ $^

# -------------------------------------------------------
# Clean
# -------------------------------------------------------

clean:
	rm -f *.o *.elf *.bin *.hex *.vvp *.vcd *.lst *.log *.mif

.PHONY: demo inference install install_batch sim sim_batch clean
