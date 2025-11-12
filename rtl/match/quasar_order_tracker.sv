// =============================================================================
// Per-session order tracker.
//
// Maintains a compact in-flight set (max MAX_LIVE orders per session) to
// answer questions the risk gate cares about quickly and without touching
// the book:
//   - Is this OID already live? (duplicate check)
//   - What is the aggregate order value currently exposed?
//   - How many live orders does this session have?
//
// Implementation: direct-mapped tag store indexed by oid[LOG_TAGS-1:0].
// A collision evicts the old entry (acceptable for order flow that does not
// reuse OID bits in the low bits within a session's live window).  For
// higher reliability, increase LOG_TAGS or add a small set-associative tag.
//
// The tracker is read combinationally and written on every fill/cancel/ack.
// It is an informational satellite — the authoritative duplicate check is in
// the book hash table.  The risk gate uses this only for low-latency notional
// accumulation without waiting for a book round-trip.
//
// In this implementation the tracker is wired up but not yet connected to
// the main pipeline (it is instantiated separately for bring-up).
// =============================================================================

module quasar_order_tracker #(
    parameter int LOG_TAGS  = 8,    // 2^8 = 256 slots
    parameter int N_SESS    = 8
) (
    input  logic                clk,
    input  logic                rst_n,
    input  logic                soft_rst,

    // Insert: new order accepted
    input  logic                ins_en,
    input  logic [7:0]          ins_sess,
    input  logic [63:0]         ins_oid,
    input  logic [31:0]         ins_qty,
    input  logic [31:0]         ins_price,
    input  logic                ins_side,

    // Remove: cancel or fully-filled
    input  logic                rem_en,
    input  logic [63:0]         rem_oid,

    // Query: lookup for dup check / notional
    input  logic [63:0]         q_oid,
    output logic                q_hit,
    output logic [31:0]         q_qty,
    output logic [31:0]         q_price,
    output logic                q_side,
    output logic [7:0]          q_sess,

    // Per-session live-order count and notional
    output logic [7:0]          live_count  [N_SESS-1:0],
    output logic [63:0]         live_notional [N_SESS-1:0]
);

    localparam int TAGS = 1 << LOG_TAGS;

    typedef struct packed {
        logic             valid;
        logic [63:0]      oid;
        logic [31:0]      qty;
        logic [31:0]      price;
        logic             side;
        logic [7:0]       sess;
    } tag_t;

    tag_t tags [0:TAGS-1];

    function automatic logic [LOG_TAGS-1:0] idx(input logic [63:0] oid);
        idx = oid[LOG_TAGS-1:0];
    endfunction

    // Query (combinational)
    always_comb begin
        tag_t t;
        t       = tags[idx(q_oid)];
        q_hit   = t.valid && (t.oid == q_oid);
        q_qty   = t.qty;
        q_price = t.price;
        q_side  = t.side;
        q_sess  = t.sess;
    end

    // Live count / notional accumulators
    integer li;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (li = 0; li < TAGS; li++)
                tags[li] <= '0;
            for (li = 0; li < N_SESS; li++) begin
                live_count[li]    <= 8'h0;
                live_notional[li] <= 64'h0;
            end
        end else if (soft_rst) begin
            for (li = 0; li < TAGS; li++)
                tags[li].valid <= 1'b0;
            for (li = 0; li < N_SESS; li++) begin
                live_count[li]    <= 8'h0;
                live_notional[li] <= 64'h0;
            end
        end else begin
            // Remove before insert (handles same-cycle replace)
            if (rem_en) begin
                logic [LOG_TAGS-1:0] ri;
                tag_t rt;
                ri = idx(rem_oid);
                rt = tags[ri];
                if (rt.valid && rt.oid == rem_oid) begin
                    tags[ri].valid <= 1'b0;
                    if (rt.sess < N_SESS[7:0]) begin
                        if (live_count[rt.sess] != 8'h0)
                            live_count[rt.sess] <= live_count[rt.sess] - 8'h1;
                        logic [63:0] nv;
                        nv = {32'h0, rt.qty} * {32'h0, rt.price};
                        if (live_notional[rt.sess] >= nv)
                            live_notional[rt.sess] <= live_notional[rt.sess] - nv;
                        else
                            live_notional[rt.sess] <= 64'h0;
                    end
                end
            end

            if (ins_en) begin
                logic [LOG_TAGS-1:0] ii;
                ii = idx(ins_oid);
                // Evict whatever was here (may add a small count/notional error
                // if evicting a live order from a different session — acceptable
                // for the soft-check role of this module).
                if (tags[ii].valid && tags[ii].oid != ins_oid) begin
                    tag_t ot;
                    ot = tags[ii];
                    if (ot.sess < N_SESS[7:0]) begin
                        if (live_count[ot.sess] != 8'h0)
                            live_count[ot.sess] <= live_count[ot.sess] - 8'h1;
                        logic [63:0] onv;
                        onv = {32'h0, ot.qty} * {32'h0, ot.price};
                        if (live_notional[ot.sess] >= onv)
                            live_notional[ot.sess] <= live_notional[ot.sess] - onv;
                        else
                            live_notional[ot.sess] <= 64'h0;
                    end
                end
                tags[ii].valid <= 1'b1;
                tags[ii].oid   <= ins_oid;
                tags[ii].qty   <= ins_qty;
                tags[ii].price <= ins_price;
                tags[ii].side  <= ins_side;
                tags[ii].sess  <= ins_sess;
                if (ins_sess < N_SESS[7:0]) begin
                    if (!tags[ii].valid || tags[ii].oid != ins_oid) begin
                        // New slot
                        if (live_count[ins_sess] != 8'hFF)
                            live_count[ins_sess] <= live_count[ins_sess] + 8'h1;
                        logic [63:0] inv;
                        inv = {32'h0, ins_qty} * {32'h0, ins_price};
                        if (live_notional[ins_sess] + inv >= live_notional[ins_sess])
                            live_notional[ins_sess] <= live_notional[ins_sess] + inv;
                        else
                            live_notional[ins_sess] <= 64'hFFFF_FFFF_FFFF_FFFF;
                    end
                end
            end
        end
    end

`ifdef QUASAR_SVA
    property p_valid_has_oid;
        @(posedge clk) disable iff (!rst_n)
            q_hit |-> tags[q_oid[LOG_TAGS-1:0]].valid;
    endproperty
    a_valid: assert property (p_valid_has_oid);
`endif

endmodule
