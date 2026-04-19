# NN Cores for neural networks mini-project
This project has the idea of realizing small RISC V cores to be optimized for NN operations, contributing with increased speed of execution.

---

## Strategy

What is the project plan and the stage it is right now:

### Presets

- [x] Custom small CNN in python for the MNIST dataset, for predicting handwritten numbers, with the following architecture:
  - input image is 1x1x28x28 (NCHW)
  - convolution layer kernel is 1x4x3x3 (NCHW)
  - max pooling 2x2
  - fully connected dense layer (4x13x13)x10
- [x] Quantization of final weights after training
- [x] Generating final C header file that will contain all quantization constants, weights and sample images that the architecture will be tested on

### Simulation validation (before FPGA)

- [x] Simulate baseline inference in Icarus Verilog / Verilator
  - adapted the existing testbench infrastructure (`testbench.v`) with a `NEURAL_SIM` build that compiles and runs `neural/apps/inference_baseline.c` on the PicoRV32 core
  - `make test_neural` builds the firmware (start.S -> inference_test.c -> .elf -> .hex) and runs it in Icarus Verilog simulation
  - `make test_neural_vcd` generates a VCD waveform for GTKWave inspection
  - **result**: 10/10 correct predictions on all sample images, verified in simulation
  - simulation log saved in `neural/apps/simulation_baseline.log`

### Test FPGA environment setup

- [x] Setup Quartus project
  - create project targeting EP2C35F672C6 chip (Cyclone II, DE2 board)
  - import `picorv32.v` from repository
  - **note**: the existing `scripts/quartus/system.v` already contains a PicoRV32 + BRAM wrapper - adapt it instead of writing from scratch. It targets Cyclone IV so the `.qsf` pin assignments and device must be changed to EP2C35F672C6
- [ ] Configure internal memory (M4K BRAM)
  - use MegaWizard Plug-In Manager to generate a single-port RAM block of **at least 32 KB** (48 KB recommended). The Cyclone II has 52.5 KB total M4K BRAM. Memory budget: ~7 KB weights, ~8 KB test images, ~4-8 KB code, ~4 KB stack = ~25-30 KB minimum
  - adapt the memory wrapper from `scripts/quartus/system.v` (it handles `mem_valid`, `mem_addr`, `mem_wdata`, `mem_ready` signals already)
- [ ] Test execution
  - write a tiny C program that toggles a memory-mapped output. Compile using the RISC-V GCC toolchain into a `.mif` (Memory Initialization File)
  - load the `.mif` into the RAM block, compile the project and program the DE2. Map the output to the DE2's green LEDs to verify the CPU is running

### The AI Hardware Coprocessor

- [x] Create `picorv32_pcpi_mac.v`
  - model it after `picorv32_pcpi_mul.v` (defined in `picorv32.v`). It must implement the PCPI protocol: assert `pcpi_wait` to claim the instruction, then `pcpi_ready` + `pcpi_wr` + `pcpi_rd` when the result is ready
  - use **opcode `0x2B`** (custom1) to avoid conflicts with the existing IRQ custom ops on `0x0B` (getq, setq, retirq, etc. in `firmware/custom_ops.S`)
- [x] Implement the 4-way MAC logic
  - take two 32-bit registers, treat each as four packed int8 values
  - compute: `A0*B0 + A1*B1 + A2*B2 + A3*B3` (result is int32)
  - leverage Cyclone II's embedded 18x18 multipliers (35 available) for the four 8-bit multiplies
  - this can complete in 1-2 clock cycles since the multiplies are parallel
- [x] Wire it to core
  - **important**: if using `ENABLE_MUL` or `ENABLE_DIV` (needed for rv32im), set those parameters to use the *internal* multiplier (`ENABLE_MUL=1`, not the PCPI-based `picorv32_pcpi_mul`), so the PCPI bus is free for the MAC coprocessor
  - in the top-level wrapper, instantiate the MAC coprocessor and connect its `pcpi_*` wires to the core's `pcpi_*` ports. Set `ENABLE_PCPI=1`
