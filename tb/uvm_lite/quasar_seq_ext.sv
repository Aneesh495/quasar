// Extra directed sequences: FOK, IOC, STP, replace, modify, CRC poison,
// instrument sweep.  Included by tb_uvm_lite when running the long seed.

`ifndef QUASAR_SEQ_EXT_SV
`define QUASAR_SEQ_EXT_SV

package quasar_seq_ext;
    import quasar_pkg::*;
    import quasar_tb_pkg::*;
    import quasar_uvm_lite::*;

    class quasar_seq_ext_lib extends quasar_seq_lib;
        function new(mailbox #(txn_t) seq_mbox, mailbox #(txn_t) scb_mbox);
            super.new(seq_mbox, scb_mbox);
        endfunction

        task automatic directed_fok_fail();
            txn_t a, b;
            a = new();
            a.opcode = OP_NEW; a.inst = 2; a.firm = 1; a.side = SIDE_ASK;
            a.tif = TIF_GTC; a.qty = 2; a.price = 33; a.oid = next_oid++;
            put(a);
            b = new();
            b.opcode = OP_NEW; b.inst = 2; b.firm = 2; b.side = SIDE_BID;
            b.tif = TIF_FOK; b.qty = 9; b.price = 33; b.oid = next_oid++;
            put(b);
        endtask

        task automatic directed_ioc();
            txn_t a, b;
            a = new();
            a.opcode = OP_NEW; a.inst = 3; a.firm = 1; a.side = SIDE_BID;
            a.tif = TIF_GTC; a.qty = 3; a.price = 44; a.oid = next_oid++;
            put(a);
            b = new();
            b.opcode = OP_NEW; b.inst = 3; b.firm = 2; b.side = SIDE_ASK;
            b.tif = TIF_IOC; b.qty = 10; b.price = 44; b.oid = next_oid++;
            put(b);
        endtask

        task automatic directed_modify();
            txn_t a, m, c;
            a = new();
            a.opcode = OP_NEW; a.inst = 1; a.firm = 1; a.side = SIDE_ASK;
            a.tif = TIF_GTC; a.qty = 12; a.price = 19; a.oid = next_oid++;
            put(a);
            m = new();
            m.opcode = OP_MODIFY; m.inst = 1; m.firm = 1; m.side = SIDE_ASK;
            m.qty = 5; m.price = 19; m.oid = a.oid;
            put(m);
            c = new();
            c.opcode = OP_CANCEL; c.inst = 1; c.firm = 1; c.oid = a.oid;
            put(c);
        endtask

        task automatic directed_replace();
            txn_t a, r, c;
            a = new();
            a.opcode = OP_NEW; a.inst = 0; a.firm = 1; a.side = SIDE_BID;
            a.tif = TIF_GTC; a.qty = 2; a.price = 10; a.oid = next_oid++;
            put(a);
            r = new();
            r.opcode = OP_REPLACE; r.inst = 0; r.firm = 1; r.side = SIDE_BID;
            r.tif = TIF_GTC; r.qty = 2; r.price = 14; r.oid = a.oid;
            put(r);
            c = new();
            c.opcode = OP_CANCEL; c.inst = 0; c.firm = 1; c.oid = a.oid;
            put(c);
        endtask

        task automatic directed_crc_poison();
            txn_t t;
            t = new();
            t.opcode = OP_NEW; t.inst = 0; t.firm = 1; t.side = SIDE_BID;
            t.tif = TIF_GTC; t.qty = 1; t.price = 1; t.oid = next_oid++;
            t.crc_corrupt = 1'b1;
            put(t);
        endtask

        task automatic instrument_sweep();
            txn_t t, c;
            int i;
            for (i = 0; i < NUM_INSTRUMENTS; i++) begin
                t = new();
                t.opcode = OP_NEW; t.inst = 8'(i); t.firm = 1; t.side = SIDE_BID;
                t.tif = TIF_GTC; t.qty = 1; t.price = 32'(100 + i); t.oid = next_oid++;
                put(t);
                c = new();
                c.opcode = OP_CANCEL; c.inst = 8'(i); c.firm = 1; c.oid = t.oid;
                put(c);
            end
        endtask

        task automatic run_battery();
            directed_rest_and_hit();
            directed_cancel();
            directed_fok_fail();
            directed_ioc();
            directed_modify();
            directed_replace();
            directed_crc_poison();
            instrument_sweep();
            random_stream(16);
        endtask
    endclass
endpackage

`endif
