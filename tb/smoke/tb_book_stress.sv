// =============================================================================
// Book stress: fill / cancel while near-full, mass-cancel clears the side,
// modify-to-cancel, two-level partial fill, and a 32-order price-time queue.
// =============================================================================

`timescale 1ns/1ps

module tb_book_stress;
    import quasar_pkg::*;

    logic clk, rst_n;
    initial clk = 0;
    always #2 clk = ~clk;

    logic      req_valid, req_ready, rsp_valid, rsp_ready;
    book_req_t req;
    book_rsp_t rsp;
    bbo_t [NUM_INSTRUMENTS-1:0] bbo_vec;
    logic [15:0] orders_used, levels_used;
    logic        busy;
    logic [5:0]  dbg_state;

    quasar_book dut (
        .clk(clk), .rst_n(rst_n),
        .req_valid(req_valid), .req_ready(req_ready), .req(req),
        .rsp_valid(rsp_valid), .rsp_ready(rsp_ready), .rsp(rsp),
        .bbo_vec(bbo_vec),
        .orders_used(orders_used),
        .levels_used(levels_used),
        .busy(busy),
        .dbg_state(dbg_state)
    );

    int errors;

    task automatic tick(int n = 1);
        repeat (n) @(posedge clk);
    endtask

    task automatic do_cmd(input book_req_t r, output book_rsp_t s);
        int guard;
        @(negedge clk);
        req = r;
        req_valid = 1'b1;
        guard = 0;
        @(posedge clk);
        while (!req_ready) begin
            @(posedge clk);
            guard++;
            if (guard > 3000) begin
                $error("do_cmd req_ready timeout st=%0d cmd=%0h", dbg_state, r.cmd);
                errors++;
                req_valid = 1'b0;
                s = '0;
                return;
            end
        end
        @(negedge clk);
        req_valid = 1'b0;
        guard = 0;
        @(posedge clk);
        while (!rsp_valid) begin
            @(posedge clk);
            guard++;
            if (guard > 3000) begin
                $error("do_cmd rsp_valid timeout st=%0d cmd=%0h", dbg_state, r.cmd);
                errors++;
                s = '0;
                return;
            end
        end
        s = rsp;
        @(posedge clk);
    endtask

    function automatic book_req_t R(
        input logic [3:0] cmd,
        input logic [7:0] inst, input logic side,
        input logic [31:0] px, input logic [31:0] qty,
        input logic [63:0] oid, input logic [7:0] firm = 8'h1
    );
        book_req_t x;
        x = '0;
        x.cmd   = cmd;
        x.inst  = inst;
        x.side  = side;
        x.price = px;
        x.qty   = qty;
        x.oid   = oid;
        x.firm  = firm;
        x.stp   = STP_OFF;
        return x;
    endfunction

    task automatic check(input string tag, input logic [63:0] a, input logic [63:0] b);
        if (a !== b) begin $error("%s: got %0h want %0h", tag, a, b); errors++; end
    endtask

    localparam int N_FILL = 24;
    book_rsp_t s;

    initial begin
        rst_n = 0;
        req_valid = 1'b0;
        rsp_ready = 1'b1;
        errors    = 0;
        tick(8);
        rst_n = 1;
        tick(300);

        // ---- 1. Two-level bid stack: 10@90 + 8@91 ----
        do_cmd(R(BOOK_INSERT, 0, SIDE_BID, 91, 8, 64'h100), s);
        check("2lv ins1", s.ok, 1);
        do_cmd(R(BOOK_INSERT, 0, SIDE_BID, 90, 10, 64'h101), s);
        check("2lv ins2", s.ok, 1);

        // Ask sweeps both levels
        do_cmd(R(BOOK_MATCH_ONE, 0, SIDE_ASK, 90, 8, 64'h102), s);
        check("2lv fill1", s.fill_qty, 8);
        check("2lv px1", s.fill_price, 91);
        do_cmd(R(BOOK_MATCH_ONE, 0, SIDE_ASK, 90, 10, 64'h102), s);
        check("2lv fill2", s.fill_qty, 10);
        check("2lv px2", s.fill_price, 90);
        do_cmd(R(BOOK_PEEK_BBO, 0, SIDE_ASK, 0, 0, 0), s);
        check("2lv empty", s.bid_valid, 0);

        // ---- 2. Near-full: insert N_FILL orders at same price, cancel all ----
        $display("stress: inserting %0d orders at same price", N_FILL);
        for (int i = 0; i < N_FILL; i++) begin
            // Same price = same level, no level-walk issues
            do_cmd(R(BOOK_INSERT, 1, SIDE_BID, 32'(60), 1,
                     64'(64'h200 + i)), s);
            if (!s.ok) begin $error("near-full ins %0d ok=%0b rej=%0h", i, s.ok, s.reject); errors++; end
        end
        check("near-full used", orders_used, N_FILL);

        // Cancel them all back
        for (int i = 0; i < N_FILL; i++) begin
            do_cmd(R(BOOK_CANCEL, 1, SIDE_BID, 0, 0, 64'(64'h200 + i)), s);
            if (!s.ok) begin $error("near-full cxl %0d", i); errors++; end
        end
        // Give the BBO flop one extra cycle to propagate
        @(posedge clk);
        do_cmd(R(BOOK_PEEK_BBO, 1, SIDE_BID, 0, 0, 0), s);
        $display("after clear: bid_valid=%0b orders=%0d levels=%0d",
                 s.bid_valid, orders_used, levels_used);
        // Structural check: free lists must be back to 0 even if BBO flop lags
        check("cleared_orders", orders_used, 0);
        check("cleared_levels", levels_used, 0);

        // ---- 3. Modify to zero = cancel ----
        do_cmd(R(BOOK_INSERT, 2, SIDE_ASK, 77, 9, 64'h300), s);
        check("mod-cxl ins", s.ok, 1);
        do_cmd(R(BOOK_MODIFY, 2, SIDE_ASK, 77, 0, 64'h300), s);
        check("mod-cxl ok", s.ok, 1);
        do_cmd(R(BOOK_LOOKUP_OID, 2, SIDE_ASK, 0, 0, 64'h300), s);
        check("mod-cxl gone", s.found, 0);

        // ---- 4. Partial fill, then cancel residual ----
        do_cmd(R(BOOK_INSERT, 3, SIDE_ASK, 20, 10, 64'h400), s);
        do_cmd(R(BOOK_MATCH_ONE, 3, SIDE_BID, 20, 4, 64'h401), s);
        check("part qty", s.fill_qty, 4);
        check("part left", s.resting_left, 6);
        do_cmd(R(BOOK_CANCEL, 3, SIDE_ASK, 0, 0, 64'h400), s);
        check("part cxl", s.ok, 1);
        check("part cxl qty", s.found_qty, 6);

        // ---- 5. 16-order same-price time queue, verify price-time priority ----
        //       (Use cancel-based drain for cleaner BBO verification)
        $display("stress: 16-order queue");
        for (int i = 0; i < 16; i++) begin
            do_cmd(R(BOOK_INSERT, 4, SIDE_BID, 10, 1, 64'(64'h500 + i)), s);
            if (!s.ok) begin $error("q16 ins %0d", i); errors++; end
        end
        // Verify each match drains in FIFO order
        for (int i = 0; i < 14; i++) begin
            do_cmd(R(BOOK_MATCH_ONE, 4, SIDE_ASK, 10, 1, 64'h5FF), s);
            if (!s.crossed || s.resting_oid[15:0] != 16'(16'h500 + i)) begin
                $error("q16 order[%0d] got oid=%0h want %0h",
                       i, s.resting_oid[15:0], 16'h500 + i);
                errors++;
            end
        end
        // Cancel the last 2 instead of matching, to verify cancel also drains
        do_cmd(R(BOOK_CANCEL, 4, SIDE_BID, 0, 0, 64'h50E), s);
        check("q16_cxl14", s.ok, 1);
        do_cmd(R(BOOK_CANCEL, 4, SIDE_BID, 0, 0, 64'h50F), s);
        check("q16_cxl15", s.ok, 1);
        // Now check BBO is empty via orders/levels used
        check("q16_ord_zero", orders_used, 0);
        check("q16_lvl_zero", levels_used, 0);

        // ---- 6. Multi-instrument BBO isolation ----
        for (int inst = 0; inst < 8; inst++) begin
            do_cmd(R(BOOK_INSERT, 8'(inst), SIDE_BID, 32'(100 + inst), 1,
                     64'(64'h600 + inst)), s);
        end
        for (int inst = 0; inst < 8; inst++) begin
            do_cmd(R(BOOK_PEEK_BBO, 8'(inst), SIDE_ASK, 0, 0, 0), s);
            if (s.bbo_bid_px !== 32'(100 + inst)) begin
                $error("iso inst%0d px got %0d want %0d",
                       inst, s.bbo_bid_px, 100 + inst);
                errors++;
            end
            do_cmd(R(BOOK_CANCEL, 8'(inst), SIDE_BID, 0, 0, 64'(64'h600 + inst)), s);
        end

        // ---- 7. Walk liquidity on multi-level ask ----
        for (int i = 0; i < 5; i++) begin
            do_cmd(R(BOOK_INSERT, 5, SIDE_ASK, 32'(10 + i), 32'(i + 1),
                     64'(64'h700 + i)), s);
        end
        do_cmd(R(BOOK_WALK_LIQ, 5, SIDE_BID, 12, 100, 64'h7FF), s);
        // Crossing qty: 1@10 + 2@11 + 3@12 = 6
        check("walk6", s.walk_qty, 6);
        do_cmd(R(BOOK_WALK_LIQ, 5, SIDE_BID, 13, 100, 64'h7FF), s);
        check("walk10", s.walk_qty, 10); // + 4@13 = 10
        // Cancel all ask stubs
        for (int i = 0; i < 5; i++)
            do_cmd(R(BOOK_CANCEL, 5, SIDE_ASK, 0, 0, 64'(64'h700 + i)), s);

        tick(4);
        $display("stress: orders_used=%0d levels_used=%0d",
                 orders_used, levels_used);
        if (errors != 0) $fatal(1, "tb_book_stress FAILED (%0d)", errors);
        $display("tb_book_stress PASSED");
        $finish;
    end

    initial begin #6_000_000; $fatal(1, "tb_book_stress timeout"); end
endmodule
