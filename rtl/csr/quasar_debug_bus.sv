// =============================================================================
// Debug bus aggregator
//
// Collects live diagnostic signals from across the pipeline and presents
// them as a single struct that the CSR can snapshot on demand.  Avoids
// routing individual wires from every block to the CSR; instead the CSR
// reads from this centralised register which is updated every cycle.
//
// The snapshot is triggered by a CSR read of any DBG_ address (via a strobe
// from the CSR to here); between reads, the live signals continue updating.
// For coherent snapshots of multiple registers, the CSR write CTRL.DBG_FREEZE
// halts updates until released.
//
// Fields:
//   cycle        — free-running core cycle counter
//   mt_state     — matcher FSM state
//   bk_state     — book FSM state
//   rk_tokens    — remaining risk tokens
//   ord_used     — live order count
//   lvl_used     — live level count
//   evt_fifo_lvl — egress event FIFO fill level
//   cmd_fifo_lvl — ingress command FIFO fill level
//   bbo_bid_px   — BBO bid price for the configured DBG_INST
//   bbo_ask_px   — BBO ask price
//   bbo_bid_qty  — BBO bid aggregate qty
//   bbo_ask_qty  — BBO ask aggregate qty
// =============================================================================

module quasar_debug_bus
    import quasar_pkg::*;
(
    input  logic                  clk,
    input  logic                  rst_n,

    input  logic                  freeze,

    input  logic [31:0]           cycle,
    input  logic [5:0]            mt_state,
    input  logic [5:0]            bk_state,
    input  logic [15:0]           rk_tokens,
    input  logic [15:0]           ord_used,
    input  logic [15:0]           lvl_used,
    input  logic [15:0]           evt_fifo_lvl,
    input  logic [15:0]           cmd_fifo_lvl,
    input  logic [PRICE_W-1:0]    bbo_bid_px,
    input  logic [PRICE_W-1:0]    bbo_ask_px,
    input  logic [QTY_W-1:0]      bbo_bid_qty,
    input  logic [QTY_W-1:0]      bbo_ask_qty,

    // Snapshot outputs (to CSR read-data mux)
    output logic [31:0]           snap_cycle,
    output logic [5:0]            snap_mt_state,
    output logic [5:0]            snap_bk_state,
    output logic [15:0]           snap_rk_tokens,
    output logic [15:0]           snap_ord_used,
    output logic [15:0]           snap_lvl_used,
    output logic [15:0]           snap_evt_fifo_lvl,
    output logic [15:0]           snap_cmd_fifo_lvl,
    output logic [PRICE_W-1:0]    snap_bbo_bid_px,
    output logic [PRICE_W-1:0]    snap_bbo_ask_px,
    output logic [QTY_W-1:0]      snap_bbo_bid_qty,
    output logic [QTY_W-1:0]      snap_bbo_ask_qty,

    output logic                  busy    // any FSM non-IDLE
);

    assign busy = (mt_state != 6'h0) || (bk_state != 6'h0);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            snap_cycle       <= 32'h0;
            snap_mt_state    <= 6'h0;
            snap_bk_state    <= 6'h0;
            snap_rk_tokens   <= 16'h0;
            snap_ord_used    <= 16'h0;
            snap_lvl_used    <= 16'h0;
            snap_evt_fifo_lvl <= 16'h0;
            snap_cmd_fifo_lvl <= 16'h0;
            snap_bbo_bid_px  <= '0;
            snap_bbo_ask_px  <= '0;
            snap_bbo_bid_qty <= '0;
            snap_bbo_ask_qty <= '0;
        end else if (!freeze) begin
            snap_cycle       <= cycle;
            snap_mt_state    <= mt_state;
            snap_bk_state    <= bk_state;
            snap_rk_tokens   <= rk_tokens;
            snap_ord_used    <= ord_used;
            snap_lvl_used    <= lvl_used;
            snap_evt_fifo_lvl <= evt_fifo_lvl;
            snap_cmd_fifo_lvl <= cmd_fifo_lvl;
            snap_bbo_bid_px  <= bbo_bid_px;
            snap_bbo_ask_px  <= bbo_ask_px;
            snap_bbo_bid_qty <= bbo_bid_qty;
            snap_bbo_ask_qty <= bbo_ask_qty;
        end
    end

endmodule
