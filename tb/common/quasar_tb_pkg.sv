// =============================================================================
// Testbench helpers: CRC, message pack/unpack, AXIS beat tasks, AXI-Lite
// R/W, and a small scoreboard transaction class.  Shared by the directed
// smoke tests and the UVM-lite environment.
// =============================================================================

`ifndef QUASAR_TB_PKG_SV
`define QUASAR_TB_PKG_SV

package quasar_tb_pkg;
    import quasar_pkg::*;

    function automatic logic [31:0] crc32_ieee(input logic [223:0] body);
        logic [31:0] acc, t;
        logic [7:0]  b;
        acc = 32'hFFFF_FFFF;
        for (int i = 0; i < 28; i++) begin
            b = body[i*8 +: 8];
            t = acc ^ {24'h0, b};
            for (int k = 0; k < 8; k++)
                t = t[0] ? ((t >> 1) ^ 32'hEDB88320) : (t >> 1);
            acc = t;
        end
        return acc ^ 32'hFFFF_FFFF;
    endfunction

    function automatic msg_t mk_msg(
        input logic [7:0]  opcode,
        input logic [7:0]  inst,
        input logic [7:0]  firm,
        input logic        side,
        input logic [1:0]  tif,
        input logic [1:0]  stp,
        input logic        post_only,
        input logic [31:0] qty,
        input logic [31:0] price,
        input logic [63:0] oid,
        input logic [31:0] seq = 32'h0,
        input logic [31:0] aux = 32'h0
    );
        msg_t m;
        m = '0;
        m.opcode    = opcode;
        m.inst      = inst;
        m.firm      = firm;
        m.side      = side;
        m.tif       = tif;
        m.stp       = stp;
        m.post_only = post_only;
        m.qty       = qty;
        m.price     = price;
        m.oid       = oid;
        m.seq       = seq;
        m.aux       = aux;
        m.crc32     = crc32_ieee(m[223:0]);
        return m;
    endfunction

    function automatic event_t bits_to_event(input logic [255:0] w);
        return event_t'(w);
    endfunction

    function automatic string ev_name(input logic [7:0] e);
        case (e)
            EV_ACK:         ev_name = "ACK";
            EV_REJECT:      ev_name = "REJECT";
            EV_FILL:        ev_name = "FILL";
            EV_CANCEL_ACK:  ev_name = "CANCEL_ACK";
            EV_MODIFY_ACK:  ev_name = "MODIFY_ACK";
            EV_REPLACE_ACK: ev_name = "REPLACE_ACK";
            EV_BBO:         ev_name = "BBO";
            EV_DELTA:       ev_name = "DELTA";
            EV_DROP:        ev_name = "DROP";
            EV_STATUS:      ev_name = "STATUS";
            default:        ev_name = $sformatf("EV_%02h", e);
        endcase
    endfunction

    function automatic string rej_name(input logic [3:0] r);
        case (r)
            REJ_NONE:          rej_name = "NONE";
            REJ_CRC:           rej_name = "CRC";
            REJ_OPCODE:        rej_name = "OPCODE";
            REJ_INSTRUMENT:    rej_name = "INSTRUMENT";
            REJ_QTY:           rej_name = "QTY";
            REJ_PRICE:         rej_name = "PRICE";
            REJ_RISK_NOTIONAL: rej_name = "NOTIONAL";
            REJ_RISK_POS:      rej_name = "POS";
            REJ_RATE:          rej_name = "RATE";
            REJ_STP:           rej_name = "STP";
            REJ_NOT_FOUND:     rej_name = "NOT_FOUND";
            REJ_BOOK_FULL:     rej_name = "BOOK_FULL";
            REJ_DUP_OID:       rej_name = "DUP_OID";
            REJ_DISABLED:      rej_name = "DISABLED";
            REJ_FOK:           rej_name = "FOK";
            REJ_POST_ONLY:     rej_name = "POST_ONLY";
            default:           rej_name = $sformatf("REJ_%0h", r);
        endcase
    endfunction

    // Lightweight transaction used by the UVM-lite driver / monitor.
    class quasar_txn;
        rand logic [7:0]  opcode;
        rand logic [7:0]  inst;
        rand logic [7:0]  firm;
        rand logic        side;
        rand logic [1:0]  tif;
        rand logic [1:0]  stp;
        rand logic        post_only;
        rand logic [31:0] qty;
        rand logic [31:0] price;
        rand logic [63:0] oid;
        rand logic [31:0] seq;
        rand logic [31:0] aux;
        bit               crc_corrupt;

        constraint c_op   { opcode inside {OP_NEW, OP_CANCEL, OP_REPLACE, OP_MODIFY, OP_STATUS}; }
        constraint c_inst { inst inside {[0:NUM_INSTRUMENTS-1]}; }
        constraint c_qty  { qty  inside {[1:64]}; }
        constraint c_px   { price inside {[100:200]}; }
        constraint c_tif  { tif inside {TIF_GTC, TIF_IOC, TIF_FOK}; }
        constraint c_stp  { stp == STP_OFF; }
        constraint c_po   { post_only == 1'b0; }

        function msg_t to_msg();
            msg_t m;
            m = mk_msg(opcode, inst, firm, side, tif, stp, post_only,
                       qty, price, oid, seq, aux);
            if (crc_corrupt)
                m.crc32 ^= 32'h1;
            return m;
        endfunction

        function void copy_from_msg(input msg_t m);
            opcode    = m.opcode;
            inst      = m.inst;
            firm      = m.firm;
            side      = m.side;
            tif       = m.tif;
            stp       = m.stp;
            post_only = m.post_only;
            qty       = m.qty;
            price     = m.price;
            oid       = m.oid;
            seq       = m.seq;
            aux       = m.aux;
        endfunction
    endclass

    class quasar_event_txn;
        event_t e;
        function new(event_t x);
            e = x;
        endfunction
        function string sprint();
            return $sformatf("%s inst=%0d side=%0d qty=%0d px=%0d oid=%0h rej=%s",
                             ev_name(e.ev), e.inst, e.side, e.qty, e.price,
                             e.oid, rej_name(e.reject));
        endfunction
    endclass

endpackage

`endif
