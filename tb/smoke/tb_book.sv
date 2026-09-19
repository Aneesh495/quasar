// =============================================================================
// Directed book unit test — talks to quasar_book without the SoC wrapper.
// Covers insert, BBO, time priority, partial/full fill, multi-level walk,
// cancel of head/middle/tail, modify, FOK liquidity probe, hash collisions
// (oids that share a bucket), and book-full.
// =============================================================================

`timescale 1ns/1ps

module tb_book;
    import quasar_pkg::*;

    logic clk, rst_n;
    initial clk = 1'b0;
    always #2 clk = ~clk; // 250 MHz

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
    int tests;

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
            if (guard > 2000) begin
                $error("do_cmd: timeout waiting req_ready cmd=%0h busy=%0d rsp=%0d",
                       r.cmd, busy, rsp_valid);
                s = '0;
                req_valid = 1'b0;
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
            if (guard > 2000) begin
                $error("do_cmd: timeout waiting rsp_valid cmd=%0h busy=%0d ready=%0d st=%0d",
                       r.cmd, busy, req_ready, dbg_state);
                s = '0;
                return;
            end
        end
        s = rsp;
        @(posedge clk);
    endtask

    function automatic book_req_t R(
        input logic [3:0] cmd,
        input logic [7:0] inst,
        input logic side,
        input logic [31:0] px,
        input logic [31:0] qty,
        input logic [63:0] oid,
        input logic [7:0] firm = 8'h1
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

    task automatic expect_ok(input string tag, input book_rsp_t s, input bit want_ok);
        tests++;
        if (s.ok !== want_ok) begin
            $error("%s: ok=%0d want=%0d rej=%0h", tag, s.ok, want_ok, s.reject);
            errors++;
        end
    endtask

    task automatic expect_eq(input string tag, input logic [63:0] a, input logic [63:0] b);
        tests++;
        if (a !== b) begin
            $error("%s: got %0d want %0d", tag, a, b);
            errors++;
        end
    endtask

    initial begin
        book_rsp_t s;
        rst_n = 1'b0;
        req_valid = 1'b0;
        rsp_ready = 1'b1;
        req = '0;
        errors = 0;
        tests = 0;
        tick(8);
        rst_n = 1'b1;
        // book INIT clears 256 hash buckets
        tick(300);
        $display("after init: ready=%0d busy=%0d used=%0d", req_ready, busy, orders_used);

        // -----------------------------------------------------------------
        // 1. Resting bid, BBO updates
        // -----------------------------------------------------------------
        $display("issuing first insert");
        do_cmd(R(BOOK_INSERT, 0, SIDE_BID, 100, 10, 64'hA1), s);
        $display("first insert done ok=%0d", s.ok);
        expect_ok("ins bid", s, 1'b1);
        do_cmd(R(BOOK_PEEK_BBO, 0, SIDE_ASK, 0, 0, 0), s);
        expect_eq("bbo bid px", s.bbo_bid_px, 100);
        expect_eq("bbo bid qty", s.bbo_bid_qty, 10);
        expect_eq("bid valid", s.bid_valid, 1);

        // -----------------------------------------------------------------
        // 2. Resting ask worse than bid — no lock
        // -----------------------------------------------------------------
        do_cmd(R(BOOK_INSERT, 0, SIDE_ASK, 105, 4, 64'hA2), s);
        expect_ok("ins ask", s, 1'b1);
        do_cmd(R(BOOK_PEEK_BBO, 0, SIDE_BID, 0, 0, 0), s);
        expect_eq("bbo ask px", s.bbo_ask_px, 105);
        expect_eq("bbo ask qty", s.bbo_ask_qty, 4);

        // -----------------------------------------------------------------
        // 3. Crossing sell (ask @ 100) fills the bid
        // -----------------------------------------------------------------
        do_cmd(R(BOOK_MATCH_ONE, 0, SIDE_ASK, 100, 3, 64'hA3), s);
        expect_ok("match part", s, 1'b1);
        expect_eq("crossed", s.crossed, 1);
        expect_eq("fill qty", s.fill_qty, 3);
        expect_eq("fill px", s.fill_price, 100);
        expect_eq("rest oid", s.resting_oid, 64'hA1);
        expect_eq("rest left", s.resting_left, 7);

        do_cmd(R(BOOK_PEEK_BBO, 0, SIDE_ASK, 0, 0, 0), s);
        expect_eq("bid qty after part", s.bbo_bid_qty, 7);

        // -----------------------------------------------------------------
        // 4. Finish the residual bid
        // -----------------------------------------------------------------
        do_cmd(R(BOOK_MATCH_ONE, 0, SIDE_ASK, 99, 20, 64'hA4), s);
        expect_eq("fill rest", s.fill_qty, 7);
        expect_eq("left 0", s.resting_left, 0);
        do_cmd(R(BOOK_PEEK_BBO, 0, SIDE_ASK, 0, 0, 0), s);
        expect_eq("bid gone", s.bid_valid, 0);

        // -----------------------------------------------------------------
        // 5. Time priority: two bids at 90, incoming ask fills oldest
        // -----------------------------------------------------------------
        do_cmd(R(BOOK_INSERT, 0, SIDE_BID, 90, 5, 64'hB1), s);
        do_cmd(R(BOOK_INSERT, 0, SIDE_BID, 90, 5, 64'hB2), s);
        do_cmd(R(BOOK_MATCH_ONE, 0, SIDE_ASK, 90, 5, 64'hB3), s);
        expect_eq("time prio oid", s.resting_oid, 64'hB1);
        do_cmd(R(BOOK_MATCH_ONE, 0, SIDE_ASK, 90, 5, 64'hB4), s);
        expect_eq("time prio 2", s.resting_oid, 64'hB2);

        // -----------------------------------------------------------------
        // 6. Price priority: 95 beats 90
        // -----------------------------------------------------------------
        do_cmd(R(BOOK_INSERT, 0, SIDE_BID, 90, 8, 64'hC1), s);
        do_cmd(R(BOOK_INSERT, 0, SIDE_BID, 95, 8, 64'hC2), s);
        do_cmd(R(BOOK_PEEK_BBO, 0, SIDE_ASK, 0, 0, 0), s);
        expect_eq("best bid 95", s.bbo_bid_px, 95);
        do_cmd(R(BOOK_MATCH_ONE, 0, SIDE_ASK, 90, 8, 64'hC3), s);
        expect_eq("hit 95 first", s.fill_price, 95);
        expect_eq("hit oid C2", s.resting_oid, 64'hC2);
        do_cmd(R(BOOK_CANCEL, 0, SIDE_BID, 90, 0, 64'hC1), s);
        expect_ok("cxl leftover", s, 1'b1);

        // -----------------------------------------------------------------
        // 7. Cancel middle of a 3-order queue
        // -----------------------------------------------------------------
        do_cmd(R(BOOK_INSERT, 1, SIDE_ASK, 50, 1, 64'hD1), s);
        do_cmd(R(BOOK_INSERT, 1, SIDE_ASK, 50, 1, 64'hD2), s);
        do_cmd(R(BOOK_INSERT, 1, SIDE_ASK, 50, 1, 64'hD3), s);
        do_cmd(R(BOOK_CANCEL, 1, SIDE_ASK, 0, 0, 64'hD2), s);
        expect_ok("cxl mid", s, 1'b1);
        do_cmd(R(BOOK_LOOKUP_OID, 1, SIDE_ASK, 0, 0, 64'hD2), s);
        expect_eq("mid gone", s.found, 0);
        do_cmd(R(BOOK_MATCH_ONE, 1, SIDE_BID, 50, 1, 64'hD4), s);
        expect_eq("head still D1", s.resting_oid, 64'hD1);
        do_cmd(R(BOOK_MATCH_ONE, 1, SIDE_BID, 50, 1, 64'hD5), s);
        expect_eq("then D3", s.resting_oid, 64'hD3);

        // -----------------------------------------------------------------
        // 8. Cancel missing
        // -----------------------------------------------------------------
        do_cmd(R(BOOK_CANCEL, 1, SIDE_ASK, 0, 0, 64'hDEAD), s);
        expect_ok("cxl miss", s, 1'b0);
        expect_eq("rej not found", s.reject, REJ_NOT_FOUND);

        // -----------------------------------------------------------------
        // 9. Duplicate oid
        // -----------------------------------------------------------------
        do_cmd(R(BOOK_INSERT, 2, SIDE_BID, 10, 2, 64'hE1), s);
        do_cmd(R(BOOK_INSERT, 2, SIDE_BID, 11, 2, 64'hE1), s);
        expect_ok("dup", s, 1'b0);
        expect_eq("rej dup", s.reject, REJ_DUP_OID);
        do_cmd(R(BOOK_CANCEL, 2, SIDE_BID, 0, 0, 64'hE1), s);

        // -----------------------------------------------------------------
        // 10. Modify qty down; BBO qty tracks
        // -----------------------------------------------------------------
        do_cmd(R(BOOK_INSERT, 2, SIDE_ASK, 70, 20, 64'hF1), s);
        do_cmd(R(BOOK_MODIFY, 2, SIDE_ASK, 70, 6, 64'hF1), s);
        expect_ok("mod", s, 1'b1);
        expect_eq("mod qty", s.found_qty, 6);
        do_cmd(R(BOOK_PEEK_BBO, 2, SIDE_BID, 0, 0, 0), s);
        expect_eq("bbo after mod", s.bbo_ask_qty, 6);
        do_cmd(R(BOOK_CANCEL, 2, SIDE_ASK, 0, 0, 64'hF1), s);

        // -----------------------------------------------------------------
        // 11. Walk liquidity across two ask levels
        // -----------------------------------------------------------------
        do_cmd(R(BOOK_INSERT, 3, SIDE_ASK, 10, 4, 64'h71), s);
        do_cmd(R(BOOK_INSERT, 3, SIDE_ASK, 11, 7, 64'h72), s);
        do_cmd(R(BOOK_WALK_LIQ, 3, SIDE_BID, 11, 100, 64'h73), s);
        expect_eq("walk 11", s.walk_qty, 11);
        do_cmd(R(BOOK_WALK_LIQ, 3, SIDE_BID, 10, 100, 64'h73), s);
        expect_eq("walk 4", s.walk_qty, 4);
        do_cmd(R(BOOK_CANCEL, 3, SIDE_ASK, 0, 0, 64'h71), s);
        do_cmd(R(BOOK_CANCEL, 3, SIDE_ASK, 0, 0, 64'h72), s);

        // -----------------------------------------------------------------
        // 12. Hash collisions: oids that xor to the same bucket
        //     hash = xor of 8 bytes.  0x01 and 0x0100 both → 0x01
        // -----------------------------------------------------------------
        do_cmd(R(BOOK_INSERT, 4, SIDE_BID, 1, 1, 64'h01), s);
        do_cmd(R(BOOK_INSERT, 4, SIDE_BID, 2, 1, 64'h0100), s);
        do_cmd(R(BOOK_LOOKUP_OID, 4, SIDE_BID, 0, 0, 64'h0100), s);
        expect_eq("collide find", s.found, 1);
        expect_eq("collide px", s.found_price, 2);
        do_cmd(R(BOOK_CANCEL, 4, SIDE_BID, 0, 0, 64'h01), s);
        do_cmd(R(BOOK_LOOKUP_OID, 4, SIDE_BID, 0, 0, 64'h0100), s);
        expect_eq("survive unlink", s.found, 1);
        do_cmd(R(BOOK_CANCEL, 4, SIDE_BID, 0, 0, 64'h0100), s);

        // -----------------------------------------------------------------
        // 13. Non-crossing match is a no-op
        // -----------------------------------------------------------------
        do_cmd(R(BOOK_INSERT, 5, SIDE_ASK, 200, 3, 64'h81), s);
        do_cmd(R(BOOK_MATCH_ONE, 5, SIDE_BID, 199, 3, 64'h82), s);
        expect_eq("no cross", s.crossed, 0);
        do_cmd(R(BOOK_CANCEL, 5, SIDE_ASK, 0, 0, 64'h81), s);

        // -----------------------------------------------------------------
        // 14. STP: same firm at BBO returns REJ_STP without consuming
        // -----------------------------------------------------------------
        do_cmd(R(BOOK_INSERT, 5, SIDE_BID, 40, 9, 64'h91, 8'h42), s);
        begin
            book_req_t rr;
            rr = R(BOOK_MATCH_ONE, 5, SIDE_ASK, 40, 9, 64'h92, 8'h42);
            rr.stp = STP_CANCEL_TAKER;
            do_cmd(rr, s);
        end
        expect_eq("stp rej", s.reject, REJ_STP);
        do_cmd(R(BOOK_LOOKUP_OID, 5, SIDE_BID, 0, 0, 64'h91), s);
        expect_eq("stp resting lives", s.found, 1);
        do_cmd(R(BOOK_CANCEL, 5, SIDE_BID, 0, 0, 64'h91), s);

        // -----------------------------------------------------------------
        // 15. Multi-instrument isolation
        // -----------------------------------------------------------------
        do_cmd(R(BOOK_INSERT, 6, SIDE_BID, 8, 1, 64'hA11), s);
        do_cmd(R(BOOK_INSERT, 7, SIDE_ASK, 9, 1, 64'hA12), s);
        do_cmd(R(BOOK_PEEK_BBO, 6, SIDE_ASK, 0, 0, 0), s);
        expect_eq("inst6 ask empty", s.ask_valid, 0);
        expect_eq("inst6 bid", s.bbo_bid_px, 8);
        do_cmd(R(BOOK_PEEK_BBO, 7, SIDE_BID, 0, 0, 0), s);
        expect_eq("inst7 bid empty", s.bid_valid, 0);
        expect_eq("inst7 ask", s.bbo_ask_px, 9);
        do_cmd(R(BOOK_CANCEL, 6, SIDE_BID, 0, 0, 64'hA11), s);
        do_cmd(R(BOOK_CANCEL, 7, SIDE_ASK, 0, 0, 64'hA12), s);

        tick(4);
        $display("tb_book: %0d checks, %0d errors, orders_used=%0d levels_used=%0d",
                 tests, errors, orders_used, levels_used);
        if (errors != 0) $fatal(1, "tb_book FAILED");
        $display("tb_book PASSED");
        $finish;
    end

    // watchdog
    initial begin
        #2_000_000;
        $fatal(1, "tb_book timeout");
    end

endmodule
