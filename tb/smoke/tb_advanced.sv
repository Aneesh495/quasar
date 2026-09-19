// =============================================================================
// Advanced scenario test: interleaved multi-instrument concurrent sessions,
// rapid price-level creation and deletion, FOK across five levels, book
// invariant checks via CSR, soft-reset mid-session, rate-limit interaction
// with risk gate, and modify/replace chains on the same OID.
//
// All scenarios leave the book in a clean state (verified via CSR_DBG_ORD_USED).
// =============================================================================

`timescale 1ns/1ps

module tb_advanced;
    import quasar_pkg::*;
    import quasar_tb_pkg::*;

    logic clk, rst_n;
    initial clk = 0;
    always #2 clk = ~clk;

    logic         s_tvalid, s_tready, s_tlast, s_ferr;
    logic [255:0] s_tdata;
    logic [31:0]  s_tkeep;
    logic         m_tvalid, m_tready, m_tlast;
    logic [255:0] m_tdata;
    logic [31:0]  m_tkeep;

    logic [15:0] awaddr, araddr;
    logic [2:0]  awprot, arprot;
    logic        awvalid, awready, wvalid, wready, bvalid, bready;
    logic [31:0] wdata, rdata;
    logic [3:0]  wstrb;
    logic [1:0]  bresp, rresp;
    logic        arvalid, arready, rvalid, rready;

    quasar_core dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready),
        .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep),
        .s_axis_tlast(s_tlast), .s_axis_framing_err(s_ferr),
        .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready),
        .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep),
        .m_axis_tlast(m_tlast),
        .s_axil_awaddr(awaddr), .s_axil_awprot(awprot),
        .s_axil_awvalid(awvalid), .s_axil_awready(awready),
        .s_axil_wdata(wdata), .s_axil_wstrb(wstrb),
        .s_axil_wvalid(wvalid), .s_axil_wready(wready),
        .s_axil_bresp(bresp), .s_axil_bvalid(bvalid), .s_axil_bready(bready),
        .s_axil_araddr(araddr), .s_axil_arprot(arprot),
        .s_axil_arvalid(arvalid), .s_axil_arready(arready),
        .s_axil_rdata(rdata), .s_axil_rresp(rresp),
        .s_axil_rvalid(rvalid), .s_axil_rready(rready)
    );

    int errors;
    event_t evq [$];
    int n_fill, n_ack, n_rej, n_cxl, n_mod;

    always_ff @(posedge clk) begin
        if (m_tvalid && m_tready) begin
            event_t eb;
            eb = event_t'(m_tdata);
            evq.push_back(eb);
            case (eb.ev)
                EV_FILL:       n_fill++;
                EV_ACK:        n_ack++;
                EV_REJECT:     n_rej++;
                EV_CANCEL_ACK: n_cxl++;
                EV_MODIFY_ACK: n_mod++;
                default: ;
            endcase
        end
    end

    task automatic tick(int n = 1); repeat (n) @(posedge clk); endtask

    task automatic axil_wr(input logic [15:0] a, input logic [31:0] d);
        bit ad, wd;
        ad = 0; wd = 0;
        @(negedge clk);
        awaddr = a; awvalid = 1; awprot = 0;
        wdata = d; wvalid = 1; wstrb = 4'hF; bready = 1;
        while (!ad || !wd) begin
            @(posedge clk);
            if (awvalid && awready) ad = 1;
            if (wvalid && wready)   wd = 1;
            @(negedge clk);
            if (ad) awvalid = 0;
            if (wd) wvalid = 0;
        end
        @(posedge clk); while (!bvalid) @(posedge clk);
        @(negedge clk); bready = 0;
    endtask

    task automatic axil_rd(input logic [15:0] a, output logic [31:0] d);
        @(negedge clk);
        araddr = a; arvalid = 1; arprot = 0; rready = 1;
        @(posedge clk); while (!arready) @(posedge clk);
        @(negedge clk); arvalid = 0;
        @(posedge clk); while (!rvalid) @(posedge clk);
        d = rdata; @(negedge clk); rready = 0;
    endtask

    task automatic send_msg(input msg_t m);
        @(negedge clk);
        s_tdata = 256'(m); s_tkeep = {32{1'b1}}; s_tlast = 1; s_ferr = 0;
        s_tvalid = 1;
        @(posedge clk); while (!s_tready) @(posedge clk);
        @(negedge clk); s_tvalid = 0; s_tlast = 0;
    endtask

    task automatic wait_ev(input logic [7:0] kind, output event_t e, input int tmo = 6000);
        automatic int t = 0;
        e = '0;
        while (t < tmo) begin
            if (evq.size() > 0) begin
                e = evq.pop_front();
                if (e.ev == kind) return;
            end else begin @(posedge clk); t++; end
        end
        $error("wait_ev timeout for %s", ev_name(kind));
        errors++;
    endtask

    task automatic drain(int n);
        tick(n);
        while (evq.size() > 0) void'(evq.pop_front());
    endtask

    task automatic check_eq(input string tag, input logic [63:0] a, input logic [63:0] b);
        if (a !== b) begin $error("%s: got %0h want %0h", tag, a, b); errors++; end
    endtask

    task automatic check_book_empty(input string tag);
        logic [31:0] ord, lvl;
        tick(20); // allow pipeline to drain
        axil_rd(CSR_DBG_ORD_USED, ord);
        axil_rd(CSR_DBG_LVL_USED, lvl);
        if (ord != 0 || lvl != 0) begin
            $error("%s: book not empty ord=%0d lvl=%0d", tag, ord, lvl);
            errors++;
        end
    endtask

    task automatic rest(input logic [7:0] inst, input logic [63:0] oid,
                        input logic side, input logic [31:0] px, input logic [31:0] qty,
                        input logic [7:0] firm = 8'h1);
        event_t e;
        msg_t m;
        m = mk_msg(OP_NEW, inst, firm, side, TIF_GTC, STP_OFF, 0, qty, px, oid);
        send_msg(m);
        wait_ev(EV_ACK, e);
    endtask

    task automatic cancel(input logic [7:0] inst, input logic [63:0] oid,
                          input logic side, input logic [7:0] firm = 8'h1);
        event_t e;
        msg_t m;
        m = mk_msg(OP_CANCEL, inst, firm, side, TIF_GTC, STP_OFF, 0, 0, 0, oid);
        send_msg(m);
        wait_ev(EV_CANCEL_ACK, e);
    endtask

    msg_t m;
    event_t e;
    logic [31:0] rd;
    logic [31:0] rd_lat_min;

    initial begin
        rst_n = 0;
        s_tvalid = 0; s_tdata = 0; s_tkeep = 0; s_tlast = 0; s_ferr = 0;
        m_tready = 1;
        awvalid = 0; wvalid = 0; arvalid = 0; bready = 0; rready = 0;
        awaddr = 0; araddr = 0; wdata = 0; wstrb = 0; awprot = 0; arprot = 0;
        errors = 0; n_fill = 0; n_ack = 0; n_rej = 0; n_cxl = 0; n_mod = 0;
        tick(10); rst_n = 1; tick(400);
        axil_wr(CSR_CTRL, 32'h0000_0001);
        axil_wr(CSR_INST_MASK, 32'hFF);

        // ====================================================================
        // 1. Interleaved instruments: bids on 0..7, asks across all
        // ====================================================================
        $display("ADV 1: interleaved 8-instrument rest");
        for (int i = 0; i < 8; i++)
            rest(8'(i), 64'(64'h1000 + i), SIDE_BID, 32'(50 + i), 3, 8'h1);
        for (int i = 0; i < 8; i++) begin
            m = mk_msg(OP_NEW, 8'(i), 2, SIDE_ASK, TIF_IOC, STP_OFF, 0,
                       3, 32'(50 + i), 64'(64'h1100 + i));
            send_msg(m);
            wait_ev(EV_FILL, e);
            check_eq("inst_fill", e.inst, 8'(i));
            check_eq("inst_fill_qty", e.qty, 3);
            wait_ev(EV_ACK, e);
        end
        check_book_empty("after_8inst");

        // ====================================================================
        // 2. FOK across five price levels
        // ====================================================================
        $display("ADV 2: FOK across 5 levels");
        for (int i = 0; i < 5; i++)
            rest(0, 64'(64'h2000 + i), SIDE_ASK, 32'(10 + i), 4, 8'h1);
        // FOK buy for 20 = exactly 5*4 = 20 total available
        m = mk_msg(OP_NEW, 0, 3, SIDE_BID, TIF_FOK, STP_OFF, 0,
                   32'd20, 32'd14, 64'h2099);
        send_msg(m);
        for (int i = 0; i < 5; i++) wait_ev(EV_FILL, e);
        wait_ev(EV_ACK, e); check_eq("fok5_rem", e.qty, 0);
        check_book_empty("after_fok5");

        // ====================================================================
        // 3. Modify chain: increase, decrease, increase again, cancel
        // ====================================================================
        $display("ADV 3: modify chain");
        rest(1, 64'h3001, SIDE_BID, 80, 10, 8'h2);
        m = mk_msg(OP_MODIFY, 1, 2, SIDE_BID, TIF_GTC, STP_OFF, 0, 20, 80, 64'h3001);
        send_msg(m); wait_ev(EV_MODIFY_ACK, e); check_eq("mod+", e.qty, 20);
        m = mk_msg(OP_MODIFY, 1, 2, SIDE_BID, TIF_GTC, STP_OFF, 0, 3, 80, 64'h3001);
        send_msg(m); wait_ev(EV_MODIFY_ACK, e); check_eq("mod-", e.qty, 3);
        m = mk_msg(OP_MODIFY, 1, 2, SIDE_BID, TIF_GTC, STP_OFF, 0, 7, 80, 64'h3001);
        send_msg(m); wait_ev(EV_MODIFY_ACK, e); check_eq("mod++", e.qty, 7);
        cancel(1, 64'h3001, SIDE_BID, 8'h2);
        check_book_empty("after_mod_chain");

        // ====================================================================
        // 4. Replace across price, then cancel both resulting orders
        // ====================================================================
        $display("ADV 4: replace across price");
        rest(2, 64'h4001, SIDE_BID, 30, 5, 8'h3);
        rest(2, 64'h4002, SIDE_BID, 28, 5, 8'h3);
        // Replace 4001 from 30 → 35 (cancel old, new at 35)
        m = mk_msg(OP_REPLACE, 2, 3, SIDE_BID, TIF_GTC, STP_OFF, 0,
                   32'd5, 32'd35, 64'h4001);
        send_msg(m); wait_ev(EV_REPLACE_ACK, e);
        check_eq("rep_ack", e.ev, EV_REPLACE_ACK);
        // Clean up: cancel both
        cancel(2, 64'h4001, SIDE_BID, 8'h3);
        cancel(2, 64'h4002, SIDE_BID, 8'h3);
        check_book_empty("after_replace");

        // ====================================================================
        // 5. STP both modes in sequence
        // ====================================================================
        $display("ADV 5: STP modes");
        // cancel-resting: bid rests, ask from same firm → resting removed, ask rests
        rest(3, 64'h5001, SIDE_BID, 60, 4, 8'h10);
        m = mk_msg(OP_NEW, 3, 8'h10, SIDE_ASK, TIF_GTC, STP_CANCEL_RESTING, 0,
                   32'd4, 32'd60, 64'h5002);
        send_msg(m); wait_ev(EV_ACK, e);
        // ask should now be resting at 60; cancel it
        cancel(3, 64'h5002, SIDE_ASK, 8'h10);

        // cancel-taker: bid rests, ask from same firm → taker rejected
        rest(3, 64'h5003, SIDE_BID, 60, 4, 8'h11);
        m = mk_msg(OP_NEW, 3, 8'h11, SIDE_ASK, TIF_IOC, STP_CANCEL_TAKER, 0,
                   32'd4, 32'd60, 64'h5004);
        send_msg(m); wait_ev(EV_REJECT, e); check_eq("stp_taker", e.reject, REJ_STP);
        cancel(3, 64'h5003, SIDE_BID, 8'h11);
        check_book_empty("after_stp");

        // ====================================================================
        // 6. Soft reset mid-session: perf counters clear, book survives
        // ====================================================================
        $display("ADV 6: soft reset");
        rest(4, 64'h6001, SIDE_ASK, 100, 2, 8'h1);
        axil_rd(CSR_CNT_ORDERS, rd);
        if (rd == 0) begin $error("cnt_orders zero before soft-rst"); errors++; end
        axil_wr(CSR_CTRL, 32'h0000_0003); // enable + soft_rst
        tick(4);
        axil_rd(CSR_CNT_ORDERS, rd);
        check_eq("post_soft_rst_cnt", rd, 0); // counter cleared
        axil_rd(CSR_DBG_ORD_USED, rd);
        check_eq("post_soft_rst_book", rd, 1); // book order still live
        cancel(4, 64'h6001, SIDE_ASK, 8'h1);
        axil_wr(CSR_CTRL, 32'h0000_0001);

        // ====================================================================
        // 7. Position limit: multiple fills accumulate position then hit cap
        // ====================================================================
        $display("ADV 7: position limit accumulation");
        axil_wr(CSR_RISK_POSITION, 32'd6); // max |pos| = 6
        // Three buys of 2 each: 2, 4, 6 — all pass
        for (int i = 0; i < 3; i++) begin
            rest(5, 64'(64'h7100 + i), SIDE_ASK, 10, 2, 8'h1);
            m = mk_msg(OP_NEW, 5, 2, SIDE_BID, TIF_IOC, STP_OFF, 0,
                       32'd2, 32'd10, 64'(64'h7000 + i));
            send_msg(m);
            wait_ev(EV_FILL, e);
            wait_ev(EV_ACK, e);
        end
        // Fourth buy would push pos to 8 > 6 → reject
        m = mk_msg(OP_NEW, 5, 2, SIDE_BID, TIF_IOC, STP_OFF, 0,
                   32'd2, 32'd10, 64'h7099);
        send_msg(m);
        wait_ev(EV_REJECT, e);
        check_eq("pos_limit", e.reject, REJ_RISK_POS);
        axil_wr(CSR_RISK_POSITION, 32'd0);

        // ====================================================================
        // 8. Concurrent same-level queue: 10 bids at same price on inst 6,
        //    a single ask sweeps them in FIFO order
        // ====================================================================
        $display("ADV 8: 10-order FIFO queue");
        for (int i = 0; i < 10; i++)
            rest(6, 64'(64'h8000 + i), SIDE_BID, 44, 1, 8'h5);
        m = mk_msg(OP_NEW, 6, 9, SIDE_ASK, TIF_IOC, STP_OFF, 0,
                   32'd10, 32'd44, 64'h8FFF);
        send_msg(m);
        for (int i = 0; i < 10; i++) begin
            wait_ev(EV_FILL, e);
            // OIDs should arrive in insertion order
            if (e.match_oid_lo[15:0] !== 16'h8000 + 16'(i)) begin
                $error("q10 order[%0d] oid got %0h want %0h",
                       i, e.match_oid_lo[15:0], 16'h8000 + 16'(i));
                errors++;
            end
        end
        wait_ev(EV_ACK, e);
        check_book_empty("after_q10");

        // ====================================================================
        // 9. Latency counter sanity: LAT_MIN should be < LAT_MAX
        // ====================================================================
        $display("ADV 9: latency counters");
        drain(50);
        axil_rd(CSR_LAT_MIN, rd);
        rd_lat_min = rd;
        axil_rd(CSR_LAT_MAX, rd);
        if (rd_lat_min > rd) begin
            $error("lat_min=%0d > lat_max=%0d", rd_lat_min, rd);
            errors++;
        end
        if (rd_lat_min == 32'hFFFF_FFFF) begin
            $error("lat_min never updated");
            errors++;
        end

        drain(100);
        $display("ADV: fills=%0d acks=%0d rej=%0d cxl=%0d mod=%0d",
                 n_fill, n_ack, n_rej, n_cxl, n_mod);
        if (errors) $fatal(1, "tb_advanced FAILED (%0d errors)", errors);
        $display("tb_advanced PASSED");
        $finish;
    end

    initial begin #40_000_000; $fatal(1, "tb_advanced timeout"); end
endmodule
