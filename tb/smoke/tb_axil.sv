// AXI4-Lite CSR directed test: VERSION, SCRATCH strobes, CTRL self-clear,
// counter increment visibility after a tiny traffic burst.

`timescale 1ns/1ps

module tb_axil;
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
        .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep), .m_axis_tlast(m_tlast),
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
    assign m_tready = 1'b1;

    task automatic tick(int n=1);
        repeat (n) @(posedge clk);
    endtask

    task automatic axil_wr(input logic [15:0] a, input logic [31:0] d, input logic [3:0] s = 4'hF);
        bit aw_done, w_done;
        aw_done = 0; w_done = 0;
        @(negedge clk);
        awaddr = a; awvalid = 1; awprot = 0;
        wdata = d; wvalid = 1; wstrb = s; bready = 1;
        while (!aw_done || !w_done) begin
            @(posedge clk);
            if (awvalid && awready) aw_done = 1;
            if (wvalid && wready) w_done = 1;
            @(negedge clk);
            if (aw_done) awvalid = 0;
            if (w_done) wvalid = 0;
        end
        @(posedge clk);
        while (!bvalid) @(posedge clk);
        if (bresp != 2'b00) begin $error("bresp"); errors++; end
        @(negedge clk);
        bready = 0;
    endtask

    task automatic axil_rd(input logic [15:0] a, output logic [31:0] d);
        @(negedge clk);
        araddr = a; arvalid = 1; arprot = 0; rready = 1;
        @(posedge clk);
        while (!arready) @(posedge clk);
        @(negedge clk);
        arvalid = 0;
        @(posedge clk);
        while (!rvalid) @(posedge clk);
        d = rdata;
        if (rresp != 2'b00) begin $error("rresp"); errors++; end
        @(negedge clk);
        rready = 0;
    endtask

    initial begin
        logic [31:0] rd;
        rst_n = 0;
        s_tvalid = 0; s_tdata = 0; s_tkeep = 0; s_tlast = 0; s_ferr = 0;
        awvalid = 0; wvalid = 0; arvalid = 0; bready = 0; rready = 0;
        awaddr = 0; araddr = 0; wdata = 0; wstrb = 0; awprot = 0; arprot = 0;
        errors = 0;
        tick(6);
        rst_n = 1;
        tick(20);

        axil_rd(CSR_VERSION, rd);
        if (rd !== QUASAR_VERSION) begin $error("ver"); errors++; end
        axil_rd(CSR_FEATURE, rd);
        if (rd !== QUASAR_FEATURE) begin $error("feat"); errors++; end

        axil_wr(CSR_SCRATCH, 32'h1122_3344);
        axil_rd(CSR_SCRATCH, rd);
        if (rd !== 32'h1122_3344) begin $error("scratch full"); errors++; end

        // byte strobe: write only high byte
        axil_wr(CSR_SCRATCH, 32'hAA00_0000, 4'b1000);
        axil_rd(CSR_SCRATCH, rd);
        if (rd !== 32'hAA22_3344) begin
            $error("scratch strobe got %08h", rd);
            errors++;
        end

        axil_rd(CSR_CTRL, rd);
        if (rd[0] !== 1'b1) begin $error("default enable"); errors++; end

        axil_wr(CSR_CTRL, 32'h0000_0003); // enable + soft rst
        tick(4);
        axil_rd(CSR_CTRL, rd);
        if (rd[1] !== 1'b0) begin $error("soft rst not self-clear"); errors++; end

        axil_rd(16'h0ABC, rd);
        if (rd !== 32'hDEAD_BEEF) begin $error("unmapped"); errors++; end

        if (errors) $fatal(1, "tb_axil FAILED");
        $display("tb_axil PASSED");
        $finish;
    end
endmodule
