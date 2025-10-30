// =============================================================================
// Quasar matching-engine core (single clock)
//
//   AXIS in → ingress parser → cmd FIFO → risk → matcher ⇄ book
//                                              ↘ reject events
//                         matcher events + rejects → egress → AXIS out
//   AXI-Lite → CSR / perf / BBO debug
// =============================================================================

module quasar_core
    import quasar_pkg::*;
(
    input  logic         clk,
    input  logic         rst_n,

    input  logic         s_axis_tvalid,
    output logic         s_axis_tready,
    input  logic [AXIS_DATA_W-1:0] s_axis_tdata,
    input  logic [AXIS_KEEP_W-1:0] s_axis_tkeep,
    input  logic         s_axis_tlast,
    input  logic         s_axis_framing_err,

    output logic         m_axis_tvalid,
    input  logic         m_axis_tready,
    output logic [AXIS_DATA_W-1:0] m_axis_tdata,
    output logic [AXIS_KEEP_W-1:0] m_axis_tkeep,
    output logic         m_axis_tlast,

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

    // -------------------------------------------------------------------------
    logic [TS_W-1:0] cycle;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) cycle <= '0;
        else        cycle <= cycle + TS_W'(1);
    end

    logic enable, soft_rst, stp_en, bbo_ev_en, delta_ev_en;
    logic [1:0] stp_mode;
    logic [NUM_INSTRUMENTS-1:0] inst_mask;
    logic [NOTIONAL_W-1:0] max_notional;
    logic [POS_W-1:0]      max_position;
    logic [15:0]           rate_limit, rate_window;
    logic [INST_W-1:0]     dbg_inst;

    // -------------------------------------------------------------------------
    // Ingress
    // -------------------------------------------------------------------------
    logic         ig_valid, ig_ready;
    cmd_t         ig_cmd;
    logic [31:0]  drop_ig, crc_fail_ig;

    quasar_ingress u_ingress (
        .clk          (clk),
        .rst_n        (rst_n),
        .s_tvalid     (s_axis_tvalid),
        .s_tready     (s_axis_tready),
        .s_tdata      (s_axis_tdata),
        .s_tkeep      (s_axis_tkeep),
        .s_tlast      (s_axis_tlast),
        .framing_err_i(s_axis_framing_err),
        .cmd_valid    (ig_valid),
        .cmd_ready    (ig_ready),
        .cmd          (ig_cmd),
        .drop_count   (drop_ig),
        .crc_fail_count(crc_fail_ig),
        .cycle        (cycle)
    );

    logic         fifo_rd, fifo_empty, fifo_full, fifo_af;
    cmd_t         fifo_cmd;
    logic [$clog2(FIFO_DEPTH_INGRESS+1)-1:0] fifo_cnt;
    logic [31:0]  fifo_drops;

    quasar_sync_fifo #(
        .WIDTH($bits(cmd_t)),
        .DEPTH(FIFO_DEPTH_INGRESS),
        .FWFT (1'b1)
    ) u_cmd_fifo (
        .clk(clk), .rst_n(rst_n),
        .wr_en(ig_valid && !fifo_full),
        .wr_data(ig_cmd),
        .full(fifo_full),
        .almost_full(fifo_af),
        .rd_en(fifo_rd),
        .rd_data(fifo_cmd),
        .empty(fifo_empty),
        .count(fifo_cnt),
        .drop_count(fifo_drops)
    );
    assign ig_ready = !fifo_af;

    // -------------------------------------------------------------------------
    // Risk
    // -------------------------------------------------------------------------
    logic         rk_in_valid, rk_in_ready;
    logic         rk_out_valid, rk_out_ready;
    cmd_t         rk_out_cmd;
    logic         rk_rej_valid;
    logic [REJ_W-1:0] rk_rej;
    logic         pos_we;
    logic [INST_W-1:0] pos_inst;
    logic signed [POS_W-1:0] pos_delta;
    logic signed [POS_W-1:0] position [NUM_INSTRUMENTS-1:0];
    logic [15:0]  tokens_left;

    assign rk_in_valid = !fifo_empty;
    assign fifo_rd     = rk_in_valid && rk_in_ready;

    quasar_risk_gate u_risk (
        .clk(clk), .rst_n(rst_n), .soft_rst(soft_rst),
        .enable(enable),
        .inst_mask(inst_mask),
        .max_notional(max_notional),
        .max_position(max_position),
        .rate_limit(rate_limit),
        .rate_window(rate_window),
        .stp_en(stp_en),
        .stp_mode(stp_mode),
        .cmd_valid(rk_in_valid),
        .cmd_ready(rk_in_ready),
        .cmd(fifo_cmd),
        .out_valid(rk_out_valid),
        .out_ready(rk_out_ready),
        .out_cmd(rk_out_cmd),
        .reject_valid(rk_rej_valid),
        .reject_code(rk_rej),
        .pos_we(pos_we),
        .pos_inst(pos_inst),
        .pos_delta(pos_delta),
        .position(position),
        .tokens_left(tokens_left)
    );

    // -------------------------------------------------------------------------
    // Matcher + book
    // -------------------------------------------------------------------------
    logic         mt_cmd_ready;
    logic         mt_ev_valid, mt_ev_ready;
    event_t       mt_ev;
    logic         b_req_v, b_req_r, b_rsp_v, b_rsp_r;
    book_req_t    b_req;
    book_rsp_t    b_rsp;
    bbo_t [NUM_INSTRUMENTS-1:0] bbo_vec;
    logic [15:0]  ord_used, lvl_used;
    logic         book_busy, mt_busy;
    logic [5:0]   mt_state;

    logic cnt_order, cnt_fill, cnt_reject, cnt_cancel, cnt_ack;
    logic cnt_modify, cnt_replace, cnt_stp, lat_v;
    logic [LAT_W-1:0] lat_s;

    assign rk_out_ready = rk_rej_valid ? 1'b1 /* consumed below */ : mt_cmd_ready;

    quasar_matcher u_matcher (
        .clk(clk), .rst_n(rst_n), .soft_rst(soft_rst),
        .bbo_ev_en(bbo_ev_en),
        .delta_ev_en(delta_ev_en),
        .cmd_valid(rk_out_valid && !rk_rej_valid),
        .cmd_ready(mt_cmd_ready),
        .cmd(rk_out_cmd),
        .ev_valid(mt_ev_valid),
        .ev_ready(mt_ev_ready),
        .ev(mt_ev),
        .book_req_valid(b_req_v),
        .book_req_ready(b_req_r),
        .book_req(b_req),
        .book_rsp_valid(b_rsp_v),
        .book_rsp_ready(b_rsp_r),
        .book_rsp(b_rsp),
        .pos_we(pos_we),
        .pos_inst(pos_inst),
        .pos_delta(pos_delta),
        .cnt_order(cnt_order),
        .cnt_fill(cnt_fill),
        .cnt_reject(cnt_reject),
        .cnt_cancel(cnt_cancel),
        .cnt_ack(cnt_ack),
        .cnt_modify(cnt_modify),
        .cnt_replace(cnt_replace),
        .cnt_stp(cnt_stp),
        .lat_sample(lat_s),
        .lat_valid(lat_v),
        .dbg_state(mt_state),
        .busy(mt_busy)
    );

    quasar_book u_book (
        .clk(clk), .rst_n(rst_n),
        .req_valid(b_req_v),
        .req_ready(b_req_r),
        .req(b_req),
        .rsp_valid(b_rsp_v),
        .rsp_ready(b_rsp_r),
        .rsp(b_rsp),
        .bbo_vec(bbo_vec),
        .orders_used(ord_used),
        .levels_used(lvl_used),
        .busy(book_busy),
        .dbg_state()
    );

    // -------------------------------------------------------------------------
    // Event mux: risk reject has priority over matcher
    // -------------------------------------------------------------------------
    logic      eg_valid, eg_ready;
    event_t    eg_ev;
    logic      rk_rej_hold;
    event_t    rk_rej_ev;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rk_rej_hold <= 1'b0;
        else if (rk_rej_valid && !rk_rej_hold)
            rk_rej_hold <= 1'b1;
        else if (rk_rej_hold && eg_ready && !mt_ev_valid)
            rk_rej_hold <= 1'b0;
    end

    always_comb begin
        rk_rej_ev = mk_event(EV_REJECT, rk_out_cmd.inst, rk_out_cmd.firm,
                             rk_out_cmd.side, rk_rej,
                             rk_out_cmd.qty, rk_out_cmd.price, rk_out_cmd.oid,
                             32'h0, rk_out_cmd.seq, cycle);
        if (rk_rej_valid || rk_rej_hold) begin
            eg_valid    = 1'b1;
            eg_ev       = rk_rej_ev;
            mt_ev_ready = 1'b0;
        end else begin
            eg_valid    = mt_ev_valid;
            eg_ev       = mt_ev;
            mt_ev_ready = eg_ready;
        end
    end

    logic [31:0] drop_eg;
    logic [15:0] eg_count;
    logic        eg_ovf;

    quasar_egress u_egress (
        .clk(clk), .rst_n(rst_n),
        .ev_valid(eg_valid),
        .ev_ready(eg_ready),
        .ev(eg_ev),
        .m_tvalid(m_axis_tvalid),
        .m_tready(m_axis_tready),
        .m_tdata (m_axis_tdata),
        .m_tkeep (m_axis_tkeep),
        .m_tlast (m_axis_tlast),
        .drop_count(drop_eg),
        .fifo_count(eg_count),
        .overflow(eg_ovf)
    );

    // -------------------------------------------------------------------------
    // Perf + CSR
    // -------------------------------------------------------------------------
    logic [31:0] c_ord, c_fil, c_rej, c_cxl, c_ack, c_mod, c_rep, c_stp;
    logic [31:0] lmin, lmax, lsum;

    logic risk_rej_pulse;
    assign risk_rej_pulse = rk_rej_valid;

    quasar_perf_counters u_perf (
        .clk(clk), .rst_n(rst_n), .soft_rst(soft_rst),
        .inc_order(cnt_order),
        .inc_fill(cnt_fill),
        .inc_reject(cnt_reject | risk_rej_pulse),
        .inc_cancel(cnt_cancel),
        .inc_ack(cnt_ack),
        .inc_modify(cnt_modify),
        .inc_replace(cnt_replace),
        .inc_stp(cnt_stp),
        .lat_valid(lat_v),
        .lat_sample(lat_s),
        .cnt_orders(c_ord),
        .cnt_fills(c_fil),
        .cnt_rejects(c_rej),
        .cnt_cancels(c_cxl),
        .cnt_acks(c_ack),
        .cnt_modify(c_mod),
        .cnt_replace(c_rep),
        .cnt_stp(c_stp),
        .lat_min(lmin),
        .lat_max(lmax),
        .lat_sum_lo(lsum)
    );

    logic [INST_W-1:0] di;
    assign di = (dbg_inst < INST_W'(NUM_INSTRUMENTS)) ? dbg_inst : '0;

    quasar_csr u_csr (
        .clk(clk), .rst_n(rst_n),
        .s_awaddr(s_axil_awaddr), .s_awprot(s_axil_awprot),
        .s_awvalid(s_axil_awvalid), .s_awready(s_axil_awready),
        .s_wdata(s_axil_wdata), .s_wstrb(s_axil_wstrb),
        .s_wvalid(s_axil_wvalid), .s_wready(s_axil_wready),
        .s_bresp(s_axil_bresp), .s_bvalid(s_axil_bvalid), .s_bready(s_axil_bready),
        .s_araddr(s_axil_araddr), .s_arprot(s_axil_arprot),
        .s_arvalid(s_axil_arvalid), .s_arready(s_axil_arready),
        .s_rdata(s_axil_rdata), .s_rresp(s_axil_rresp),
        .s_rvalid(s_axil_rvalid), .s_rready(s_axil_rready),
        .enable(enable), .soft_rst(soft_rst),
        .stp_en(stp_en), .bbo_ev_en(bbo_ev_en), .delta_ev_en(delta_ev_en),
        .stp_mode(stp_mode), .inst_mask(inst_mask),
        .max_notional(max_notional), .max_position(max_position),
        .rate_limit(rate_limit), .rate_window(rate_window),
        .dbg_inst(dbg_inst),
        .busy(mt_busy | book_busy),
        .fsm_state(mt_state),
        .cnt_orders(c_ord), .cnt_fills(c_fil), .cnt_rejects(c_rej),
        .cnt_cancels(c_cxl), .cnt_drops(drop_eg), .cnt_acks(c_ack),
        .cnt_modify(c_mod), .cnt_replace(c_rep), .cnt_stp(c_stp),
        .drop_ingress(drop_ig + crc_fail_ig + fifo_drops),
        .drop_egress(drop_eg),
        .lat_min(lmin), .lat_max(lmax), .lat_sum_lo(lsum),
        .dbg_bid_px (bbo_vec[di].bid_px),
        .dbg_ask_px (bbo_vec[di].ask_px),
        .dbg_bid_qty(bbo_vec[di].bid_qty),
        .dbg_ask_qty(bbo_vec[di].ask_qty),
        .dbg_ord_used(32'(ord_used)),
        .dbg_lvl_used(32'(lvl_used))
    );

    wire unused_tokens = |tokens_left;
    wire unused_pos    = |position[0];
    wire unused_egc    = |eg_count;
    wire unused_ovf    = eg_ovf;
    wire unused_fcnt   = |fifo_cnt;

endmodule
