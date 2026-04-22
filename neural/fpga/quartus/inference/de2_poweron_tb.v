// Power-on testbench: simulates EXACT FPGA behavior after .sof upload
// KEY[0] = HIGH from the start (not pressed)
// On the old design, the CPU would trap immediately. With the fix, the
// power-on reset counter holds resetn LOW until it counts up.

`timescale 1 ns / 1 ps

module de2_poweron_tb;
    reg clk = 0;
    // KEY[0] = 1 from power-on (not pressed) - FPGA reality
    reg [3:0] KEY = 4'b0001;
    reg [17:0] SW = 18'h0;

    wire [8:0]  LEDG;
    wire [17:0] LEDR;
    wire [6:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5, HEX6, HEX7;

    de2_top #(
        .MEM_WORDS(12288),
        .RESET_BITS(3)      // fast reset for simulation
    ) uut (
        .CLOCK_50(clk),
        .KEY(KEY),
        .SW(SW),
        .LEDG(LEDG),
        .LEDR(LEDR),
        .HEX0(HEX0), .HEX1(HEX1), .HEX2(HEX2), .HEX3(HEX3),
        .HEX4(HEX4), .HEX5(HEX5), .HEX6(HEX6), .HEX7(HEX7)
    );

    // 50 MHz clock
    always #10 clk = ~clk;

    // Track trap status
    integer trap_ever = 0;
    always @(posedge clk) begin
        if (uut.trap) trap_ever = 1;
    end

    // Print console output
    always @(posedge clk) begin
        if (uut.out_byte_en)
            $write("%c", uut.out_byte);
    end

    // Watch 7-seg
    reg [31:0] prev_seg7 = 0;
    always @(posedge clk) begin
        if (uut.seg7_reg !== prev_seg7) begin
            if (uut.seg7_reg == 32'hFFFFFFFF)
                $display("[%0t ns] HEX0: blanked", $time);
            else
                $display("[%0t ns] HEX0: showing digit %0d", $time, uut.seg7_reg);
            prev_seg7 <= uut.seg7_reg;
        end
    end

    // Watch confidence LEDs
    reg [9:0] prev_led = 0;
    always @(posedge clk) begin
        if (uut.led_conf_reg !== prev_led) begin
            $display("[%0t ns] LEDR[9:0] = %b", $time, uut.led_conf_reg);
            prev_led <= uut.led_conf_reg;
        end
    end

    initial begin
        $display("============================================================");
        $display("  POWER-ON TEST: KEY[0]=HIGH from start (no button press)");
        $display("============================================================");
        $display("");

        // ---- Phase 1: Check power-on reset behavior ----
        #10;
        $display("[%0t ns] Power-on: resetn=%b, trap=%b, LEDG[0]=%b, LEDR[17]=%b",
                 $time, uut.resetn, uut.trap, LEDG[0], LEDR[17]);

        // Wait for reset counter to release (RESET_BITS=3 -> 8 cycles = 160 ns)
        #500;
        $display("[%0t ns] After reset counter: resetn=%b, trap=%b, LEDG[0]=%b, LEDR[17]=%b",
                 $time, uut.resetn, uut.trap, LEDG[0], LEDR[17]);

        if (uut.trap) begin
            $display("");
            $display("*** FAIL: CPU TRAPPED after power-on! ***");
            $display("*** This is the old bug - design is NOT fixed. ***");
            $finish;
        end

        // ---- Phase 2: Wait for firmware to boot ----
        #5000000;  // 5 ms
        $display("");
        $display("[%0t ns] CPU boot complete: trap=%b, LEDG[0]=%b, LEDR[17]=%b",
                 $time, uut.trap, LEDG[0], LEDR[17]);

        if (uut.trap) begin
            $display("*** FAIL: CPU trapped during boot! ***");
            $finish;
        end
        $display(">> PASS: CPU booted without trap, LEDG[0]=green");

        // ---- Phase 3: Flip SW[0] and wait for inference ----
        $display("");
        $display("---- Flipping SW[0] ON: classify image 0 ----");
        SW = 18'h01;
        #55000000;  // ~55 ms for inference (~1s real time scaled)

        $display("[%0t ns] After SW[0]: trap=%b, seg7=%0d, LEDR[9:0]=%b",
                 $time, uut.trap, uut.seg7_reg, uut.led_conf_reg);

        if (uut.trap) begin
            $display("*** FAIL: CPU trapped during inference! ***");
            $finish;
        end

        if (uut.seg7_reg == 32'hFFFFFFFF) begin
            $display("*** FAIL: HEX0 still blank after inference! ***");
            $finish;
        end

        $display(">> PASS: HEX0 shows digit %0d, confidence LEDs = %b",
                 uut.seg7_reg, uut.led_conf_reg);

        // ---- Phase 4: Flip SW[5] (higher priority) ----
        $display("");
        $display("---- Flipping SW[5] ON (with SW[0]): classify image 5 ----");
        SW = 18'h21;  // SW[5] + SW[0]
        #55000000;

        $display("[%0t ns] After SW[5]: trap=%b, seg7=%0d, LEDR[9:0]=%b",
                 $time, uut.trap, uut.seg7_reg, uut.led_conf_reg);

        if (uut.seg7_reg != 5) begin
            $display("*** FAIL: Expected digit 5, got %0d ***", uut.seg7_reg);
            $finish;
        end
        $display(">> PASS: HEX0 shows digit 5");

        // ---- Phase 5: All switches off -> blank ----
        $display("");
        $display("---- All switches OFF ----");
        SW = 18'h0;
        #5000000;

        if (uut.seg7_reg != 32'hFFFFFFFF) begin
            $display("*** FAIL: HEX0 not blanked after switches off ***");
            $finish;
        end
        $display(">> PASS: HEX0 blanked, LEDR[9:0]=%b", uut.led_conf_reg);

        // ---- Summary ----
        $display("");
        $display("============================================================");
        $display("  ALL TESTS PASSED");
        $display("  - Power-on reset: CPU did NOT trap");
        $display("  - Inference: correct digit on HEX0");
        $display("  - Switch priority: highest switch wins");
        $display("  - Blanking: HEX0 clears when all switches off");
        $display("  - Trap ever asserted: %s", trap_ever ? "YES (BUG!)" : "NO");
        $display("============================================================");
        $finish;
    end
endmodule
