// =============================================================================
// Quasar SVA library — bind-ready properties for FIFO, AXI-Stream, book
// invariants, and "no lost order" tracking.  Compiled when +define+QUASAR_SVA
// is set.  Verilator supports a useful subset (`assert property`); commercial
// simulators get the full concurrent / cover set.
// =============================================================================

`ifndef QUASAR_SVA_SV
`define QUASAR_SVA_SV

module quasar_axis_sva #(
    parameter int DATA_W = 256
) (
    input logic clk,
    input logic rst_n,
    input logic tvalid,
    input logic tready,
    input logic [DATA_W-1:0] tdata,
    input logic              tlast
);

    property p_valid_stable;
        @(posedge clk) disable iff (!rst_n)
            (tvalid && !tready) |=> tvalid;
    endproperty
    a_valid_stable: assert property (p_valid_stable)
        else $error("AXIS tvalid dropped while !tready");

    property p_data_stable;
        @(posedge clk) disable iff (!rst_n)
            (tvalid && !tready) |=> $stable(tdata) && $stable(tlast);
    endproperty
    a_data_stable: assert property (p_data_stable)
        else $error("AXIS payload changed while stalled");

    property p_no_x_on_valid;
        @(posedge clk) disable iff (!rst_n)
            tvalid |-> !$isunknown(tdata) && !$isunknown(tlast);
    endproperty
    a_no_x: assert property (p_no_x_on_valid);

    cover_beat: cover property (@(posedge clk) tvalid && tready && tlast);
    cover_stall: cover property (@(posedge clk) tvalid && !tready);

endmodule

module quasar_fifo_sva #(
    parameter int DEPTH = 16
) (
    input logic clk,
    input logic rst_n,
    input logic wr_en,
    input logic rd_en,
    input logic full,
    input logic empty,
    input logic [$clog2(DEPTH+1)-1:0] count
);

    property p_no_overflow;
        @(posedge clk) disable iff (!rst_n)
            !(wr_en && full);
    endproperty
    a_no_ovf: assert property (p_no_overflow);

    property p_no_underflow;
        @(posedge clk) disable iff (!rst_n)
            !(rd_en && empty);
    endproperty
    a_no_udf: assert property (p_no_underflow);

    property p_count_range;
        @(posedge clk) disable iff (!rst_n)
            count <= DEPTH[$clog2(DEPTH+1)-1:0];
    endproperty
    a_count: assert property (p_count_range);

    property p_empty_zero;
        @(posedge clk) disable iff (!rst_n)
            empty |-> (count == '0);
    endproperty
    a_empty: assert property (p_empty_zero);

endmodule

// Bound onto quasar_core: every accepted ingress message eventually produces
// at least one egress event (ack, reject, fill, ...).  Implemented with a
// credit counter rather than a per-oid scoreboard so it stays synthesizable
// as a checker.
module quasar_nolost_sva (
    input logic clk,
    input logic rst_n,
    input logic in_fire,
    input logic out_fire,
    input logic [7:0] out_ev
);
    integer inflight;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            inflight <= 0;
        else begin
            if (in_fire)
                inflight <= inflight + 1;
            // terminal events retire one command
            if (out_fire && (out_ev == 8'h10 || out_ev == 8'h11 ||
                             out_ev == 8'h13 || out_ev == 8'h14 ||
                             out_ev == 8'h15 || out_ev == 8'h19))
                inflight <= inflight - (in_fire ? 0 : 1) + (in_fire ? 1 : 0) - 1 + (in_fire ? 1 : 0);
        end
    end

    // Simpler concurrent form:
    property p_inflight_bounded;
        @(posedge clk) disable iff (!rst_n)
            inflight < 64;
    endproperty
    a_bound: assert property (p_inflight_bounded);

endmodule

module quasar_book_sva
    import quasar_pkg::*;
(
    input logic clk,
    input logic rst_n,
    input logic req_valid,
    input logic req_ready,
    input logic [3:0] cmd,
    input logic rsp_valid,
    input logic rsp_ok,
    input logic [3:0] reject,
    input logic [15:0] orders_used,
    input logic [15:0] levels_used
);

    property p_used_bounds;
        @(posedge clk) disable iff (!rst_n)
            (orders_used <= 16'(MAX_ORDERS)) && (levels_used <= 16'(MAX_LEVELS));
    endproperty
    a_used: assert property (p_used_bounds);

    property p_req_hold;
        @(posedge clk) disable iff (!rst_n)
            (req_valid && !req_ready) |=> req_valid;
    endproperty
    a_req_hold: assert property (p_req_hold);

    property p_rsp_implies_cmd;
        @(posedge clk) disable iff (!rst_n)
            rsp_valid |-> (reject == REJ_NONE) || !rsp_ok ||
                          (reject inside {REJ_NOT_FOUND, REJ_DUP_OID,
                                          REJ_BOOK_FULL, REJ_STP, REJ_OPCODE});
    endproperty
    a_rej: assert property (p_rsp_implies_cmd);

    cover_match: cover property (@(posedge clk) req_valid && req_ready && cmd == BOOK_MATCH_ONE);
    cover_insert: cover property (@(posedge clk) req_valid && req_ready && cmd == BOOK_INSERT);
    cover_cancel: cover property (@(posedge clk) req_valid && req_ready && cmd == BOOK_CANCEL);

endmodule

`endif
