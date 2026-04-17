# NN Cores for neural networks mini-project
This project has the idea of realizing small RISC V cores to be optimized for NN operations, contributing with increased speed of execution.

---

## Strategy

What is the project plan and the stage it is right now:

### [X] Presets
[X] Custom small CNN in python for the MNIST dataset, for predicting handwritten numbers, with the following architecture:
    - input image is 1x1x28x28 (NCHW)
    - convolution layer kernel is 1x4x3x3 (NCHW)
    - max pooling 2x2
    - fully connected dense layer (4x13x13)x10
[X] Quantization of final weights after training
[X] Generating final C header file that will contain all quantization constants, weights and sample images that the architecture will be tested on

### [X] Simulation validation (before FPGA)
[X] Simulate baseline inference in Icarus Verilog / Verilator
    - adapted the existing testbench infrastructure (`testbench.v`) with a `NEURAL_SIM` build that compiles and runs `neural/tests/inference_test.c` on the PicoRV32 core
    - `make test_neural` builds the firmware (start.S -> inference_test.c -> .elf -> .hex) and runs it in Icarus Verilog simulation
    - `make test_neural_vcd` generates a VCD waveform for GTKWave inspection
    - **result**: 10/10 correct predictions on all sample images, verified in simulation
    - simulation log saved in `neural/tests/simulation_baseline.log`

### [ ] Test FPGA environment setup
[ ] Setup Quartus project
    - create project targeting EP2C35F672C6 chip (Cyclone II, DE2 board)
    - import `picorv32.v` from repository
    - **note**: the existing `scripts/quartus/system.v` already contains a PicoRV32 + BRAM wrapper - adapt it instead of writing from scratch. It targets Cyclone IV so the `.qsf` pin assignments and device must be changed to EP2C35F672C6
[ ] Configure internal memory (M4K BRAM)
    - use MegaWizard Plug-In Manager to generate a single-port RAM block of **at least 32 KB** (48 KB recommended). The Cyclone II has 52.5 KB total M4K BRAM. Memory budget: ~7 KB weights, ~8 KB test images, ~4-8 KB code, ~4 KB stack = ~25-30 KB minimum
    - adapt the memory wrapper from `scripts/quartus/system.v` (it handles `mem_valid`, `mem_addr`, `mem_wdata`, `mem_ready` signals already)
[ ] Test execution 
    - write a tiny C program that toggles a memory-mapped output. Compile using the RISC-V GCC toolchain into a `.mif` (Memory Initialization File)
    - load the `.mif` into the RAM block, compile the project and program the DE2. Map the output to the DE2's green LEDs to verify the CPU is running

### [ ] The AI Hardware Coprocessor
[ ] Create `picorv32_pcpi_mac.v`
    - model it after `picorv32_pcpi_mul.v` (defined in `picorv32.v`). It must implement the PCPI protocol: assert `pcpi_wait` to claim the instruction, then `pcpi_ready` + `pcpi_wr` + `pcpi_rd` when the result is ready
    - use **opcode `0x2B`** (custom1) to avoid conflicts with the existing IRQ custom ops on `0x0B` (getq, setq, retirq, etc. in `firmware/custom_ops.S`)
[ ] Implement the 4-way MAC logic
    - take two 32-bit registers, treat each as four packed int8 values
    - compute: `A0*B0 + A1*B1 + A2*B2 + A3*B3` (result is int32)
    - leverage Cyclone II's embedded 18x18 multipliers (35 available) for the four 8-bit multiplies
    - this can complete in 1-2 clock cycles since the multiplies are parallel
[ ] Wire it to core
    - **important**: if using `ENABLE_MUL` or `ENABLE_DIV` (needed for rv32im), set those parameters to use the *internal* multiplier (`ENABLE_MUL=1`, not the PCPI-based `picorv32_pcpi_mul`), so the PCPI bus is free for the MAC coprocessor
    - in the top-level wrapper, instantiate the MAC coprocessor and connect its `pcpi_*` wires to the core's `pcpi_*` ports. Set `ENABLE_PCPI=1`
[ ] Simulate coprocessor
    - test the MAC coprocessor in Icarus Verilog simulation before synthesizing to FPGA. Verify with known input pairs that the packed int8 MAC produces correct results

### [ ] Testing the software integration
[ ] Define custom instruction macro
    - use opcode `0x2B` (custom1), with a unique funct3/funct7 combination:
    ```c
    #define MAC4(rd, rs1, rs2) \
        asm volatile (".insn r 0x2B, 0, 0, %0, %1, %2" : "=r"(rd) : "r"(rs1), "r"(rs2))
    ```
[ ] Write accelerated inference code
    - start from the existing baseline in `neural/tests/inference_test.c`
    - pack 4 consecutive int8 weights and 4 consecutive int8 activations into 32-bit registers, then use `MAC4` to process them in one instruction
    - **note**: the conv layer kernel is only 3x3 (9 values per filter) - not cleanly divisible by 4. The FC layer (676 inputs per output) benefits much more from MAC4. Focus optimization on the FC layer first
    - measure cycle counts (using PicoRV32's `rdcycle` CSR) for both baseline and MAC4 versions, produce a speedup report

### [ ] Verification and demonstration
[ ] Output results on DE2 board
    - map PicoRV32 output register to the DE2's 7-segment displays to show the predicted digit (0-9)
    - use the DE2's **toggle switches (SW[3:0])** to select which of the 10 pre-loaded test images to classify (switches select an image index)
    - optionally use LEDs to show confidence or cycle count


---

## RISC V Architecture

---

## Tests and results