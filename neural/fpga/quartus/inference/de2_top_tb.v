`timescale 1 ns / 1 ps

module de2_top_tb;
    reg clk = 0;
    reg [3:0] KEY = 4'b0000;
    reg [17:0] SW = 18'h0;

    wire [8:0]  LEDG;
    wire [17:0] LEDR;
    wire [6:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5, HEX6, HEX7;

    de2_top #(
        .MEM_WORDS(12288)
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

    // Print console output from the CPU
    integer char_count = 0;
    always @(posedge clk) begin
        if (uut.out_byte_en) begin
            $write("%c", uut.out_byte);
            char_count = char_count + 1;
        end
    end

    // Watch for 7-seg changes
    reg [31:0] prev_seg7 = 0;
    always @(posedge clk) begin
        if (uut.seg7_reg !== prev_seg7) begin
            if (uut.seg7_reg == 32'hFFFFFFFF)
                $display("[%0t ns] 7SEG: blanked", $time);
            else
                $display("[%0t ns] 7SEG: showing %0d", $time, uut.seg7_reg);
            prev_seg7 <= uut.seg7_reg;
        end
    end

    // Watch for confidence LED changes
    reg [9:0] prev_led_conf = 0;
    always @(posedge clk) begin
        if (uut.led_conf_reg !== prev_led_conf) begin
            $display("[%0t ns] LEDR[9:0]: %b (%0d LEDs lit)",
                     $time, uut.led_conf_reg,
                     uut.led_conf_reg[0] + uut.led_conf_reg[1] +
                     uut.led_conf_reg[2] + uut.led_conf_reg[3] +
                     uut.led_conf_reg[4] + uut.led_conf_reg[5] +
                     uut.led_conf_reg[6] + uut.led_conf_reg[7] +
                     uut.led_conf_reg[8] + uut.led_conf_reg[9]);
            prev_led_conf <= uut.led_conf_reg;
        end
    end

    // Monitor status LEDs
    always @(posedge clk) begin
        if (LEDG[0] === 1'b1 && LEDR[17] === 1'b0) begin
            // Normal operation - green on, red off
        end
        else if (LEDG[0] === 1'b0 && LEDR[17] === 1'b1) begin
            // Reset or trapped - red on, green off
        end
    end

    initial begin
        $display("=== DE2 Inference Demo Testbench ===");
        $display("LEDG[0] = green (working), LEDR[17] = red (reset/error)");
        $display("LEDR[9:0] = confidence bar graph");
        $display("");

        // Hold reset - red LED should be on
        KEY = 4'b0000;
        #2000;
        $display("[%0t ns] Reset active: LEDG=%b LEDR[17]=%b", $time, LEDG[0], LEDR[17]);

        // Release reset - wait for power-on reset counter (~21 ms)
        KEY = 4'b0001;
        SW = 18'h0;
        $display("[%0t ns] Reset released (waiting for debounce counter)", $time);

        // Wait for reset counter + CPU boot (~25ms total)
        #25000000;
        $display("[%0t ns] CPU booted: LEDG=%b LEDR[17]=%b", $time, LEDG[0], LEDR[17]);

        // --- Test 1: SW[3] -> classify image 3 ---
        $display("\n--- SW[3] on: classify image 3 ---");
        SW = 18'h08;    // bit 3
        #50000000;      // wait ~50ms for inference

        // --- Test 2: SW[7] (with SW[3] still on) -> highest wins, classify image 7 ---
        $display("\n--- SW[7] on (SW[3]+SW[7]): classify image 7 ---");
        SW = 18'h88;    // bits 3 and 7
        #50000000;

        // --- Test 3: SW[7] off, SW[3] remains -> fall back to image 3 ---
        $display("\n--- SW[7] off (SW[3] only): fall back to image 3 ---");
        SW = 18'h08;
        #50000000;

        // --- Test 4: SW[0] -> classify image 0 ---
        $display("\n--- SW[0] on (SW[0]+SW[3]): classify image 3 (highest wins) ---");
        SW = 18'h09;    // bits 0 and 3
        #10000000;      // no re-inference needed (still image 3)

        // --- Test 5: All switches off -> blank ---
        $display("\n--- All switches off ---");
        SW = 18'h00;
        #10000000;

        $display("\n=== Simulation complete ===");
        $display("Characters printed: %0d", char_count);
        $display("Final LEDG = %b", LEDG);
        $display("Final LEDR = %b", LEDR);
        $display("Trap = %b", uut.trap);
        $finish;
    end
endmodule
