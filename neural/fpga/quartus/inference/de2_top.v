// DE2 Board (EP2C35F672C6) top-level wrapper for PicoRV32 + MAC coprocessor
// Adapted from neural/fpga/quartus/test/de2_top.v with PCPI MAC4 coprocessor

`timescale 1 ns / 1 ps

module de2_top (
    // Clock
    input         CLOCK_50,

    // Keys (active-low pushbuttons)
    input  [3:0]  KEY,

    // Toggle Switches
    input  [17:0] SW,

    // Green LEDs
    output [8:0]  LEDG,

    // Red LEDs
    output [17:0] LEDR,

    // 7-Segment Displays (active-low segments a-g)
    output [6:0]  HEX0,
    output [6:0]  HEX1,
    output [6:0]  HEX2,
    output [6:0]  HEX3,
    output [6:0]  HEX4,
    output [6:0]  HEX5,
    output [6:0]  HEX6,
    output [6:0]  HEX7
);

    // -------------------------------------------------------
    // Parameters
    // -------------------------------------------------------

    // 12288 x 32-bit words = 48 KB BRAM
    parameter MEM_WORDS = 12288;

    // -------------------------------------------------------
    // Clocking & Reset
    // -------------------------------------------------------
    wire clk = CLOCK_50;

    // Power-on reset generator + KEY[0] debounce.
    // At FPGA configuration all regs are 0, so resetn starts LOW
    // (active reset).  The counter counts up while KEY[0] is
    // released (high).  resetn goes HIGH only after the counter
    // saturates, which also filters mechanical key bounce.
    // synthesis: 2^20 cycles (~21 ms at 50 MHz)
    // simulation: 2^3 cycles (fast)
    parameter RESET_BITS = 20; // synthesis value; testbench overrides to 3
    reg [RESET_BITS:0] reset_cnt = 0;
    always @(posedge clk) begin
        if (!KEY[0])
            reset_cnt <= 0;
        else if (!reset_cnt[RESET_BITS])
            reset_cnt <= reset_cnt + 1;
    end
    wire resetn = reset_cnt[RESET_BITS];

    // -------------------------------------------------------
    // CPU trap signal
    // -------------------------------------------------------
    wire trap;

    // -------------------------------------------------------
    // Memory interface
    // -------------------------------------------------------
    wire        mem_valid;
    wire        mem_instr;
    reg         mem_ready;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [3:0]  mem_wstrb;
    reg  [31:0] mem_rdata;

    // -------------------------------------------------------
    // PCPI interface (MAC coprocessor)
    // -------------------------------------------------------
    wire        pcpi_valid;
    wire [31:0] pcpi_insn;
    wire [31:0] pcpi_rs1;
    wire [31:0] pcpi_rs2;
    wire        pcpi_wr;
    wire [31:0] pcpi_rd;
    wire        pcpi_wait;
    wire        pcpi_ready;

    // -------------------------------------------------------
    // PicoRV32 core instantiation
    //   ENABLE_MUL=1, ENABLE_DIV=1: use internal multiplier/divider
    //   ENABLE_PCPI=1: PCPI bus free for MAC coprocessor
    // -------------------------------------------------------
    picorv32 #(
        .ENABLE_COUNTERS  (1),
        .ENABLE_REGS_16_31(1),
        .ENABLE_MUL       (1),
        .ENABLE_DIV       (1),
        .ENABLE_PCPI      (1),
        .ENABLE_IRQ       (0),
        .BARREL_SHIFTER   (1),
        .STACKADDR        (MEM_WORDS * 4)
    ) cpu (
        .clk         (clk        ),
        .resetn      (resetn     ),
        .trap        (trap       ),
        .mem_valid   (mem_valid  ),
        .mem_instr   (mem_instr  ),
        .mem_ready   (mem_ready  ),
        .mem_addr    (mem_addr   ),
        .mem_wdata   (mem_wdata  ),
        .mem_wstrb   (mem_wstrb  ),
        .mem_rdata   (mem_rdata  ),
        .pcpi_valid  (pcpi_valid ),
        .pcpi_insn   (pcpi_insn  ),
        .pcpi_rs1    (pcpi_rs1   ),
        .pcpi_rs2    (pcpi_rs2   ),
        .pcpi_wr     (pcpi_wr    ),
        .pcpi_rd     (pcpi_rd    ),
        .pcpi_wait   (pcpi_wait  ),
        .pcpi_ready  (pcpi_ready )
    );

    // -------------------------------------------------------
    // MAC4 Coprocessor
    // -------------------------------------------------------
    picorv32_pcpi_mac mac_copro (
        .clk        (clk        ),
        .resetn     (resetn     ),
        .pcpi_valid (pcpi_valid ),
        .pcpi_insn  (pcpi_insn  ),
        .pcpi_rs1   (pcpi_rs1   ),
        .pcpi_rs2   (pcpi_rs2   ),
        .pcpi_wr    (pcpi_wr    ),
        .pcpi_rd    (pcpi_rd    ),
        .pcpi_wait  (pcpi_wait  ),
        .pcpi_ready (pcpi_ready )
    );

    // -------------------------------------------------------
    // Memory (M4K BRAM inferred by Quartus)
    // -------------------------------------------------------
    // ram_init_file: Quartus uses the .mif for M4K block initialization.
    // $readmemh: Icarus Verilog uses the .hex for simulation.
    (* ramstyle = "M4K", ram_init_file = "firmware.mif" *)
    reg [31:0] memory [0:MEM_WORDS-1];
    initial $readmemh("firmware.hex", memory);

    wire [13:0] mem_word_addr = mem_addr[15:2];
    wire        mem_addr_is_ram = (mem_addr[31:16] == 0) && (mem_word_addr < MEM_WORDS);

    reg [31:0] ram_rdata;

    always @(posedge clk) begin
        ram_rdata <= memory[mem_word_addr];
        if (mem_valid && mem_addr_is_ram && |mem_wstrb) begin
            if (mem_wstrb[0]) memory[mem_word_addr][ 7: 0] <= mem_wdata[ 7: 0];
            if (mem_wstrb[1]) memory[mem_word_addr][15: 8] <= mem_wdata[15: 8];
            if (mem_wstrb[2]) memory[mem_word_addr][23:16] <= mem_wdata[23:16];
            if (mem_wstrb[3]) memory[mem_word_addr][31:24] <= mem_wdata[31:24];
        end
    end

    // -------------------------------------------------------
    // I/O Registers (memory-mapped I/O)
    // -------------------------------------------------------
    // 0x1000_0000 : output byte (console output, used in simulation)
    // 0x2000_0000 : test pass/fail signal
    // 0x3000_0004 : 7-segment display register
    // 0x3000_0008 : Switch/key input register (read)
    // 0x3000_000C : confidence LED bar register (write) -> LEDR[9:0]

    reg [31:0] seg7_reg;
    reg [9:0]  led_conf_reg;
    reg [7:0]  out_byte;
    reg        out_byte_en;

    // -------------------------------------------------------
    // Bus controller - address decode and ready/data mux
    // -------------------------------------------------------
    reg [31:0] m_read_data;
    reg        m_read_en;
    reg        ram_read_pending;

    always @(posedge clk) begin
        m_read_en <= 0;
        mem_ready <= mem_valid && !mem_ready && m_read_en;
        mem_rdata <= m_read_data;
        out_byte_en <= 0;

        if (ram_read_pending) begin
            m_read_data      <= ram_rdata;
            m_read_en        <= 1;
            ram_read_pending <= 0;
        end
        else if (mem_valid && !mem_ready) begin
            if (mem_addr_is_ram) begin
                if (!mem_wstrb) begin
                    ram_read_pending <= 1;
                end else begin
                    mem_ready <= 1;
                end
            end
            else if (mem_addr == 32'h1000_0000 && |mem_wstrb) begin
                out_byte_en <= 1;
                out_byte    <= mem_wdata[7:0];
                mem_ready   <= 1;
            end
            else if (mem_addr == 32'h2000_0000 && |mem_wstrb) begin
                mem_ready <= 1;
            end
            else if (mem_addr == 32'h3000_0004 && |mem_wstrb) begin
                seg7_reg  <= mem_wdata;
                mem_ready <= 1;
            end
            else if (mem_addr == 32'h3000_0008 && !mem_wstrb) begin
                m_read_data <= {10'b0, SW[17:0], KEY[3:0]};
                m_read_en   <= 1;
            end
            else if (mem_addr == 32'h3000_000C && |mem_wstrb) begin
                led_conf_reg <= mem_wdata[9:0];
                mem_ready    <= 1;
            end
            else begin
                // Unmapped address: complete the transaction so the
                // CPU does not hang.  Reads get 0xFFFFFFFF.
                m_read_data <= 32'hFFFFFFFF;
                m_read_en   <= !mem_wstrb ? 1'b1 : 1'b0;
                mem_ready   <= |mem_wstrb ? 1'b1 : 1'b0;
            end
        end
    end

    // -------------------------------------------------------
    // 7-segment decoder
    // -------------------------------------------------------
    function [6:0] seg7_decode;
        input [3:0] digit;
        case (digit)
            4'h0: seg7_decode = 7'b1000000;
            4'h1: seg7_decode = 7'b1111001;
            4'h2: seg7_decode = 7'b0100100;
            4'h3: seg7_decode = 7'b0110000;
            4'h4: seg7_decode = 7'b0011001;
            4'h5: seg7_decode = 7'b0010010;
            4'h6: seg7_decode = 7'b0000010;
            4'h7: seg7_decode = 7'b1111000;
            4'h8: seg7_decode = 7'b0000000;
            4'h9: seg7_decode = 7'b0010000;
            4'hA: seg7_decode = 7'b0001000;
            4'hB: seg7_decode = 7'b0000011;
            4'hC: seg7_decode = 7'b1000110;
            4'hD: seg7_decode = 7'b0100001;
            4'hE: seg7_decode = 7'b0000110;
            4'hF: seg7_decode = 7'b0001110;
        endcase
    endfunction

    // -------------------------------------------------------
    // Output assignments
    // -------------------------------------------------------

    // Green LED[0]: working state (CPU alive, not trapped)
    assign LEDG[0] = ~trap & resetn;
    assign LEDG[8:1] = 8'b0;

    // Red LED[17]: error / reset / non-working state
    assign LEDR[17] = trap | ~resetn;
    // Red LEDs [9:0]: confidence bar graph (software-driven)
    assign LEDR[9:0] = led_conf_reg;
    assign LEDR[16:10] = 7'b0;

    // 7-segment display: show predicted digit on HEX0, blank others
    wire seg7_blank = (seg7_reg == 32'hFFFFFFFF);
    assign HEX0 = seg7_blank ? 7'b1111111 : seg7_decode(seg7_reg[3:0]);
    assign HEX1 = 7'b1111111;
    assign HEX2 = 7'b1111111;
    assign HEX3 = 7'b1111111;
    assign HEX4 = 7'b1111111;
    assign HEX5 = 7'b1111111;
    assign HEX6 = 7'b1111111;
    assign HEX7 = 7'b1111111;

endmodule
