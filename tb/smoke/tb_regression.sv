// =============================================================================
// Quasar regression: longer directed sequence exercising all opcodes, all
// reject reasons, STP modes, multi-instrument, mass-cancel, rate-limit refill,
// status query, and BBO event generation.  Aimed at finding interaction bugs
// between successive commands; each scenario leaves the book clean.
// =============================================================================

`timescale 1ns/1ps

module tb_regression;
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
    int n_fill, n_ack, n_rej, n_cxl, n_mod, n_rep, n_bbo;

    always_ff @(posedge clk) begin
        if (m_tvalid && m_tready) begin
            event_t eb;
            eb = event_t'(m_tdata);
            evq.push_back(eb);
            case (eb.ev)
                EV_FILL:        n_fill++;
                EV_ACK:         n_ack++;
                EV_REJECT:      n_rej++;
                EV_CANCEL_ACK:  n_cxl++;
                EV_MODIFY_ACK:  n_mod++;
                EV_REPLACE_ACK: n_rep++;
                EV_BBO:         n_bbo++;
                default: ;
            endcase
        end
    end

    task automatic tick(int n = 1);
        repeat (n) @(posedge clk);
    endtask

    task automatic axil_wr(input logic [15:0] a, input logic [31:0] d);
        bit aw_done, w_done;
        aw_done = 0; w_done = 0;
        @(negedge clk);
        awaddr = a; awvalid = 1; awprot = 0;
        wdata = d; wvalid = 1; wstrb = 4'hF; bready = 1;
        while (!aw_done || !w_done) begin
            @(posedge clk);
            if (awvalid && awready) aw_done = 1;
            if (wvalid && wready)   w_done = 1;
            @(negedge clk);
            if (aw_done) awvalid = 0;
            if (w_done) wvalid = 0;
        end
        @(posedge clk);
        while (!bvalid) @(posedge clk);
        @(negedge clk); bready = 0;
    endtask

    task automatic axil_rd(input logic [15:0] a, output logic [31:0] d);
        @(negedge clk);
        araddr = a; arvalid = 1; arprot = 0; rready = 1;
        @(posedge clk);
        while (!arready) @(posedge clk);
        @(negedge clk); arvalid = 0;
        @(posedge clk);
        while (!rvalid) @(posedge clk);
        d = rdata;
        @(negedge clk); rready = 0;
    endtask

    task automatic send_msg(input msg_t m);
        @(negedge clk);
        s_tdata = 256'(m); s_tkeep = {32{1'b1}}; s_tlast = 1; s_ferr = 0;
        s_tvalid = 1;
        @(posedge clk);
        while (!s_tready) @(posedge clk);
        @(negedge clk);
        s_tvalid = 0; s_tlast = 0;
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

    // ---- Scenario helpers ----
    task automatic rest_bid(input logic [7:0] inst, input logic [63:0] oid,
                            input logic [31:0] px, input logic [31:0] qty,
                            input logic [7:0] firm = 1);
        event_t e;
        msg_t m;
        m = mk_msg(OP_NEW, inst, firm, SIDE_BID, TIF_GTC, STP_OFF, 0, qty, px, oid);
        send_msg(m);
        wait_ev(EV_ACK, e);
    endtask

    task automatic rest_ask(input logic [7:0] inst, input logic [63:0] oid,
                            input logic [31:0] px, input logic [31:0] qty,
                            input logic [7:0] firm = 1);
        event_t e;
        msg_t m;
        m = mk_msg(OP_NEW, inst, firm, SIDE_ASK, TIF_GTC, STP_OFF, 0, qty, px, oid);
        send_msg(m);
        wait_ev(EV_ACK, e);
    endtask

    task automatic cancel_oid(input logic [7:0] inst, input logic [63:0] oid,
                              input logic side, input logic [7:0] firm = 1);
        event_t e;
        msg_t m;
        m = mk_msg(OP_CANCEL, inst, firm, side, TIF_GTC, STP_OFF, 0, 0, 0, oid);
        send_msg(m);
        wait_ev(EV_CANCEL_ACK, e);
    endtask

    msg_t m;
    event_t e;
    logic [31:0] rd;
    int ord_cnt_start;

    initial begin
        rst_n = 0;
        s_tvalid = 0; s_tdata = 0; s_tkeep = 0; s_tlast = 0; s_ferr = 0;
        m_tready = 1;
        awvalid = 0; wvalid = 0; arvalid = 0; bready = 0; rready = 0;
        awaddr = 0; araddr = 0; wdata = 0; wstrb = 0; awprot = 0; arprot = 0;
        errors = 0;
        n_fill = 0; n_ack = 0; n_rej = 0; n_cxl = 0; n_mod = 0; n_rep = 0; n_bbo = 0;
        tick(10);
        rst_n = 1;
        tick(400);
        axil_wr(CSR_CTRL,      32'h0000_0001); // enable, no BBO
        axil_wr(CSR_INST_MASK, 32'hFF);

        // =========================================================
        // A. Cascading multi-level fill (3 levels: 10@100, 8@101, 5@102)
        // =========================================================
        $display("REG A: cascading fill");
        rest_bid(0, 64'h1A1, 100, 10);
        rest_bid(0, 64'h1A2, 101, 8);
        rest_bid(0, 64'h1A3, 102, 5);
        // Ask at 100 crosses all three levels
        m = mk_msg(OP_NEW, 0, 2, SIDE_ASK, TIF_GTC, STP_OFF, 0,
                   32'd23, 32'd100, 64'h1A4);
        send_msg(m);
        wait_ev(EV_FILL, e); check_eq("A.fill0_qty", e.qty, 5);  check_eq("A.fill0_px", e.price, 102);
        wait_ev(EV_FILL, e); check_eq("A.fill1_qty", e.qty, 8);  check_eq("A.fill1_px", e.price, 101);
        wait_ev(EV_FILL, e); check_eq("A.fill2_qty", e.qty, 10); check_eq("A.fill2_px", e.price, 100);
        wait_ev(EV_ACK, e);  check_eq("A.rem", e.qty, 0);

        // =========================================================
        // B. FOK success across 2 levels (8 + 4 = 12)
        // =========================================================
        $display("REG B: FOK success");
        rest_ask(1, 64'h101, 50, 8);
        rest_ask(1, 64'h102, 51, 4);
        m = mk_msg(OP_NEW, 1, 3, SIDE_BID, TIF_FOK, STP_OFF, 0,
                   32'd12, 32'd51, 64'h103);
        send_msg(m);
        wait_ev(EV_FILL, e); check_eq("B.f0", e.qty, 8);
        wait_ev(EV_FILL, e); check_eq("B.f1", e.qty, 4);
        wait_ev(EV_ACK, e);

        // =========================================================
        // C. Successive modify: increase, then decrease
        // =========================================================
        $display("REG C: modify sequence");
        rest_ask(2, 64'h201, 30, 10);
        m = mk_msg(OP_MODIFY, 2, 1, SIDE_ASK, TIF_GTC, STP_OFF, 0,
                   32'd15, 32'd30, 64'h201);
        send_msg(m);
        wait_ev(EV_MODIFY_ACK, e); check_eq("C.mod1", e.qty, 15);
        m = mk_msg(OP_MODIFY, 2, 1, SIDE_ASK, TIF_GTC, STP_OFF, 0,
                   32'd7, 32'd30, 64'h201);
        send_msg(m);
        wait_ev(EV_MODIFY_ACK, e); check_eq("C.mod2", e.qty, 7);
        cancel_oid(2, 64'h201, SIDE_ASK);

        // =========================================================
        // D. Replace across price levels
        // =========================================================
        $display("REG D: replace");
        rest_bid(3, 64'h301, 20, 5);
        rest_bid(3, 64'h302, 20, 5); // Same price, 2 orders
        // Replace D01 to price 22 (better bid) — cancel + new
        m = mk_msg(OP_REPLACE, 3, 1, SIDE_BID, TIF_GTC, STP_OFF, 0,
                   32'd5, 32'd22, 64'h301);
        send_msg(m);
        wait_ev(EV_REPLACE_ACK, e); check_eq("D.rep_qty", e.qty, 5);
        // D01 is now at 22, D02 still at 20; cancel both
        cancel_oid(3, 64'h301, SIDE_BID);
        cancel_oid(3, 64'h302, SIDE_BID);

        // =========================================================
        // E. STP cancel-resting: same firm, bid and ask
        // =========================================================
        $display("REG E: STP cancel-resting");
        rest_bid(4, 64'h401, 40, 5, 8'h77);
        m = mk_msg(OP_NEW, 4, 8'h77, SIDE_ASK, TIF_IOC, STP_CANCEL_RESTING, 0,
                   32'd5, 32'd40, 64'h402);
        send_msg(m);
        // IOC: STP fires (resting cancelled), taker continues but no cross left -> IOC discards
        wait_ev(EV_ACK, e); check_eq("E.stp_rem", e.qty, 5);

        // =========================================================
        // F. Mass-cancel of one side
        // =========================================================
        $display("REG F: cancel multiple bids");
        rest_bid(5, 64'h501, 11, 1);
        rest_bid(5, 64'h502, 12, 2);
        rest_bid(5, 64'h503, 13, 3);
        cancel_oid(5, 64'h501, SIDE_BID);
        cancel_oid(5, 64'h502, SIDE_BID);
        cancel_oid(5, 64'h503, SIDE_BID);
        // All 3 bids gone; IOC sell should see nothing to fill
        m = mk_msg(OP_NEW, 5, 2, SIDE_ASK, TIF_IOC, STP_OFF, 0,
                   32'd6, 32'd11, 64'h599);
        send_msg(m);
        wait_ev(EV_ACK, e); check_eq("F.no_fill_rem", e.qty, 6);

        // =========================================================
        // G. Status query mid-trading
        // =========================================================
        $display("REG G: status query");
        rest_ask(6, 64'h601, 88, 10);
        m = mk_msg(OP_STATUS, 6, 1, SIDE_ASK, TIF_GTC, STP_OFF, 0,
                   32'd0, 32'd0, 64'h600);
        send_msg(m);
        wait_ev(EV_STATUS, e);
        check_eq("G.ask_px", e.match_oid_lo, 88); // ask BBO px in match_oid_lo
        cancel_oid(6, 64'h601, SIDE_ASK);

        // =========================================================
        // H. BBO event generation (enable BBO flag)
        // =========================================================
        $display("REG H: BBO events");
        axil_wr(CSR_CTRL, 32'h0000_0009); // enable + BBO
        rest_bid(7, 64'h701, 70, 3);
        // Should get ACK + BBO
        wait_ev(EV_BBO, e);
        check_eq("H.bbo_bid_px", e.price, 70);
        cancel_oid(7, 64'h701, SIDE_BID);
        wait_ev(EV_BBO, e); // cancel also emits BBO (now empty)
        axil_wr(CSR_CTRL, 32'h0000_0001);

        // =========================================================
        // I. Counter verification
        // =========================================================
        $display("REG I: CSR counters");
        drain(100);
        axil_rd(CSR_CNT_FILLS,   rd); if (rd < 3) begin $error("cnt_fills=%0d", rd); errors++; end
        axil_rd(CSR_CNT_ACKS,    rd); if (rd < 8) begin $error("cnt_acks=%0d", rd); errors++; end
        axil_rd(CSR_CNT_CANCELS, rd); if (rd < 3) begin $error("cnt_cxl=%0d", rd); errors++; end
        axil_rd(CSR_LAT_MIN,     rd); if (rd == 32'hFFFF_FFFF) begin $error("lat_min not set"); errors++; end
        axil_rd(CSR_LAT_MAX,     rd); if (rd == 32'h0) begin $error("lat_max zero"); errors++; end
        axil_rd(CSR_DBG_ORD_USED, rd); check_eq("I.ords_clean", rd, 0);
        axil_rd(CSR_DBG_LVL_USED, rd); check_eq("I.lvls_clean", rd, 0);

        // =========================================================
        // J. Rapid-fire 8 orders on same instrument, partially fill, cancel rest
        // =========================================================
        $display("REG J: rapid-fire");
        for (int i = 0; i < 8; i++)
            rest_ask(0, {56'h4A3030303030 + 64'(i)}, 32'(10 + i), 2);
        // bid sweeps first 3
        m = mk_msg(OP_NEW, 0, 9, SIDE_BID, TIF_GTC, STP_OFF, 0,
                   32'd6, 32'd12, 64'h4A_FF);
        send_msg(m);
        wait_ev(EV_FILL, e); check_eq("J.f0_px", e.price, 10);
        wait_ev(EV_FILL, e); check_eq("J.f1_px", e.price, 11);
        wait_ev(EV_FILL, e); check_eq("J.f2_qty", e.qty, 2);
        wait_ev(EV_ACK, e);
        // Cancel remaining 5
        for (int i = 3; i < 8; i++)
            cancel_oid(0, {56'h4A3030303030 + 64'(i)}, SIDE_ASK);

        drain(200);

        $display("REG: fills=%0d acks=%0d rej=%0d cxl=%0d mod=%0d rep=%0d bbo=%0d",
                 n_fill, n_ack, n_rej, n_cxl, n_mod, n_rep, n_bbo);
        if (errors) $fatal(1, "tb_regression FAILED (%0d errors)", errors);
        $display("tb_regression PASSED");
        $finish;
    end

    initial begin #30_000_000; $fatal(1, "tb_regression timeout"); end
endmodule
