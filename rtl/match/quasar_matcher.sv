// =============================================================================
// Matching pipeline
//
//   decode → (risk already applied) → book lookup → match* → rest/update → emit
//
// One ingress command is in-flight at a time.  MATCH_ONE is issued repeatedly
// while the residual quantity still crosses; each fill is emitted as EV_FILL
// before the next hop so a stalled egress cannot lose a trade.  GTC residual
// is inserted; IOC residual is discarded; FOK is probed with WALK_LIQ and
// rejected unless the full size is available.
//
// Replace is cancel + new (same oid) when price changes, or in-place modify
// when only quantity changes.  Cancel/replace correctness hangs off the book's
// hash + doubly-linked unlinks — this module never pokes RAM directly.
// =============================================================================

module quasar_matcher
    import quasar_pkg::*;
(
    input  logic          clk,
    input  logic          rst_n,
    input  logic          soft_rst,
    input  logic          bbo_ev_en,
    input  logic          delta_ev_en,

    input  logic          cmd_valid,
    output logic          cmd_ready,
    input  cmd_t          cmd,

    output logic          ev_valid,
    input  logic          ev_ready,
    output event_t        ev,

    output logic          book_req_valid,
    input  logic          book_req_ready,
    output book_req_t     book_req,
    input  logic          book_rsp_valid,
    output logic          book_rsp_ready,
    input  book_rsp_t     book_rsp,

    output logic                  pos_we,
    output logic [INST_W-1:0]     pos_inst,
    output logic signed [POS_W-1:0] pos_delta,

    output logic          cnt_order,
    output logic          cnt_fill,
    output logic          cnt_reject,
    output logic          cnt_cancel,
    output logic          cnt_ack,
    output logic          cnt_modify,
    output logic          cnt_replace,
    output logic          cnt_stp,
    output logic [LAT_W-1:0] lat_sample,
    output logic          lat_valid,
    output logic [5:0]    dbg_state,
    output logic          busy
);

    typedef enum logic [5:0] {
        ST_IDLE,
        ST_DECODE,
        ST_PEEK,
        ST_PEEK_WAIT,
        ST_FOK_WALK,
        ST_FOK_WAIT,
        ST_MATCH_ISSUE,
        ST_MATCH_WAIT,
        ST_EMIT_FILL,
        ST_STP,
        ST_STP_WAIT,
        ST_REST_ISSUE,
        ST_REST_WAIT,
        ST_CXL_ISSUE,
        ST_CXL_WAIT,
        ST_MOD_ISSUE,
        ST_MOD_WAIT,
        ST_REP_LOOKUP,
        ST_REP_WAIT,
        ST_REP_CXL,
        ST_REP_CXL_WAIT,
        ST_STATUS_ISSUE,
        ST_STATUS_WAIT,
        ST_MASS_ISSUE,
        ST_MASS_WAIT,
        ST_EMIT,
        ST_EMIT_BBO,
        ST_DONE
    } state_e;

    state_e state, state_n;

    cmd_t           c, c_n;
    logic [QTY_W-1:0] rem, rem_n;
    logic [QTY_W-1:0] filled, filled_n;
    event_t         ev_n, ev_q;
    book_req_t      breq, breq_n;
    logic           breq_v, breq_v_n;
    logic           ev_v, ev_v_n;
    book_rsp_t      last, last_n;
    logic [31:0]    cycle;
    logic           need_bbo, need_bbo_n;
    logic           do_insert, do_insert_n;
    logic           replace_mode, replace_mode_n;
    logic [PRICE_W-1:0] old_px, old_px_n;
    logic           pos_we_n;
    logic signed [POS_W-1:0] pos_d_n;
    logic [INST_W-1:0] pos_i_n;

    logic cnt_order_n, cnt_fill_n, cnt_reject_n, cnt_cancel_n;
    logic cnt_ack_n, cnt_modify_n, cnt_replace_n, cnt_stp_n;
    logic lat_v_n;
    logic [LAT_W-1:0] lat_n;

    assign cmd_ready       = (state == ST_IDLE);
    assign ev_valid        = ev_v;
    assign ev              = ev_q;
    assign book_req_valid  = breq_v;
    assign book_req        = breq;
    assign book_rsp_ready  = 1'b1; // always drain; matcher is the only client
    assign dbg_state       = state;
    assign busy            = (state != ST_IDLE);

    // pos_we is a 1-cycle pulse from the sequential block
    logic pos_we_r;
    logic signed [POS_W-1:0] pos_d_r;
    logic [INST_W-1:0] pos_i_r;
    assign pos_we    = pos_we_r;
    assign pos_delta = pos_d_r;
    assign pos_inst  = pos_i_r;

    function automatic book_req_t mk_req(
        input logic [3:0] cmdc,
        input cmd_t cc,
        input logic [QTY_W-1:0] qty_i,
        input logic [PRICE_W-1:0] px_i
    );
        mk_req = '0;
        mk_req.cmd   = cmdc;
        mk_req.inst  = cc.inst;
        mk_req.side  = cc.side;
        mk_req.price = px_i;
        mk_req.qty   = qty_i;
        mk_req.oid   = cc.oid;
        mk_req.firm  = cc.firm;
        mk_req.ts    = cc.ingress_ts;
        mk_req.stp   = cc.stp;
    endfunction

    function automatic event_t ev_rej(input cmd_t cc, input logic [REJ_W-1:0] r, input logic [31:0] ts);
        ev_rej = mk_event(EV_REJECT, cc.inst, cc.firm, cc.side, r,
                          cc.qty, cc.price, cc.oid, 32'h0, cc.seq, ts);
    endfunction

    function automatic event_t ev_ack(input logic [EVENT_W-1:0] k, input cmd_t cc,
                                      input logic [QTY_W-1:0] qleft, input logic [31:0] ts);
        ev_ack = mk_event(k, cc.inst, cc.firm, cc.side, REJ_NONE,
                          qleft, cc.price, cc.oid, 32'h0, cc.seq, ts);
    endfunction

    always_comb begin
        state_n        = state;
        c_n            = c;
        rem_n          = rem;
        filled_n       = filled;
        ev_n           = ev_q;
        ev_v_n         = ev_v;
        breq_n         = breq;
        breq_v_n       = 1'b0;
        last_n         = last;
        need_bbo_n     = need_bbo;
        do_insert_n    = do_insert;
        replace_mode_n = replace_mode;
        old_px_n       = old_px;
        pos_we_n       = 1'b0;
        pos_d_n        = '0;
        pos_i_n        = c.inst;
        cnt_order_n    = 1'b0;
        cnt_fill_n     = 1'b0;
        cnt_reject_n   = 1'b0;
        cnt_cancel_n   = 1'b0;
        cnt_ack_n      = 1'b0;
        cnt_modify_n   = 1'b0;
        cnt_replace_n  = 1'b0;
        cnt_stp_n      = 1'b0;
        lat_v_n        = 1'b0;
        lat_n          = LAT_W'(cycle - 32'(c.ingress_ts));

        // hold event until accepted
        if (ev_v && ev_ready)
            ev_v_n = 1'b0;

        unique case (state)
            ST_IDLE: begin
                if (cmd_valid) begin
                    c_n         = cmd;
                    rem_n       = cmd.qty;
                    filled_n    = '0;
                    replace_mode_n = 1'b0;
                    do_insert_n = 1'b0;
                    need_bbo_n  = bbo_ev_en;
                    state_n     = ST_DECODE;
                    cnt_order_n = (cmd.opcode == OP_NEW);
                end
            end

            ST_DECODE: begin
                unique case (c.opcode)
                    OP_NEW: begin
                        if (c.post_only || c.tif == TIF_FOK) begin
                            breq_n   = mk_req(BOOK_PEEK_BBO, c, rem, c.price);
                            breq_v_n = 1'b1;
                            state_n  = ST_PEEK;
                        end else begin
                            state_n = ST_MATCH_ISSUE;
                        end
                    end
                    OP_CANCEL:   state_n = ST_CXL_ISSUE;
                    OP_MODIFY:   state_n = ST_MOD_ISSUE;
                    OP_REPLACE:  state_n = ST_REP_LOOKUP;
                    OP_STATUS:   state_n = ST_STATUS_ISSUE;
                    OP_MASS_CXL: state_n = ST_MASS_ISSUE;
                    default: begin
                        ev_n   = ev_rej(c, REJ_OPCODE, cycle);
                        ev_v_n = 1'b1;
                        cnt_reject_n = 1'b1;
                        state_n = ST_EMIT;
                    end
                endcase
            end

            ST_PEEK: begin
                breq_n   = mk_req(BOOK_PEEK_BBO, c, rem, c.price);
                breq_v_n = !book_req_ready ? 1'b1 : 1'b1;
                if (book_req_ready)
                    state_n = ST_PEEK_WAIT;
            end

            ST_PEEK_WAIT: begin
                if (book_rsp_valid) begin
                    last_n = book_rsp;
                    if (c.post_only && book_rsp.would_cross) begin
                        ev_n   = ev_rej(c, REJ_POST_ONLY, cycle);
                        ev_v_n = 1'b1;
                        cnt_reject_n = 1'b1;
                        state_n = ST_EMIT;
                    end else if (c.tif == TIF_FOK) begin
                        state_n = ST_FOK_WALK;
                    end else begin
                        state_n = ST_MATCH_ISSUE;
                    end
                end
            end

            ST_FOK_WALK: begin
                breq_n   = mk_req(BOOK_WALK_LIQ, c, rem, c.price);
                breq_v_n = 1'b1;
                if (book_req_ready)
                    state_n = ST_FOK_WAIT;
            end

            ST_FOK_WAIT: begin
                if (book_rsp_valid) begin
                    last_n = book_rsp;
                    if (book_rsp.walk_qty < rem) begin
                        ev_n   = ev_rej(c, REJ_FOK, cycle);
                        ev_v_n = 1'b1;
                        cnt_reject_n = 1'b1;
                        state_n = ST_EMIT;
                    end else
                        state_n = ST_MATCH_ISSUE;
                end
            end

            ST_MATCH_ISSUE: begin
                breq_n   = mk_req(BOOK_MATCH_ONE, c, rem, c.price);
                breq_v_n = 1'b1;
                if (book_req_ready)
                    state_n = ST_MATCH_WAIT;
            end

            ST_MATCH_WAIT: begin
                if (book_rsp_valid) begin
                    last_n = book_rsp;
                    if (book_rsp.reject == REJ_STP) begin
                        state_n = ST_STP;
                    end else if (book_rsp.crossed) begin
                        rem_n    = rem - book_rsp.fill_qty;
                        filled_n = filled + book_rsp.fill_qty;
                        ev_n = mk_event(EV_FILL, c.inst, c.firm, c.side, REJ_NONE,
                                        book_rsp.fill_qty, book_rsp.fill_price,
                                        c.oid, book_rsp.resting_oid[31:0],
                                        book_rsp.resting_left, cycle);
                        ev_v_n = 1'b1;
                        cnt_fill_n = 1'b1;
                        pos_we_n = 1'b1;
                        pos_i_n  = c.inst;
                        pos_d_n  = (c.side == SIDE_BID)
                                 ? $signed(book_rsp.fill_qty[POS_W-1:0])
                                 : -$signed(book_rsp.fill_qty[POS_W-1:0]);
                        state_n  = ST_EMIT_FILL;
                    end else begin
                        // no (more) liquidity
                        do_insert_n = (c.tif == TIF_GTC || c.tif == TIF_DAY) && (rem != '0);
                        if (do_insert_n)
                            state_n = ST_REST_ISSUE;
                        else begin
                            ev_n = ev_ack(replace_mode ? EV_REPLACE_ACK : EV_ACK,
                                          c, rem, cycle);
                            ev_v_n = 1'b1;
                            cnt_ack_n = 1'b1;
                            if (replace_mode) cnt_replace_n = 1'b1;
                            state_n = ST_EMIT;
                        end
                    end
                end
            end

            ST_EMIT_FILL: begin
                if (ev_v && !ev_ready)
                    state_n = ST_EMIT_FILL;
                else if (!ev_v || ev_ready) begin
                    ev_v_n = 1'b0;
                    if (rem == '0) begin
                        ev_n = ev_ack(replace_mode ? EV_REPLACE_ACK : EV_ACK,
                                      c, 32'h0, cycle);
                        ev_v_n = 1'b1;
                        cnt_ack_n = 1'b1;
                        if (replace_mode) cnt_replace_n = 1'b1;
                        state_n = ST_EMIT;
                    end else
                        state_n = ST_MATCH_ISSUE;
                end
            end

            ST_STP: begin
                cnt_stp_n = 1'b1;
                unique case (c.stp)
                    STP_CANCEL_TAKER: begin
                        ev_n   = ev_rej(c, REJ_STP, cycle);
                        ev_v_n = 1'b1;
                        cnt_reject_n = 1'b1;
                        state_n = ST_EMIT;
                    end
                    STP_CANCEL_RESTING,
                    STP_CANCEL_BOTH: begin
                        breq_n   = mk_req(BOOK_UNLINK_RESTING, c, rem, c.price);
                        breq_v_n = 1'b1;
                        if (book_req_ready)
                            state_n = ST_STP_WAIT;
                    end
                    default: begin
                        ev_n   = ev_rej(c, REJ_STP, cycle);
                        ev_v_n = 1'b1;
                        cnt_reject_n = 1'b1;
                        state_n = ST_EMIT;
                    end
                endcase
            end

            ST_STP_WAIT: begin
                if (book_rsp_valid) begin
                    if (c.stp == STP_CANCEL_BOTH) begin
                        ev_n   = ev_rej(c, REJ_STP, cycle);
                        ev_v_n = 1'b1;
                        cnt_reject_n = 1'b1;
                        state_n = ST_EMIT;
                    end else begin
                        // resting gone; try to match the next level
                        state_n = ST_MATCH_ISSUE;
                    end
                end
            end

            ST_REST_ISSUE: begin
                breq_n   = mk_req(BOOK_INSERT, c, rem, c.price);
                breq_v_n = 1'b1;
                if (book_req_ready)
                    state_n = ST_REST_WAIT;
            end

            ST_REST_WAIT: begin
                if (book_rsp_valid) begin
                    last_n = book_rsp;
                    if (!book_rsp.ok) begin
                        ev_n   = ev_rej(c, book_rsp.reject, cycle);
                        ev_v_n = 1'b1;
                        cnt_reject_n = 1'b1;
                    end else begin
                        ev_n = ev_ack(replace_mode ? EV_REPLACE_ACK : EV_ACK,
                                      c, rem, cycle);
                        ev_v_n = 1'b1;
                        cnt_ack_n = 1'b1;
                        if (replace_mode) cnt_replace_n = 1'b1;
                    end
                    state_n = ST_EMIT;
                end
            end

            ST_CXL_ISSUE: begin
                breq_n   = mk_req(BOOK_CANCEL, c, c.qty, c.price);
                breq_v_n = 1'b1;
                if (book_req_ready)
                    state_n = ST_CXL_WAIT;
            end

            ST_CXL_WAIT: begin
                if (book_rsp_valid) begin
                    last_n = book_rsp;
                    if (!book_rsp.ok) begin
                        ev_n   = ev_rej(c, book_rsp.reject, cycle);
                        ev_v_n = 1'b1;
                        cnt_reject_n = 1'b1;
                    end else begin
                        ev_n = ev_ack(EV_CANCEL_ACK, c, book_rsp.found_qty, cycle);
                        ev_n.price = book_rsp.found_price;
                        ev_v_n = 1'b1;
                        cnt_cancel_n = 1'b1;
                    end
                    state_n = ST_EMIT;
                end
            end

            ST_MOD_ISSUE: begin
                breq_n   = mk_req(BOOK_MODIFY, c, c.qty, c.price);
                breq_v_n = 1'b1;
                if (book_req_ready)
                    state_n = ST_MOD_WAIT;
            end

            ST_MOD_WAIT: begin
                if (book_rsp_valid) begin
                    last_n = book_rsp;
                    if (!book_rsp.ok) begin
                        ev_n   = ev_rej(c, book_rsp.reject, cycle);
                        ev_v_n = 1'b1;
                        cnt_reject_n = 1'b1;
                    end else begin
                        ev_n = ev_ack(EV_MODIFY_ACK, c, book_rsp.found_qty, cycle);
                        ev_n.price = book_rsp.found_price;
                        ev_v_n = 1'b1;
                        cnt_modify_n = 1'b1;
                    end
                    state_n = ST_EMIT;
                end
            end

            ST_REP_LOOKUP: begin
                breq_n   = mk_req(BOOK_LOOKUP_OID, c, c.qty, c.price);
                breq_v_n = 1'b1;
                if (book_req_ready)
                    state_n = ST_REP_WAIT;
            end

            ST_REP_WAIT: begin
                if (book_rsp_valid) begin
                    last_n = book_rsp;
                    if (!book_rsp.found) begin
                        ev_n   = ev_rej(c, REJ_NOT_FOUND, cycle);
                        ev_v_n = 1'b1;
                        cnt_reject_n = 1'b1;
                        state_n = ST_EMIT;
                    end else begin
                        old_px_n = book_rsp.found_price;
                        replace_mode_n = 1'b1;
                        if (book_rsp.found_price == c.price) begin
                            state_n = ST_MOD_ISSUE;
                        end else
                            state_n = ST_REP_CXL;
                    end
                end
            end

            ST_REP_CXL: begin
                breq_n   = mk_req(BOOK_CANCEL, c, c.qty, old_px);
                breq_v_n = 1'b1;
                if (book_req_ready)
                    state_n = ST_REP_CXL_WAIT;
            end

            ST_REP_CXL_WAIT: begin
                if (book_rsp_valid) begin
                    // re-enter as a NEW with the replacement price/qty
                    rem_n    = c.qty;
                    filled_n = '0;
                    if (c.post_only || c.tif == TIF_FOK)
                        state_n = ST_PEEK;
                    else
                        state_n = ST_MATCH_ISSUE;
                end
            end

            ST_STATUS_ISSUE: begin
                breq_n   = mk_req(BOOK_GET_STATUS, c, '0, '0);
                breq_v_n = 1'b1;
                if (book_req_ready)
                    state_n = ST_STATUS_WAIT;
            end

            ST_STATUS_WAIT: begin
                if (book_rsp_valid) begin
                    last_n = book_rsp;
                    ev_n = mk_event(EV_STATUS, c.inst, c.firm, 1'b0, REJ_NONE,
                                    book_rsp.bbo_bid_qty, book_rsp.bbo_bid_px,
                                    c.oid, book_rsp.bbo_ask_px, book_rsp.bbo_ask_qty,
                                    cycle);
                    ev_v_n = 1'b1;
                    state_n = ST_EMIT;
                end
            end

            ST_MASS_ISSUE: begin
                // Purge opposite? We purge the requested side first via
                // UNLINK_RESTING on that side by pretending to be the taker
                // on the other side (UNLINK uses opposite BBO of req.side).
                // Issue UNLINK as if we are the opposite aggressor so the
                // requested side is consumed.
                begin
                    cmd_t tmp;
                    tmp = c;
                    tmp.side = ~c.side;
                    tmp.price = (c.side == SIDE_BID) ? {PRICE_W{1'b1}} : '0;
                    breq_n   = mk_req(BOOK_UNLINK_RESTING, tmp, 32'hFFFF_FFFF, tmp.price);
                    breq_n.side  = tmp.side;
                    breq_n.price = tmp.price;
                    breq_v_n = 1'b1;
                    if (book_req_ready)
                        state_n = ST_MASS_WAIT;
                end
            end

            ST_MASS_WAIT: begin
                if (book_rsp_valid) begin
                    last_n = book_rsp;
                    if (book_rsp.crossed || book_rsp.ok) begin
                        // keep going until the side is empty
                        if ((c.side == SIDE_BID && book_rsp.bid_valid) ||
                            (c.side == SIDE_ASK && book_rsp.ask_valid) ||
                            book_rsp.crossed)
                            state_n = ST_MASS_ISSUE;
                        else begin
                            ev_n = ev_ack(EV_CANCEL_ACK, c, 32'h0, cycle);
                            ev_v_n = 1'b1;
                            cnt_cancel_n = 1'b1;
                            state_n = ST_EMIT;
                        end
                    end else begin
                        ev_n = ev_ack(EV_CANCEL_ACK, c, 32'h0, cycle);
                        ev_v_n = 1'b1;
                        cnt_cancel_n = 1'b1;
                        state_n = ST_EMIT;
                    end
                end
            end

            ST_EMIT: begin
                if (ev_v && !ev_ready)
                    state_n = ST_EMIT;
                else begin
                    ev_v_n = 1'b0;
                    lat_v_n = 1'b1;
                    if (need_bbo)
                        state_n = ST_EMIT_BBO;
                    else
                        state_n = ST_DONE;
                end
            end

            ST_EMIT_BBO: begin
                if (!ev_v) begin
                    ev_n = mk_event(EV_BBO, c.inst, c.firm, 1'b0, REJ_NONE,
                                    last.bbo_bid_qty, last.bbo_bid_px,
                                    64'h0, last.bbo_ask_px, last.bbo_ask_qty, cycle);
                    ev_v_n = 1'b1;
                    need_bbo_n = 1'b0;
                end else if (ev_ready) begin
                    ev_v_n = 1'b0;
                    state_n = ST_DONE;
                end
            end

            ST_DONE: begin
                ev_v_n  = 1'b0;
                state_n = ST_IDLE;
            end

            default: state_n = ST_IDLE;
        endcase

        // drop book request once accepted
        if (breq_v && book_req_ready && state_n != state)
            breq_v_n = 1'b0;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= ST_IDLE;
            c            <= '0;
            rem          <= '0;
            filled       <= '0;
            ev_q         <= '0;
            ev_v         <= 1'b0;
            breq         <= '0;
            breq_v       <= 1'b0;
            last         <= '0;
            need_bbo     <= 1'b0;
            do_insert    <= 1'b0;
            replace_mode <= 1'b0;
            old_px       <= '0;
            cycle        <= 32'h0;
            pos_we_r     <= 1'b0;
            pos_d_r      <= '0;
            pos_i_r      <= '0;
            cnt_order    <= 1'b0;
            cnt_fill     <= 1'b0;
            cnt_reject   <= 1'b0;
            cnt_cancel   <= 1'b0;
            cnt_ack      <= 1'b0;
            cnt_modify   <= 1'b0;
            cnt_replace  <= 1'b0;
            cnt_stp      <= 1'b0;
            lat_sample   <= '0;
            lat_valid    <= 1'b0;
        end else if (soft_rst) begin
            state        <= ST_IDLE;
            ev_v         <= 1'b0;
            breq_v       <= 1'b0;
            pos_we_r     <= 1'b0;
            cnt_order    <= 1'b0;
            cnt_fill     <= 1'b0;
            cnt_reject   <= 1'b0;
            cnt_cancel   <= 1'b0;
            cnt_ack      <= 1'b0;
            cnt_modify   <= 1'b0;
            cnt_replace  <= 1'b0;
            cnt_stp      <= 1'b0;
            lat_valid    <= 1'b0;
        end else begin
            state        <= state_n;
            c            <= c_n;
            rem          <= rem_n;
            filled       <= filled_n;
            ev_q         <= ev_n;
            ev_v         <= ev_v_n;
            breq         <= breq_n;
            breq_v       <= breq_v_n;
            last         <= last_n;
            need_bbo     <= need_bbo_n;
            do_insert    <= do_insert_n;
            replace_mode <= replace_mode_n;
            old_px       <= old_px_n;
            cycle        <= cycle + 32'd1;
            pos_we_r     <= pos_we_n;
            pos_d_r      <= pos_d_n;
            pos_i_r      <= pos_i_n;
            cnt_order    <= cnt_order_n;
            cnt_fill     <= cnt_fill_n;
            cnt_reject   <= cnt_reject_n;
            cnt_cancel   <= cnt_cancel_n;
            cnt_ack      <= cnt_ack_n;
            cnt_modify   <= cnt_modify_n;
            cnt_replace  <= cnt_replace_n;
            cnt_stp      <= cnt_stp_n;
            lat_sample   <= lat_n;
            lat_valid    <= lat_v_n;
        end
    end

endmodule
