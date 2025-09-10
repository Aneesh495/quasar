// =============================================================================
// AXI4-Lite interface (32-bit data, 16-bit addr by default).
// =============================================================================

interface quasar_axil_if #(
    parameter int ADDR_W = 16,
    parameter int DATA_W = 32
) (
    input logic clk,
    input logic rst_n
);

    localparam int STRB_W = DATA_W / 8;

    logic [ADDR_W-1:0] awaddr;
    logic [2:0]        awprot;
    logic              awvalid;
    logic              awready;

    logic [DATA_W-1:0] wdata;
    logic [STRB_W-1:0] wstrb;
    logic              wvalid;
    logic              wready;

    logic [1:0]        bresp;
    logic              bvalid;
    logic              bready;

    logic [ADDR_W-1:0] araddr;
    logic [2:0]        arprot;
    logic              arvalid;
    logic              arready;

    logic [DATA_W-1:0] rdata;
    logic [1:0]        rresp;
    logic              rvalid;
    logic              rready;

    modport master (
        output awaddr, awprot, awvalid, wdata, wstrb, wvalid, bready,
               araddr, arprot, arvalid, rready,
        input  awready, wready, bresp, bvalid, arready, rdata, rresp, rvalid
    );

    modport slave (
        input  awaddr, awprot, awvalid, wdata, wstrb, wvalid, bready,
               araddr, arprot, arvalid, rready,
        output awready, wready, bresp, bvalid, arready, rdata, rresp, rvalid
    );

`ifdef QUASAR_SVA
    property p_aw_hold;
        @(posedge clk) disable iff (!rst_n)
            (awvalid && !awready) |=> awvalid && $stable(awaddr);
    endproperty
    assert property (p_aw_hold);

    property p_w_hold;
        @(posedge clk) disable iff (!rst_n)
            (wvalid && !wready) |=> wvalid && $stable(wdata) && $stable(wstrb);
    endproperty
    assert property (p_w_hold);

    property p_ar_hold;
        @(posedge clk) disable iff (!rst_n)
            (arvalid && !arready) |=> arvalid && $stable(araddr);
    endproperty
    assert property (p_ar_hold);

    property p_b_hold;
        @(posedge clk) disable iff (!rst_n)
            (bvalid && !bready) |=> bvalid && $stable(bresp);
    endproperty
    assert property (p_b_hold);

    property p_r_hold;
        @(posedge clk) disable iff (!rst_n)
            (rvalid && !rready) |=> rvalid && $stable(rdata) && $stable(rresp);
    endproperty
    assert property (p_r_hold);
`endif

endinterface
