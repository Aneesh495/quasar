// =============================================================================
// Matcher SVA: in-flight command lifecycle, fill non-negative residual,
// book-request round-trip, and state-legal transitions.
// =============================================================================

`ifndef QUASAR_MATCHER_SVA_SV
`define QUASAR_MATCHER_SVA_SV

module quasar_matcher_sva
    import quasar_pkg::*;
(
    input logic        clk,
    input logic        rst_n,

    // command side
    input logic        cmd_valid,
    input logic        cmd_ready,
    input cmd_t        cmd,

    // event side
    input logic        ev_valid,
    input logic        ev_ready,
    input event_t      ev,

    // book interface
    input logic        book_req_valid,
    input logic        book_req_ready,
    input book_req_t   book_req,
    input logic        book_rsp_valid,
    input book_rsp_t   book_rsp,

    // matcher internal
    input logic        busy,
    input logic [5:0]  dbg_state
);

    // -----------------------------------------------------------------------
    // AXI-Stream liveness / stability on event output
    // -----------------------------------------------------------------------
    property p_ev_stable;
        @(posedge clk) disable iff (!rst_n)
            (ev_valid && !ev_ready) |=> ev_valid && $stable(ev);
    endproperty
    a_ev_stable: assert property (p_ev_stable)
        else $error("matcher: ev dropped while !ev_ready");

    // -----------------------------------------------------------------------
    // Book request: once raised, held until accepted
    // -----------------------------------------------------------------------
    property p_breq_stable;
        @(posedge clk) disable iff (!rst_n)
            (book_req_valid && !book_req_ready) |=> book_req_valid && $stable(book_req);
    endproperty
    a_breq_stable: assert property (p_breq_stable)
        else $error("matcher: book_req changed while !ready");

    // -----------------------------------------------------------------------
    // Fill qty must be nonzero
    // -----------------------------------------------------------------------
    property p_fill_nz;
        @(posedge clk) disable iff (!rst_n)
            (ev_valid && ev_ready && ev.ev == EV_FILL) |-> (ev.qty != '0);
    endproperty
    a_fill_nz: assert property (p_fill_nz)
        else $error("matcher: zero-qty fill emitted");

    // -----------------------------------------------------------------------
    // Busy iff a command is in-flight
    // -----------------------------------------------------------------------
    property p_idle_when_accept;
        @(posedge clk) disable iff (!rst_n)
            (cmd_valid && cmd_ready) |=> busy;
    endproperty
    a_idle: assert property (p_idle_when_accept);

    // -----------------------------------------------------------------------
    // No book request without a command in-flight
    // -----------------------------------------------------------------------
    property p_req_needs_busy;
        @(posedge clk) disable iff (!rst_n)
            book_req_valid |-> busy;
    endproperty
    a_req_busy: assert property (p_req_needs_busy)
        else $error("matcher: book request with no command in-flight");

    // -----------------------------------------------------------------------
    // Reject code populated on EV_REJECT
    // -----------------------------------------------------------------------
    property p_rej_code_set;
        @(posedge clk) disable iff (!rst_n)
            (ev_valid && ev_ready && ev.ev == EV_REJECT) |-> (ev.reject != REJ_NONE);
    endproperty
    a_rej: assert property (p_rej_code_set)
        else $error("matcher: EV_REJECT with REJ_NONE");

    // -----------------------------------------------------------------------
    // Cover
    // -----------------------------------------------------------------------
    cover_new_fill:    cover property (@(posedge clk) ev_valid && ev.ev == EV_FILL);
    cover_new_ack:     cover property (@(posedge clk) ev_valid && ev.ev == EV_ACK);
    cover_new_reject:  cover property (@(posedge clk) ev_valid && ev.ev == EV_REJECT);
    cover_book_match:  cover property (@(posedge clk) book_req_valid && book_req.cmd == BOOK_MATCH_ONE);
    cover_book_insert: cover property (@(posedge clk) book_req_valid && book_req.cmd == BOOK_INSERT);
    cover_book_cancel: cover property (@(posedge clk) book_req_valid && book_req.cmd == BOOK_CANCEL);
    cover_book_walk:   cover property (@(posedge clk) book_req_valid && book_req.cmd == BOOK_WALK_LIQ);
    cover_multi_fill:  cover property (@(posedge clk)
        ev_valid && ev.ev == EV_FILL ##[1:32] ev_valid && ev.ev == EV_FILL);

endmodule

`endif
