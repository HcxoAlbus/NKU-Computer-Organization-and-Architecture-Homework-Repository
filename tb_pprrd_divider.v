//----------------------------------------------------
// tb_pprrd_divider.v
// Revised Testbench for the PPRRD/SRT 32x32 Divider
// - Includes timeout mechanism
// - Corrects start signal handling
// - Includes required modules directly (no `include)
//----------------------------------------------------
`timescale 1ns / 1ps

// --- Common Modules Included Directly ---

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

// --- Testbench Module Definition ---

module tb_pprrd_divider;

    // Parameters
    localparam CLK_PERIOD = 10;
    localparam TIMEOUT_CYCLES = 50; // Max cycles to wait for 'done'

    // Testbench signals
    reg clk;
    reg rst_n;
    reg start;
    reg signed [31:0] tb_dividend_in;
    reg signed [31:0] tb_divisor_in;

    wire done;
    wire signed [31:0] tb_quotient_out;
    wire signed [31:0] tb_remainder_out;
    wire tb_error_div_by_zero;

    // Instantiate the DUT (ensure pprrd_divider.v is compiled alongside)
    pprrd_32x32 dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .dividend_in(tb_dividend_in),
        .divisor_in(tb_divisor_in),
        .done(done),
        .quotient_out(tb_quotient_out),
        .remainder_out(tb_remainder_out),
        .error_div_by_zero(tb_error_div_by_zero)
    );

    // Clock generation
    initial begin
        clk = 0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    // Test sequence
    initial begin
        // Initialize signals and apply reset
        rst_n = 1'b0; // Assert reset
        start = 1'b0;
        tb_dividend_in = 32'b0;
        tb_divisor_in = 32'b0;
        $display("--------------------------------------");
        $display("[%0t] Starting PPRRD Divider Testbench (No Include)", $time);
        $display("--------------------------------------");
        repeat(2) @(posedge clk); // Hold reset for 2 cycles
        rst_n = 1'b1; // Deassert reset
        @(posedge clk); // Wait one cycle after reset release

        // --- Start Test Cases ---

        // Test Case 1: Simple positive
        run_test(32'd100, 32'd10); // Q=10, R=0

        // Test Case 2: Positive with remainder
        run_test(32'd105, 32'd10); // Q=10, R=5

        // Test Case 3: Positive Dividend, Negative Divisor
        run_test(32'd105, -32'd10); // Q=-10, R=5 (Remainder sign matches dividend)

        // Test Case 4: Negative Dividend, Positive Divisor
        run_test(-32'd105, 32'd10); // Q=-10, R=-5

        // Test Case 5: Both Negative
        run_test(-32'd105, -32'd10); // Q=10, R=-5

        // Test Case 6: Dividend smaller than divisor
        run_test(32'd7, 32'd10); // Q=0, R=7

        // Test Case 7: Negative Dividend smaller mag than divisor
        run_test(-32'd7, 32'd10); // Q=0, R=-7

        // Test Case 8: Division by 1
        run_test(32'd12345, 32'd1); // Q=12345, R=0

        // Test Case 9: Division by -1
        run_test(32'd12345, -32'd1); // Q=-12345, R=0
        run_test(-32'd12345, -32'd1); // Q=12345, R=0

        // Test Case 10: Larger numbers
        run_test(32'd200000, 32'd1000); // Q=200, R=0

        // Test Case 11: Division by zero
        run_test(32'd100, 32'd0); // Expect error

        // Test Case 12: Zero dividend
        run_test(32'd0, 32'd10); // Q=0, R=0

        // **Add more difficult SRT test cases if refining QDSL**
        // e.g., cases where PR is very close to a decision boundary

        $display("--------------------------------------");
        $display("[%0t] Testbench Finished", $time);
        $display("--------------------------------------");
        $finish;
    end

    // Task to run a single test case
    task run_test (input signed [31:0] dividend, input signed [31:0] divisor);
        reg signed [31:0] expected_q;
        reg signed [31:0] expected_r;
        reg expected_error;
        integer timeout_count;
        begin
            $display("--------------------");
            $display("[%0t] Test: Dividend = %d (%h), Divisor = %d (%h)", $time, dividend, dividend, divisor, divisor);
            tb_dividend_in = dividend;
            tb_divisor_in = divisor;
            start = 1'b1; // Assert start
            @(posedge clk); // Wait one clock cycle
            start = 1'b0; // Deassert start

            // Wait for done signal or error, with timeout
            timeout_count = 0;
            while (!done && !tb_error_div_by_zero && timeout_count < TIMEOUT_CYCLES) begin
                @(posedge clk);
                timeout_count = timeout_count + 1;
            end

            // Check results after waiting one more cycle for outputs to settle potentially
            @(posedge clk);

            // Calculate expected results
            expected_error = (divisor == 0);
            if (!expected_error) begin
                // Use Verilog built-in operators for expected values
                expected_q = $signed(dividend) / $signed(divisor);
                expected_r = $signed(dividend) % $signed(divisor);

                // Optional: Adjust expected remainder sign if needed based on definition
                // if (expected_r != 0 && dividend[31] != expected_r[31]) begin
                //    if (dividend[31]) begin // Dividend negative
                //        if (!expected_r[31]) expected_r = expected_r - |divisor;
                //    end else begin // Dividend positive
                //        if (expected_r[31]) expected_r = expected_r + |divisor;
                //    end
                //    expected_q = (dividend - expected_r) / divisor;
                // end

            end else begin
                expected_q = 32'bX; // Don't care on error
                expected_r = 32'bX; // Don't care on error
            end

            // Display results and check
            if (timeout_count >= TIMEOUT_CYCLES) begin
                $display("  [%0t] Result: TIMEOUT (FAIL - Done/Error not asserted after %d cycles)", $time, TIMEOUT_CYCLES);
            end else if (tb_error_div_by_zero) begin
                if (expected_error) begin
                    $display("  [%0t] Result: Division by Zero Error (PASS)", $time);
                end else begin
                    $display("  [%0t] Result: Unexpected Division by Zero Error (FAIL)", $time);
                end
            end else if (expected_error) begin
                 $display("  [%0t] Result: Expected Division by Zero Error, but none occurred (FAIL)", $time);
            end else begin
                // Check Quotient and Remainder
                if (tb_quotient_out === expected_q && tb_remainder_out === expected_r) begin
                    $display("  [%0t] Result: Q=%d (%h), R=%d (%h) (PASS)", $time, tb_quotient_out, tb_quotient_out, tb_remainder_out, tb_remainder_out);
                    // Optional: Validate equation: dividend = quotient * divisor + remainder
                    if (dividend !== (tb_quotient_out * divisor + tb_remainder_out)) begin
                         $display("  [%0t] Validation Eq Fail: %d != %d * %d + %d", $time, dividend, tb_quotient_out, divisor, tb_remainder_out);
                    end
                end else begin
                    $display("  [%0t] Result: Q=%d (%h), R=%d (%h) (FAIL)", $time, tb_quotient_out, tb_quotient_out, tb_remainder_out, tb_remainder_out);
                    $display("                Expected: Q=%d (%h), R=%d (%h)", expected_q, expected_q, expected_r, expected_r);
                end
            end
            $display("--------------------");
            // Add a small delay between tests for clarity in waveforms
            repeat(2) @(posedge clk);
        end
    endtask

endmodule