//----------------------------------------------------
// tb_sabcm_multiplier.v
// Testbench for the SABCM 32x32 Multiplier
//----------------------------------------------------
`timescale 1ns / 1ps

module tb_sabcm_multiplier;

    // Parameters
    localparam CLK_PERIOD = 10;

    // Testbench signals
    reg clk;
    reg rst_n;
    reg start;
    reg signed [31:0] tb_operand_a;
    reg signed [31:0] tb_operand_b;

    wire done;
    wire signed [63:0] tb_product_out;
    wire [4:0] tb_op_a_leading_bits;
    wire [4:0] tb_op_b_leading_bits;

    // Instantiate the DUT
    sabcm_32x32 dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .operand_a(tb_operand_a),
        .operand_b(tb_operand_b),
        .done(done),
        .product_out(tb_product_out),
        .op_a_leading_bits(tb_op_a_leading_bits),
        .op_b_leading_bits(tb_op_b_leading_bits)
    );

    // Clock generation
    initial begin
        clk = 0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    // Test sequence
    initial begin
        rst_n = 0;
        start = 0;
        tb_operand_a = 0;
        tb_operand_b = 0;
        $display("--------------------------------------");
        $display(" Starting SABCM Multiplier Testbench ");
        $display("--------------------------------------");
        # (CLK_PERIOD * 2);
        rst_n = 1;
        # (CLK_PERIOD);

        // Test Case 1: Small positive numbers
        run_test(32'd12, 32'd10);

        // Test Case 2: Positive and Negative
        run_test(32'd50, -32'd5);

        // Test Case 3: Negative and Positive
        run_test(-32'd7, 32'd8);

        // Test Case 4: Both negative
        run_test(-32'd9, -32'd11);

        // Test Case 5: Zero
        run_test(32'd12345, 32'd0);
        run_test(32'd0, -32'd54321);

        // Test Case 6: Larger numbers
        run_test(32'd100000, 32'd20000);

        // Test Case 7: Max positive * small positive
        run_test(32'h7FFFFFFF, 32'd2);

        // Test Case 8: Min negative * small positive
        run_test(32'h80000000, 32'd3); // Be careful with expected result size

        // Test Case 9: Max positive * Max positive (will overflow standard signed 64 bit if not careful)
        // run_test(32'h7FFFFFFF, 32'h7FFFFFFF); // Requires careful handling of expected result

        // Test Case 10: Min negative * Min negative
        run_test(32'h80000000, 32'h80000000);

         // Test Case 11: Small numbers demonstrating LZC
        run_test(32'd5, 32'd3); // Expect many leading zeros

        $display("--------------------------------------");
        $display(" Testbench Finished ");
        $display("--------------------------------------");
        $finish;
    end

    // Task to run a single test case
    task run_test (input signed [31:0] a, input signed [31:0] b);
        reg signed [63:0] expected_product;
        integer timeout_count; // For done signal timeout
        localparam MAX_TIMEOUT_CYCLES = 100; // Adjust as needed

        begin
            // 1. Apply inputs while start is low
            start = 0;
            tb_operand_a = a;
            tb_operand_b = b;
            @(posedge clk); // Wait one clock cycle for inputs to settle

            // 2. Assert start for one full clock cycle
            start = 1;
            @(posedge clk); // DUT should detect start rising edge here (start=1, start_reg=0)

            // 3. De-assert start
            start = 0;

            // 4. Wait for 'done' signal with timeout
            $display("Waiting for DUT: A = %d, B = %d", a, b);
            timeout_count = 0;
            while (!done && timeout_count < MAX_TIMEOUT_CYCLES) begin
                @(posedge clk);
                timeout_count = timeout_count + 1;
            end

            // 5. Check results
            if (!done) begin // Check if timeout occurred
                $display("TIMEOUT waiting for done signal!");
                // You might want to add $stop here to halt simulation on timeout
                // $stop;
            end else begin
                // Optional: Wait one more cycle if outputs register on 'done' assertion cycle
                // @(posedge clk);

                expected_product = $signed(a) * $signed(b);

                $display("Test: A = %d (%d lz), B = %d (%d lz)", a, tb_op_a_leading_bits, b, tb_op_b_leading_bits);
                if (tb_product_out === expected_product) begin
                    $display("  Result: %d (PASS)", tb_product_out);
                end else begin
                    $display("  Result: %d (FAIL - Expected: %d)", tb_product_out, expected_product);
                end
            end

            // 6. Delay before next test
            # (CLK_PERIOD * 2);
        end
    endtask

endmodule
