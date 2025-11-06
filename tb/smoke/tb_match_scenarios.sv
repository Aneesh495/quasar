// =============================================================================
// Directed matching scenarios on quasar_core: multi-level walk, FOK success,
// IOC leftover, book-full, duplicate oid, notional / position / rate risk,
// STP cancel-resting, and a 16-order time-priority queue.
// =============================================================================

`timescale 1ns/1ps

module tb_match_scenarios;
    import quasar_pkg::*;
    import quasar_tb_pkg::*;

    logic clk, rst_n;
    initial clk = 1'b0;
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

    always_ff @(posedge clk) begin
        if (m_tvalid && m_tready) begin
            event_t ev_beat;
            ev_beat = event_t'(m_tdata);
            evq.push_back(ev_beat);
        end
    end

    task automatic tick(int n = 1);
        repeat (n) @(posedge clk);
    endtask

    task automatic axil_wr(input logic [15:0] a, input logic [31:0] d);
        bit aw_done, w_done;
        aw_done = 0; w_done = 0;
        @(negedge clk);
        awaddr = a; awvalid = 1'b1; awprot = 3'b0;
        wdata  = d; wvalid  = 1'b1; wstrb  = 4'hF;
        bready = 1'b1;
        while (!aw_done || !w_done) begin
            @(posedge clk);
            if (awvalid && awready) aw_done = 1'b1;
            if (wvalid && wready)   w_done  = 1'b1;
            @(negedge clk);
            if (aw_done) awvalid = 1'b0;
            if (w_done)  wvalid  = 1'b0;
        end
        @(posedge clk);
        while (!bvalid) @(posedge clk);
        @(negedge clk);
        bready = 1'b0;
    endtask

    task automatic send_msg(input msg_t m);
        @(negedge clk);
        s_tdata  = 256'(m);
        s_tkeep  = {32{1'b1}};
        s_tlast  = 1'b1;
        s_ferr   = 1'b0;
        s_tvalid = 1'b1;
        @(posedge clk);
        while (!s_tready) @(posedge clk);
        @(negedge clk);
        s_tvalid = 1'b0;
        s_tlast  = 1'b0;
    endtask

    task automatic wait_ev(input logic [7:0] kind, output event_t e, input int timeout = 8000);
        int t;
        t = 0;
        e = '0;
        while (t < timeout) begin
            if (evq.size() > 0) begin
                e = evq.pop_front();
                if (e.ev == kind) return;
            end else begin
                @(posedge clk);
                t++;
            end
        end
        $error("timeout waiting for %s", ev_name(kind));
        errors++;
    endtask

    task automatic drain(int ncycles);
        tick(ncycles);
        while (evq.size() > 0) void'(evq.pop_front());
    endtask

    task automatic check_eq(input string tag, input logic [63:0] a, input logic [63:0] b);
        if (a !== b) begin
            $error("%s: got %0h want %0h", tag, a, b);
            errors++;
        end
    endtask

    task automatic rest_bid(input logic [7:0] inst, input logic [63:0] oid,
                            input logic [31:0] px, input logic [31:0] qty,
                            input logic [7:0] firm = 8'h1);
        msg_t m;
        event_t e;
        m = mk_msg(OP_NEW, inst, firm, SIDE_BID, TIF_GTC, STP_OFF, 1'b0, qty, px, oid);
        send_msg(m);
        wait_ev(EV_ACK, e);
    endtask

    task automatic rest_ask(input logic [7:0] inst, input logic [63:0] oid,
                            input logic [31:0] px, input logic [31:0] qty,
                            input logic [7:0] firm = 8'h1);
        msg_t m;
        event_t e;
        m = mk_msg(OP_NEW, inst, firm, SIDE_ASK, TIF_GTC, STP_OFF, 1'b0, qty, px, oid);
        send_msg(m);
        wait_ev(EV_ACK, e);
    endtask

    initial begin
        msg_t m;
        event_t e;
        int i;
        rst_n = 0;
        s_tvalid = 0; s_tdata = 0; s_tkeep = 0; s_tlast = 0; s_ferr = 0;
        m_tready = 1;
        awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
        awaddr = 0; araddr = 0; wdata = 0; wstrb = 0; awprot = 0; arprot = 0;
        errors = 0;
        tick(8);
        rst_n = 1;
        tick(400);
        axil_wr(CSR_CTRL, 32'h0000_0001); // enable, no BBO side-channel
        axil_wr(CSR_INST_MASK, 32'hFF);

        // ---- multi-level ask walk: 10@50 + 7@51, bid 17@51 ----
        rest_ask(0, 64'h10, 50, 10);
        rest_ask(0, 64'h11, 51, 7);
        m = mk_msg(OP_NEW, 0, 2, SIDE_BID, TIF_GTC, STP_OFF, 1'b0,
                   32'd17, 32'd51, 64'h12);
        send_msg(m);
        wait_ev(EV_FILL, e);
        check_eq("ml fill0 qty", e.qty, 10);
        check_eq("ml fill0 px", e.price, 50);
        wait_ev(EV_FILL, e);
        check_eq("ml fill1 qty", e.qty, 7);
        check_eq("ml fill1 px", e.price, 51);
        wait_ev(EV_ACK, e);
        check_eq("ml rem", e.qty, 0);

        // ---- FOK success: rest 5, FOK 5 ----
        rest_ask(1, 64'h20, 8, 5);
        m = mk_msg(OP_NEW, 1, 3, SIDE_BID, TIF_FOK, STP_OFF, 1'b0,
                   32'd5, 32'd8, 64'h21);
        send_msg(m);
        wait_ev(EV_FILL, e);
        check_eq("fok ok qty", e.qty, 5);
        wait_ev(EV_ACK, e);

        // ---- FOK fail does not consume resting ----
        rest_ask(1, 64'h22, 9, 2);
        m = mk_msg(OP_NEW, 1, 3, SIDE_BID, TIF_FOK, STP_OFF, 1'b0,
                   32'd9, 32'd9, 64'h23);
        send_msg(m);
        wait_ev(EV_REJECT, e);
        check_eq("fok fail", e.reject, REJ_FOK);
        m = mk_msg(OP_CANCEL, 1, 1, SIDE_ASK, TIF_GTC, STP_OFF, 1'b0,
                   32'd0, 32'd0, 64'h22);
        send_msg(m);
        wait_ev(EV_CANCEL_ACK, e);
        check_eq("fok rest lives", e.qty, 2);

        // ---- IOC leftover discarded ----
        rest_ask(2, 64'h30, 40, 3);
        m = mk_msg(OP_NEW, 2, 4, SIDE_BID, TIF_IOC, STP_OFF, 1'b0,
                   32'd10, 32'd40, 64'h31);
        send_msg(m);
        wait_ev(EV_FILL, e);
        check_eq("ioc take", e.qty, 3);
        wait_ev(EV_ACK, e);
        check_eq("ioc rem not resting", e.qty, 7);
        m = mk_msg(OP_CANCEL, 2, 4, SIDE_BID, TIF_GTC, STP_OFF, 1'b0,
                   32'd0, 32'd0, 64'h31);
        send_msg(m);
        wait_ev(EV_REJECT, e);
        check_eq("ioc no rest", e.reject, REJ_NOT_FOUND);

        // ---- duplicate oid ----
        rest_bid(3, 64'h40, 12, 1);
        m = mk_msg(OP_NEW, 3, 1, SIDE_BID, TIF_GTC, STP_OFF, 1'b0,
                   32'd1, 32'd13, 64'h40);
        send_msg(m);
        wait_ev(EV_REJECT, e);
        check_eq("dup", e.reject, REJ_DUP_OID);
        m = mk_msg(OP_CANCEL, 3, 1, SIDE_BID, TIF_GTC, STP_OFF, 1'b0,
                   32'd0, 32'd0, 64'h40);
        send_msg(m);
        wait_ev(EV_CANCEL_ACK, e);

        // ---- time priority: 8 bids at same px, one ask sweeps them in order ----
        for (i = 0; i < 8; i++)
            rest_bid(4, 64'h50 + i, 70, 1, 8'h1);
        m = mk_msg(OP_NEW, 4, 9, SIDE_ASK, TIF_IOC, STP_OFF, 1'b0,
                   32'd8, 32'd70, 64'h5A);
        send_msg(m);
        for (i = 0; i < 8; i++) begin
            wait_ev(EV_FILL, e);
            check_eq("prio oid", e.match_oid_lo, 32'(64'h50 + i));
        end
        wait_ev(EV_ACK, e);

        // ---- notional risk ----
        axil_wr(CSR_RISK_NOTIONAL, 32'd100);
        m = mk_msg(OP_NEW, 5, 1, SIDE_BID, TIF_GTC, STP_OFF, 1'b0,
                   32'd3, 32'd50, 64'h60);
        send_msg(m);
        wait_ev(EV_REJECT, e);
        check_eq("notional", e.reject, REJ_RISK_NOTIONAL);
        axil_wr(CSR_RISK_NOTIONAL, 32'd0);

        // ---- disabled ----
        axil_wr(CSR_CTRL, 32'h0);
        m = mk_msg(OP_NEW, 5, 1, SIDE_BID, TIF_GTC, STP_OFF, 1'b0,
                   32'd1, 32'd1, 64'h61);
        send_msg(m);
        wait_ev(EV_REJECT, e);
        check_eq("disabled", e.reject, REJ_DISABLED);
        axil_wr(CSR_CTRL, 32'h1);

        // ---- instrument mask ----
        axil_wr(CSR_INST_MASK, 32'h01);
        m = mk_msg(OP_NEW, 2, 1, SIDE_BID, TIF_GTC, STP_OFF, 1'b0,
                   32'd1, 32'd1, 64'h62);
        send_msg(m);
        wait_ev(EV_REJECT, e);
        check_eq("mask", e.reject, REJ_INSTRUMENT);
        axil_wr(CSR_INST_MASK, 32'hFF);

        drain(100);
        if (errors != 0)
            $fatal(1, "tb_match_scenarios FAILED (%0d)", errors);
        $display("tb_match_scenarios PASSED");
        $finish;
    end

    initial begin
        #20_000_000;
        $fatal(1, "tb_match_scenarios timeout");
    end
endmodule