- [x] Simulate coprocessor
  - test the MAC coprocessor in Icarus Verilog simulation before synthesizing to FPGA. Verify with known input pairs that the packed int8 MAC produces correct results

### Testing the software integration

- [x] Define custom instruction macro
  - use opcode `0x2B` (custom1), with a unique funct3/funct7 combination:
    ```c
    #define MAC4(rd, rs1, rs2) \
        asm volatile (".insn r 0x2B, 0, 0, %0, %1, %2" : "=r"(rd) : "r"(rs1), "r"(rs2))
    ```
- [x] Write accelerated inference code
  - start from the existing baseline in `neural/apps/inference_baseline.c`
  - pack 4 consecutive int8 weights and 4 consecutive int8 activations into 32-bit registers, then use `MAC4` to process them in one instruction
  - **note**: the conv layer kernel is only 3x3 (9 values per filter) - not cleanly divisible by 4. The FC layer (676 inputs per output) benefits much more from MAC4. Focus optimization on the FC layer first
  - measure cycle counts (using PicoRV32's `rdcycle` CSR) for both baseline and MAC4 versions, produce a speedup report

### Verification and demonstration

- [x] Output results on DE2 board
  - map PicoRV32 output register to the DE2's 7-segment displays to show the predicted digit (0-9)
  - use the DE2's **toggle switches (SW[0]-SW[9])** to select which of the 10 pre-loaded test images to classify (highest switch wins via priority logic)
  - **LEDR[9:0]** show confidence as a cumulative bar graph (10% per LED): e.g. 80% confidence lights LEDs 0-7
  - **LEDG[0]** = green LED for working state (CPU running, not trapped)
  - **LEDR[17]** = red LED for reset / error / non-working state
  - firmware: `inference_demo.c` - switch-polling loop that runs MAC4-accelerated inference on demand
  - Verilog: `de2_top.v` updated with `0x3000_000C` LED confidence bar register
  - build: `make demo` builds firmware, `make sim` runs Icarus Verilog simulation


---

## RISC V Architecture

### CPU Core: PicoRV32

| Parameter            | Value     | Description                                      |
|----------------------|-----------|--------------------------------------------------|
| ISA                  | rv32im    | 32-bit base integer + multiply/divide extension  |
| `ENABLE_MUL`         | 1         | Internal multiplier (frees PCPI bus)             |
| `ENABLE_DIV`         | 1         | Internal divider                                 |
| `ENABLE_PCPI`        | 1         | Pico Co-Processor Interface for MAC4             |
| `ENABLE_IRQ`         | 0         | Interrupts disabled (not needed for inference)   |
| `ENABLE_COUNTERS`    | 1         | `rdcycle` CSR available for benchmarking         |
| `ENABLE_REGS_16_31`  | 1         | Full 32-register file                            |
| `BARREL_SHIFTER`     | 1         | Single-cycle shifts                              |
| `STACKADDR`          | 48 KB     | Stack at top of BRAM                             |

### MAC4 Coprocessor (`picorv32_pcpi_mac`)

Custom PCPI accelerator for neural network inference.

| Property          | Value                                                      |
|-------------------|-------------------------------------------------------------|
| Opcode            | `0x2B` (custom1 R-type)                                    |
| Encoding          | `.insn r 0x2B, funct3=0, funct7=0, rd, rs1, rs2`          |
| Inputs            | `rs1` = 4x packed int8 activations, `rs2` = 4x packed int8 weights |
| Output            | `rd` = `a0*b0 + a1*b1 + a2*b2 + a3*b3` (int32)            |
| Latency           | 2 clock cycles (multiply -> accumulate)                     |
| Hardware          | 4 parallel 8x8 signed multipliers (maps to Cyclone II 18x18 DSP blocks) |

### Memory Map

| Address        | R/W | Description                          |
|----------------|-----|--------------------------------------|
| `0x0000_0000`  | R/W | BRAM (48 KB, 12288 x 32-bit words)  |
| `0x1000_0000`  | W   | Console output (simulation only)     |
| `0x2000_0000`  | W   | Test pass/fail signal                |
| `0x3000_0004`  | W   | 7-segment display register           |
| `0x3000_0008`  | R   | Switch/key input (`{SW[17:0], KEY[3:0]}`) |
| `0x3000_000C`  | W   | Confidence LED bar register (`LEDR[9:0]`) |

### FPGA Resource Usage (EP2C35F672C6)

| Resource             | Used   | Available | Utilization |
|----------------------|--------|-----------|-------------|
| Logic elements       | 5,424  | 33,216    | 16%         |
| M4K RAM blocks       | 96     | 105       | 91%         |
| DSP (18x18 multiply) | 4      | 35        | 11%         |
| Clock                | 50 MHz | -         | 6.6 ns setup slack |

### Neural Network Model

| Layer      | Configuration                  | Output Shape   |
|------------|--------------------------------|----------------|
| Input      | 1x28x28 grayscale image        | 1x28x28        |
| Conv2D     | 4 filters, 3x3, stride 1, ReLU | 4x26x26       |
| MaxPool2D  | 2x2, stride 2                  | 4x13x13        |
| FC (Dense) | 676 -> 10                      | 10             |

All weights and activations are **int8 quantized**. Requantization uses multiply-shift: `(val x 169) >> 15`.

---

## Tests and results

### Simulation: Baseline Inference (pure integer C)

Tested on PicoRV32 in Icarus Verilog, no coprocessor.

| Image | Actual | Predicted | Confidence | Cycles    |
|-------|--------|-----------|------------|-----------|
| 0     | 0      | 0         | 96%        | 4,316,215 |
| 1     | 1      | 1         | 100%       | 4,316,146 |
| 2     | 2      | 2         | 91%        | 4,316,207 |
| 3     | 3      | 3         | 49%        | 4,316,218 |
| 4     | 4      | 4         | 81%        | 4,316,197 |
| 5     | 5      | 5         | 61%        | 4,316,196 |
| 6     | 6      | 6         | 84%        | 4,316,218 |
| 7     | 7      | 7         | 74%        | 4,316,166 |
| 8     | 8      | 8         | 88%        | 4,316,176 |
| 9     | 9      | 9         | 82%        | 4,316,172 |

- **Accuracy**: 10/10
- **Average cycles per image**: 4,316,191

### Simulation: MAC4-Accelerated Inference

Same test, with `picorv32_pcpi_mac` coprocessor enabled.

| Image | Actual | Predicted | Confidence | Cycles    |
|-------|--------|-----------|------------|-----------|
| 0     | 0      | 0         | 96%        | 1,543,878 |
| 1     | 1      | 1         | 100%       | 1,543,819 |
| 2     | 2      | 2         | 91%        | 1,543,870 |
| 3     | 3      | 3         | 49%        | 1,543,886 |
| 4     | 4      | 4         | 81%        | 1,543,880 |
| 5     | 5      | 5         | 61%        | 1,543,866 |
| 6     | 6      | 6         | 84%        | 1,543,896 |
| 7     | 7      | 7         | 74%        | 1,543,841 |
| 8     | 8      | 8         | 88%        | 1,543,845 |
| 9     | 9      | 9         | 82%        | 1,543,849 |

- **Accuracy**: 10/10
- **Average cycles per image**: 1,543,863

### Speedup Summary

| Metric                  | Baseline     | MAC4         | Improvement |
|-------------------------|-------------|--------------|-------------|
| Total cycles (10 imgs)  | 43,161,911  | 15,438,630   | −64.2%      |
| Avg cycles / image      | 4,316,191   | 1,543,863    | −64.2%      |
| Accuracy                | 10/10       | 10/10        | identical   |
| **Overall speedup**     | -           | -            | **2.80x**   |

MAC4 instructions per image: 9,802 (replacing 31,096 scalar MACs).

### Quartus Compilation

- **Device**: EP2C35F672C6 (Cyclone II, DE2 board)
- **Fmax**: ~75 MHz (6.6 ns setup slack at 50 MHz)
- **Compilation**: 0 errors, warnings are benign (unused DE2 pins, picorv32 synthesis attributes)