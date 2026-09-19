// =============================================================================
// Covergroups for opcodes, reject reasons, fill sizes, and TIF.  Instantiated
// from the UVM-lite / commercial TB.  Verilator 5 has only partial covergroup
// support — wrap with `ifndef VERILATOR if the smoke compile rejects them.
// =============================================================================

`ifndef QUASAR_COVER_SV
`define QUASAR_COVER_SV

module quasar_cover
    import quasar_pkg::*;
(
    input logic        clk,
    input logic        rst_n,
    input logic        cmd_fire,
    input logic [7:0]  opcode,
    input logic [1:0]  tif,
    input logic        side,
    input logic        ev_fire,
    input logic [7:0]  ev,
    input logic [3:0]  reject,
    input logic [31:0] fill_qty
);

`ifndef VERILATOR
    covergroup cg_opcode @(posedge clk);
        option.per_instance = 1;
        cp_op: coverpoint opcode iff (cmd_fire) {
            bins new_o  = {OP_NEW};
            bins cxl    = {OP_CANCEL};
            bins repl   = {OP_REPLACE};
            bins mod    = {OP_MODIFY};
            bins stat   = {OP_STATUS};
            bins mass   = {OP_MASS_CXL};
            illegal_bins nop = {OP_NOP};
        }
        cp_tif: coverpoint tif iff (cmd_fire && opcode == OP_NEW) {
            bins gtc = {TIF_GTC};
            bins ioc = {TIF_IOC};
            bins fok = {TIF_FOK};
        }
        cp_side: coverpoint side iff (cmd_fire);
        x_op_tif: cross cp_op, cp_tif;
    endgroup

    covergroup cg_event @(posedge clk);
        option.per_instance = 1;
        cp_ev: coverpoint ev iff (ev_fire) {
            bins ack  = {EV_ACK};
            bins rej  = {EV_REJECT};
            bins fill = {EV_FILL};
            bins cxl  = {EV_CANCEL_ACK};
            bins mod  = {EV_MODIFY_ACK};
            bins rep  = {EV_REPLACE_ACK};
            bins bbo  = {EV_BBO};
            bins st   = {EV_STATUS};
        }
        cp_rej: coverpoint reject iff (ev_fire && ev == EV_REJECT) {
            bins crc     = {REJ_CRC};
            bins opcode  = {REJ_OPCODE};
            bins inst    = {REJ_INSTRUMENT};
            bins qty     = {REJ_QTY};
            bins px      = {REJ_PRICE};
            bins notional= {REJ_RISK_NOTIONAL};
            bins pos     = {REJ_RISK_POS};
            bins rate    = {REJ_RATE};
            bins stp     = {REJ_STP};
            bins miss    = {REJ_NOT_FOUND};
            bins full    = {REJ_BOOK_FULL};
            bins dup     = {REJ_DUP_OID};
            bins dis     = {REJ_DISABLED};
            bins fok     = {REJ_FOK};
            bins po      = {REJ_POST_ONLY};
        }
        cp_fill: coverpoint fill_qty iff (ev_fire && ev == EV_FILL) {
            bins one     = {1};
            bins small   = {[2:8]};
            bins medium  = {[9:32]};
            bins large   = {[33:1024]};
        }
    endgroup

    cg_opcode  u_cg_op  = new();
    cg_event   u_cg_ev  = new();
`else
    // Verilator: sample as cover properties so the smoke compile stays clean.
    cover_op_new:  cover property (@(posedge clk) cmd_fire && opcode == OP_NEW);
    cover_op_cxl:  cover property (@(posedge clk) cmd_fire && opcode == OP_CANCEL);
    cover_op_rep:  cover property (@(posedge clk) cmd_fire && opcode == OP_REPLACE);
    cover_op_mod:  cover property (@(posedge clk) cmd_fire && opcode == OP_MODIFY);
    cover_ev_fill: cover property (@(posedge clk) ev_fire && ev == EV_FILL);
    cover_ev_ack:  cover property (@(posedge clk) ev_fire && ev == EV_ACK);
    cover_ev_rej:  cover property (@(posedge clk) ev_fire && ev == EV_REJECT);
    cover_rej_crc: cover property (@(posedge clk) ev_fire && reject == REJ_CRC);
    cover_rej_fok: cover property (@(posedge clk) ev_fire && reject == REJ_FOK);
    cover_tif_ioc: cover property (@(posedge clk) cmd_fire && tif == TIF_IOC);
    cover_tif_fok: cover property (@(posedge clk) cmd_fire && tif == TIF_FOK);
`endif

endmodule

`endif
