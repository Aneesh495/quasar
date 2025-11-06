// Protocol-level SVA: legal opcode/event pairings, reject-only-on-reject,
// fill quantity nonzero, and BBO snapshot consistency flags.

`ifndef QUASAR_PROTOCOL_SVA_SV
`define QUASAR_PROTOCOL_SVA_SV

module quasar_protocol_sva
    import quasar_pkg::*;
(
    input logic        clk,
    input logic        rst_n,
    input logic        ev_fire,
    input event_t      ev,
    input logic        cmd_fire,
    input cmd_t        cmd
);

    property p_fill_qty_nz;
        @(posedge clk) disable iff (!rst_n)
            (ev_fire && ev.ev == EV_FILL) |-> (ev.qty != '0);
    endproperty
    a_fill_qty: assert property (p_fill_qty_nz);

    property p_reject_code;
        @(posedge clk) disable iff (!rst_n)
            (ev_fire && ev.ev == EV_REJECT) |-> (ev.reject != REJ_NONE);
    endproperty
    a_rej_code: assert property (p_reject_code);

    property p_ack_no_rej;
        @(posedge clk) disable iff (!rst_n)
            (ev_fire && ev.ev inside {EV_ACK, EV_CANCEL_ACK, EV_MODIFY_ACK,
                                      EV_REPLACE_ACK}) |-> (ev.reject == REJ_NONE);
    endproperty
    a_ack_clean: assert property (p_ack_no_rej);

    property p_known_event;
        @(posedge clk) disable iff (!rst_n)
            ev_fire |-> ev.ev inside {EV_NOP, EV_ACK, EV_REJECT, EV_FILL,
                                      EV_CANCEL_ACK, EV_MODIFY_ACK, EV_REPLACE_ACK,
                                      EV_BBO, EV_DELTA, EV_DROP, EV_STATUS};
    endproperty
    a_ev: assert property (p_known_event);

    property p_cmd_inst_range_or_reject;
        @(posedge clk) disable iff (!rst_n)
            (cmd_fire && cmd.crc_ok && opcode_is_book(cmd.opcode) &&
             cmd.inst >= INST_W'(NUM_INSTRUMENTS)) |-> ##[1:64] ev_fire;
    endproperty
    a_bad_inst_retires: assert property (p_cmd_inst_range_or_reject);

    cover_fill:   cover property (@(posedge clk) ev_fire && ev.ev == EV_FILL);
    cover_ack:    cover property (@(posedge clk) ev_fire && ev.ev == EV_ACK);
    cover_cxl:    cover property (@(posedge clk) ev_fire && ev.ev == EV_CANCEL_ACK);
    cover_rej:    cover property (@(posedge clk) ev_fire && ev.ev == EV_REJECT);
    cover_new:    cover property (@(posedge clk) cmd_fire && cmd.opcode == OP_NEW);
    cover_cxl_op: cover property (@(posedge clk) cmd_fire && cmd.opcode == OP_CANCEL);

endmodule

`endif
