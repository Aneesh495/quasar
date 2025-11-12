// =============================================================================
// Ingress-side command arbiter and sequence-number checker.
//
// Quasar's ingress path supports a single AXI-Stream input, but larger
// systems may want to demux order flow from multiple sessions (firms) onto one
// book engine.  This module accepts up to N_SESS 256-bit AXI-Stream inputs,
// round-robin arbitrates them, applies per-session sequence tracking (detects
// gaps and resets the per-session seq counter on soft-reset), and emits a
// single cmd_t stream toward the risk gate.
//
// The arbitration is weighted-round-robin with weight=1 for all sessions
// (fairness-first; latency parity across sessions).  The arbiter holds a
// session until its current message is fully parsed; since every message is a
// single beat the grant always releases the same cycle it fires.
//
// Session tracking:
//   - Each session has an expected sequence number (starts at 0 after reset).
//   - A gap (next_seq != expected + 1) raises a sticky "seq_gap" flag per
//     session visible in a CSR extension.  The engine does NOT reject the
//     message — sequence gaps are informational because the ordering guarantee
//     only holds within a session, not across the book.
//   - OP_NOP beats are silently dropped at this stage (the ingress parser
//     would drop them too, but doing it here saves a command-FIFO slot).
//
// This module is optional; quasar_core routes sessions_in[0] directly
// when N_SESS == 1.
// =============================================================================

module quasar_ingress_mux #(
    parameter int N_SESS = 2
) (
    input  logic                   clk,
    input  logic                   rst_n,
    input  logic                   soft_rst,

    // Per-session AXI-Stream inputs
    input  logic [N_SESS-1:0]      s_tvalid,
    output logic [N_SESS-1:0]      s_tready,
    input  logic [255:0]           s_tdata  [N_SESS-1:0],
    input  logic [31:0]            s_tkeep  [N_SESS-1:0],
    input  logic [N_SESS-1:0]      s_tlast,
    input  logic [N_SESS-1:0]      s_ferr,

    // Muxed output
    output logic                   m_tvalid,
    input  logic                   m_tready,
    output logic [255:0]           m_tdata,
    output logic [31:0]            m_tkeep,
    output logic                   m_tlast,
    output logic                   m_ferr,

    // Per-session sticky sequence-gap flags (read via CSR extension)
    output logic [N_SESS-1:0]      seq_gap,
    input  logic [N_SESS-1:0]      seq_gap_clr
);

    localparam int SW = $clog2(N_SESS);

    // Round-robin grant
    logic [N_SESS-1:0] gnt;
    logic              gnt_valid;
    logic [SW-1:0]     gnt_idx;
    logic              hold;

    quasar_rr_arbiter #(.N(N_SESS)) u_arb (
        .clk(clk), .rst_n(rst_n),
        .req(s_tvalid),
        .hold(hold),
        .gnt(gnt),
        .gnt_valid(gnt_valid),
        .gnt_idx(gnt_idx)
    );

    // Grant is for a single-beat message; hold = 0 always.
    assign hold = 1'b0;

    // Mux
    always_comb begin
        s_tready = '0;
        m_tvalid = 1'b0;
        m_tdata  = '0;
        m_tkeep  = '0;
        m_tlast  = 1'b0;
        m_ferr   = 1'b0;
        if (gnt_valid) begin
            m_tvalid            = s_tvalid[gnt_idx];
            m_tdata             = s_tdata[gnt_idx];
            m_tkeep             = s_tkeep[gnt_idx];
            m_tlast             = s_tlast[gnt_idx];
            m_ferr              = s_ferr[gnt_idx];
            s_tready[gnt_idx]   = m_tready;
        end
    end

    // Per-session sequence tracking
    import quasar_pkg::*;

    logic [31:0] expected [N_SESS-1:0];
    logic        fire, drop_nop;

    assign fire     = gnt_valid && m_tvalid && m_tready;
    assign drop_nop = fire && (msg_t'(m_tdata).opcode == OP_NOP);

    genvar gi;
    generate
        for (gi = 0; gi < N_SESS; gi++) begin : g_seq
            logic this_fire;
            assign this_fire = fire && (gnt_idx == SW'(gi));

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    expected[gi] <= 32'h1;
                    seq_gap[gi]  <= 1'b0;
                end else if (soft_rst || seq_gap_clr[gi]) begin
                    expected[gi] <= 32'h1;
                    seq_gap[gi]  <= 1'b0;
                end else if (this_fire && !drop_nop) begin
                    logic [31:0] got_seq;
                    got_seq = msg_t'(m_tdata).seq;
                    if (got_seq != expected[gi] && expected[gi] != 32'h1)
                        seq_gap[gi] <= 1'b1;
                    expected[gi] <= got_seq + 32'h1;
                end
            end
        end
    endgenerate

`ifdef QUASAR_SVA
    property p_onehot;
        @(posedge clk) disable iff (!rst_n)
            gnt_valid |-> $onehot(gnt);
    endproperty
    a_onehot: assert property (p_onehot);
`endif

endmodule
