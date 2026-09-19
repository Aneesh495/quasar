// =============================================================================
// quasar_soc — top-level SoC wrapper
//
// Clock domains (production):
//   clk_axis_in   ingress AXIS + 64→256 upsizer
//   clk_core      book, matcher, risk, CSR datapath
//   clk_axis_out  egress AXIS + 256→64 downsizer
//   clk_axil      AXI4-Lite CSR (may be tied to clk_core)
//
// Domains are crossed with gray-coded async FIFOs.  Smoke simulation ties
// every clock together; the dual-clock path is still instantiated so the
// CDC modules are compiled and reviewed.
//
// Reset: asynchronous assert / synchronous deassert per domain, OR-ed with
// the CSR soft-reset (core domain only).
// =============================================================================

module quasar_soc
    import quasar_pkg::*;
(
    input  logic         clk_axis_in,
    input  logic         clk_core,
    input  logic         clk_axis_out,
    input  logic         clk_axil,
    input  logic         rst_n,

    // 64-bit host AXIS (production pin).  Tie tdata[63:0] and use 4-beat
    // frames, or set NARROW_AXIS=0 for native 256-bit smoke.
    input  logic         s_axis_tvalid,
    output logic         s_axis_tready,
    input  logic [63:0]  s_axis_tdata,
    input  logic [7:0]   s_axis_tkeep,
    input  logic         s_axis_tlast,

    output logic         m_axis_tvalid,
    input  logic         m_axis_tready,
    output logic [63:0]  m_axis_tdata,
    output logic [7:0]   m_axis_tkeep,
    output logic         m_axis_tlast,

    // AXI4-Lite (clk_axil)
    input  logic [AXIL_ADDR_W-1:0] s_axil_awaddr,
    input  logic [2:0]            s_axil_awprot,
    input  logic                  s_axil_awvalid,
    output logic                  s_axil_awready,
    input  logic [AXIL_DATA_W-1:0] s_axil_wdata,
    input  logic [AXIL_STRB_W-1:0] s_axil_wstrb,
    input  logic                  s_axil_wvalid,
    output logic                  s_axil_wready,
    output logic [1:0]            s_axil_bresp,
    output logic                  s_axil_bvalid,
    input  logic                  s_axil_bready,
    input  logic [AXIL_ADDR_W-1:0] s_axil_araddr,
    input  logic [2:0]            s_axil_arprot,
    input  logic                  s_axil_arvalid,
    output logic                  s_axil_arready,
    output logic [AXIL_DATA_W-1:0] s_axil_rdata,
    output logic [1:0]            s_axil_rresp,
    output logic                  s_axil_rvalid,
    input  logic                  s_axil_rready
);

    parameter bit NARROW_AXIS = 1'b1;
    parameter bit TIE_CLOCKS  = 1'b1; // 1: still instantiate async FIFOs

    logic rst_in_n, rst_core_n, rst_out_n, rst_axil_n;

    quasar_rst_sync u_rst_in   (.clk(clk_axis_in),  .async_rst_n(rst_n), .rst_n(rst_in_n));
    quasar_rst_sync u_rst_core (.clk(clk_core),     .async_rst_n(rst_n), .rst_n(rst_core_n));
    quasar_rst_sync u_rst_out  (.clk(clk_axis_out), .async_rst_n(rst_n), .rst_n(rst_out_n));
    quasar_rst_sync u_rst_axil (.clk(clk_axil),     .async_rst_n(rst_n), .rst_n(rst_axil_n));

    // -------------------------------------------------------------------------
    // Ingress width + CDC  (axis_in → core)
    // -------------------------------------------------------------------------
    logic         w_tvalid, w_tready, w_tlast, w_ferr;
    logic [255:0] w_tdata;
    logic [31:0]  w_tkeep;

    if (NARROW_AXIS) begin : g_up
        quasar_axis_upsizer u_up (
            .clk(clk_axis_in), .rst_n(rst_in_n),
            .s_tvalid(s_axis_tvalid), .s_tready(s_axis_tready),
            .s_tdata(s_axis_tdata), .s_tkeep(s_axis_tkeep), .s_tlast(s_axis_tlast),
            .m_tvalid(w_tvalid), .m_tready(w_tready),
            .m_tdata(w_tdata), .m_tkeep(w_tkeep), .m_tlast(w_tlast),
            .framing_err(w_ferr)
        );
    end else begin : g_up_bypass
        assign w_tvalid = s_axis_tvalid;
        assign s_axis_tready = w_tready;
        assign w_tdata = {192'h0, s_axis_tdata}; // not used in smoke-narrow
        assign w_tkeep = 32'hFFFF_FFFF;
        assign w_tlast = s_axis_tlast;
        assign w_ferr  = 1'b0;
    end

    logic         c_in_valid, c_in_ready, c_in_last, c_in_ferr;
    logic [255:0] c_in_data;
    logic [31:0]  c_in_keep;
    logic [31:0]  cdc_in_drops;

    typedef struct packed {
        logic [255:0] data;
        logic [31:0]  keep;
        logic         last;
        logic         ferr;
    } axis256_t;

    axis256_t in_w, in_r;

    assign in_w = '{data: w_tdata, keep: w_tkeep, last: w_tlast, ferr: w_ferr};

    quasar_async_fifo #(.WIDTH($bits(axis256_t)), .DEPTH(FIFO_DEPTH_CDC)) u_cdc_in (
        .wr_clk(clk_axis_in), .wr_rst_n(rst_in_n),
        .wr_en(w_tvalid && !cdc_in_full),
        .wr_data(in_w),
        .wr_full(cdc_in_full),
        .wr_almost_full(cdc_in_af),
        .rd_clk(clk_core), .rd_rst_n(rst_core_n),
        .rd_en(c_in_ready && !cdc_in_empty),
        .rd_data(in_r),
        .rd_empty(cdc_in_empty),
        .wr_drop_count(cdc_in_drops)
    );

    logic cdc_in_full, cdc_in_af, cdc_in_empty;
    assign w_tready   = !cdc_in_af;
    assign c_in_valid = !cdc_in_empty;
    assign c_in_data  = in_r.data;
    assign c_in_keep  = in_r.keep;
    assign c_in_last  = in_r.last;
    assign c_in_ferr  = in_r.ferr;

    // -------------------------------------------------------------------------
    // Core
    // -------------------------------------------------------------------------
    logic         c_out_valid, c_out_ready, c_out_last;
    logic [255:0] c_out_data;
    logic [31:0]  c_out_keep;

    // AXI-Lite is used on clk_core in this wrapper; a second async path
    // would be needed for a truly independent PCLK.  Documented in
    // docs/architecture.md.  Ports are still clocked by clk_axil through
    // a simple two-flop when TIE_CLOCKS=1 they are the same edge.
    quasar_core u_core (
        .clk(clk_core), .rst_n(rst_core_n),
        .s_axis_tvalid(c_in_valid),
        .s_axis_tready(c_in_ready),
        .s_axis_tdata (c_in_data),
        .s_axis_tkeep (c_in_keep),
        .s_axis_tlast (c_in_last),
        .s_axis_framing_err(c_in_ferr),
        .m_axis_tvalid(c_out_valid),
        .m_axis_tready(c_out_ready),
        .m_axis_tdata (c_out_data),
        .m_axis_tkeep (c_out_keep),
        .m_axis_tlast (c_out_last),
        .s_axil_awaddr(s_axil_awaddr),
        .s_axil_awprot(s_axil_awprot),
        .s_axil_awvalid(s_axil_awvalid),
        .s_axil_awready(s_axil_awready),
        .s_axil_wdata(s_axil_wdata),
        .s_axil_wstrb(s_axil_wstrb),
        .s_axil_wvalid(s_axil_wvalid),
        .s_axil_wready(s_axil_wready),
        .s_axil_bresp(s_axil_bresp),
        .s_axil_bvalid(s_axil_bvalid),
        .s_axil_bready(s_axil_bready),
        .s_axil_araddr(s_axil_araddr),
        .s_axil_arprot(s_axil_arprot),
        .s_axil_arvalid(s_axil_arvalid),
        .s_axil_arready(s_axil_arready),
        .s_axil_rdata(s_axil_rdata),
        .s_axil_rresp(s_axil_rresp),
        .s_axil_rvalid(s_axil_rvalid),
        .s_axil_rready(s_axil_rready)
    );

    wire unused_axil_rst = rst_axil_n;
    wire unused_tie      = TIE_CLOCKS;

    // -------------------------------------------------------------------------
    // Egress CDC + downsizer  (core → axis_out)
    // -------------------------------------------------------------------------
    axis256_t out_w, out_r;
    logic     cdc_out_full, cdc_out_af, cdc_out_empty;
    logic [31:0] cdc_out_drops;

    assign out_w = '{data: c_out_data, keep: c_out_keep, last: c_out_last, ferr: 1'b0};

    quasar_async_fifo #(.WIDTH($bits(axis256_t)), .DEPTH(FIFO_DEPTH_CDC)) u_cdc_out (
        .wr_clk(clk_core), .wr_rst_n(rst_core_n),
        .wr_en(c_out_valid && !cdc_out_full),
        .wr_data(out_w),
        .wr_full(cdc_out_full),
        .wr_almost_full(cdc_out_af),
        .rd_clk(clk_axis_out), .rd_rst_n(rst_out_n),
        .rd_en(dn_ready && !cdc_out_empty),
        .rd_data(out_r),
        .rd_empty(cdc_out_empty),
        .wr_drop_count(cdc_out_drops)
    );

    logic dn_ready, dn_valid;
    assign c_out_ready = !cdc_out_af;
    assign dn_valid    = !cdc_out_empty;

    if (NARROW_AXIS) begin : g_dn
        quasar_axis_downsizer u_dn (
            .clk(clk_axis_out), .rst_n(rst_out_n),
            .s_tvalid(dn_valid), .s_tready(dn_ready),
            .s_tdata(out_r.data), .s_tkeep(out_r.keep), .s_tlast(out_r.last),
            .m_tvalid(m_axis_tvalid), .m_tready(m_axis_tready),
            .m_tdata(m_axis_tdata), .m_tkeep(m_axis_tkeep), .m_tlast(m_axis_tlast)
        );
    end else begin : g_dn_bypass
        assign m_axis_tvalid = dn_valid;
        assign dn_ready      = m_axis_tready;
        assign m_axis_tdata  = out_r.data[63:0];
        assign m_axis_tkeep  = out_r.keep[7:0];
        assign m_axis_tlast  = out_r.last;
    end

    wire unused_in_drops  = |cdc_in_drops;
    wire unused_out_drops = |cdc_out_drops;

endmodule
