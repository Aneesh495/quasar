// =============================================================================
// AXI4-Lite CSR bank
//
// Independent read and write channels, OKAY responses, byte-strobed writes
// on 32-bit words.  Soft-reset is a one-cycle pulse decoded from CTRL[1]
// (self-clearing).  Debug BBO words follow CSR_DBG_INST.
// =============================================================================

module quasar_csr
    import quasar_pkg::*;
(
    input  logic                  clk,
    input  logic                  rst_n,

    input  logic [AXIL_ADDR_W-1:0] s_awaddr,
    input  logic [2:0]            s_awprot,
    input  logic                  s_awvalid,
    output logic                  s_awready,
    input  logic [AXIL_DATA_W-1:0] s_wdata,
    input  logic [AXIL_STRB_W-1:0] s_wstrb,
    input  logic                  s_wvalid,
    output logic                  s_wready,
    output logic [1:0]            s_bresp,
    output logic                  s_bvalid,
    input  logic                  s_bready,
    input  logic [AXIL_ADDR_W-1:0] s_araddr,
    input  logic [2:0]            s_arprot,
    input  logic                  s_arvalid,
    output logic                  s_arready,
    output logic [AXIL_DATA_W-1:0] s_rdata,
    output logic [1:0]            s_rresp,
    output logic                  s_rvalid,
    input  logic                  s_rready,

    output logic                  enable,
    output logic                  soft_rst,
    output logic                  stp_en,
    output logic                  bbo_ev_en,
    output logic                  delta_ev_en,
    output logic [1:0]            stp_mode,
    output logic [NUM_INSTRUMENTS-1:0] inst_mask,
    output logic [NOTIONAL_W-1:0] max_notional,
    output logic [POS_W-1:0]      max_position,
    output logic [15:0]           rate_limit,
    output logic [15:0]           rate_window,
    output logic [INST_W-1:0]     dbg_inst,

    input  logic                  busy,
    input  logic [5:0]            fsm_state,
    input  logic [31:0]           cnt_orders,
    input  logic [31:0]           cnt_fills,
    input  logic [31:0]           cnt_rejects,
    input  logic [31:0]           cnt_cancels,
    input  logic [31:0]           cnt_drops,
    input  logic [31:0]           cnt_acks,
    input  logic [31:0]           cnt_modify,
    input  logic [31:0]           cnt_replace,
    input  logic [31:0]           cnt_stp,
    input  logic [31:0]           drop_ingress,
    input  logic [31:0]           drop_egress,
    input  logic [31:0]           lat_min,
    input  logic [31:0]           lat_max,
    input  logic [31:0]           lat_sum_lo,
    input  logic [31:0]           dbg_bid_px,
    input  logic [31:0]           dbg_ask_px,
    input  logic [31:0]           dbg_bid_qty,
    input  logic [31:0]           dbg_ask_qty,
    input  logic [31:0]           dbg_ord_used,
    input  logic [31:0]           dbg_lvl_used
);

    logic [31:0] ctrl, scratch;
    logic [31:0] risk_notional_lo, risk_pos, risk_rate;
    logic [31:0] inst_mask_r, stp_r, dbg_inst_r;

    assign enable      = ctrl[CTRL_ENABLE];
    assign stp_en      = ctrl[CTRL_STP_EN];
    assign bbo_ev_en   = ctrl[CTRL_BBO_EN];
    assign delta_ev_en = ctrl[CTRL_DELTA_EN];
    assign inst_mask   = inst_mask_r[NUM_INSTRUMENTS-1:0];
    assign max_notional= {32'h0, risk_notional_lo};
    assign max_position= risk_pos;
    assign rate_limit  = risk_rate[15:0];
    assign rate_window = risk_rate[31:16];
    assign stp_mode    = stp_r[1:0];
    assign dbg_inst    = dbg_inst_r[INST_W-1:0];

    // self-clearing soft reset
    logic soft_rst_r;
    assign soft_rst = soft_rst_r;

    // ---- write channel: wait for both AW and W, then B ----
    logic              aw_h, w_h;
    logic [15:0]       aw_addr;
    logic [31:0]       w_data;
    logic [3:0]        w_strb;
    logic              wr_fire, wr_go;

    assign s_awready = !aw_h && !s_bvalid;
    assign s_wready  = !w_h  && !s_bvalid;
    assign wr_fire   = (aw_h || (s_awvalid && s_awready)) &&
                       (w_h  || (s_wvalid  && s_wready));
    assign wr_go     = wr_fire && !s_bvalid;

    function automatic logic [31:0] merge_w(
        input logic [31:0] oldv,
        input logic [31:0] newv,
        input logic [3:0]  strb
    );
        logic [31:0] r;
        r = oldv;
        if (strb[0]) r[7:0]   = newv[7:0];
        if (strb[1]) r[15:8]  = newv[15:8];
        if (strb[2]) r[23:16] = newv[23:16];
        if (strb[3]) r[31:24] = newv[31:24];
        merge_w = r;
    endfunction

    logic [15:0] wr_addr;
    logic [31:0] wr_data;
    logic [3:0]  wr_strb;

    always_comb begin
        wr_addr = aw_h ? aw_addr : s_awaddr;
        wr_data = w_h  ? w_data  : s_wdata;
        wr_strb = w_h  ? w_strb  : s_wstrb;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_h <= 1'b0;
            w_h  <= 1'b0;
            aw_addr <= '0;
            w_data  <= '0;
            w_strb  <= '0;
            s_bvalid <= 1'b0;
            s_bresp  <= 2'b00;
            ctrl <= 32'h0000_0009; // enable + bbo_ev
            scratch <= 32'h0;
            risk_notional_lo <= 32'h0; // 0 = off
            risk_pos <= 32'h0;
            risk_rate <= 32'h0;
            inst_mask_r <= 32'h0000_00FF;
            stp_r <= 32'h0;
            dbg_inst_r <= 32'h0;
            soft_rst_r <= 1'b0;
        end else begin
            soft_rst_r <= 1'b0;

            if (s_awvalid && s_awready) begin
                aw_h    <= 1'b1;
                aw_addr <= s_awaddr;
            end
            if (s_wvalid && s_wready) begin
                w_h    <= 1'b1;
                w_data <= s_wdata;
                w_strb <= s_wstrb;
            end

            if (wr_go) begin
                aw_h <= 1'b0;
                w_h  <= 1'b0;
                s_bvalid <= 1'b1;
                s_bresp  <= 2'b00;
                unique case ({wr_addr[15:2], 2'b00})
                    CSR_CTRL: begin
                        ctrl <= merge_w(ctrl, wr_data, wr_strb);
                        if (wr_data[CTRL_SOFT_RST] && wr_strb[0])
                            soft_rst_r <= 1'b1;
                    end
                    CSR_RISK_NOTIONAL: risk_notional_lo <= merge_w(risk_notional_lo, wr_data, wr_strb);
                    CSR_RISK_POSITION: risk_pos <= merge_w(risk_pos, wr_data, wr_strb);
                    CSR_RISK_RATE:     risk_rate <= merge_w(risk_rate, wr_data, wr_strb);
                    CSR_RISK_WINDOW:   risk_rate[31:16] <= wr_strb[2] ? wr_data[15:0] : risk_rate[31:16];
                    CSR_INST_MASK:     inst_mask_r <= merge_w(inst_mask_r, wr_data, wr_strb);
                    CSR_STP_MODE:      stp_r <= merge_w(stp_r, wr_data, wr_strb);
                    CSR_SCRATCH:       scratch <= merge_w(scratch, wr_data, wr_strb);
                    CSR_DBG_INST:      dbg_inst_r <= merge_w(dbg_inst_r, wr_data, wr_strb);
                    default: ;
                endcase
            end else if (s_bvalid && s_bready) begin
                s_bvalid <= 1'b0;
            end

            // CTRL[1] is self-clearing
            if (ctrl[CTRL_SOFT_RST])
                ctrl[CTRL_SOFT_RST] <= 1'b0;
        end
    end

    // ---- read channel ----
    logic [31:0] rdata_n;

    always_comb begin
        unique case ({s_araddr[15:2], 2'b00})
            CSR_CTRL:          rdata_n = ctrl;
            CSR_STATUS:        rdata_n = {10'h0, fsm_state, 8'h0, 7'h0, busy};
            CSR_RISK_NOTIONAL: rdata_n = risk_notional_lo;
            CSR_RISK_POSITION: rdata_n = risk_pos;
            CSR_RISK_RATE:     rdata_n = {16'h0, rate_limit};
            CSR_RISK_WINDOW:   rdata_n = {16'h0, rate_window};
            CSR_INST_MASK:     rdata_n = inst_mask_r;
            CSR_STP_MODE:      rdata_n = stp_r;
            CSR_CNT_ORDERS:    rdata_n = cnt_orders;
            CSR_CNT_FILLS:     rdata_n = cnt_fills;
            CSR_CNT_REJECTS:   rdata_n = cnt_rejects;
            CSR_CNT_CANCELS:   rdata_n = cnt_cancels;
            CSR_CNT_DROPS:     rdata_n = cnt_drops;
            CSR_CNT_ACKS:      rdata_n = cnt_acks;
            CSR_LAT_MIN:       rdata_n = lat_min;
            CSR_LAT_MAX:       rdata_n = lat_max;
            CSR_LAT_SUM_LO:    rdata_n = lat_sum_lo;
            CSR_SCRATCH:       rdata_n = scratch;
            CSR_DBG_INST:      rdata_n = dbg_inst_r;
            CSR_DBG_BID_PX:    rdata_n = dbg_bid_px;
            CSR_DBG_ASK_PX:    rdata_n = dbg_ask_px;
            CSR_DBG_BID_QTY:   rdata_n = dbg_bid_qty;
            CSR_DBG_ASK_QTY:   rdata_n = dbg_ask_qty;
            CSR_DBG_ORD_USED:  rdata_n = dbg_ord_used;
            CSR_DBG_LVL_USED:  rdata_n = dbg_lvl_used;
            CSR_VERSION:       rdata_n = QUASAR_VERSION;
            CSR_FEATURE:       rdata_n = QUASAR_FEATURE;
            CSR_CNT_MODIFY:    rdata_n = cnt_modify;
            CSR_CNT_REPLACE:   rdata_n = cnt_replace;
            CSR_CNT_STP:       rdata_n = cnt_stp;
            CSR_DROP_INGRESS:  rdata_n = drop_ingress;
            CSR_DROP_EGRESS:   rdata_n = drop_egress;
            default:           rdata_n = 32'hDEAD_BEEF;
        endcase
    end

    assign s_arready = !s_rvalid;
    assign s_rresp   = 2'b00;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_rvalid <= 1'b0;
            s_rdata  <= 32'h0;
        end else begin
            if (s_arvalid && s_arready) begin
                s_rvalid <= 1'b1;
                s_rdata  <= rdata_n;
            end else if (s_rvalid && s_rready) begin
                s_rvalid <= 1'b0;
            end
        end
    end

    wire unused_awprot = |s_awprot;
    wire unused_arprot = |s_arprot;

endmodule
