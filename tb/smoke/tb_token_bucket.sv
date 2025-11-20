// Directed test for quasar_token_bucket.

`timescale 1ns/1ps

module tb_token_bucket;
    logic clk, rst_n;
    initial clk = 0;
    always #2 clk = ~clk;

    logic [15:0] capacity, window;
    logic        consume_en;
    logic [15:0] consume_qty;
    logic [15:0] tokens;
    logic        blocked;
    logic        soft_rst;

    quasar_token_bucket #(.WIDTH(16)) dut (
        .clk(clk), .rst_n(rst_n), .soft_rst(soft_rst),
        .capacity(capacity), .window(window),
        .consume_en(consume_en), .consume_qty(consume_qty),
        .tokens(tokens), .blocked(blocked)
    );

    int errors;

    task automatic tick(int n = 1); repeat (n) @(posedge clk); endtask

    initial begin
        rst_n = 0;
        capacity = 0; window = 0; consume_en = 0; consume_qty = 1; soft_rst = 0;
        errors = 0;
        tick(4);
        rst_n = 1;
        tick(2);

        // Disabled: consume never blocks
        consume_en = 1; consume_qty = 1;
        tick(4);
        if (blocked) begin $error("disabled should not block"); errors++; end
        consume_en = 0;

        // Enable with capacity=4, window=32 (long window to avoid refill during test)
        capacity = 16'd4; window = 16'd32;
        soft_rst = 1; tick(1); soft_rst = 0;
        // After soft_rst, tokens = capacity = 4
        tick(2);
        if (tokens != 16'd4) begin $error("post_soft_rst tokens=%0d want 4", tokens); errors++; end

        // Consume 4 in a row → tokens hits 0
        consume_en = 1; consume_qty = 1;
        tick(4);
        consume_en = 0;
        tick(1);
        if (tokens != 16'd0) begin $error("after 4 consume tokens=%0d want 0", tokens); errors++; end

        // One more consume attempt should see blocked
        @(negedge clk);
        consume_en = 1;
        @(posedge clk);
        if (!blocked) begin
            $error("should be blocked tokens=%0d cap=%0d", tokens, capacity);
            errors++;
        end
        @(negedge clk);
        consume_en = 0;

        // Wait for window refill: poll until refill arrives (≤ 40 more cycles)
        begin
            automatic int wait_cnt = 0;
            while (tokens == 16'd0 && wait_cnt < 50) begin @(posedge clk); wait_cnt++; end
        end
        if (tokens != 16'd4) begin $error("after refill tokens=%0d want 4", tokens); errors++; end

        // Partial consume (qty=2)
        @(negedge clk);
        consume_en = 1; consume_qty = 2;
        @(posedge clk);
        @(negedge clk);
        consume_en = 0;
        tick(2);
        // After taking 2 from the refilled bucket (tokens was 4), should be 2
        if (tokens < 16'd2) begin $error("partial consume tokens=%0d", tokens); errors++; end

        if (errors) $fatal(1, "tb_token_bucket FAILED");
        $display("tb_token_bucket PASSED");
        $finish;
    end
endmodule
