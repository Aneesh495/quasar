// =============================================================================
// Verilator smoke: quasar_core, 256-bit AXIS, single clock.
// Directed stream: rest, cross, partial, cancel, replace, modify, CRC fail,
// AXI-Lite VERSION/CTRL/counter reads.  Scoreboard is a lightweight in-TB
// checker (the C++ golden book is used by the UVM-lite path).
// =============================================================================

`timescale 1ns/1ps

module tb_quasar_smoke;
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

    int errors, n_fill, n_ack, n_rej, n_cxl, n_mod, n_bbo;

    event_t evq [$];

    always_ff @(posedge clk) begin
        if (m_tvalid && m_tready) begin
            evq.push_back(event_t'(m_tdata));
            unique case (event_t'(m_tdata).ev)
                EV_FILL:        n_fill++;
                EV_ACK:         n_ack++;
                EV_REJECT:      n_rej++;
                EV_CANCEL_ACK:  n_cxl++;
                EV_MODIFY_ACK:  n_mod++;
                EV_REPLACE_ACK: n_ack++;
                EV_BBO:         n_bbo++;
                default: ;
            endcase
        end
    end

    task automatic tick(int n = 1);
        repeat (n) @(posedge clk);
    endtask

    task automatic axil_wr(input logic [15:0] a, input logic [31:0] d);
        awaddr <= a; awvalid <= 1'b1; awprot <= 3'b0;
        wdata  <= d; wvalid  <= 1'b1; wstrb  <= 4'hF;
        bready <= 1'b1;
        fork
            begin
                @(posedge clk);
                while (!awready) @(posedge clk);
                awvalid <= 1'b0;
            end
            begin
                @(posedge clk);
                while (!wready) @(posedge clk);
                wvalid <= 1'b0;
            end
        join
        @(posedge clk);
        while (!bvalid) @(posedge clk);
        @(posedge clk);
        bready <= 1'b0;
    endtask

    task automatic axil_rd(input logic [15:0] a, output logic [31:0] d);
        araddr <= a; arvalid <= 1'b1; arprot <= 3'b0; rready <= 1'b1;
        @(posedge clk);
        while (!arready) @(posedge clk);
        arvalid <= 1'b0;
        @(posedge clk);
        while (!rvalid) @(posedge clk);
        d = rdata;
        @(posedge clk);
        rready <= 1'b0;
    endtask

    task automatic send_msg(input msg_t m);
        s_tdata  <= 256'(m);
        s_tkeep  <= {32{1'b1}};
        s_tlast  <= 1'b1;
        s_ferr   <= 1'b0;
        s_tvalid <= 1'b1;
        @(posedge clk);
        while (!s_tready) @(posedge clk);
        s_tvalid <= 1'b0;
        s_tlast  <= 1'b0;
    endtask

    task automatic wait_ev(input logic [7:0] kind, output event_t e, input int timeout = 4000);
        int t;
        t = 0;
        while (t < timeout) begin
            if (evq.size() > 0) begin
                e = evq.pop_front();
                if (e.ev == kind) return;
                // keep BBO / other side-channel events
            end else begin
                @(posedge clk);
                t++;
            end
        end
        $error("timeout waiting for %s", ev_name(kind));
        errors++;
        e = '0;
    endtask

    task automatic drain(int ncycles);
        tick(ncycles);
        while (evq.size() > 0) void'(evq.pop_front());
    endtask

    task automatic expect(input string tag, input logic [63:0] a, input logic [63:0] b);
        if (a !== b) begin
            $error("%s: got %0h want %0h", tag, a, b);
            errors++;
        end
    endtask

    initial begin
        event_t e;
        logic [31:0] rd;
        msg_t m;

        rst_n = 0;
        s_tvalid = 0; s_tdata = 0; s_tkeep = 0; s_tlast = 0; s_ferr = 0;
        m_tready = 1;
        awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
        awaddr = 0; araddr = 0; wdata = 0; wstrb = 0; awprot = 0; arprot = 0;
        errors = 0; n_fill = 0; n_ack = 0; n_rej = 0; n_cxl = 0; n_mod = 0; n_bbo = 0;
        tick(10);
        rst_n = 1;
        tick(400); // reset sync + book INIT

        // AXI-Lite identity
        axil_rd(CSR_VERSION, rd);
        expect("version", rd, QUASAR_VERSION);
        axil_rd(CSR_FEATURE, rd);
        expect("feature", rd, QUASAR_FEATURE);
        axil_wr(CSR_SCRATCH, 32'hA5A5_5A5A);
        axil_rd(CSR_SCRATCH, rd);
        expect("scratch", rd, 32'hA5A5_5A5A);
        axil_wr(CSR_CTRL, 32'h0000_0009); // enable + bbo
        axil_wr(CSR_INST_MASK, 32'h0000_00FF);

        // Resting bid 100 x 10
        m = mk_msg(OP_NEW, 0, 1, SIDE_BID, TIF_GTC, STP_OFF, 1'b0,
                   32'd10, 32'd100, 64'h1001);
        send_msg(m);
        wait_ev(EV_ACK, e);
        expect("ack qty rest", e.qty, 10);

        // Crossing ask 100 x 4 → fill 4, ack residual 0 (IOC would drop;
        // GTC residual 0 because fully filled? qty 4 < 10 so fill 4, rest 0 on taker)
        m = mk_msg(OP_NEW, 0, 2, SIDE_ASK, TIF_GTC, STP_OFF, 1'b0,
                   32'd4, 32'd100, 64'h1002);
        send_msg(m);
        wait_ev(EV_FILL, e);
        expect("fill qty", e.qty, 4);
        expect("fill px", e.price, 100);
        wait_ev(EV_ACK, e);

        // Cancel residual bid
        m = mk_msg(OP_CANCEL, 0, 1, SIDE_BID, TIF_GTC, STP_OFF, 1'b0,
                   32'd0, 32'd0, 64'h1001);
        send_msg(m);
        wait_ev(EV_CANCEL_ACK, e);
        expect("cxl qty", e.qty, 6);

        // Resting ask, modify down, then hit it
        m = mk_msg(OP_NEW, 1, 3, SIDE_ASK, TIF_GTC, STP_OFF, 1'b0,
                   32'd8, 32'd50, 64'h2001);
        send_msg(m);
        wait_ev(EV_ACK, e);
        m = mk_msg(OP_MODIFY, 1, 3, SIDE_ASK, TIF_GTC, STP_OFF, 1'b0,
                   32'd5, 32'd50, 64'h2001);
        send_msg(m);
        wait_ev(EV_MODIFY_ACK, e);
        expect("mod qty", e.qty, 5);

        m = mk_msg(OP_NEW, 1, 4, SIDE_BID, TIF_IOC, STP_OFF, 1'b0,
                   32'd5, 32'd50, 64'h2002);
        send_msg(m);
        wait_ev(EV_FILL, e);
        expect("ioc fill", e.qty, 5);
        wait_ev(EV_ACK, e);

        // Replace: rest bid, replace price up (loses priority / reinserts)
        m = mk_msg(OP_NEW, 2, 5, SIDE_BID, TIF_GTC, STP_OFF, 1'b0,
                   32'd2, 32'd10, 64'h3001);
        send_msg(m);
        wait_ev(EV_ACK, e);
        m = mk_msg(OP_REPLACE, 2, 5, SIDE_BID, TIF_GTC, STP_OFF, 1'b0,
                   32'd2, 32'd12, 64'h3001);
        send_msg(m);
        wait_ev(EV_REPLACE_ACK, e);
        m = mk_msg(OP_CANCEL, 2, 5, SIDE_BID, TIF_GTC, STP_OFF, 1'b0,
                   32'd0, 32'd0, 64'h3001);
        send_msg(m);
        wait_ev(EV_CANCEL_ACK, e);
        expect("rep cxl px", e.price, 12);

        // CRC failure
        m = mk_msg(OP_NEW, 0, 1, SIDE_BID, TIF_GTC, STP_OFF, 1'b0,
                   32'd1, 32'd1, 64'h4001);
        m.crc32 ^= 32'hFFFF;
        send_msg(m);
        wait_ev(EV_REJECT, e);
        expect("crc rej", e.reject, REJ_CRC);

        // Bad instrument
        m = mk_msg(OP_NEW, 8'h20, 1, SIDE_BID, TIF_GTC, STP_OFF, 1'b0,
                   32'd1, 32'd1, 64'h4002);
        send_msg(m);
        wait_ev(EV_REJECT, e);
        expect("inst rej", e.reject, REJ_INSTRUMENT);

        // Cancel missing
        m = mk_msg(OP_CANCEL, 0, 1, SIDE_BID, TIF_GTC, STP_OFF, 1'b0,
                   32'd0, 32'd0, 64'h0BAD);
        send_msg(m);
        wait_ev(EV_REJECT, e);
        expect("miss cxl", e.reject, REJ_NOT_FOUND);

        // Post-only that would take
        m = mk_msg(OP_NEW, 0, 9, SIDE_ASK, TIF_GTC, STP_OFF, 1'b0,
                   32'd3, 32'd80, 64'h5001);
        send_msg(m);
        wait_ev(EV_ACK, e);
        m = mk_msg(OP_NEW, 0, 9, SIDE_BID, TIF_GTC, STP_OFF, 1'b1,
                   32'd3, 32'd80, 64'h5002);
        send_msg(m);
        wait_ev(EV_REJECT, e);
        expect("post only", e.reject, REJ_POST_ONLY);
        m = mk_msg(OP_CANCEL, 0, 9, SIDE_ASK, TIF_GTC, STP_OFF, 1'b0,
                   32'd0, 32'd0, 64'h5001);
        send_msg(m);
        wait_ev(EV_CANCEL_ACK, e);

        // FOK that cannot fill
        m = mk_msg(OP_NEW, 0, 1, SIDE_ASK, TIF_FOK, STP_OFF, 1'b0,
                   32'd99, 32'd1, 64'h6001);
        send_msg(m);
        wait_ev(EV_REJECT, e);
        expect("fok", e.reject, REJ_FOK);

        drain(200);

        axil_rd(CSR_CNT_FILLS, rd);
        $display("CSR fills=%0d acks=%0d rejects=%0d", n_fill, n_ack, n_rej);
        axil_rd(CSR_CNT_ORDERS, rd);
        axil_rd(CSR_DBG_ORD_USED, rd);
        $display("orders_used csr=%0d", rd);

        if (n_fill == 0) begin
            $error("expected at least one fill");
            errors++;
        end
        if (errors != 0)
            $fatal(1, "tb_quasar_smoke FAILED (%0d errors)", errors);
        $display("tb_quasar_smoke PASSED  fills=%0d acks=%0d rej=%0d cxl=%0d mod=%0d bbo=%0d",
                 n_fill, n_ack, n_rej, n_cxl, n_mod, n_bbo);
        $finish;
    end

    initial begin
        #8_000_000;
        $fatal(1, "tb_quasar_smoke timeout");
    end

endmodule
