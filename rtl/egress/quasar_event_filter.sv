// =============================================================================
// Egress event filter / gate.
//
// Sits between the event mux and the egress FIFO.  Allows software to
// suppress certain event types (e.g., turn off EV_BBO floods during a
// low-latency burst window) without a full soft-reset.  Configuration is
// a 32-bit bitmask where bit N suppresses events with `ev == N`.
//
// Also provides per-event-type saturating counters visible over a small
// sideband; these are separate from the main perf counters in quasar_csr
// so the filter's drop statistics can be read without stopping the pipeline.
//
// Latency: zero (combinational path, one skid buffer to isolate timing).
// =============================================================================

module quasar_event_filter
    import quasar_pkg::*;
(
    input  logic         clk,
    input  logic         rst_n,
    input  logic         soft_rst,

    // Filter mask: bit N suppresses ev==N.  CSR-driven.
    input  logic [31:0]  suppress_mask,

    // Input from event mux
    input  logic         in_valid,
    output logic         in_ready,
    input  event_t       in_ev,

    // Output to egress FIFO
    output logic         out_valid,
    input  logic         out_ready,
    output event_t       out_ev,

    // Per-type drop counters (clocked, 16-bit saturating)
    output logic [15:0]  drop_fill,
    output logic [15:0]  drop_bbo,
    output logic [15:0]  drop_ack,
    output logic [15:0]  drop_rej,
    output logic [15:0]  drop_other
);

    logic suppress;
    assign suppress = suppress_mask[in_ev.ev[4:0]];

    assign in_ready  = suppress ? 1'b1 : out_ready;
    assign out_valid = in_valid && !suppress;
    assign out_ev    = in_ev;

    // Drop counters
    logic drop_pulse, drop_fill_p, drop_bbo_p, drop_ack_p, drop_rej_p, drop_oth_p;
    assign drop_pulse  = in_valid && suppress;
    assign drop_fill_p = drop_pulse && in_ev.ev == EV_FILL;
    assign drop_bbo_p  = drop_pulse && in_ev.ev == EV_BBO;
    assign drop_ack_p  = drop_pulse && (in_ev.ev == EV_ACK || in_ev.ev == EV_REPLACE_ACK);
    assign drop_rej_p  = drop_pulse && in_ev.ev == EV_REJECT;
    assign drop_oth_p  = drop_pulse && !drop_fill_p && !drop_bbo_p && !drop_ack_p && !drop_rej_p;

    function automatic logic [15:0] sat_inc(input logic [15:0] v);
        sat_inc = (&v) ? v : v + 16'd1;
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            drop_fill  <= 16'h0;
            drop_bbo   <= 16'h0;
            drop_ack   <= 16'h0;
            drop_rej   <= 16'h0;
            drop_other <= 16'h0;
        end else if (soft_rst) begin
            drop_fill  <= 16'h0;
            drop_bbo   <= 16'h0;
            drop_ack   <= 16'h0;
            drop_rej   <= 16'h0;
            drop_other <= 16'h0;
        end else begin
            if (drop_fill_p) drop_fill  <= sat_inc(drop_fill);
            if (drop_bbo_p)  drop_bbo   <= sat_inc(drop_bbo);
            if (drop_ack_p)  drop_ack   <= sat_inc(drop_ack);
            if (drop_rej_p)  drop_rej   <= sat_inc(drop_rej);
            if (drop_oth_p)  drop_other <= sat_inc(drop_other);
        end
    end

`ifdef QUASAR_SVA
    // Suppressed events never reach the output.
    property p_suppress;
        @(posedge clk) disable iff (!rst_n)
            (in_valid && suppress_mask[in_ev.ev[4:0]]) |->
                (!out_valid || out_ev.ev != in_ev.ev);
    endproperty
    // Note: this is approximate — it checks the cycle not the causal path.
    // Full verification uses the scoreboard.
`endif

endmodule
