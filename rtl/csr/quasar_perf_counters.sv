// =============================================================================
// Performance counter block: saturating 32-bit counters + latency min/max/sum.
// =============================================================================

module quasar_perf_counters
    import quasar_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        soft_rst,

    input  logic        inc_order,
    input  logic        inc_fill,
    input  logic        inc_reject,
    input  logic        inc_cancel,
    input  logic        inc_ack,
    input  logic        inc_modify,
    input  logic        inc_replace,
    input  logic        inc_stp,
    input  logic        lat_valid,
    input  logic [LAT_W-1:0] lat_sample,

    output logic [31:0] cnt_orders,
    output logic [31:0] cnt_fills,
    output logic [31:0] cnt_rejects,
    output logic [31:0] cnt_cancels,
    output logic [31:0] cnt_acks,
    output logic [31:0] cnt_modify,
    output logic [31:0] cnt_replace,
    output logic [31:0] cnt_stp,
    output logic [31:0] lat_min,
    output logic [31:0] lat_max,
    output logic [31:0] lat_sum_lo
);

    quasar_counter u_ord  (.clk(clk), .rst_n(rst_n), .clr(soft_rst), .inc(inc_order),   .add('0), .add_en(1'b0), .value(cnt_orders));
    quasar_counter u_fil  (.clk(clk), .rst_n(rst_n), .clr(soft_rst), .inc(inc_fill),    .add('0), .add_en(1'b0), .value(cnt_fills));
    quasar_counter u_rej  (.clk(clk), .rst_n(rst_n), .clr(soft_rst), .inc(inc_reject),  .add('0), .add_en(1'b0), .value(cnt_rejects));
    quasar_counter u_cxl  (.clk(clk), .rst_n(rst_n), .clr(soft_rst), .inc(inc_cancel),  .add('0), .add_en(1'b0), .value(cnt_cancels));
    quasar_counter u_ack  (.clk(clk), .rst_n(rst_n), .clr(soft_rst), .inc(inc_ack),     .add('0), .add_en(1'b0), .value(cnt_acks));
    quasar_counter u_mod  (.clk(clk), .rst_n(rst_n), .clr(soft_rst), .inc(inc_modify),  .add('0), .add_en(1'b0), .value(cnt_modify));
    quasar_counter u_rep  (.clk(clk), .rst_n(rst_n), .clr(soft_rst), .inc(inc_replace), .add('0), .add_en(1'b0), .value(cnt_replace));
    quasar_counter u_stp  (.clk(clk), .rst_n(rst_n), .clr(soft_rst), .inc(inc_stp),     .add('0), .add_en(1'b0), .value(cnt_stp));

    logic [31:0] lmin, lmax, lsum;
    assign lat_min    = lmin;
    assign lat_max    = lmax;
    assign lat_sum_lo = lsum;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lmin <= 32'hFFFF_FFFF;
            lmax <= 32'h0;
            lsum <= 32'h0;
        end else if (soft_rst) begin
            lmin <= 32'hFFFF_FFFF;
            lmax <= 32'h0;
            lsum <= 32'h0;
        end else if (lat_valid) begin
            if (32'(lat_sample) < lmin)
                lmin <= 32'(lat_sample);
            if (32'(lat_sample) > lmax)
                lmax <= 32'(lat_sample);
            lsum <= lsum + 32'(lat_sample);
        end
    end

endmodule
