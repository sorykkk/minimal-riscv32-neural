// 4-way packed int8 MAC coprocessor for PicoRV32 PCPI interface
//
// Custom1 R-type instruction (opcode 0x2B):
//   .insn r 0x2B, funct3=0, funct7=0, rd, rs1, rs2
//
// Semantics:
//   rs1 = packed 4x int8 {a3, a2, a1, a0}  (a0 in bits [7:0])
//   rs2 = packed 4x int8 {b3, b2, b1, b0}  (b0 in bits [7:0])
//   rd  = a0*b0 + a1*b1 + a2*b2 + a3*b3    (int32 result)
//
// Completes in 2 clock cycles (multiply in cycle 1, accumulate in cycle 2).
// Uses 4 parallel multipliers (maps to Cyclone II 18x18 embedded multipliers).

`timescale 1 ns / 1 ps

module picorv32_pcpi_mac (
	input             clk,
	input             resetn,

	input             pcpi_valid,
	input      [31:0] pcpi_insn,
	input      [31:0] pcpi_rs1,
	input      [31:0] pcpi_rs2,
	output reg        pcpi_wr,
	output reg [31:0] pcpi_rd,
	output reg        pcpi_wait,
	output reg        pcpi_ready
);
	// Instruction decode: custom1 opcode = 7'b0101011 = 0x2B
	wire instr_mac4 = pcpi_valid && (pcpi_insn[6:0] == 7'b0101011)
	                              && (pcpi_insn[14:12] == 3'b000)
	                              && (pcpi_insn[31:25] == 7'b0000000);

	// Extract 4 signed int8 values from each packed register
	wire signed [7:0] a0 = pcpi_rs1[ 7: 0];
	wire signed [7:0] a1 = pcpi_rs1[15: 8];
	wire signed [7:0] a2 = pcpi_rs1[23:16];
	wire signed [7:0] a3 = pcpi_rs1[31:24];

	wire signed [7:0] b0 = pcpi_rs2[ 7: 0];
	wire signed [7:0] b1 = pcpi_rs2[15: 8];
	wire signed [7:0] b2 = pcpi_rs2[23:16];
	wire signed [7:0] b3 = pcpi_rs2[31:24];

	// Stage 1: four parallel 8x8 signed multiplies (registered)
	// These infer as embedded 18x18 multipliers on Cyclone II
	reg signed [15:0] prod0, prod1, prod2, prod3;
	reg                stage1_valid;

	always @(posedge clk) begin
		if (!resetn) begin
			stage1_valid <= 0;
		end else begin
			stage1_valid <= instr_mac4;
			if (instr_mac4) begin
				prod0 <= a0 * b0;
				prod1 <= a1 * b1;
				prod2 <= a2 * b2;
				prod3 <= a3 * b3;
			end
		end
	end

	// Stage 2: sum the four products (registered output)
	wire signed [31:0] sum = prod0 + prod1 + prod2 + prod3;

	always @(posedge clk) begin
		pcpi_wr    <= 0;
		pcpi_ready <= 0;
		if (!resetn) begin
			// nothing
		end else if (stage1_valid) begin
			pcpi_wr    <= 1;
			pcpi_ready <= 1;
			pcpi_rd    <= sum;
		end
	end

	// Assert pcpi_wait as soon as we recognise our instruction,
	// so the core knows not to treat it as illegal.
	always @(posedge clk) begin
		if (!resetn)
			pcpi_wait <= 0;
		else
			pcpi_wait <= instr_mac4;
	end
endmodule