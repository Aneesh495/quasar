// =============================================================================
// BBO level-depth scanner — optional satellite module that iterates through
// the ask and bid level chains from the BBO pointer and accumulates the top-N
// depth snapshot (price, aggregate qty) into a small RAM that the CSR can
// report.  Used for pre-trade analytics and post-match delta emission.
//
// Scan is kick-started on every EV_BBO or when software writes to DBG_INST.
// One price level is processed per cycle in SCAN state.  The book book FSM
// is the only SRAM master; this scanner reads the same level RAM read-port
// via separate re-registered reads (it loses if the book is writing, which
// is fine — the data can lag a few cycles).
//
// Does NOT share any write ports with the book FSM.  Pure read-only.
// =============================================================================

module quasar_bbo_scan
    import quasar_pkg::*;
#(
    parameter int DEPTH_LEVELS = 5  // how many levels to capture per side
) (
    input  logic                  clk,
    input  logic                  rst_n,

    input  logic                  scan_kick,          // pulse to start
    input  logic [INST_W-1:0]     scan_inst,          // which instrument

    input  bbo_t                  bbo,                // from book BBO flops

    // Read port to level RAM (shared, read-only, 1-cycle latency)
    output logic [7:0]            lvl_raddr,
    input  level_rec_t            lvl_rdata,

    // Depth snapshot output (registered, stable during scan)
    output logic [DEPTH_LEVELS-1:0][PRICE_W-1:0]  bid_px,
    output logic [DEPTH_LEVELS-1:0][QTY_W-1:0]    bid_qty,
    output logic [DEPTH_LEVELS-1:0]                bid_valid_vec,

    output logic [DEPTH_LEVELS-1:0][PRICE_W-1:0]  ask_px,
    output logic [DEPTH_LEVELS-1:0][QTY_W-1:0]    ask_qty,
    output logic [DEPTH_LEVELS-1:0]                ask_valid_vec,

    output logic                  scan_busy,
    output logic                  scan_done
);

    localparam int IDX_W = $clog2(DEPTH_LEVELS);

    typedef enum logic [2:0] {
        SC_IDLE,
        SC_START,
        SC_BID_WAIT,
        SC_BID_LATCH,
        SC_ASK_WAIT,
        SC_ASK_LATCH,
        SC_DONE
    } sc_state_e;

    sc_state_e state, state_n;

    logic [IDX_W-1:0]  slot, slot_n;
    logic              do_bid, do_bid_n;
    logic [PTR_W-1:0]  walk_ptr, walk_ptr_n;
    logic [INST_W-1:0] inst_q, inst_q_n;

    logic [DEPTH_LEVELS-1:0][PRICE_W-1:0]  bp, ap;
    logic [DEPTH_LEVELS-1:0][QTY_W-1:0]   bq, aq;
    logic [DEPTH_LEVELS-1:0]               bv, av;

    assign bid_px        = bp;
    assign bid_qty       = bq;
    assign bid_valid_vec = bv;
    assign ask_px        = ap;
    assign ask_qty       = aq;
    assign ask_valid_vec = av;
    assign scan_busy     = (state != SC_IDLE);
    assign scan_done     = (state == SC_DONE);

    function automatic logic is_null_ptr(input logic [PTR_W-1:0] p);
        is_null_ptr = (p == NULL_PTR);
    endfunction

    always_comb begin
        state_n     = state;
        slot_n      = slot;
        do_bid_n    = do_bid;
        walk_ptr_n  = walk_ptr;
        inst_q_n    = inst_q;
        lvl_raddr   = 8'h0;

        unique case (state)
            SC_IDLE: begin
                if (scan_kick) begin
                    inst_q_n = scan_inst;
                    state_n  = SC_START;
                end
            end

            SC_START: begin
                slot_n   = '0;
                do_bid_n = 1'b1;
                // start with bid side
                if (!is_null_ptr(bbo.bid_lvl) && bbo.bid_valid) begin
                    walk_ptr_n = bbo.bid_lvl;
                    lvl_raddr  = bbo.bid_lvl[7:0];
                    state_n    = SC_BID_WAIT;
                end else begin
                    // empty bid — go to ask side
                    if (!is_null_ptr(bbo.ask_lvl) && bbo.ask_valid) begin
                        walk_ptr_n = bbo.ask_lvl;
                        lvl_raddr  = bbo.ask_lvl[7:0];
                        state_n    = SC_ASK_WAIT;
                    end else
                        state_n = SC_DONE;
                end
            end

            SC_BID_WAIT: begin
                lvl_raddr  = walk_ptr[7:0];
                state_n    = SC_BID_LATCH;
            end

            SC_BID_LATCH: begin
                if (lvl_rdata.valid && slot < IDX_W'(DEPTH_LEVELS)) begin
                    slot_n = slot + IDX_W'(1);
                    if (!is_null_ptr(lvl_rdata.next_lvl) &&
                        slot_n < IDX_W'(DEPTH_LEVELS)) begin
                        walk_ptr_n = lvl_rdata.next_lvl;
                        lvl_raddr  = lvl_rdata.next_lvl[7:0];
                        state_n    = SC_BID_WAIT;
                    end else begin
                        // switch to ask side
                        slot_n = '0;
                        if (!is_null_ptr(bbo.ask_lvl) && bbo.ask_valid) begin
                            walk_ptr_n = bbo.ask_lvl;
                            lvl_raddr  = bbo.ask_lvl[7:0];
                            state_n    = SC_ASK_WAIT;
                        end else
                            state_n = SC_DONE;
                    end
                end else begin
                    slot_n  = '0;
                    if (!is_null_ptr(bbo.ask_lvl) && bbo.ask_valid) begin
                        walk_ptr_n = bbo.ask_lvl;
                        lvl_raddr  = bbo.ask_lvl[7:0];
                        state_n    = SC_ASK_WAIT;
                    end else
                        state_n = SC_DONE;
                end
            end

            SC_ASK_WAIT: begin
                lvl_raddr = walk_ptr[7:0];
                state_n   = SC_ASK_LATCH;
            end

            SC_ASK_LATCH: begin
                if (lvl_rdata.valid && slot < IDX_W'(DEPTH_LEVELS)) begin
                    slot_n = slot + IDX_W'(1);
                    if (!is_null_ptr(lvl_rdata.next_lvl) &&
                        slot_n < IDX_W'(DEPTH_LEVELS)) begin
                        walk_ptr_n = lvl_rdata.next_lvl;
                        lvl_raddr  = lvl_rdata.next_lvl[7:0];
                        state_n    = SC_ASK_WAIT;
                    end else
                        state_n = SC_DONE;
                end else
                    state_n = SC_DONE;
            end

            SC_DONE: begin
                state_n = SC_IDLE;
            end

            default: state_n = SC_IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= SC_IDLE;
            slot     <= '0;
            do_bid   <= 1'b1;
            walk_ptr <= NULL_PTR;
            inst_q   <= '0;
            for (int i = 0; i < DEPTH_LEVELS; i++) begin
                bp[i] <= '0; bq[i] <= '0; bv[i] <= 1'b0;
                ap[i] <= '0; aq[i] <= '0; av[i] <= 1'b0;
            end
        end else begin
            state    <= state_n;
            slot     <= slot_n;
            do_bid   <= do_bid_n;
            walk_ptr <= walk_ptr_n;
            inst_q   <= inst_q_n;

            if (state == SC_BID_LATCH && lvl_rdata.valid &&
                slot < IDX_W'(DEPTH_LEVELS)) begin
                bp[slot] <= lvl_rdata.price;
                bq[slot] <= lvl_rdata.agg_qty;
                bv[slot] <= 1'b1;
            end

            if (state == SC_ASK_LATCH && lvl_rdata.valid &&
                slot < IDX_W'(DEPTH_LEVELS)) begin
                ap[slot] <= lvl_rdata.price;
                aq[slot] <= lvl_rdata.agg_qty;
                av[slot] <= 1'b1;
            end

            if (state == SC_START) begin
                for (int i = 0; i < DEPTH_LEVELS; i++) begin
                    bv[i] <= 1'b0;
                    av[i] <= 1'b0;
                end
            end
        end
    end

`ifdef QUASAR_SVA
    property p_busy_not_kick;
        @(posedge clk) disable iff (!rst_n)
            scan_busy |-> !scan_kick;
    endproperty
    a_no_reentrant: assert property (p_busy_not_kick);
`endif

    wire unused_do_bid = do_bid;
    wire unused_inst   = |inst_q;

endmodule
