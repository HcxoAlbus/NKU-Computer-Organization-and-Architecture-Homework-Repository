`timescale 1ns / 1ps

//----------------------------------------------------
// common_modules.v
// Contains shared modules like CSA and LZC
//----------------------------------------------------

// --- 3-to-2 Carry Save Adder (CSA) ---
module csa_3_2 #(parameter WIDTH = 32) (
    input  wire [WIDTH-1:0] a,
    input  wire [WIDTH-1:0] b,
    input  wire [WIDTH-1:0] c,
    output wire [WIDTH-1:0] sum,
    output wire [WIDTH-1:0] carry
);
    assign sum = a ^ b ^ c;
    assign carry = ((a & b) | (a & c) | (b & c)) << 1; // Shift carry out
endmodule


// --- Leading Zero/One Counter (for Adaptive Width Concept) ---
// Counts leading zeros for positive numbers, leading ones for negative
// ** Corrected for Verilog-2001 Synthesis (removed break) **
module lzc32 (
    input wire signed [31:0] data_in,
    output reg [4:0] leading_bits // Output: Number of leading zeros/ones (0-31)
);
    integer i;
    wire sign_bit = data_in[31];
    reg found_diff; // Flag to indicate if the first differing bit was found

    always @(*) begin
        leading_bits = 5'd31; // Default: assume all bits match sign bit (covers 0 and -1 initially)
        found_diff = 1'b0;    // Reset flag for each calculation

        // Iterate from MSB-1 down to LSB
        for (i = 30; i >= 0; i = i - 1) begin
            // Check if a differing bit is found AND we haven't found one before
            if (data_in[i] != sign_bit && !found_diff) begin
                leading_bits = 31 - (i + 1); // Calculate leading bits count
                found_diff = 1'b1;          // Set the flag, subsequent diffs ignored
            end
        end
        // Note: The default value of 31 correctly handles the cases where
        // data_in is 0 or -1, as the loop will complete without found_diff becoming true.
        // Explicit checks for 0 and -1 after the loop are redundant here but harmless.
        // if (data_in == 32'b0 || data_in == 32'hFFFFFFFF) begin
        //     leading_bits = 5'd31;
        // end
    end
endmodule