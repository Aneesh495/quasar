// =============================================================================
// Full quasar_soc test through the 64-bit AXIS pin interface (4-beat frames).
// Exercises: upsizer framing, async FIFO CDC (clocks tied = degenerate but
// structurally correct), downsizer, AXI-Lite VERSION read.  Verifies the
// complete ingress → book → egress path with the production-pin interface.
//
// If the per-beat valid/ready handshake is wrong the test hangs; the upsizer
// framing checks fire on early TLAST.
// =============================================================================

`timescale 1ns/1ps

module tb_soc_64b;
    import quasar_pkg::*;
    import quasar_tb_pkg::*;

    // single-clock smoke — all four clock pins tied
    logic clk, rst_n;
    initial clk = 1'b0;
    always #2 clk = ~clk;

    logic         s_tvalid, s_tready, s_tlast;
    logic [63:0]  s_tdata;
    logic [7:0]   s_tkeep;
    logic         m_tvalid, m_tready, m_tlast;
    logic [63:0]  m_tdata;
    logic [7:0]   m_tkeep;

    logic [15:0] awaddr, araddr;
    logic [2:0]  awprot, arprot;
    logic        awvalid, awready, wvalid, wready, bvalid, bready;
    logic [31:0] wdata, rdata;
    logic [3:0]  wstrb;
    logic [1:0]  bresp, rresp;
    logic        arvalid, arready, rvalid, rready;

    // All four clock domains tied to clk — CDC FIFOs still elaborate.
    quasar_soc dut (
        .clk_axis_in (clk),
        .clk_core    (clk),
        .clk_axis_out(clk),
        .clk_axil    (clk),
        .rst_n       (rst_n),
        .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_tready),
        .s_axis_tdata (s_tdata),
        .s_axis_tkeep (s_tkeep),
        .s_axis_tlast (s_tlast),
        .m_axis_tvalid(m_tvalid),
        .m_axis_tready(m_tready),
        .m_axis_tdata (m_tdata),
        .m_axis_tkeep (m_tkeep),
        .m_axis_tlast (m_tlast),
        .s_axil_awaddr (awaddr), .s_axil_awprot(awprot),
        .s_axil_awvalid(awvalid), .s_axil_awready(awready),
        .s_axil_wdata  (wdata), .s_axil_wstrb(wstrb),
        .s_axil_wvalid (wvalid), .s_axil_wready(wready),
        .s_axil_bresp  (bresp), .s_axil_bvalid(bvalid), .s_axil_bready(bready),
        .s_axil_araddr (araddr), .s_axil_arprot(arprot),
        .s_axil_arvalid(arvalid), .s_axil_arready(arready),
        .s_axil_rdata  (rdata), .s_axil_rresp(rresp),
        .s_axil_rvalid (rvalid), .s_axil_rready(rready)
    );

    // Collect 4-beat downsized output into a 256-bit accumulator
    logic [255:0] m_accum;
    logic [1:0]   m_beat;
    event_t evq [$];
    int n_fill, n_ack, n_rej, n_cxl;
    int errors;

    // Beat accumulator: combinational shift into a register
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_beat <= 2'd0;
            m_accum <= '0;
        end else if (m_tvalid && m_tready) begin
            m_accum[m_beat*64 +: 64] <= m_tdata;
            if (m_tlast) begin
                m_beat <= 2'd0;
            end else begin
                m_beat <= m_beat + 2'd1;
            end
        end
    end

    // Capture on TLAST: use the accum from previous beats + current beat
    // by building the full word combinationally then registering.
    logic [255:0] m_accum_full;
    always_comb begin
        m_accum_full = m_accum;
        if (m_tvalid && m_tready)
            m_accum_full[m_beat*64 +: 64] = m_tdata;
    end

    always_ff @(posedge clk) begin
        if (m_tvalid && m_tready && m_tlast) begin
            event_t eb;
            eb = event_t'(m_accum_full);
            evq.push_back(eb);
            $display("SOC64_EV t=%0t ev=%0h inst=%0d qty=%0d", $time, eb.ev, eb.inst, eb.qty);
            case (eb.ev)
                EV_FILL:       n_fill++;
                EV_ACK:        n_ack++;
                EV_REJECT:     n_rej++;
                EV_CANCEL_ACK: n_cxl++;
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
        awaddr = a; awvalid = 1'b1; awprot = 3'b0;
        wdata  = d; wvalid  = 1'b1; wstrb  = 4'hF;
        bready = 1'b1;
        while (!aw_done || !w_done) begin
            @(posedge clk);
            if (awvalid && awready) aw_done = 1'b1;
            if (wvalid  && wready ) w_done  = 1'b1;
            @(negedge clk);
            if (aw_done) awvalid = 1'b0;
            if (w_done)  wvalid  = 1'b0;
        end
        @(posedge clk);
        while (!bvalid) @(posedge clk);
        @(negedge clk);
        bready = 1'b0;
    endtask

    task automatic axil_rd(input logic [15:0] a, output logic [31:0] d);
        @(negedge clk);
        araddr = a; arvalid = 1'b1; arprot = 3'b0; rready = 1'b1;
        @(posedge clk);
        while (!arready) @(posedge clk);
        @(negedge clk);
        arvalid = 1'b0;
        @(posedge clk);
        while (!rvalid) @(posedge clk);
        d = rdata;
        @(negedge clk);
        rready = 1'b0;
    endtask

    // Send a 256-bit message as four 64-bit beats on the narrow pin.
    task automatic send_msg_64(input msg_t m);
        logic [255:0] bits;
        logic [1:0]   beat;
        bits = 256'(m);
        for (beat = 2'd0; beat < 2'd4; beat++) begin
            @(negedge clk);
            s_tdata  = bits[beat*64 +: 64];
            s_tkeep  = 8'hFF;
            s_tlast  = (beat == 2'd3);
            s_tvalid = 1'b1;
            @(posedge clk);
            while (!s_tready) @(posedge clk);
        end
        @(negedge clk);
        s_tvalid = 1'b0;
        s_tlast  = 1'b0;
    endtask

    task automatic wait_ev(input logic [7:0] kind, output event_t e, input int tmo = 8000);
        int t;
        e = '0;
        t = 0;
        while (t < tmo) begin
            if (evq.size() > 0) begin
                e = evq.pop_front();
                if (e.ev == kind) return;
            end else begin
                @(posedge clk);
                t++;
            end
        end
        $error("wait_ev timeout for %s", ev_name(kind));
        errors++;
    endtask

    task automatic drain(int n);
        repeat(n) @(posedge clk);
        while (evq.size() > 0) void'(evq.pop_front());
    endtask

    initial begin
        msg_t m;
        event_t e;
        logic [31:0] rd;

        rst_n = 0;
        s_tvalid = 0; s_tdata = 0; s_tkeep = 0; s_tlast = 0;
        m_tready = 1;
        awvalid = 0; wvalid = 0; arvalid = 0; bready = 0; rready = 0;
        awaddr = 0; araddr = 0; wdata = 0; wstrb = 0; awprot = 0; arprot = 0;
        errors = 0;
        n_fill = 0; n_ack = 0; n_rej = 0; n_cxl = 0;

        tick(10);
        rst_n = 1;
        // Wait for rst_sync (3 stages) + book hash init (256 cycles) + margin
        tick(400);

        // AXI-Lite confirm version through the SoC (same CSR bank, different path)
        axil_rd(CSR_VERSION, rd);
        if (rd !== QUASAR_VERSION) begin
            $error("soc64 version got %08h", rd);
            errors++;
        end
        axil_wr(CSR_CTRL,      32'h0000_0001); // enable
        axil_wr(CSR_INST_MASK, 32'hFF);

        // -------- Case 1: resting bid --------
        $display("SOC64: sending resting bid t=%0t", $time);
        m = mk_msg(OP_NEW, 0, 1, SIDE_BID, TIF_GTC, STP_OFF, 1'b0,
                   32'd10, 32'd100, 64'hF001);
        send_msg_64(m);
        $display("SOC64: msg sent, waiting ACK t=%0t", $time);
        wait_ev(EV_ACK, e);
        if (e.qty != 10) begin $error("soc64 rest qty"); errors++; end

        // -------- Case 2: matching ask fills 6, rest 4 --------
        m = mk_msg(OP_NEW, 0, 2, SIDE_ASK, TIF_GTC, STP_OFF, 1'b0,
                   32'd6, 32'd100, 64'hF002);
        send_msg_64(m);
        wait_ev(EV_FILL, e);
        if (e.qty != 6) begin $error("soc64 fill qty"); errors++; end
        wait_ev(EV_ACK, e);

        // -------- Case 3: cancel residual --------
        m = mk_msg(OP_CANCEL, 0, 1, SIDE_BID, TIF_GTC, STP_OFF, 1'b0,
                   32'd0, 32'd0, 64'hF001);
        send_msg_64(m);
        wait_ev(EV_CANCEL_ACK, e);
        if (e.qty != 4) begin $error("soc64 cxl qty got %0d", e.qty); errors++; end

        // -------- Case 4: framing error (send only 3 beats) --------
        // Send 3 beats and assert TLAST early => framing_err triggers reject.
        begin
            logic [255:0] bits;
            bits = 256'(mk_msg(OP_NEW, 0, 1, SIDE_BID, TIF_GTC, STP_OFF, 1'b0,
                               32'd1, 32'd1, 64'hF003));
            @(negedge clk);
            s_tdata = bits[63:0];   s_tkeep = 8'hFF; s_tlast = 1'b0; s_tvalid = 1'b1;
            @(posedge clk); while (!s_tready) @(posedge clk);
            @(negedge clk);
            s_tdata = bits[127:64]; s_tkeep = 8'hFF; s_tlast = 1'b0;
            @(posedge clk); while (!s_tready) @(posedge clk);
            @(negedge clk);
            // Send TLAST on beat 2 instead of beat 3 → framing error
            s_tdata = bits[191:128]; s_tkeep = 8'hFF; s_tlast = 1'b1;
            @(posedge clk); while (!s_tready) @(posedge clk);
            @(negedge clk);
            s_tvalid = 1'b0; s_tlast = 1'b0;
        end
        wait_ev(EV_REJECT, e);
        if (e.reject !== REJ_CRC) begin
            $error("soc64 framing rej got %0d", e.reject);
            errors++;
        end

        // -------- Case 5: multiple instrument round-trip --------
        for (int inst = 0; inst < 4; inst++) begin
            m = mk_msg(OP_NEW, 8'(inst), 1, SIDE_ASK, TIF_GTC, STP_OFF, 1'b0,
                       32'd1, 32'd50, 64'(64'hA000 + inst));
            send_msg_64(m);
            wait_ev(EV_ACK, e);
            if (e.inst != 8'(inst)) begin
                $error("soc64 inst mismatch got %0d want %0d", e.inst, inst);
                errors++;
            end
            // cancel it
            m = mk_msg(OP_CANCEL, 8'(inst), 1, SIDE_ASK, TIF_GTC, STP_OFF, 1'b0,
                       32'd0, 32'd0, 64'(64'hA000 + inst));
            send_msg_64(m);
            wait_ev(EV_CANCEL_ACK, e);
        end

        // -------- Case 6: replace via narrow pin --------
        m = mk_msg(OP_NEW, 0, 1, SIDE_BID, TIF_GTC, STP_OFF, 1'b0,
                   32'd5, 32'd30, 64'hB001);
        send_msg_64(m);
        wait_ev(EV_ACK, e);
        m = mk_msg(OP_REPLACE, 0, 1, SIDE_BID, TIF_GTC, STP_OFF, 1'b0,
                   32'd5, 32'd32, 64'hB001);
        send_msg_64(m);
        wait_ev(EV_REPLACE_ACK, e);
        m = mk_msg(OP_CANCEL, 0, 1, SIDE_BID, TIF_GTC, STP_OFF, 1'b0,
                   32'd0, 32'd0, 64'hB001);
        send_msg_64(m);
        wait_ev(EV_CANCEL_ACK, e);
        if (e.price !== 32'd32) begin
            $error("soc64 replace px got %0d", e.price);
            errors++;
        end

        drain(200);

        $display("tb_soc_64b: fills=%0d acks=%0d rej=%0d cxl=%0d",
                 n_fill, n_ack, n_rej, n_cxl);
        if (n_fill < 1 || errors != 0)
            $fatal(1, "tb_soc_64b FAILED (%0d errors)", errors);
        $display("tb_soc_64b PASSED");
        $finish;
    end

    initial begin
        #20_000_000;
        $fatal(1, "tb_soc_64b timeout");
    end
endmodule
