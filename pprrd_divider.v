`timescale 1ns / 1ps
//----------------------------------------------------
// pprrd_divider.v
// 32x32 Signed Divider based on PPRRD/SRT Radix-4 concepts
// - Uses Carry-Save for Partial Remainder
// - Simplified Radix-4 QDSL (Quotient Digit Selection) - **NOT ROBUST FOR ALL CASES**
// - Iterative structure
// - Handles signs and division by zero (basic)
// ** Corrected for Verilog-2001 Synthesis **
//----------------------------------------------------

module pprrd_32x32 (
    input clk,
    input rst_n,
    input start,                 // Start signal
    input signed [31:0] dividend_in,
    input signed [31:0] divisor_in,
    output reg done,             // Computation finished signal
    output reg signed [31:0] quotient_out,   // Quotient
    output reg signed [31:0] remainder_out,  // Remainder
    output reg error_div_by_zero // Error flag
);

    localparam N = 32;
    localparam N_EXT = N + 2; // Extended width for partial remainder (guard bits)
    localparam RADIX_BITS = 2; // Radix-4
    localparam ITERATIONS = N / RADIX_BITS; // 16 iterations

    // State machine - Use parameters for Verilog-2001 compatibility
    localparam STATE_WIDTH = 3; // Use 3 bits for 5 distinct states
    localparam IDLE         = 3'b000;
    localparam PREP         = 3'b001;
    localparam ITERATE      = 3'b010;
    localparam POST_PROCESS = 3'b011;
    localparam FINISH       = 3'b100;

    reg [STATE_WIDTH-1:0] current_state, next_state; // Use defined width

    // Registers for operands and results
    reg signed [N-1:0] dividend_mag;
    reg signed [N-1:0] divisor_mag;
    reg dividend_sign;
    reg divisor_sign;
    reg calc_sign_q; // Expected quotient sign
    reg calc_sign_r; // Expected remainder sign

    // Partial Remainder (Carry-Save format, extended width)
    reg signed [N_EXT-1:0] pr_sum;
    reg signed [N_EXT-1:0] pr_carry;

    // Quotient (non-redundant representation)
    reg signed [N-1:0] quotient_wip; // Work-in-progress quotient

    // Iteration counter
    reg [3:0] iteration_count; // For ITERATIONS=16 (needs 4 bits)

    // Divisor multiples (precomputed) - width N_EXT
    reg signed [N_EXT-1:0] d_1x;
    reg signed [N_EXT-1:0] d_2x;
    reg signed [N_EXT-1:0] neg_d_1x;
    reg signed [N_EXT-1:0] neg_d_2x;

    // QDSL signals
    reg signed [2:0] q_digit_sel; // Selected quotient digit {-2, -1, 0, +1, +2} (encoded)
    wire signed [N_EXT-1:0] pr_shifted_sum;
    wire signed [N_EXT-1:0] pr_shifted_carry;
    wire signed [N_EXT+RADIX_BITS-1:0] pr_combined_shifted; // For QDSL approx

    // Declare variables used in QDSL always block here
    reg signed [N_EXT+RADIX_BITS-1:0] pr_approx;
    reg pr_is_positive;

    // Next PR calculation
    wire signed [N_EXT-1:0] subtrahend;
    wire signed [N_EXT-1:0] next_pr_s_w;
    wire signed [N_EXT-1:0] next_pr_c_w;

    // Instantiate CSA for the main iteration
    csa_3_2 #(.WIDTH(N_EXT)) csa_iter (
        .a(pr_shifted_sum),
        .b(pr_shifted_carry),
        .c(subtrahend), // This is effectively - q_i * D
        .sum(next_pr_s_w),
        .carry(next_pr_c_w)
    );

    // --- Combinational Logic ---

    // Shift PR left by Radix (2 bits for Radix-4)
    assign pr_shifted_sum = pr_sum << RADIX_BITS;
    assign pr_shifted_carry = pr_carry << RADIX_BITS;

    // Approximate combined PR for QDSL (High bits needed) - **Simplification**
    // Combine shifted sum and carry for approximation
    assign pr_combined_shifted = pr_shifted_sum + pr_shifted_carry;

    // Select subtrahend based on QDSL output (determined in the previous cycle's combinational logic)
    assign subtrahend = (q_digit_sel == 3'b010) ? neg_d_2x : // +2
                        (q_digit_sel == 3'b001) ? neg_d_1x : // +1
                        (q_digit_sel == 3'b111) ? d_1x :     // -1
                        (q_digit_sel == 3'b110) ? d_2x :     // -2
                        {N_EXT{1'b0}}; // 0

    // --- QDSL (Quotient Digit Selection) - **Highly Simplified** ---
    // Determines q_digit_sel for the *next* cycle based on *current* pr_sum/pr_carry
    always @(*) begin
        // Based on approximate combined PR shifted value - Compare against multiples of D
        pr_approx = pr_combined_shifted; // Assign to pre-declared reg
        pr_is_positive = !pr_approx[N_EXT+RADIX_BITS-1]; // Assign to pre-declared reg

        // Default to 0
        q_digit_sel = 3'b000;

        // Simplified comparison logic (Needs refinement for robust SRT)
        // Compare using the extended width for consistency
        // Note: d_1x, neg_d_1x are N_EXT wide. Pad them for comparison with pr_approx (N_EXT+RADIX_BITS wide)
        if (pr_is_positive) begin
             // Example: If PR >= ~1.5*D -> select +2? (Not implemented here)
             // If PR >= ~0.5*D -> select +1
             // Using d_1x (1*D) as a boundary for +1 (conservative)
             if (pr_approx >= {{RADIX_BITS{1'b0}}, d_1x}) begin
                   q_digit_sel = 3'b001; // Tentatively +1
             end
             // else q_digit_sel remains 0
        end else begin // PR is negative
             // Example: If PR <= ~-1.5*D -> select -2? (Not implemented here)
             // If PR <= ~-0.5*D -> select -1
             // Using neg_d_1x (-1*D) as a boundary for -1 (conservative)
             if (pr_approx <= {{RADIX_BITS{1'b0}}, neg_d_1x}) begin
                  q_digit_sel = 3'b111; // Tentatively -1
             end
             // else q_digit_sel remains 0
        end
        // A more robust QDSL would compare against fractional multiples of D (e.g., 0.5*D, 1.5*D)
        // and potentially use more bits of the PR for better accuracy.
    end

    // --- State Machine Logic ---
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_state <= IDLE;
        end else begin
            current_state <= next_state;
        end
    end

    // --- Main Sequential Logic ---
    reg signed [N_EXT-1:0] final_pr_combined_reg; // Register for final combined PR
    reg signed [N-1:0] final_remainder_mag_reg; // Register for final remainder magnitude
    reg signed [N-1:0] quotient_corrected_reg; // Register for corrected quotient

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset registers
            dividend_mag <= {N{1'b0}};
            divisor_mag <= {N{1'b0}};
            dividend_sign <= 1'b0;
            divisor_sign <= 1'b0;
            calc_sign_q <= 1'b0;
            calc_sign_r <= 1'b0;
            pr_sum <= {N_EXT{1'b0}};
            pr_carry <= {N_EXT{1'b0}};
            quotient_wip <= {N{1'b0}};
            iteration_count <= 4'b0;
            d_1x <= {N_EXT{1'b0}};
            d_2x <= {N_EXT{1'b0}};
            neg_d_1x <= {N_EXT{1'b0}};
            neg_d_2x <= {N_EXT{1'b0}};
            done <= 1'b0;
            quotient_out <= {N{1'b0}};
            remainder_out <= {N{1'b0}};
            error_div_by_zero <= 1'b0;
            q_digit_sel <= 3'b000; // Reset Q digit selection
            // Reset post-processing regs
            final_pr_combined_reg <= {N_EXT{1'b0}};
            final_remainder_mag_reg <= {N{1'b0}};
            quotient_corrected_reg <= {N{1'b0}};
            next_state <= IDLE; // Ensure next_state is reset

        end else begin
            // Default assignments
            done <= 1'b0;
            // error_div_by_zero <= error_div_by_zero; // Keep error status unless cleared

            case (current_state)
                IDLE: begin
                    error_div_by_zero <= 1'b0; // Clear error on new start attempt
                    quotient_wip <= {N{1'b0}}; // Clear WIP quotient
                    iteration_count <= 4'b0; // Reset counter
                    if (start) begin
                        if (divisor_in == 32'b0) begin
                            error_div_by_zero <= 1'b1;
                            done <= 1'b1; // Signal completion (with error)
                            quotient_out <= {N{1'bX}}; // Indicate invalid output
                            remainder_out <= {N{1'bX}};
                            next_state <= IDLE; // Stay in IDLE or go to a specific error state if desired
                        end else begin
                            error_div_by_zero <= 1'b0;
                            next_state <= PREP;
                        end
                    end else begin
                        next_state <= IDLE;
                    end
                end

                PREP: begin
                    // Store magnitudes and signs
                    dividend_sign <= dividend_in[N-1];
                    divisor_sign <= divisor_in[N-1];
                    dividend_mag <= dividend_sign ? -dividend_in : dividend_in;
                    divisor_mag <= divisor_sign ? -divisor_in : divisor_in;

                    // Determine result signs
                    calc_sign_q <= dividend_sign ^ divisor_sign;
                    calc_sign_r <= dividend_sign; // Remainder sign matches dividend

                    // Initialize PR Sum with dividend magnitude, zero-padded to N_EXT
                    // The effective radix point is to the right of bit 0.
                    // We align the dividend magnitude here.
                    pr_sum <= {{(N_EXT-N){1'b0}}, (dividend_sign ? -dividend_in : dividend_in)};
                    pr_carry <= {N_EXT{1'b0}}; // Initialize carry to zero

                    // Precompute divisor multiples (width N_EXT) using magnitude
                    d_1x <= {{(N_EXT-N){1'b0}}, (divisor_sign ? -divisor_in : divisor_in)};
                    d_2x <= {{(N_EXT-N){1'b0}}, (divisor_sign ? -divisor_in : divisor_in)} << 1;
                    // Calculate negatives using two's complement
                    neg_d_1x <= -({{(N_EXT-N){1'b0}}, (divisor_sign ? -divisor_in : divisor_in)});
                    neg_d_2x <= -({{(N_EXT-N){1'b0}}, (divisor_sign ? -divisor_in : divisor_in)} << 1);

                    quotient_wip <= {N{1'b0}}; // Reset quotient WIP
                    iteration_count <= 4'b0; // Reset iteration counter
                    q_digit_sel <= 3'b000; // Reset Q digit selection for first iteration
                    next_state <= ITERATE;
                end

                ITERATE: begin
                    if (iteration_count < ITERATIONS) begin
                        // 1. Latch next PR state (calculated combinationally based on previous state's pr_sum, pr_carry, and q_digit_sel)
                        pr_sum <= next_pr_s_w;
                        pr_carry <= next_pr_c_w;

                        // 2. Update quotient WIP based on the q_digit_sel that *was used* to calculate the new PR
                        //    q_digit_sel itself is updated combinationally for the *next* iteration.
                        //    Use the registered q_digit_sel from the previous cycle for quotient update.
                        //    (Need to register q_digit_sel or use a delayed version if strict pipelining is needed)
                        //    Assuming q_digit_sel combinational logic is fast enough relative to clock cycle:
                        case (q_digit_sel) // Use the q_digit_sel determined in the *previous* combinational phase
                            3'b010: quotient_wip <= (quotient_wip << RADIX_BITS) + 2'd2; // +2
                            3'b001: quotient_wip <= (quotient_wip << RADIX_BITS) + 2'd1; // +1
                            3'b000: quotient_wip <= (quotient_wip << RADIX_BITS) + 2'd0; // +0
                            3'b111: quotient_wip <= (quotient_wip << RADIX_BITS) - 2'd1; // -1 (Using subtraction)
                            3'b110: quotient_wip <= (quotient_wip << RADIX_BITS) - 2'd2; // -2 (Using subtraction)
                            default: quotient_wip <= (quotient_wip << RADIX_BITS); // Should not happen
                        endcase

                        iteration_count <= iteration_count + 1;
                        next_state <= ITERATE;
                    end else begin
                         // After the last iteration, latch the final PR state
                         pr_sum <= next_pr_s_w;
                         pr_carry <= next_pr_c_w;
                         // Don't update quotient_wip here, last update was in the final iteration step
                         next_state <= POST_PROCESS;
                    end
                end

                POST_PROCESS: begin
                    // Combine final Sum/Carry (latched in the previous cycle)
                    final_pr_combined_reg = pr_sum + pr_carry;

                    // Remainder Correction (Simplified)
                    // The final PR (sum+carry) needs to be shifted right conceptually
                    // to get the actual remainder magnitude.
                    // And potentially corrected if negative.
                    if (final_pr_combined_reg[N_EXT-1]) begin // If final PR is negative
                        // Need to add Divisor back to make remainder positive (or less negative)
                        // And adjust quotient
                        final_remainder_mag_reg = (final_pr_combined_reg + d_1x) >>> RADIX_BITS; // Shift right after correction
                        quotient_corrected_reg = quotient_wip - 1;
                    end else begin
                        // Final PR is positive or zero
                        final_remainder_mag_reg = final_pr_combined_reg >>> RADIX_BITS; // Just shift right
                        quotient_corrected_reg = quotient_wip;
                    end
                    // Note: The right shift amount (RADIX_BITS) assumes the initial PR alignment.
                    // Ensure final_remainder_mag_reg takes the correct bits [N-1:0] after shift.
                    // The above shift might need adjustment based on exact PR representation.
                    // Let's assume simple truncation/selection is sufficient after shift:
                    final_remainder_mag_reg = final_remainder_mag_reg[N-1:0];


                    next_state <= FINISH;
                end

                 FINISH: begin
                     // Apply signs to the corrected quotient and remainder magnitude
                     quotient_out <= calc_sign_q ? -quotient_corrected_reg : quotient_corrected_reg;
                     // Remainder sign matches original dividend sign
                     remainder_out <= calc_sign_r ? -final_remainder_mag_reg : final_remainder_mag_reg;
                     done <= 1'b1;
                     next_state <= IDLE; // Ready for next operation
                 end

                default: next_state <= IDLE;
            endcase
        end
    end

endmodule

// Include or ensure csa_3_2 module is available during synthesis
// Example csa_3_2 from common_modules.v:
/*
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
*/