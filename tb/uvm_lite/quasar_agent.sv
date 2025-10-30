// =============================================================================
// UVM-lite (no UVM library): AXIS driver / monitor / scoreboard / sequences.
// Runs under Verilator.  Full UVM (uvm_agent, uvm_sequencer, ...) is the
// commercial-sim path — see docs/verification.md.
// =============================================================================

`ifndef QUASAR_AGENT_SV
`define QUASAR_AGENT_SV

package quasar_uvm_lite;
    import quasar_pkg::*;
    import quasar_tb_pkg::*;

    // ---- mailbox aliases ------------------------------------------------
    typedef quasar_txn       txn_t;
    typedef quasar_event_txn etxn_t;

    // ---- driver ---------------------------------------------------------
    class quasar_axis_driver;
        virtual quasar_axis_if.master vif;
        mailbox #(txn_t) seq_mbox;
        int n_sent;

        function new(virtual quasar_axis_if.master vif,
                     mailbox #(txn_t) seq_mbox);
            this.vif = vif;
            this.seq_mbox = seq_mbox;
            n_sent = 0;
        endfunction

        task automatic run();
            txn_t t;
            msg_t m;
            vif.tvalid <= 1'b0;
            vif.tdata  <= '0;
            vif.tkeep  <= '0;
            vif.tlast  <= 1'b0;
            vif.tuser  <= '0;
            vif.tid    <= '0;
            vif.tdest  <= '0;
            forever begin
                seq_mbox.get(t);
                m = t.to_msg();
                @(posedge vif.clk);
                while (!vif.rst_n) @(posedge vif.clk);
                vif.tdata  <= 256'(m);
                vif.tkeep  <= {32{1'b1}};
                vif.tlast  <= 1'b1;
                vif.tvalid <= 1'b1;
                do @(posedge vif.clk); while (!vif.tready);
                vif.tvalid <= 1'b0;
                vif.tlast  <= 1'b0;
                n_sent++;
                // small random inter-message gap
                repeat ($urandom_range(0, 3)) @(posedge vif.clk);
            end
        endtask
    endclass

    // ---- monitor --------------------------------------------------------
    class quasar_axis_monitor;
        virtual quasar_axis_if.monitor vif;
        mailbox #(etxn_t) mon_mbox;
        int n_seen;

        function new(virtual quasar_axis_if.monitor vif,
                     mailbox #(etxn_t) mon_mbox);
            this.vif = vif;
            this.mon_mbox = mon_mbox;
            n_seen = 0;
        endfunction

        task automatic run();
            etxn_t e;
            forever begin
                @(posedge vif.clk);
                if (vif.rst_n && vif.tvalid && vif.tready) begin
                    e = new(event_t'(vif.tdata));
                    mon_mbox.put(e);
                    n_seen++;
                end
            end
        endtask
    endclass

    // ---- AXI-Lite driver ------------------------------------------------
    class quasar_axil_driver;
        virtual quasar_axil_if.master vif;

        function new(virtual quasar_axil_if.master vif);
            this.vif = vif;
        endfunction

        task automatic write(input logic [15:0] a, input logic [31:0] d);
            vif.awaddr  <= a;
            vif.awprot  <= 3'b0;
            vif.awvalid <= 1'b1;
            vif.wdata   <= d;
            vif.wstrb   <= 4'hF;
            vif.wvalid  <= 1'b1;
            vif.bready  <= 1'b1;
            fork
                begin
                    @(posedge vif.clk);
                    while (!vif.awready) @(posedge vif.clk);
                    vif.awvalid <= 1'b0;
                end
                begin
                    @(posedge vif.clk);
                    while (!vif.wready) @(posedge vif.clk);
                    vif.wvalid <= 1'b0;
                end
            join
            @(posedge vif.clk);
            while (!vif.bvalid) @(posedge vif.clk);
            @(posedge vif.clk);
            vif.bready <= 1'b0;
        endtask

        task automatic read(input logic [15:0] a, output logic [31:0] d);
            vif.araddr  <= a;
            vif.arprot  <= 3'b0;
            vif.arvalid <= 1'b1;
            vif.rready  <= 1'b1;
            @(posedge vif.clk);
            while (!vif.arready) @(posedge vif.clk);
            vif.arvalid <= 1'b0;
            @(posedge vif.clk);
            while (!vif.rvalid) @(posedge vif.clk);
            d = vif.rdata;
            @(posedge vif.clk);
            vif.rready <= 1'b0;
        endtask
    endclass

    // ---- scoreboard vs C++ golden book ----------------------------------
    import "DPI-C" context function void dpi_book_reset();
    import "DPI-C" context function void dpi_book_apply(
        byte unsigned opcode, byte unsigned inst, byte unsigned firm,
        byte unsigned side, byte unsigned tif, byte unsigned stp,
        byte unsigned post_only, int unsigned qty, int unsigned price,
        longint unsigned oid, int unsigned aux, output int n_events
    );
    import "DPI-C" context function void dpi_book_event(
        int idx,
        output byte unsigned ev, output byte unsigned inst,
        output byte unsigned firm, output byte unsigned side,
        output byte unsigned reject,
        output int unsigned qty, output int unsigned price,
        output longint unsigned oid, output int unsigned match_lo,
        output int unsigned aux
    );
    import "DPI-C" context function byte unsigned dpi_book_invariants();

    class quasar_scoreboard;
        mailbox #(txn_t)  exp_in;   // commands the driver sent
        mailbox #(etxn_t) seen;     // events the monitor saw
        int mismatches;
        int compared;

        function new(mailbox #(txn_t) exp_in, mailbox #(etxn_t) seen);
            this.exp_in = exp_in;
            this.seen   = seen;
            mismatches  = 0;
            compared    = 0;
        endfunction

        task automatic run();
            txn_t t;
            int n, i;
            byte unsigned ev, inst, firm, side, reject;
            int unsigned qty, price, match_lo, aux;
            longint unsigned oid;
            etxn_t got;
            forever begin
                exp_in.get(t);
                if (t.crc_corrupt) begin
                    // DUT must reject; drain until REJECT
                    seen.get(got);
                    compared++;
                    if (got.e.ev != EV_REJECT) begin
                        $error("scoreboard: corrupt CRC produced %s", got.sprint());
                        mismatches++;
                    end
                    continue;
                end
                dpi_book_apply(t.opcode, t.inst, t.firm, t.side, t.tif, t.stp,
                               t.post_only, t.qty, t.price, t.oid, t.aux, n);
                for (i = 0; i < n; i++) begin
                    dpi_book_event(i, ev, inst, firm, side, reject,
                                   qty, price, oid, match_lo, aux);
                    // skip BBO side-channel from DUT by draining until match
                    do seen.get(got); while (got.e.ev == EV_BBO);
                    compared++;
                    if (got.e.ev != ev) begin
                        $error("scoreboard ev mismatch dut=%s gold=%0h oid=%0h",
                               ev_name(got.e.ev), ev, t.oid);
                        mismatches++;
                    end else if (ev == EV_FILL && got.e.qty != qty) begin
                        $error("scoreboard fill qty dut=%0d gold=%0d", got.e.qty, qty);
                        mismatches++;
                    end else if (ev == EV_FILL && got.e.price != price) begin
                        $error("scoreboard fill px dut=%0d gold=%0d", got.e.price, price);
                        mismatches++;
                    end
                end
                if (dpi_book_invariants() == 0)
                    $error("golden book invariant broken after oid %0h", t.oid);
            end
        endtask
    endclass

    // ---- sequences ------------------------------------------------------
    class quasar_seq_lib;
        mailbox #(txn_t) seq_mbox;
        mailbox #(txn_t) scb_mbox;
        int next_oid;

        function new(mailbox #(txn_t) seq_mbox, mailbox #(txn_t) scb_mbox);
            this.seq_mbox = seq_mbox;
            this.scb_mbox = scb_mbox;
            next_oid = 1;
        endfunction

        task automatic put(txn_t t);
            seq_mbox.put(t);
            scb_mbox.put(t);
        endtask

        task automatic directed_rest_and_hit();
            txn_t a, b;
            a = new();
            a.opcode = OP_NEW; a.inst = 0; a.firm = 1; a.side = SIDE_BID;
            a.tif = TIF_GTC; a.stp = STP_OFF; a.post_only = 0;
            a.qty = 10; a.price = 100; a.oid = next_oid++; a.seq = 1;
            put(a);
            b = new();
            b.opcode = OP_NEW; b.inst = 0; b.firm = 2; b.side = SIDE_ASK;
            b.tif = TIF_GTC; b.stp = STP_OFF; b.post_only = 0;
            b.qty = 4; b.price = 100; b.oid = next_oid++; b.seq = 2;
            put(b);
        endtask

        task automatic directed_cancel();
            txn_t a, c;
            a = new();
            a.opcode = OP_NEW; a.inst = 1; a.firm = 1; a.side = SIDE_ASK;
            a.tif = TIF_GTC; a.qty = 3; a.price = 55; a.oid = next_oid++;
            put(a);
            c = new();
            c.opcode = OP_CANCEL; c.inst = 1; c.firm = 1; c.side = SIDE_ASK;
            c.oid = a.oid; c.qty = 0; c.price = 0;
            put(c);
        endtask

        task automatic random_stream(int n);
            txn_t t;
            for (int i = 0; i < n; i++) begin
                t = new();
                if (!t.randomize() with {
                    inst inside {[0:3]};
                    qty  inside {[1:16]};
                    price inside {[90:110]};
                    opcode == OP_NEW;
                    tif == TIF_GTC;
                }) $fatal(1, "randomize failed");
                t.oid  = next_oid++;
                t.firm = 8'(1 + (i % 4));
                t.seq  = i;
                put(t);
            end
        endtask
    endclass

    // ---- environment ----------------------------------------------------
    class quasar_env;
        quasar_axis_driver  drv;
        quasar_axis_monitor mon;
        quasar_axil_driver  csr;
        quasar_scoreboard   scb;
        quasar_seq_lib      seq;
        mailbox #(txn_t)    seq_mb;
        mailbox #(txn_t)    scb_mb;
        mailbox #(etxn_t)   mon_mb;

        function new(virtual quasar_axis_if.master in_vif,
                     virtual quasar_axis_if.monitor out_vif,
                     virtual quasar_axil_if.master axil_vif);
            seq_mb = new();
            scb_mb = new();
            mon_mb = new();
            drv = new(in_vif, seq_mb);
            mon = new(out_vif, mon_mb);
            csr = new(axil_vif);
            scb = new(scb_mb, mon_mb);
            seq = new(seq_mb, scb_mb);
        endfunction

        task automatic run();
            dpi_book_reset();
            fork
                drv.run();
                mon.run();
                scb.run();
            join_none
        endtask
    endclass

endpackage

`endif
