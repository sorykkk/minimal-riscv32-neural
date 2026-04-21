`timescale 1 ns / 1 ps

module de2_top_tb;
    reg clk = 0;
    reg [3:0] KEY = 4'b0000;
    reg [17:0] SW = 18'h0;

    wire [8:0]  LEDG;
    wire [17:0] LEDR;
    wire [6:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5, HEX6, HEX7;

    de2_top #(
        .MEM_WORDS(12288),
        .RESET_BITS(3)
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

    initial begin
        // Hold reset
        KEY = 4'b0000;
        #2000;

        // Release reset, SW all off
        KEY = 4'b0001;
        SW = 18'h0;
        #50000000;  // let CPU boot and enter loop

        // Turn on SW[0] -> should show 0
        $display("\n--- SW[0] on ---");
        SW = 18'h01;
        #10000000;

        // Add SW[1] -> should show 1 (highest)
        $display("\n--- SW[1] on (SW[0]+SW[1]) ---");
        SW = 18'h03;
        #10000000;

        // Turn off SW[1] -> should fall back to 0 (SW[0])
        $display("\n--- SW[1] off (SW[0] only) ---");
        SW = 18'h01;
        #10000000;

        // Turn on SW[5] -> should show 5
        $display("\n--- SW[5] on (SW[0]+SW[5]) ---");
        SW = 18'h21;
        #10000000;

        // Turn on SW[9] -> should show 9 (highest in range)
        $display("\n--- SW[9] on (SW[0]+SW[5]+SW[9]) ---");
        SW = 18'h221;   // bits 0, 5, 9
        #10000000;

        // Turn off SW[9], keep SW[5] -> should fall back to 5
        $display("\n--- SW[9] off (SW[0]+SW[5]) ---");
        SW = 18'h21;
        #10000000;

        // Turn off all -> should blank
        $display("\n--- All off ---");
        SW = 18'h00;
        #10000000;

        $display("\n=== Simulation complete ===");
        $display("Characters printed: %0d", char_count);
        $display("LEDG = %b", LEDG);
        $display("LEDR = %b", LEDR);
        $display("Trap = %b", uut.trap);
        $finish;
    end
endmodule
