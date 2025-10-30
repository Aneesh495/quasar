// =============================================================================
// Egress path
//
// Event log FIFO (FWFT) → AXI4-Stream master.  When the FIFO is full the
// drop counter increments and the beat is discarded (the matcher still
// completes — we never stall the book on a slow consumer past the FIFO
// depth).  Optional 64-bit downsizer sits after this block.
//
// Events: fills, rejects, acks, cancel/modify/replace acks, BBO, drops.
// =============================================================================

module quasar_egress
    import quasar_pkg::*;
(
    input  logic         clk,
    input  logic         rst_n,

    input  logic         ev_valid,
    output logic         ev_ready,
    input  event_t       ev,

    output logic         m_tvalid,
    input  logic         m_tready,
    output logic [AXIS_DATA_W-1:0] m_tdata,
    output logic [AXIS_KEEP_W-1:0] m_tkeep,
    output logic         m_tlast,

    output logic [31:0]  drop_count,
    output logic [15:0]  fifo_count,
    output logic         overflow
);

    logic             wr_en, rd_en, full, empty, almost_full;
    logic [31:0]      drops;
    event_t           rd_ev;
    logic [$clog2(FIFO_DEPTH_EVENT+1)-1:0] used;

    assign wr_en    = ev_valid && !full;
    assign ev_ready = !almost_full;   // leave a slot so matcher can handshake
    assign overflow = ev_valid && full;

    quasar_sync_fifo #(
        .WIDTH      ($bits(event_t)),
        .DEPTH      (FIFO_DEPTH_EVENT),
        .FWFT       (1'b1),
        .DROP_ON_FULL(1'b1)
    ) u_log (
        .clk         (clk),
        .rst_n       (rst_n),
        .wr_en       (wr_en),
        .wr_data     (ev),
        .full        (full),
        .almost_full (almost_full),
        .rd_en       (rd_en),
        .rd_data     (rd_ev),
        .empty       (empty),
        .count       (used),
        .drop_count  (drops)
    );

    // AXI-Stream skid so tready can be combinationally isolated.
    logic             sk_valid, sk_ready;
    logic [AXIS_DATA_W-1:0] sk_data;

    assign sk_valid = !empty;
    assign rd_en    = sk_ready && !empty;
    assign sk_data  = AXIS_DATA_W'(rd_ev);

    quasar_skid_buffer #(.WIDTH(AXIS_DATA_W)) u_skid (
        .clk     (clk),
        .rst_n   (rst_n),
        .s_valid (sk_valid),
        .s_ready (sk_ready),
        .s_data  (sk_data),
        .m_valid (m_tvalid),
        .m_ready (m_tready),
        .m_data  (m_tdata)
    );

    assign m_tkeep = {AXIS_KEEP_W{1'b1}};
    assign m_tlast = 1'b1;
    assign drop_count = drops;
    assign fifo_count = 16'(used);

endmodule
