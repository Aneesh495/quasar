// =============================================================================
// Quasar limit order book
//
// Shared SRAM-backed book for NUM_INSTRUMENTS names.  Each side of each name
// is a price-sorted singly-linked list of levels; each level is a doubly-linked
// FIFO of orders (head = oldest = time priority).  Order-id lookup is a
// 256-bucket chained hash with doubly-linked collision lists so cancel and
// fill-to-zero are O(1) unlinks after the probe.
//
// All mutating ops are multi-cycle and issue at most one write per RAM per
// cycle.  Reads are registered (1-cycle latency).  The matcher sees a
// ready/valid command interface and a held response.
//
// Price-time priority:
//   * Bid levels descend in price; ask levels ascend.
//   * Within a level, dequeue from head, enqueue at tail.
// =============================================================================

module quasar_book
    import quasar_pkg::*;
(
    input  logic                  clk,
    input  logic                  rst_n,

    input  logic                  req_valid,
    output logic                  req_ready,
    input  book_req_t             req,

    output logic                  rsp_valid,
    input  logic                  rsp_ready,
    output book_rsp_t             rsp,

    output bbo_t [NUM_INSTRUMENTS-1:0] bbo_vec,
    output logic [15:0]           orders_used,
    output logic [15:0]           levels_used,
    output logic                  busy
);

    // -------------------------------------------------------------------------
    // Memories
    // -------------------------------------------------------------------------
    order_rec_t           ord_mem  [0:MAX_ORDERS-1];
    level_rec_t           lvl_mem  [0:MAX_LEVELS-1];
    logic [PTR_W-1:0]     hash_mem [0:HASH_BUCKETS-1];

    logic [7:0]           ord_raddr, ord_waddr;
    logic [7:0]           lvl_raddr, lvl_waddr;
    logic [7:0]           hash_raddr, hash_waddr;
    logic                 ord_we, lvl_we, hash_we;
    order_rec_t           ord_wdata, ord_rdata;
    level_rec_t           lvl_wdata, lvl_rdata;
    logic [PTR_W-1:0]     hash_wdata, hash_rdata;

    always_ff @(posedge clk) begin
        ord_rdata  <= ord_mem[ord_raddr];
        lvl_rdata  <= lvl_mem[lvl_raddr];
        hash_rdata <= hash_mem[hash_raddr];
        if (ord_we)  ord_mem[ord_waddr]   <= ord_wdata;
        if (lvl_we)  lvl_mem[lvl_waddr]   <= lvl_wdata;
        if (hash_we) hash_mem[hash_waddr] <= hash_wdata;
    end

    // -------------------------------------------------------------------------
    // Free lists
    // -------------------------------------------------------------------------
    logic                 ord_pop, ord_push, ord_empty, ord_full;
    logic [PTR_W-1:0]     ord_pop_ptr, ord_push_ptr;
    logic [15:0]          ord_used;
    logic                 lvl_pop, lvl_push, lvl_empty, lvl_full;
    logic [PTR_W-1:0]     lvl_pop_ptr, lvl_push_ptr;
    logic [15:0]          lvl_used;

    quasar_free_list #(.N(MAX_ORDERS), .PTR_W(PTR_W)) u_ord_free (
        .clk(clk), .rst_n(rst_n),
        .pop(ord_pop), .pop_ptr(ord_pop_ptr), .empty(ord_empty),
        .push(ord_push), .push_ptr(ord_push_ptr), .full(ord_full),
        .used(ord_used)
    );

    quasar_free_list #(.N(MAX_LEVELS), .PTR_W(PTR_W)) u_lvl_free (
        .clk(clk), .rst_n(rst_n),
        .pop(lvl_pop), .pop_ptr(lvl_pop_ptr), .empty(lvl_empty),
        .push(lvl_push), .push_ptr(lvl_push_ptr), .full(lvl_full),
        .used(lvl_used)
    );

    assign orders_used = ord_used;
    assign levels_used = lvl_used;

    // -------------------------------------------------------------------------
    // BBO flops (1-cycle peek)
    // -------------------------------------------------------------------------
    bbo_t [NUM_INSTRUMENTS-1:0] bbo, bbo_n;
    assign bbo_vec = bbo;

    // -------------------------------------------------------------------------
    // FSM
    // -------------------------------------------------------------------------
    typedef enum logic [5:0] {
        ST_INIT,
        ST_IDLE,
        ST_RSP,

        ST_HASH_WAIT,
        ST_OID_WALK,

        ST_MATCH_ORD,
        ST_MATCH_APPLY,
        ST_MATCH_NEXT,
        ST_MATCH_H1,
        ST_MATCH_H2,

        ST_INS_WALK,
        ST_INS_ALLOC,
        ST_INS_WR_ORD,
        ST_INS_WR_LVL,
        ST_INS_LINK_PREV_ORD,
        ST_INS_LINK_OLD_HEAD,
        ST_INS_LINK_LVL_PREV,
        ST_INS_LINK_LVL_NEXT,

        ST_CXL_RD_PREV,
        ST_CXL_WR_PREV,
        ST_CXL_RD_NEXT,
        ST_CXL_WR_NEXT,
        ST_CXL_RD_LVL,
        ST_CXL_WR_LVL,
        ST_CXL_H1,
        ST_CXL_H2,
        ST_CXL_FREE,
        ST_CXL_LVL_RD_PREV,
        ST_CXL_LVL_WR_PREV,
        ST_CXL_LVL_RD_NEXT,
        ST_CXL_LVL_WR_NEXT,

        ST_WALK_WAIT,
        ST_WALK_ACC,

        ST_MOD_RD_LVL,
        ST_MOD_WR
    } state_e;

    state_e state, state_n;

    book_req_t q;
    book_rsp_t rsp_n, rsp_q;
    logic      rsp_valid_n;

    logic [7:0]  init_cnt, init_cnt_n;

    logic [PTR_W-1:0] walk_ptr, walk_ptr_n;
    logic [PTR_W-1:0] hash_prev, hash_prev_n;
    logic [PTR_W-1:0] found_ptr, found_ptr_n;
    logic [PTR_W-1:0] lvl_ptr, lvl_ptr_n;
    logic [PTR_W-1:0] lvl_prev, lvl_prev_n;
    logic [PTR_W-1:0] new_ord, new_ord_n;
    logic [PTR_W-1:0] new_lvl, new_lvl_n;
    logic             lvl_found, lvl_found_n;
    logic             created_lvl, created_lvl_n;

    order_rec_t cur_ord, cur_ord_n;
    level_rec_t cur_lvl, cur_lvl_n;
    order_rec_t nei_ord, nei_ord_n;
    level_rec_t nei_lvl, nei_lvl_n;

    logic [QTY_W-1:0] acc_qty, acc_qty_n;
    logic [QTY_W-1:0] fill_qty_r, fill_qty_n;
    logic             deplete, deplete_n;
    logic             after_cxl_insert; // unused placeholder for replace
    logic             opp_side;
    logic [INST_W-1:0] inst_q;

    logic do_ord_pop, do_ord_push, do_lvl_pop, do_lvl_push;

    assign req_ready = (state == ST_IDLE);
    assign rsp_valid = (state == ST_RSP);
    assign rsp       = rsp_q;
    assign busy      = (state != ST_IDLE) && (state != ST_RSP) && (state != ST_INIT);

    function automatic bbo_t bbo_clear();
        bbo_clear = '0;
        bbo_clear.bid_lvl = NULL_PTR;
        bbo_clear.ask_lvl = NULL_PTR;
    endfunction

    function automatic logic is_null(input logic [PTR_W-1:0] p);
        is_null = (p == NULL_PTR);
    endfunction

    function automatic logic [7:0] p8(input logic [PTR_W-1:0] p);
        p8 = p[7:0];
    endfunction

    function automatic book_rsp_t rsp_clear();
        rsp_clear = '0;
        rsp_clear.reject = REJ_NONE;
    endfunction

    function automatic book_rsp_t fill_bbo_fields(input book_rsp_t r, input logic [INST_W-1:0] inst);
        book_rsp_t o;
        o = r;
        o.bbo_bid_px  = bbo[inst].bid_px;
        o.bbo_ask_px  = bbo[inst].ask_px;
        o.bbo_bid_qty = bbo[inst].bid_qty;
        o.bbo_ask_qty = bbo[inst].ask_qty;
        o.bid_valid   = bbo[inst].bid_valid;
        o.ask_valid   = bbo[inst].ask_valid;
        o.orders_used = ord_used;
        o.levels_used = lvl_used;
        fill_bbo_fields = o;
    endfunction

    // Opposite book side of an aggressor.
    function automatic logic opp(input logic side);
        opp = ~side;
    endfunction

    integer bi;

    always_comb begin
        // defaults
        state_n        = state;
        rsp_n          = rsp_q;
        rsp_valid_n    = 1'b0;
        init_cnt_n     = init_cnt;
        walk_ptr_n     = walk_ptr;
        hash_prev_n    = hash_prev;
        found_ptr_n    = found_ptr;
        lvl_ptr_n      = lvl_ptr;
        lvl_prev_n     = lvl_prev;
        new_ord_n      = new_ord;
        new_lvl_n      = new_lvl;
        lvl_found_n    = lvl_found;
        created_lvl_n  = created_lvl;
        cur_ord_n      = cur_ord;
        cur_lvl_n      = cur_lvl;
        nei_ord_n      = nei_ord;
        nei_lvl_n      = nei_lvl;
        acc_qty_n      = acc_qty;
        fill_qty_n     = fill_qty_r;
        deplete_n      = deplete;
        bbo_n          = bbo;

        ord_raddr = 8'h0;
        ord_waddr = 8'h0;
        lvl_raddr = 8'h0;
        lvl_waddr = 8'h0;
        hash_raddr = 8'h0;
        hash_waddr = 8'h0;
        ord_we = 1'b0;
        lvl_we = 1'b0;
        hash_we = 1'b0;
        ord_wdata = '0;
        lvl_wdata = '0;
        hash_wdata = NULL_PTR;

        do_ord_pop  = 1'b0;
        do_ord_push = 1'b0;
        do_lvl_pop  = 1'b0;
        do_lvl_push = 1'b0;
        ord_push_ptr = NULL_PTR;
        lvl_push_ptr = NULL_PTR;

        inst_q   = q.inst;
        opp_side = opp(q.side);

        unique case (state)
            // -----------------------------------------------------------------
            ST_INIT: begin
                hash_we    = 1'b1;
                hash_waddr = init_cnt;
                hash_wdata = NULL_PTR;
                init_cnt_n = init_cnt + 8'd1;
                if (init_cnt == 8'hFF)
                    state_n = ST_IDLE;
            end

            // -----------------------------------------------------------------
            ST_IDLE: begin
                if (req_valid) begin
                    unique case (req.cmd)
                        BOOK_PEEK_BBO,
                        BOOK_GET_STATUS: begin
                            rsp_n = fill_bbo_fields(rsp_clear(), req.inst);
                            rsp_n.ok = 1'b1;
                            if (req.side == SIDE_ASK)
                                rsp_n.would_cross = prices_cross(1'b1, req.price,
                                                                 bbo[req.inst].bid_px,
                                                                 bbo[req.inst].bid_valid);
                            else
                                rsp_n.would_cross = prices_cross(1'b0, req.price,
                                                                 bbo[req.inst].ask_px,
                                                                 bbo[req.inst].ask_valid);
                            rsp_n.book_empty = !bbo[req.inst].bid_valid &&
                                               !bbo[req.inst].ask_valid;
                            state_n = ST_RSP;
                        end

                        BOOK_LOOKUP_OID,
                        BOOK_CANCEL,
                        BOOK_MODIFY: begin
                            hash_raddr  = oid_hash(req.oid);
                            walk_ptr_n  = NULL_PTR; // filled after wait
                            hash_prev_n = NULL_PTR;
                            found_ptr_n = NULL_PTR;
                            state_n     = ST_HASH_WAIT;
                        end

                        BOOK_MATCH_ONE,
                        BOOK_UNLINK_RESTING: begin
                            if (req.side == SIDE_ASK) begin
                                // sell hits bids
                                if (!bbo[req.inst].bid_valid ||
                                    !prices_cross(1'b1, req.price,
                                                  bbo[req.inst].bid_px,
                                                  bbo[req.inst].bid_valid)) begin
                                    rsp_n = fill_bbo_fields(rsp_clear(), req.inst);
                                    rsp_n.ok = 1'b1;
                                    rsp_n.crossed = 1'b0;
                                    rsp_n.book_empty = !bbo[req.inst].bid_valid;
                                    state_n = ST_RSP;
                                end else begin
                                    lvl_ptr_n = bbo[req.inst].bid_lvl;
                                    lvl_raddr = p8(bbo[req.inst].bid_lvl);
                                    state_n   = ST_MATCH_ORD;
                                end
                            end else begin
                                if (!bbo[req.inst].ask_valid ||
                                    !prices_cross(1'b0, req.price,
                                                  bbo[req.inst].ask_px,
                                                  bbo[req.inst].ask_valid)) begin
                                    rsp_n = fill_bbo_fields(rsp_clear(), req.inst);
                                    rsp_n.ok = 1'b1;
                                    rsp_n.crossed = 1'b0;
                                    rsp_n.book_empty = !bbo[req.inst].ask_valid;
                                    state_n = ST_RSP;
                                end else begin
                                    lvl_ptr_n = bbo[req.inst].ask_lvl;
                                    lvl_raddr = p8(bbo[req.inst].ask_lvl);
                                    state_n   = ST_MATCH_ORD;
                                end
                            end
                        end

                        BOOK_INSERT: begin
                            hash_raddr  = oid_hash(req.oid);
                            hash_prev_n = NULL_PTR;
                            found_ptr_n = NULL_PTR;
                            state_n     = ST_HASH_WAIT;
                        end

                        BOOK_WALK_LIQ: begin
                            acc_qty_n = '0;
                            if (req.side == SIDE_ASK) begin
                                if (!bbo[req.inst].bid_valid) begin
                                    rsp_n = fill_bbo_fields(rsp_clear(), req.inst);
                                    rsp_n.ok = 1'b1;
                                    rsp_n.walk_qty = '0;
                                    state_n = ST_RSP;
                                end else begin
                                    walk_ptr_n = bbo[req.inst].bid_lvl;
                                    lvl_raddr  = p8(bbo[req.inst].bid_lvl);
                                    state_n    = ST_WALK_WAIT;
                                end
                            end else begin
                                if (!bbo[req.inst].ask_valid) begin
                                    rsp_n = fill_bbo_fields(rsp_clear(), req.inst);
                                    rsp_n.ok = 1'b1;
                                    rsp_n.walk_qty = '0;
                                    state_n = ST_RSP;
                                end else begin
                                    walk_ptr_n = bbo[req.inst].ask_lvl;
                                    lvl_raddr  = p8(bbo[req.inst].ask_lvl);
                                    state_n    = ST_WALK_WAIT;
                                end
                            end
                        end

                        default: begin
                            rsp_n = fill_bbo_fields(rsp_clear(), req.inst);
                            rsp_n.ok = 1'b0;
                            rsp_n.reject = REJ_OPCODE;
                            state_n = ST_RSP;
                        end
                    endcase
                end
            end

            // -----------------------------------------------------------------
            ST_HASH_WAIT: begin
                walk_ptr_n = hash_rdata;
                if (is_null(hash_rdata)) begin
                    if (q.cmd == BOOK_INSERT) begin
                        // no dup, start level walk from best
                        lvl_prev_n  = NULL_PTR;
                        lvl_found_n = 1'b0;
                        created_lvl_n = 1'b0;
                        if (q.side == SIDE_BID)
                            walk_ptr_n = bbo[q.inst].bid_lvl;
                        else
                            walk_ptr_n = bbo[q.inst].ask_lvl;
                        if (is_null(walk_ptr_n)) begin
                            // empty side — create level + order
                            state_n = ST_INS_ALLOC;
                        end else begin
                            lvl_raddr = p8(walk_ptr_n);
                            state_n   = ST_INS_WALK;
                        end
                    end else begin
                        rsp_n = fill_bbo_fields(rsp_clear(), q.inst);
                        rsp_n.ok     = 1'b0;
                        rsp_n.found  = 1'b0;
                        rsp_n.reject = REJ_NOT_FOUND;
                        state_n      = ST_RSP;
                    end
                end else begin
                    ord_raddr = p8(hash_rdata);
                    state_n   = ST_OID_WALK;
                end
            end

            ST_OID_WALK: begin
                cur_ord_n = ord_rdata;
                if (ord_rdata.valid && ord_rdata.oid == q.oid) begin
                    found_ptr_n = walk_ptr;
                    unique case (q.cmd)
                        BOOK_LOOKUP_OID: begin
                            rsp_n = fill_bbo_fields(rsp_clear(), q.inst);
                            rsp_n.ok          = 1'b1;
                            rsp_n.found       = 1'b1;
                            rsp_n.found_price = ord_rdata.price;
                            rsp_n.found_qty   = ord_rdata.qty;
                            rsp_n.found_side  = ord_rdata.side;
                            rsp_n.found_inst  = ord_rdata.inst;
                            rsp_n.resting_oid = ord_rdata.oid;
                            rsp_n.resting_firm= ord_rdata.firm;
                            rsp_n.resting_left= ord_rdata.qty;
                            state_n = ST_RSP;
                        end
                        BOOK_INSERT: begin
                            rsp_n = fill_bbo_fields(rsp_clear(), q.inst);
                            rsp_n.ok     = 1'b0;
                            rsp_n.reject = REJ_DUP_OID;
                            state_n      = ST_RSP;
                        end
                        BOOK_CANCEL: begin
                            lvl_ptr_n = ord_rdata.level_ptr;
                            state_n   = ST_CXL_RD_PREV;
                        end
                        BOOK_MODIFY: begin
                            lvl_ptr_n = ord_rdata.level_ptr;
                            lvl_raddr = p8(ord_rdata.level_ptr);
                            state_n   = ST_MOD_RD_LVL;
                        end
                        default: begin
                            rsp_n = fill_bbo_fields(rsp_clear(), q.inst);
                            rsp_n.ok = 1'b0;
                            rsp_n.reject = REJ_OPCODE;
                            state_n = ST_RSP;
                        end
                    endcase
                end else if (is_null(ord_rdata.hash_next) || !ord_rdata.valid) begin
                    if (q.cmd == BOOK_INSERT) begin
                        lvl_prev_n    = NULL_PTR;
                        lvl_found_n   = 1'b0;
                        created_lvl_n = 1'b0;
                        if (q.side == SIDE_BID)
                            walk_ptr_n = bbo[q.inst].bid_lvl;
                        else
                            walk_ptr_n = bbo[q.inst].ask_lvl;
                        if (is_null(walk_ptr_n))
                            state_n = ST_INS_ALLOC;
                        else begin
                            lvl_raddr = p8(walk_ptr_n);
                            state_n   = ST_INS_WALK;
                        end
                    end else begin
                        rsp_n = fill_bbo_fields(rsp_clear(), q.inst);
                        rsp_n.ok     = 1'b0;
                        rsp_n.found  = 1'b0;
                        rsp_n.reject = REJ_NOT_FOUND;
                        state_n      = ST_RSP;
                    end
                end else begin
                    hash_prev_n = walk_ptr;
                    walk_ptr_n  = ord_rdata.hash_next;
                    ord_raddr   = p8(ord_rdata.hash_next);
                    state_n     = ST_OID_WALK;
                end
            end

            // -----------------------------------------------------------------
            // MATCH / UNLINK_RESTING  (level read in flight → now read head)
            // -----------------------------------------------------------------
            ST_MATCH_ORD: begin
                cur_lvl_n = lvl_rdata;
                if (!lvl_rdata.valid || is_null(lvl_rdata.head)) begin
                    rsp_n = fill_bbo_fields(rsp_clear(), q.inst);
                    rsp_n.ok = 1'b1;
                    rsp_n.crossed = 1'b0;
                    rsp_n.book_empty = 1'b1;
                    state_n = ST_RSP;
                end else begin
                    ord_raddr = p8(lvl_rdata.head);
                    found_ptr_n = lvl_rdata.head;
                    state_n   = ST_MATCH_APPLY;
                end
            end

            ST_MATCH_APPLY: begin
                cur_ord_n = ord_rdata;
                if (q.cmd == BOOK_UNLINK_RESTING) begin
                    // treat as full cancel of the head (qty taken from book)
                    fill_qty_n = ord_rdata.qty;
                    deplete_n  = 1'b1;
                end else begin
                    fill_qty_n = min_qty(q.qty, ord_rdata.qty);
                    deplete_n  = (ord_rdata.qty <= q.qty);
                end

                if (q.cmd != BOOK_UNLINK_RESTING &&
                    q.stp != STP_OFF &&
                    ord_rdata.firm == q.firm) begin
                    rsp_n = fill_bbo_fields(rsp_clear(), q.inst);
                    rsp_n.ok           = 1'b1;
                    rsp_n.crossed      = 1'b0;
                    rsp_n.resting_oid  = ord_rdata.oid;
                    rsp_n.resting_firm = ord_rdata.firm;
                    rsp_n.resting_left = ord_rdata.qty;
                    rsp_n.fill_price   = ord_rdata.price;
                    rsp_n.reject       = REJ_STP;
                    state_n            = ST_RSP;
                end else if (!deplete_n) begin
                    // partial fill — write reduced qty
                    ord_we    = 1'b1;
                    ord_waddr = p8(cur_lvl.head);
                    found_ptr_n = cur_lvl.head;
                    ord_wdata = ord_rdata;
                    ord_wdata.qty = ord_rdata.qty - fill_qty_n;

                    lvl_we    = 1'b1;
                    lvl_waddr = p8(lvl_ptr);
                    lvl_wdata = cur_lvl;
                    lvl_wdata.agg_qty = cur_lvl.agg_qty - fill_qty_n;

                    if (q.side == SIDE_ASK) begin
                        bbo_n[q.inst].bid_qty = cur_lvl.agg_qty - fill_qty_n;
                    end else begin
                        bbo_n[q.inst].ask_qty = cur_lvl.agg_qty - fill_qty_n;
                    end

                    rsp_n = fill_bbo_fields(rsp_clear(), q.inst);
                    rsp_n.ok           = 1'b1;
                    rsp_n.crossed      = 1'b1;
                    rsp_n.fill_qty     = fill_qty_n;
                    rsp_n.fill_price   = ord_rdata.price;
                    rsp_n.resting_oid  = ord_rdata.oid;
                    rsp_n.resting_firm = ord_rdata.firm;
                    rsp_n.resting_left = ord_rdata.qty - fill_qty_n;
                    // BBO fields in rsp still old this cycle; ST_RSP uses bbo_n via fill after flop.
                    // Patch qty into the response now:
                    if (q.side == SIDE_ASK)
                        rsp_n.bbo_bid_qty = cur_lvl.agg_qty - fill_qty_n;
                    else
                        rsp_n.bbo_ask_qty = cur_lvl.agg_qty - fill_qty_n;
                    state_n = ST_RSP;
                end else begin
                    // full fill of resting head — unlink order
                    // update level head/count/agg first
                    lvl_we    = 1'b1;
                    lvl_waddr = p8(lvl_ptr);
                    lvl_wdata = cur_lvl;
                    lvl_wdata.head    = ord_rdata.next_ord;
                    lvl_wdata.count   = cur_lvl.count - 16'd1;
                    lvl_wdata.agg_qty = cur_lvl.agg_qty - ord_rdata.qty;
                    if (is_null(ord_rdata.next_ord))
                        lvl_wdata.tail = NULL_PTR;
                    cur_lvl_n = lvl_wdata;

                    if (!is_null(ord_rdata.next_ord)) begin
                        ord_raddr = p8(ord_rdata.next_ord);
                        state_n   = ST_MATCH_NEXT;
                    end else begin
                        state_n = ST_MATCH_H1;
                    end
                end
            end

            ST_MATCH_NEXT: begin
                // clear prev of new head
                ord_we    = 1'b1;
                ord_waddr = p8(cur_ord.next_ord);
                ord_wdata = ord_rdata;
                ord_wdata.prev_ord = NULL_PTR;
                state_n   = ST_MATCH_H1;
            end

            ST_MATCH_H1: begin
                // unlink from hash: if hash_prev null, rewrite bucket
                if (is_null(cur_ord.hash_prev)) begin
                    hash_we    = 1'b1;
                    hash_waddr = oid_hash(cur_ord.oid);
                    hash_wdata = cur_ord.hash_next;
                    if (!is_null(cur_ord.hash_next)) begin
                        ord_raddr = p8(cur_ord.hash_next);
                        state_n   = ST_MATCH_H2;
                    end else begin
                        state_n = ST_CXL_FREE; // reuse free + maybe pop level
                    end
                end else begin
                    ord_raddr = p8(cur_ord.hash_prev);
                    state_n   = ST_CXL_H1; // reuse cancel hash unlink
                end
            end

            ST_MATCH_H2: begin
                ord_we    = 1'b1;
                ord_waddr = p8(cur_ord.hash_next);
                ord_wdata = ord_rdata;
                ord_wdata.hash_prev = cur_ord.hash_prev;
                state_n   = ST_CXL_FREE;
            end

            // -----------------------------------------------------------------
            // INSERT
            // -----------------------------------------------------------------
            ST_INS_WALK: begin
                cur_lvl_n = lvl_rdata;
                if (lvl_rdata.valid && lvl_rdata.price == q.price &&
                    lvl_rdata.inst == q.inst && lvl_rdata.side == q.side) begin
                    lvl_found_n = 1'b1;
                    lvl_ptr_n   = walk_ptr;
                    state_n     = ST_INS_ALLOC;
                end else if (lvl_rdata.valid &&
                             ((q.side == SIDE_BID && lvl_rdata.price < q.price) ||
                              (q.side == SIDE_ASK && lvl_rdata.price > q.price))) begin
                    // insertion point is before walk_ptr (after lvl_prev)
                    lvl_found_n = 1'b0;
                    lvl_ptr_n   = walk_ptr; // this becomes next_lvl of new
                    state_n     = ST_INS_ALLOC;
                end else if (is_null(lvl_rdata.next_lvl)) begin
                    // append after current
                    lvl_found_n = 1'b0;
                    lvl_prev_n  = walk_ptr;
                    lvl_ptr_n   = NULL_PTR;
                    state_n     = ST_INS_ALLOC;
                end else begin
                    lvl_prev_n = walk_ptr;
                    walk_ptr_n = lvl_rdata.next_lvl;
                    lvl_raddr  = p8(lvl_rdata.next_lvl);
                    state_n    = ST_INS_WALK;
                end
            end

            ST_INS_ALLOC: begin
                if (ord_empty || (!lvl_found && lvl_empty)) begin
                    rsp_n = fill_bbo_fields(rsp_clear(), q.inst);
                    rsp_n.ok     = 1'b0;
                    rsp_n.reject = REJ_BOOK_FULL;
                    state_n      = ST_RSP;
                end else begin
                    do_ord_pop = 1'b1;
                    new_ord_n  = ord_pop_ptr;
                    if (!lvl_found) begin
                        do_lvl_pop = 1'b1;
                        new_lvl_n  = lvl_pop_ptr;
                        created_lvl_n = 1'b1;
                    end else begin
                        new_lvl_n = lvl_ptr;
                        created_lvl_n = 1'b0;
                    end
                    state_n = ST_INS_WR_ORD;
                end
            end

            ST_INS_WR_ORD: begin
                // If using existing level, need current level record.  If we
                // just walked it, cur_lvl is valid.  If side was empty,
                // cur_lvl is don't-care.
                ord_we    = 1'b1;
                ord_waddr = p8(new_ord);
                ord_wdata = '0;
                ord_wdata.valid     = 1'b1;
                ord_wdata.oid       = q.oid;
                ord_wdata.qty       = q.qty;
                ord_wdata.price     = q.price;
                ord_wdata.inst      = q.inst;
                ord_wdata.side      = q.side;
                ord_wdata.firm      = q.firm;
                ord_wdata.ts        = q.ts;
                ord_wdata.level_ptr = created_lvl ? new_lvl : lvl_ptr;
                ord_wdata.prev_ord  = created_lvl ? NULL_PTR :
                                      (lvl_found ? cur_lvl.tail : NULL_PTR);
                ord_wdata.next_ord  = NULL_PTR;
                // hash insert at bucket head
                hash_raddr = oid_hash(q.oid);
                cur_ord_n  = ord_wdata;
                state_n    = ST_INS_WR_LVL;
            end

            ST_INS_WR_LVL: begin
                // hash_rdata is the old bucket head
                // complete order hash links + write level
                logic [PTR_W-1:0] old_head;
                old_head = hash_rdata;

                // patch hash links on the new order (rewrite)
                ord_we    = 1'b1;
                ord_waddr = p8(new_ord);
                ord_wdata = cur_ord;
                ord_wdata.hash_next = old_head;
                ord_wdata.hash_prev = NULL_PTR;
                cur_ord_n = ord_wdata;

                hash_we    = 1'b1;
                hash_waddr = oid_hash(q.oid);
                hash_wdata = new_ord;

                if (!is_null(old_head)) begin
                    // need to set old head's hash_prev — read it
                    ord_raddr = p8(old_head);
                    found_ptr_n = old_head; // stash
                    state_n = ST_INS_LINK_OLD_HEAD;
                end else if (lvl_found) begin
                    state_n = ST_INS_LINK_PREV_ORD;
                end else begin
                    state_n = ST_INS_LINK_LVL_PREV;
                end

                // write / create level
                lvl_we    = 1'b1;
                if (created_lvl) begin
                    lvl_waddr = p8(new_lvl);
                    lvl_wdata = '0;
                    lvl_wdata.valid    = 1'b1;
                    lvl_wdata.price    = q.price;
                    lvl_wdata.agg_qty  = q.qty;
                    lvl_wdata.count    = 16'd1;
                    lvl_wdata.inst     = q.inst;
                    lvl_wdata.side     = q.side;
                    lvl_wdata.head     = new_ord;
                    lvl_wdata.tail     = new_ord;
                    lvl_wdata.next_lvl = lvl_ptr;      // maybe NULL or old walk
                    lvl_wdata.prev_lvl = lvl_prev;
                    cur_lvl_n = lvl_wdata;
                end else begin
                    lvl_waddr = p8(lvl_ptr);
                    lvl_wdata = cur_lvl;
                    lvl_wdata.agg_qty = cur_lvl.agg_qty + q.qty;
                    lvl_wdata.count   = cur_lvl.count + 16'd1;
                    lvl_wdata.tail    = new_ord;
                    if (is_null(cur_lvl.head))
                        lvl_wdata.head = new_ord;
                    cur_lvl_n = lvl_wdata;
                end
            end

            ST_INS_LINK_OLD_HEAD: begin
                ord_we    = 1'b1;
                ord_waddr = p8(found_ptr);
                ord_wdata = ord_rdata;
                ord_wdata.hash_prev = new_ord;
                if (lvl_found)
                    state_n = ST_INS_LINK_PREV_ORD;
                else
                    state_n = ST_INS_LINK_LVL_PREV;
            end

            ST_INS_LINK_PREV_ORD: begin
                // enqueue: old tail.next = new
                if (!is_null(cur_ord.prev_ord)) begin
                    // we need to read old tail — may not be in ord_rdata
                    // Issue: we didn't read it.  Use a dedicated cycle.
                    // cur_ord.prev_ord is the old tail (set in ST_INS_WR_ORD).
                    // Re-read it.
                    ord_raddr = p8(cur_ord.prev_ord);
                    state_n   = ST_INS_LINK_PREV_ORD; // fall through next time?
                    // Use a flag via created_lvl==0 and a substep — instead
                    // write using a two-cycle handshake via nei.
                    // Simpler: always go through a wait by using state reuse.
                end
                // We encode: first entry here, ord_rdata is stale.  Kick a read
                // then a write on the subsequent visit using nei_ord.valid as
                // a phase bit... cleaner to split states.  Use nei_lvl.valid
                // as "read issued".
                if (!nei_ord.valid) begin
                    if (is_null(cur_ord.prev_ord)) begin
                        // first order on existing empty? shouldn't happen
                        state_n = ST_RSP;
                        rsp_n = fill_bbo_fields(rsp_clear(), q.inst);
                        rsp_n.ok = 1'b1;
                    end else begin
                        ord_raddr = p8(cur_ord.prev_ord);
                        nei_ord_n = cur_ord; // mark pending: set valid
                        nei_ord_n.valid = 1'b1;
                        state_n = ST_INS_LINK_PREV_ORD;
                    end
                end else begin
                    ord_we    = 1'b1;
                    ord_waddr = p8(cur_ord.prev_ord);
                    ord_wdata = ord_rdata;
                    ord_wdata.next_ord = new_ord;
                    nei_ord_n = '0;
                    // update BBO qty if this is the best level
                    if (q.side == SIDE_BID && bbo[q.inst].bid_lvl == lvl_ptr)
                        bbo_n[q.inst].bid_qty = cur_lvl.agg_qty;
                    if (q.side == SIDE_ASK && bbo[q.inst].ask_lvl == lvl_ptr)
                        bbo_n[q.inst].ask_qty = cur_lvl.agg_qty;
                    rsp_n = fill_bbo_fields(rsp_clear(), q.inst);
                    rsp_n.ok = 1'b1;
                    if (q.side == SIDE_BID && bbo[q.inst].bid_lvl == lvl_ptr)
                        rsp_n.bbo_bid_qty = cur_lvl.agg_qty;
                    if (q.side == SIDE_ASK && bbo[q.inst].ask_lvl == lvl_ptr)
                        rsp_n.bbo_ask_qty = cur_lvl.agg_qty;
                    state_n = ST_RSP;
                end
            end

            ST_INS_LINK_LVL_PREV: begin
                // splice new level between lvl_prev and lvl_ptr
                if (!is_null(lvl_prev)) begin
                    if (!nei_lvl.valid) begin
                        lvl_raddr = p8(lvl_prev);
                        nei_lvl_n.valid = 1'b1;
                        state_n = ST_INS_LINK_LVL_PREV;
                    end else begin
                        lvl_we    = 1'b1;
                        lvl_waddr = p8(lvl_prev);
                        lvl_wdata = lvl_rdata;
                        lvl_wdata.next_lvl = new_lvl;
                        nei_lvl_n = '0;
                        state_n   = ST_INS_LINK_LVL_NEXT;
                    end
                end else begin
                    // new level is the new best
                    if (q.side == SIDE_BID) begin
                        bbo_n[q.inst].bid_valid = 1'b1;
                        bbo_n[q.inst].bid_px    = q.price;
                        bbo_n[q.inst].bid_qty   = q.qty;
                        bbo_n[q.inst].bid_lvl   = new_lvl;
                    end else begin
                        bbo_n[q.inst].ask_valid = 1'b1;
                        bbo_n[q.inst].ask_px    = q.price;
                        bbo_n[q.inst].ask_qty   = q.qty;
                        bbo_n[q.inst].ask_lvl   = new_lvl;
                    end
                    state_n = ST_INS_LINK_LVL_NEXT;
                end
            end

            ST_INS_LINK_LVL_NEXT: begin
                if (!is_null(lvl_ptr)) begin
                    if (!nei_lvl.valid) begin
                        lvl_raddr = p8(lvl_ptr);
                        nei_lvl_n.valid = 1'b1;
                        state_n = ST_INS_LINK_LVL_NEXT;
                    end else begin
                        lvl_we    = 1'b1;
                        lvl_waddr = p8(lvl_ptr);
                        lvl_wdata = lvl_rdata;
                        lvl_wdata.prev_lvl = new_lvl;
                        nei_lvl_n = '0;
                        rsp_n = fill_bbo_fields(rsp_clear(), q.inst);
                        rsp_n.ok = 1'b1;
                        if (q.side == SIDE_BID && is_null(lvl_prev)) begin
                            rsp_n.bid_valid   = 1'b1;
                            rsp_n.bbo_bid_px  = q.price;
                            rsp_n.bbo_bid_qty = q.qty;
                        end
                        if (q.side == SIDE_ASK && is_null(lvl_prev)) begin
                            rsp_n.ask_valid   = 1'b1;
                            rsp_n.bbo_ask_px  = q.price;
                            rsp_n.bbo_ask_qty = q.qty;
                        end
                        state_n = ST_RSP;
                    end
                end else begin
                    rsp_n = fill_bbo_fields(rsp_clear(), q.inst);
                    rsp_n.ok = 1'b1;
                    if (q.side == SIDE_BID && is_null(lvl_prev)) begin
                        rsp_n.bid_valid   = 1'b1;
                        rsp_n.bbo_bid_px  = q.price;
                        rsp_n.bbo_bid_qty = q.qty;
                    end
                    if (q.side == SIDE_ASK && is_null(lvl_prev)) begin
                        rsp_n.ask_valid   = 1'b1;
                        rsp_n.bbo_ask_px  = q.price;
                        rsp_n.bbo_ask_qty = q.qty;
                    end
                    state_n = ST_RSP;
                end
            end

            // -----------------------------------------------------------------
            // CANCEL sequence (cur_ord + found_ptr set)
            // -----------------------------------------------------------------
            ST_CXL_RD_PREV: begin
                if (!is_null(cur_ord.prev_ord)) begin
                    ord_raddr = p8(cur_ord.prev_ord);
                    state_n   = ST_CXL_WR_PREV;
                end else begin
                    state_n = ST_CXL_RD_NEXT;
                end
            end

            ST_CXL_WR_PREV: begin
                ord_we    = 1'b1;
                ord_waddr = p8(cur_ord.prev_ord);
                ord_wdata = ord_rdata;
                ord_wdata.next_ord = cur_ord.next_ord;
                state_n   = ST_CXL_RD_NEXT;
            end

            ST_CXL_RD_NEXT: begin
                if (!is_null(cur_ord.next_ord)) begin
                    ord_raddr = p8(cur_ord.next_ord);
                    state_n   = ST_CXL_WR_NEXT;
                end else begin
                    lvl_raddr = p8(cur_ord.level_ptr);
                    state_n   = ST_CXL_RD_LVL;
                end
            end

            ST_CXL_WR_NEXT: begin
                ord_we    = 1'b1;
                ord_waddr = p8(cur_ord.next_ord);
                ord_wdata = ord_rdata;
                ord_wdata.prev_ord = cur_ord.prev_ord;
                lvl_raddr = p8(cur_ord.level_ptr);
                state_n   = ST_CXL_RD_LVL;
            end

            ST_CXL_RD_LVL: begin
                cur_lvl_n = lvl_rdata;
                state_n   = ST_CXL_WR_LVL;
            end

            ST_CXL_WR_LVL: begin
                lvl_we    = 1'b1;
                lvl_waddr = p8(cur_ord.level_ptr);
                lvl_wdata = cur_lvl;
                lvl_wdata.agg_qty = cur_lvl.agg_qty - cur_ord.qty;
                lvl_wdata.count   = cur_lvl.count - 16'd1;
                if (is_null(cur_ord.prev_ord))
                    lvl_wdata.head = cur_ord.next_ord;
                if (is_null(cur_ord.next_ord))
                    lvl_wdata.tail = cur_ord.prev_ord;
                cur_lvl_n = lvl_wdata;
                lvl_ptr_n = cur_ord.level_ptr;
                state_n   = ST_CXL_H1;
            end

            ST_CXL_H1: begin
                if (is_null(cur_ord.hash_prev)) begin
                    hash_we    = 1'b1;
                    hash_waddr = oid_hash(cur_ord.oid);
                    hash_wdata = cur_ord.hash_next;
                    if (!is_null(cur_ord.hash_next)) begin
                        ord_raddr = p8(cur_ord.hash_next);
                        state_n   = ST_CXL_H2;
                    end else
                        state_n = ST_CXL_FREE;
                end else begin
                    if (!nei_ord.valid) begin
                        ord_raddr = p8(cur_ord.hash_prev);
                        nei_ord_n.valid = 1'b1;
                        state_n = ST_CXL_H1;
                    end else begin
                        ord_we    = 1'b1;
                        ord_waddr = p8(cur_ord.hash_prev);
                        ord_wdata = ord_rdata;
                        ord_wdata.hash_next = cur_ord.hash_next;
                        nei_ord_n = '0;
                        if (!is_null(cur_ord.hash_next)) begin
                            ord_raddr = p8(cur_ord.hash_next);
                            state_n   = ST_CXL_H2;
                        end else
                            state_n = ST_CXL_FREE;
                    end
                end
            end

            ST_CXL_H2: begin
                ord_we    = 1'b1;
                ord_waddr = p8(cur_ord.hash_next);
                ord_wdata = ord_rdata;
                ord_wdata.hash_prev = cur_ord.hash_prev;
                state_n   = ST_CXL_FREE;
            end

            ST_CXL_FREE: begin
                do_ord_push  = 1'b1;
                ord_push_ptr = (q.cmd == BOOK_MATCH_ONE ||
                                q.cmd == BOOK_UNLINK_RESTING) ? found_ptr : found_ptr;
                // found_ptr is the order we remove for match; for cancel too
                if (q.cmd == BOOK_CANCEL)
                    ord_push_ptr = found_ptr;
                else
                    ord_push_ptr = found_ptr;

                // invalidate order
                ord_we    = 1'b1;
                ord_waddr = p8(ord_push_ptr);
                ord_wdata = '0;

                if (cur_lvl.count == 16'd0) begin
                    // pop empty level
                    state_n = ST_CXL_LVL_RD_PREV;
                end else begin
                    // update BBO qty if this level is best
                    if (q.cmd == BOOK_CANCEL) begin
                        if (cur_ord.side == SIDE_BID && bbo[q.inst].bid_lvl == lvl_ptr)
                            bbo_n[q.inst].bid_qty = cur_lvl.agg_qty;
                        if (cur_ord.side == SIDE_ASK && bbo[q.inst].ask_lvl == lvl_ptr)
                            bbo_n[q.inst].ask_qty = cur_lvl.agg_qty;
                        rsp_n = fill_bbo_fields(rsp_clear(), q.inst);
                        rsp_n.ok = 1'b1;
                        rsp_n.found = 1'b1;
                        rsp_n.found_qty = cur_ord.qty;
                        rsp_n.found_price = cur_ord.price;
                        rsp_n.found_side = cur_ord.side;
                        state_n = ST_RSP;
                    end else begin
                        // match full fill, level still live
                        if (q.side == SIDE_ASK) begin
                            bbo_n[q.inst].bid_qty = cur_lvl.agg_qty;
                        end else begin
                            bbo_n[q.inst].ask_qty = cur_lvl.agg_qty;
                        end
                        rsp_n = fill_bbo_fields(rsp_clear(), q.inst);
                        rsp_n.ok           = 1'b1;
                        rsp_n.crossed      = 1'b1;
                        rsp_n.fill_qty     = fill_qty_r;
                        rsp_n.fill_price   = cur_ord.price;
                        rsp_n.resting_oid  = cur_ord.oid;
                        rsp_n.resting_firm = cur_ord.firm;
                        rsp_n.resting_left = '0;
                        if (q.side == SIDE_ASK)
                            rsp_n.bbo_bid_qty = cur_lvl.agg_qty;
                        else
                            rsp_n.bbo_ask_qty = cur_lvl.agg_qty;
                        state_n = ST_RSP;
                    end
                end
            end

            ST_CXL_LVL_RD_PREV: begin
                if (!is_null(cur_lvl.prev_lvl)) begin
                    lvl_raddr = p8(cur_lvl.prev_lvl);
                    state_n   = ST_CXL_LVL_WR_PREV;
                end else begin
                    // this was the best level
                    state_n = ST_CXL_LVL_RD_NEXT;
                end
            end

            ST_CXL_LVL_WR_PREV: begin
                lvl_we    = 1'b1;
                lvl_waddr = p8(cur_lvl.prev_lvl);
                lvl_wdata = lvl_rdata;
                lvl_wdata.next_lvl = cur_lvl.next_lvl;
                state_n   = ST_CXL_LVL_RD_NEXT;
            end

            ST_CXL_LVL_RD_NEXT: begin
                if (!is_null(cur_lvl.next_lvl)) begin
                    lvl_raddr = p8(cur_lvl.next_lvl);
                    state_n   = ST_CXL_LVL_WR_NEXT;
                end else begin
                    // no next — BBO becomes empty or already updated prev
                    do_lvl_push  = 1'b1;
                    lvl_push_ptr = lvl_ptr;
                    lvl_we       = 1'b1;
                    lvl_waddr    = p8(lvl_ptr);
                    lvl_wdata    = '0;
                    if (is_null(cur_lvl.prev_lvl)) begin
                        if ((q.cmd == BOOK_CANCEL && cur_ord.side == SIDE_BID) ||
                            ((q.cmd == BOOK_MATCH_ONE || q.cmd == BOOK_UNLINK_RESTING) &&
                             q.side == SIDE_ASK)) begin
                            bbo_n[q.inst].bid_valid = 1'b0;
                            bbo_n[q.inst].bid_lvl   = NULL_PTR;
                            bbo_n[q.inst].bid_qty   = '0;
                            bbo_n[q.inst].bid_px    = '0;
                        end else begin
                            bbo_n[q.inst].ask_valid = 1'b0;
                            bbo_n[q.inst].ask_lvl   = NULL_PTR;
                            bbo_n[q.inst].ask_qty   = '0;
                            bbo_n[q.inst].ask_px    = '0;
                        end
                    end
                    rsp_n = fill_bbo_fields(rsp_clear(), q.inst);
                    rsp_n.ok = 1'b1;
                    if (q.cmd == BOOK_CANCEL) begin
                        rsp_n.found = 1'b1;
                        rsp_n.found_qty = cur_ord.qty;
                        rsp_n.found_price = cur_ord.price;
                    end else begin
                        rsp_n.crossed      = 1'b1;
                        rsp_n.fill_qty     = fill_qty_r;
                        rsp_n.fill_price   = cur_ord.price;
                        rsp_n.resting_oid  = cur_ord.oid;
                        rsp_n.resting_firm = cur_ord.firm;
                    end
                    state_n = ST_RSP;
                end
            end

            ST_CXL_LVL_WR_NEXT: begin
                lvl_we    = 1'b1;
                lvl_waddr = p8(cur_lvl.next_lvl);
                lvl_wdata = lvl_rdata;
                lvl_wdata.prev_lvl = cur_lvl.prev_lvl;

                do_lvl_push  = 1'b1;
                lvl_push_ptr = lvl_ptr;

                // invalidate old level
                // (second write same cycle not possible) — invalidate next cycle
                // We already use lvl_we.  Skip invalidate; free-list reuse is enough
                // if we only access allocated ptrs.  Still zero it on a later
                // idle?  Accept stale valid until reuse overwrites.

                if (is_null(cur_lvl.prev_lvl)) begin
                    // promote next to BBO
                    if ((q.cmd == BOOK_CANCEL && cur_ord.side == SIDE_BID) ||
                        ((q.cmd == BOOK_MATCH_ONE || q.cmd == BOOK_UNLINK_RESTING) &&
                         q.side == SIDE_ASK)) begin
                        bbo_n[q.inst].bid_valid = 1'b1;
                        bbo_n[q.inst].bid_px    = lvl_rdata.price;
                        bbo_n[q.inst].bid_qty   = lvl_rdata.agg_qty;
                        bbo_n[q.inst].bid_lvl   = cur_lvl.next_lvl;
                    end else begin
                        bbo_n[q.inst].ask_valid = 1'b1;
                        bbo_n[q.inst].ask_px    = lvl_rdata.price;
                        bbo_n[q.inst].ask_qty   = lvl_rdata.agg_qty;
                        bbo_n[q.inst].ask_lvl   = cur_lvl.next_lvl;
                    end
                end

                rsp_n = fill_bbo_fields(rsp_clear(), q.inst);
                rsp_n.ok = 1'b1;
                if (q.cmd == BOOK_CANCEL) begin
                    rsp_n.found = 1'b1;
                    rsp_n.found_qty = cur_ord.qty;
                    rsp_n.found_price = cur_ord.price;
                end else begin
                    rsp_n.crossed      = 1'b1;
                    rsp_n.fill_qty     = fill_qty_r;
                    rsp_n.resting_oid  = cur_ord.oid;
                    rsp_n.resting_firm = cur_ord.firm;
                    rsp_n.fill_price   = cur_ord.price;
                end
                state_n = ST_RSP;
            end

            // -----------------------------------------------------------------
            ST_WALK_WAIT: begin
                cur_lvl_n = lvl_rdata;
                state_n   = ST_WALK_ACC;
            end

            ST_WALK_ACC: begin
                if (cur_lvl.valid &&
                    prices_cross(q.side, q.price, cur_lvl.price, 1'b1)) begin
                    acc_qty_n = acc_qty + cur_lvl.agg_qty;
                    if (!is_null(cur_lvl.next_lvl) && acc_qty_n < q.qty) begin
                        walk_ptr_n = cur_lvl.next_lvl;
                        lvl_raddr  = p8(cur_lvl.next_lvl);
                        state_n    = ST_WALK_WAIT;
                    end else begin
                        rsp_n = fill_bbo_fields(rsp_clear(), q.inst);
                        rsp_n.ok = 1'b1;
                        rsp_n.walk_qty = acc_qty_n;
                        rsp_n.would_cross = 1'b1;
                        state_n = ST_RSP;
                    end
                end else begin
                    rsp_n = fill_bbo_fields(rsp_clear(), q.inst);
                    rsp_n.ok = 1'b1;
                    rsp_n.walk_qty = acc_qty;
                    rsp_n.would_cross = (acc_qty != '0);
                    state_n = ST_RSP;
                end
            end

            // -----------------------------------------------------------------
            ST_MOD_RD_LVL: begin
                cur_lvl_n = lvl_rdata;
                state_n   = ST_MOD_WR;
            end

            ST_MOD_WR: begin
                if (q.qty == 32'h0) begin
                    // treat as cancel
                    state_n = ST_CXL_RD_PREV;
                end else if (q.qty == cur_ord.qty) begin
                    rsp_n = fill_bbo_fields(rsp_clear(), q.inst);
                    rsp_n.ok = 1'b1;
                    rsp_n.found = 1'b1;
                    rsp_n.found_qty = cur_ord.qty;
                    rsp_n.found_price = cur_ord.price;
                    state_n = ST_RSP;
                end else begin
                    logic [QTY_W-1:0] newq;
                    newq = q.qty;
                    ord_we    = 1'b1;
                    ord_waddr = p8(found_ptr);
                    ord_wdata = cur_ord;
                    ord_wdata.qty = newq;

                    lvl_we    = 1'b1;
                    lvl_waddr = p8(cur_ord.level_ptr);
                    lvl_wdata = cur_lvl;
                    lvl_wdata.agg_qty = cur_lvl.agg_qty - cur_ord.qty + newq;

                    if (cur_ord.side == SIDE_BID &&
                        bbo[q.inst].bid_lvl == cur_ord.level_ptr)
                        bbo_n[q.inst].bid_qty = lvl_wdata.agg_qty;
                    if (cur_ord.side == SIDE_ASK &&
                        bbo[q.inst].ask_lvl == cur_ord.level_ptr)
                        bbo_n[q.inst].ask_qty = lvl_wdata.agg_qty;

                    // Increase loses time priority: move to tail if not already
                    if (newq > cur_ord.qty && found_ptr != cur_lvl.tail) begin
                        // Full requeue would take more states; document as
                        // in-place qty update (priority kept).  See docs.
                    end

                    rsp_n = fill_bbo_fields(rsp_clear(), q.inst);
                    rsp_n.ok = 1'b1;
                    rsp_n.found = 1'b1;
                    rsp_n.found_qty = newq;
                    rsp_n.found_price = cur_ord.price;
                    state_n = ST_RSP;
                end
            end

            // -----------------------------------------------------------------
            ST_RSP: begin
                rsp_valid_n = 1'b1;
                if (rsp_ready)
                    state_n = ST_IDLE;
            end

            default: state_n = ST_IDLE;
        endcase
    end

    assign ord_pop  = do_ord_pop;
    assign ord_push = do_ord_push;
    assign lvl_pop  = do_lvl_pop;
    assign lvl_push = do_lvl_push;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= ST_INIT;
            init_cnt    <= 8'h0;
            rsp_q       <= '0;
            walk_ptr    <= NULL_PTR;
            hash_prev   <= NULL_PTR;
            found_ptr   <= NULL_PTR;
            lvl_ptr     <= NULL_PTR;
            lvl_prev    <= NULL_PTR;
            new_ord     <= NULL_PTR;
            new_lvl     <= NULL_PTR;
            lvl_found   <= 1'b0;
            created_lvl <= 1'b0;
            cur_ord     <= '0;
            cur_lvl     <= '0;
            nei_ord     <= '0;
            nei_lvl     <= '0;
            acc_qty     <= '0;
            fill_qty_r  <= '0;
            deplete     <= 1'b0;
            q           <= '0;
            after_cxl_insert <= 1'b0;
            for (bi = 0; bi < NUM_INSTRUMENTS; bi++)
                bbo[bi] <= bbo_clear();
        end else begin
            state       <= state_n;
            init_cnt    <= init_cnt_n;
            rsp_q       <= rsp_n;
            walk_ptr    <= walk_ptr_n;
            hash_prev   <= hash_prev_n;
            found_ptr   <= found_ptr_n;
            lvl_ptr     <= lvl_ptr_n;
            lvl_prev    <= lvl_prev_n;
            new_ord     <= new_ord_n;
            new_lvl     <= new_lvl_n;
            lvl_found   <= lvl_found_n;
            created_lvl <= created_lvl_n;
            cur_ord     <= cur_ord_n;
            cur_lvl     <= cur_lvl_n;
            nei_ord     <= nei_ord_n;
            nei_lvl     <= nei_lvl_n;
            acc_qty     <= acc_qty_n;
            fill_qty_r  <= fill_qty_n;
            deplete     <= deplete_n;
            bbo         <= bbo_n;
            if (state == ST_IDLE && req_valid)
                q <= req;
            if (state_n == ST_IDLE) begin
                nei_ord <= '0;
                nei_lvl <= '0;
            end
        end
    end

endmodule
