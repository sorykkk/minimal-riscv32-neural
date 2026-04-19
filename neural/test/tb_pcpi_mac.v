// Unit testbench for picorv32_pcpi_mac
//
// Drives the PCPI interface directly (no CPU) with known packed int8
// pairs and checks the result against hand-computed expected values.
//
// Run:  iverilog -o neural/test/tb_pcpi_mac.vvp neural/test/tb_pcpi_mac.v neural/rtl/picorv32_pcpi_mac.v
//       vvp neural/test/tb_pcpi_mac.vvp

`timescale 1 ns / 1 ps

module tb_pcpi_mac;
	reg         clk;
	reg         resetn;
	reg         pcpi_valid;
	reg  [31:0] pcpi_insn;
	reg  [31:0] pcpi_rs1;
	reg  [31:0] pcpi_rs2;
	wire        pcpi_wr;
	wire [31:0] pcpi_rd;
	wire        pcpi_wait;
	wire        pcpi_ready;

	picorv32_pcpi_mac dut (
		.clk        (clk),
		.resetn     (resetn),
		.pcpi_valid (pcpi_valid),
		.pcpi_insn  (pcpi_insn),
		.pcpi_rs1   (pcpi_rs1),
		.pcpi_rs2   (pcpi_rs2),
		.pcpi_wr    (pcpi_wr),
		.pcpi_rd    (pcpi_rd),
		.pcpi_wait  (pcpi_wait),
		.pcpi_ready (pcpi_ready)
	);

	// Clock: 20 ns period (50 MHz)
	initial clk = 0;
	always #10 clk = ~clk;

	// Custom1 R-type: opcode=0101011, funct3=000, funct7=0000000
	// Bit layout: {funct7[6:0], rs2[4:0], rs1[4:0], funct3[2:0], rd[4:0], opcode[6:0]}
	localparam [31:0] MAC4_INSN = {7'b0000000, 5'd2, 5'd1, 3'b000, 5'd3, 7'b0101011};

	integer pass_count;
	integer fail_count;
	integer test_num;

	// Helper: pack four int8 values into a 32-bit word (a0 in LSB)
	function [31:0] pack4;
		input signed [7:0] v0, v1, v2, v3;
		begin
			pack4 = {v3[7:0], v2[7:0], v1[7:0], v0[7:0]};
		end
	endfunction

	// Task: issue one MAC4 instruction and check the result
	task run_test;
		input [31:0] rs1;
		input [31:0] rs2;
		input signed [31:0] expected;
		begin
			test_num = test_num + 1;

			// Present instruction on rising edge
			@(posedge clk);
			pcpi_valid <= 1;
			pcpi_insn  <= MAC4_INSN;
			pcpi_rs1   <= rs1;
			pcpi_rs2   <= rs2;

			// Wait for pcpi_ready (2-cycle pipeline)
			@(posedge clk);
			// After first cycle, deassert valid (core only holds for 1 cycle)
			pcpi_valid <= 0;
			pcpi_insn  <= 0;

			@(posedge clk); #1;
			// Result should be ready now (after NBA settles)
			if (!pcpi_ready) begin
				$display("FAIL test %0d: pcpi_ready not asserted", test_num);
				fail_count = fail_count + 1;
			end else if ($signed(pcpi_rd) !== expected) begin
				$display("FAIL test %0d: got %0d, expected %0d  (rs1=0x%08x rs2=0x%08x)",
				         test_num, $signed(pcpi_rd), expected, rs1, rs2);
				fail_count = fail_count + 1;
			end else begin
				$display("PASS test %0d: %0d == %0d", test_num, $signed(pcpi_rd), expected);
				pass_count = pass_count + 1;
			end

			// Idle gap between tests
			@(posedge clk);
		end
	endtask

	initial begin
		pass_count = 0;
		fail_count = 0;
		test_num   = 0;

		// Reset
		resetn     = 0;
		pcpi_valid = 0;
		pcpi_insn  = 0;
		pcpi_rs1   = 0;
		pcpi_rs2   = 0;

		repeat (4) @(posedge clk);
		resetn = 1;
		repeat (2) @(posedge clk);

		$display("=== picorv32_pcpi_mac unit tests ===");

		// ---------------------------------------------------------------
		// Test 1: all ones -> 1*1 + 1*1 + 1*1 + 1*1 = 4
		// ---------------------------------------------------------------
		run_test(pack4(1, 1, 1, 1), pack4(1, 1, 1, 1), 4);

		// ---------------------------------------------------------------
		// Test 2: all zeros -> 0
		// ---------------------------------------------------------------
		run_test(32'h0000_0000, 32'h0000_0000, 0);

		// ---------------------------------------------------------------
		// Test 3: mixed signs -> (-1)*4 + 2*3 + (-3)*2 + 4*1 = -4+6-6+4 = 0
		// ---------------------------------------------------------------
		run_test(pack4(-1, 2, -3, 4), pack4(4, 3, 2, 1), 0);

		// ---------------------------------------------------------------
		// Test 4: boundary -> 127*1 + (-128)*1 + 0*1 + 1*1 = 127-128+0+1 = 0
		// ---------------------------------------------------------------
		run_test(pack4(127, -128, 0, 1), pack4(1, 1, 1, 1), 0);

		// ---------------------------------------------------------------
		// Test 5: max positive -> 127*127 + 127*127 + 127*127 + 127*127 = 64516
		// ---------------------------------------------------------------
		run_test(pack4(127, 127, 127, 127), pack4(127, 127, 127, 127), 64516);

		// ---------------------------------------------------------------
		// Test 6: max negative -> (-128)*(-128)*4 = 65536
		// ---------------------------------------------------------------
		run_test(pack4(-128, -128, -128, -128), pack4(-128, -128, -128, -128), 65536);

		// ---------------------------------------------------------------
		// Test 7: cross sign -> 127*(-128) + 127*(-128) + 127*(-128) + 127*(-128) = -65024
		// ---------------------------------------------------------------
		run_test(pack4(127, 127, 127, 127), pack4(-128, -128, -128, -128), -65024);

		// ---------------------------------------------------------------
		// Test 8: single lane active -> 0*5 + 0*5 + 0*5 + 10*3 = 30
		// ---------------------------------------------------------------
		run_test(pack4(0, 0, 0, 10), pack4(5, 5, 5, 3), 30);

		// ---------------------------------------------------------------
		// Test 9: asymmetric -> 1*(-1) + 2*(-2) + 3*(-3) + 4*(-4) = -1-4-9-16 = -30
		// ---------------------------------------------------------------
		run_test(pack4(1, 2, 3, 4), pack4(-1, -2, -3, -4), -30);

		// ---------------------------------------------------------------
		// Test 10: realistic weights -> 10*(-5) + (-20)*3 + 15*7 + (-8)*(-2) = -50-60+105+16 = 11
		// ---------------------------------------------------------------
		run_test(pack4(10, -20, 15, -8), pack4(-5, 3, 7, -2), 11);

		// ---------------------------------------------------------------
		// Test 11: wrong opcode -> should NOT produce a result
		//          Use opcode 0x0B (custom0) instead of 0x2B (custom1)
		// ---------------------------------------------------------------
		begin
			test_num = test_num + 1;
			@(posedge clk);
			pcpi_valid <= 1;
			pcpi_insn  <= {7'b0000000, 5'd2, 5'd1, 3'b000, 5'd3, 7'b0001011}; // custom0
			pcpi_rs1   <= pack4(1, 1, 1, 1);
			pcpi_rs2   <= pack4(1, 1, 1, 1);

			@(posedge clk);
			pcpi_valid <= 0;
			pcpi_insn  <= 0;

			@(posedge clk); #1;
			if (pcpi_ready) begin
				$display("FAIL test %0d: pcpi_ready asserted for wrong opcode!", test_num);
				fail_count = fail_count + 1;
			end else begin
				$display("PASS test %0d: correctly ignored wrong opcode", test_num);
				pass_count = pass_count + 1;
			end
			@(posedge clk);
		end

		// ---------------------------------------------------------------
		// Summary
		// ---------------------------------------------------------------
		$display("===================================");
		$display("Results: %0d passed, %0d failed out of %0d tests",
		         pass_count, fail_count, test_num);
		if (fail_count == 0)
			$display("ALL TESTS PASSED.");
		else
			$display("SOME TESTS FAILED!");
		$display("===================================");
		$finish;
	end
endmodule
