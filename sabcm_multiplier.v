`timescale 1ns / 1ps
//----------------------------------------------------
// sabcm_multiplier.v
// 32x32 Signed Multiplier based on SABCM concepts
// - Radix-4 Booth Encoding
// - CSA Tree for Partial Product Compression
// - Includes LZC for adaptive width signaling (not used for gating here)
// ** Corrected for Verilog-2001 Synthesis **
//----------------------------------------------------


module sabcm_32x32 (
    input clk,
    input rst_n,
    input start, // Start signal
    input signed [31:0] operand_a, // Multiplicand
    input signed [31:0] operand_b, // Multiplier
    output reg done, // Computation finished signal
    output reg signed [63:0] product_out, // Result
    // Adaptive width signals (for info/potential optimization)
    output wire [4:0] op_a_leading_bits,
    output wire [4:0] op_b_leading_bits
);

    localparam N = 32;
    localparam N2 = 64;
    localparam NUM_PPS = N / 2; // 16 partial products for Radix-4

    // Internal signals
    reg signed [N-1:0]   a_reg; // Registered multiplicand
    reg start_reg;
    reg busy;

    // Wires for extended operands needed by generate block
    wire signed [N2-1:0] a_extended_wire; // Sign-extended multiplicand
    wire signed [N+1:0]  b_ext_wire;      // Extended multiplier for Booth

    // Partial Products (now wires, driven by generate block)
    wire signed [N2-1:0] pp [0:NUM_PPS-1];

    // CSA Tree Stages (wires for CSA outputs)
    // ... (CSA wire declarations remain the same) ...
    wire signed [N2-1:0] csa1_s [0:4];
    wire signed [N2-1:0] csa1_c [0:4];
    wire signed [N2-1:0] csa2_s [0:2];
    wire signed [N2-1:0] csa2_c [0:2];
    wire signed [N2-1:0] csa3_s [0:1];
    wire signed [N2-1:0] csa3_c [0:1];
    wire signed [N2-1:0] csa4_s [0:1];
    wire signed [N2-1:0] csa4_c [0:1];
    wire signed [N2-1:0] csa5_s;
    wire signed [N2-1:0] csa5_c;
    wire signed [N2-1:0] final_sum_vec;
    wire signed [N2-1:0] final_carry_vec;


    // Final Adder Input Registers (pipelining)
    reg signed [N2-1:0] final_sum_reg;
    reg signed [N2-1:0] final_carry_reg;
    reg cpa_valid; // Signal that CPA inputs are ready

    // --- LZC Instantiation ---
    lzc32 lzc_a ( .data_in(operand_a), .leading_bits(op_a_leading_bits) );
    lzc32 lzc_b ( .data_in(operand_b), .leading_bits(op_b_leading_bits) );

    // --- Combinational assignments for extended operands ---
    assign a_extended_wire = a_reg; // Use registered 'a'. Sign extension is automatic.
    assign b_ext_wire = {operand_b[N-1], operand_b, 1'b0}; // Extend 'b' based on input.

    // --- Booth Encoding and PP Generation (Generate Block) ---
    genvar j; // Use genvar for generate loop
    generate
        for (j = 0; j < NUM_PPS; j = j + 1) begin : booth_pp_gen
            // Select Booth control bits
            wire [2:0] booth_bits = b_ext_wire[2*j+2 : 2*j]; // Part select using genvar 'j'

            // Calculate positive shifted versions (already 64-bit signed)
            wire signed [N2-1:0] pos_shifted_a = a_extended_wire <<< (2*j);
            wire signed [N2-1:0] pos_shifted_2a = a_extended_wire <<< (2*j + 1);

            // Calculate negative versions explicitly using 2's complement
            // Invert bits of positive version and add 1
            wire signed [N2-1:0] neg_shifted_a = ~pos_shifted_a + 1'b1;
            wire signed [N2-1:0] neg_shifted_2a = ~pos_shifted_2a + 1'b1;

            // Assign to the pp wire based on booth_bits
            assign pp[j] = (booth_bits == 3'b000 || booth_bits == 3'b111) ? 64'b0 :           // 0*A
                           (booth_bits == 3'b001 || booth_bits == 3'b010) ? pos_shifted_a :   // +1*A
                           (booth_bits == 3'b011)                      ? pos_shifted_2a :  // +2*A
                           (booth_bits == 3'b100)                      ? neg_shifted_2a :  // -2*A  (Using explicitly calculated 2's complement)
                           (booth_bits == 3'b101 || booth_bits == 3'b110) ? neg_shifted_a :  // -1*A  (Using explicitly calculated 2's complement)
                           64'b0; // Default case (should not happen)
        end
    endgenerate

    // --- CSA Tree Instantiation (Combinational) ---
    // (Instantiation code remains the same, now takes pp wires as input)
    // Level 1: 16 PPs -> 11 vectors
    genvar gv_i; // Can reuse genvar name in different generate scope if needed
    generate
        for (gv_i = 0; gv_i < 5; gv_i = gv_i + 1) begin : csa_level1
            csa_3_2 #(.WIDTH(N2)) csa (
                .a(pp[3*gv_i]), .b(pp[3*gv_i+1]), .c(pp[3*gv_i+2]),
                .sum(csa1_s[gv_i]), .carry(csa1_c[gv_i])
            );
        end
        // pp[15] is handled below
    endgenerate

    // ... (Rest of CSA tree instantiations: csa2_0, csa2_1, etc. remain the same) ...
    csa_3_2 #(.WIDTH(N2)) csa2_0 (.a(pp[15]),   .b(csa1_s[0]), .c(csa1_c[0]), .sum(csa2_s[0]), .carry(csa2_c[0]));
    csa_3_2 #(.WIDTH(N2)) csa2_1 (.a(csa1_s[1]), .b(csa1_c[1]), .c(csa1_s[2]), .sum(csa2_s[1]), .carry(csa2_c[1]));
    csa_3_2 #(.WIDTH(N2)) csa2_2 (.a(csa1_c[2]), .b(csa1_s[3]), .c(csa1_c[3]), .sum(csa2_s[2]), .carry(csa2_c[2]));
    // Remaining vectors direct from Level 1: csa1_s[4], csa1_c[4]

    // Level 3: 8 vectors (csa1_s[4], csa1_c[4], 3 sums, 3 carries from L2) -> 6 vectors
    csa_3_2 #(.WIDTH(N2)) csa3_0 (.a(csa1_s[4]), .b(csa1_c[4]), .c(csa2_s[0]), .sum(csa3_s[0]), .carry(csa3_c[0]));
    csa_3_2 #(.WIDTH(N2)) csa3_1 (.a(csa2_c[0]), .b(csa2_s[1]), .c(csa2_c[1]), .sum(csa3_s[1]), .carry(csa3_c[1]));
    // Remaining vectors direct from Level 2: csa2_s[2], csa2_c[2]

    // Level 4: 6 vectors -> 4 vectors
    csa_3_2 #(.WIDTH(N2)) csa4_0 (.a(csa2_s[2]), .b(csa2_c[2]), .c(csa3_s[0]), .sum(csa4_s[0]), .carry(csa4_c[0]));
    csa_3_2 #(.WIDTH(N2)) csa4_1 (.a(csa3_c[0]), .b(csa3_s[1]), .c(csa3_c[1]), .sum(csa4_s[1]), .carry(csa4_c[1]));

    // Level 5: 4 vectors -> 3 vectors
    csa_3_2 #(.WIDTH(N2)) csa5_0 (.a(csa4_s[0]), .b(csa4_c[0]), .c(csa4_s[1]), .sum(csa5_s), .carry(csa5_c));
    // Remaining vector direct from Level 4: csa4_c[1]

    // Level 6: 3 vectors -> 2 vectors (Final Sum/Carry for CPA)
    csa_3_2 #(.WIDTH(N2)) csa6_0 (.a(csa4_c[1]), .b(csa5_s), .c(csa5_c), .sum(final_sum_vec), .carry(final_carry_vec));


    // --- Control Logic and Final Adder Stage ---
    // (This always block remains the same as your previous version)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_reg <= 32'b0;
            start_reg <= 1'b0;
            busy <= 1'b0;
            done <= 1'b0;
            final_sum_reg <= 64'b0;
            final_carry_reg <= 64'b0;
            product_out <= 64'b0;
            cpa_valid <= 1'b0;
        end else begin
            start_reg <= start; // Register start signal
            done <= 1'b0;      // Default done to low unless calculation finishes
            cpa_valid <= 1'b0; // Default cpa_valid low

            if (start && !start_reg && !busy) begin // Rising edge of start, and not busy
                busy <= 1'b1;
                a_reg <= operand_a; // Latch multiplicand. a_extended_wire/b_ext_wire/pp/CSA update combinationally.
                // Latch the final Sum/Carry vectors from the CSA tree output for the CPA stage.
                final_sum_reg <= final_sum_vec;
                final_carry_reg <= final_carry_vec;
                cpa_valid <= 1'b1; // CPA inputs will be valid in the *next* cycle
            end else if (busy) begin
                if (cpa_valid) begin // CPA inputs were latched in the previous cycle
                   // Perform final addition (represents CPA)
                   product_out <= final_sum_reg + final_carry_reg;
                   done <= 1'b1;
                   busy <= 1'b0;
                   // cpa_valid automatically goes low unless re-asserted
                end
                // Can add more pipeline stages here if CSA tree is registered
            end
        end
    end

endmodule