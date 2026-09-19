// =============================================================================
// UVM-lite top.  Constrained-random NEW stream plus directed rest/hit and
// cancel.  Scoreboard compares DUT events against the C++ golden book.
//
//   make uvm     (Verilator + DPI)
//   Full UVM + covergroups: commercial sim, see docs/verification.md
// =============================================================================

`timescale 1ns/1ps

module tb_uvm_lite;
    import quasar_pkg::*;
    import quasar_tb_pkg::*;
    import quasar_uvm_lite::*;

    logic clk, rst_n;
    initial clk = 1'b0;
    always #2 clk = ~clk;

    quasar_axis_if #(.DATA_W(256)) in_if (clk, rst_n);
    quasar_axis_if #(.DATA_W(256)) out_if(clk, rst_n);
    quasar_axil_if                 axil_if(clk, rst_n);

    logic framing_err;
    assign framing_err = 1'b0;

    quasar_core dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tvalid(in_if.tvalid),
        .s_axis_tready(in_if.tready),
        .s_axis_tdata (in_if.tdata),
        .s_axis_tkeep (in_if.tkeep),
        .s_axis_tlast (in_if.tlast),
        .s_axis_framing_err(framing_err),
        .m_axis_tvalid(out_if.tvalid),
        .m_axis_tready(out_if.tready),
        .m_axis_tdata (out_if.tdata),
        .m_axis_tkeep (out_if.tkeep),
        .m_axis_tlast (out_if.tlast),
        .s_axil_awaddr(axil_if.awaddr),
        .s_axil_awprot(axil_if.awprot),
        .s_axil_awvalid(axil_if.awvalid),
        .s_axil_awready(axil_if.awready),
        .s_axil_wdata(axil_if.wdata),
        .s_axil_wstrb(axil_if.wstrb),
        .s_axil_wvalid(axil_if.wvalid),
        .s_axil_wready(axil_if.wready),
        .s_axil_bresp(axil_if.bresp),
        .s_axil_bvalid(axil_if.bvalid),
        .s_axil_bready(axil_if.bready),
        .s_axil_araddr(axil_if.araddr),
        .s_axil_arprot(axil_if.arprot),
        .s_axil_arvalid(axil_if.arvalid),
        .s_axil_arready(axil_if.arready),
        .s_axil_rdata(axil_if.rdata),
        .s_axil_rresp(axil_if.rresp),
        .s_axil_rvalid(axil_if.rvalid),
        .s_axil_rready(axil_if.rready)
    );

    // Always-ready consumer so the engine is never egress-stalled in this TB.
    assign out_if.tready = 1'b1;

    quasar_env env;

    initial begin
        logic [31:0] rd;
        rst_n = 1'b0;
        in_if.tvalid = 1'b0;
        axil_if.awvalid = 1'b0;
        axil_if.wvalid  = 1'b0;
        axil_if.arvalid = 1'b0;
        axil_if.bready  = 1'b0;
        axil_if.rready  = 1'b0;
        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (400) @(posedge clk);

        env = new(in_if, out_if, axil_if);
        env.run();
        env.csr.write(CSR_CTRL, 32'h0000_0001); // enable, no BBO side-channel
        env.csr.write(CSR_INST_MASK, 32'hFF);
        env.csr.read(CSR_VERSION, rd);
        if (rd !== QUASAR_VERSION)
            $fatal(1, "bad version %08h", rd);

        env.seq.directed_rest_and_hit();
        env.seq.directed_cancel();
        env.seq.random_stream(32);

        // let the pipeline drain
        repeat (8000) @(posedge clk);

        if (env.scb.mismatches != 0)
            $fatal(1, "tb_uvm_lite FAILED mismatches=%0d compared=%0d",
                   env.scb.mismatches, env.scb.compared);
        if (env.scb.compared == 0)
            $fatal(1, "tb_uvm_lite compared nothing");
        $display("tb_uvm_lite PASSED compared=%0d sent=%0d seen=%0d",
                 env.scb.compared, env.drv.n_sent, env.mon.n_seen);
        $finish;
    end

    initial begin
        #20_000_000;
        $fatal(1, "tb_uvm_lite timeout");
    end

endmodule
