// =============================================================================
// SystemVerilog golden book — same price-time / TIF / STP rules as the C++
// model.  Used when DPI is unavailable (pure-SV scoreboard) and as a
// readable spec of the matching semantics.
// =============================================================================

`ifndef GOLDEN_BOOK_SVH
`define GOLDEN_BOOK_SVH

class golden_order;
    logic [63:0] oid;
    logic [31:0] qty;
    logic [31:0] price;
    logic [7:0]  inst;
    logic        side;
    logic [7:0]  firm;
    function new();
        oid = 0; qty = 0; price = 0; inst = 0; side = 0; firm = 0;
    endfunction
    function golden_order clone();
        clone = new();
        clone.oid = oid; clone.qty = qty; clone.price = price;
        clone.inst = inst; clone.side = side; clone.firm = firm;
    endfunction
endclass

class golden_event;
    logic [7:0]  ev;
    logic [7:0]  inst;
    logic [7:0]  firm;
    logic        side;
    logic [3:0]  reject;
    logic [31:0] qty;
    logic [31:0] price;
    logic [63:0] oid;
    logic [31:0] match_lo;
    function new();
        ev = 0; inst = 0; firm = 0; side = 0; reject = 0;
        qty = 0; price = 0; oid = 0; match_lo = 0;
    endfunction
endclass

class golden_book;
    import quasar_pkg::*;

    // Per-instrument, per-side queues of orders.  Index 0 is best (time
    // then we sort by scanning for best price — N is small).
    golden_order bid_q[8][$];
    golden_order ask_q[8][$];

    function void reset();
        int i;
        for (i = 0; i < 8; i++) begin
            bid_q[i].delete();
            ask_q[i].delete();
        end
    endfunction

    function int find_oid(input logic [63:0] oid, output int inst, output bit side, output int idx);
        int i, k;
        find_oid = 0;
        inst = 0; side = 0; idx = 0;
        for (i = 0; i < 8; i++) begin
            for (k = 0; k < bid_q[i].size(); k++)
                if (bid_q[i][k].oid == oid) begin
                    inst = i; side = 0; idx = k; return 1;
                end
            for (k = 0; k < ask_q[i].size(); k++)
                if (ask_q[i][k].oid == oid) begin
                    inst = i; side = 1; idx = k; return 1;
                end
        end
    endfunction

    function int best_idx(input int inst, input bit is_ask);
        int k, best, n;
        logic [31:0] bp;
        best_idx = -1;
        if (is_ask) begin
            n = ask_q[inst].size();
            if (n == 0) return -1;
            bp = ask_q[inst][0].price;
            best = 0;
            for (k = 1; k < n; k++)
                if (ask_q[inst][k].price < bp) begin
                    bp = ask_q[inst][k].price;
                    best = k;
                end
            // time priority: first inserted among min price — scan from 0
            for (k = 0; k < n; k++)
                if (ask_q[inst][k].price == bp) return k;
            return best;
        end else begin
            n = bid_q[inst].size();
            if (n == 0) return -1;
            bp = bid_q[inst][0].price;
            for (k = 0; k < n; k++)
                if (bid_q[inst][k].price > bp) bp = bid_q[inst][k].price;
            for (k = 0; k < n; k++)
                if (bid_q[inst][k].price == bp) return k;
            return 0;
        end
    endfunction

    function bit crosses(input int inst, input bit agg_ask, input logic [31:0] px);
        int b;
        if (agg_ask) begin
            b = best_idx(inst, 0);
            if (b < 0) return 0;
            return px <= bid_q[inst][b].price;
        end else begin
            b = best_idx(inst, 1);
            if (b < 0) return 0;
            return px >= ask_q[inst][b].price;
        end
    endfunction

    function logic [31:0] walk_liq(input int inst, input bit agg_ask, input logic [31:0] px);
        int k;
        logic [31:0] acc;
        acc = 0;
        if (agg_ask) begin
            for (k = 0; k < bid_q[inst].size(); k++)
                if (px <= bid_q[inst][k].price) acc += bid_q[inst][k].qty;
        end else begin
            for (k = 0; k < ask_q[inst].size(); k++)
                if (px >= ask_q[inst][k].price) acc += ask_q[inst][k].qty;
        end
        return acc;
    endfunction

    function golden_event mk(input logic [7:0] ev, input cmd_t c,
                             input logic [31:0] qty, input logic [31:0] px,
                             input logic [3:0] rej = 4'h0);
        mk = new();
        mk.ev = ev; mk.inst = c.inst; mk.firm = c.firm; mk.side = c.side;
        mk.qty = qty; mk.price = px; mk.oid = c.oid; mk.reject = rej;
    endfunction

    function void insert(input cmd_t c, input logic [31:0] qty);
        golden_order o;
        o = new();
        o.oid = c.oid; o.qty = qty; o.price = c.price;
        o.inst = c.inst; o.side = c.side; o.firm = c.firm;
        if (c.side == SIDE_BID) bid_q[c.inst].push_back(o);
        else                    ask_q[c.inst].push_back(o);
    endfunction

    function void erase_at(input int inst, input bit is_ask, input int idx);
        if (is_ask) ask_q[inst].delete(idx);
        else        bid_q[inst].delete(idx);
    endfunction

    function int apply(input cmd_t c, ref golden_event evs[$]);
        int inst, idx, b;
        bit side;
        logic [31:0] rem, f;
        golden_event e;
        golden_order hd;
        evs.delete();
        apply = 0;
        if (c.opcode == OP_CANCEL) begin
            if (!find_oid(c.oid, inst, side, idx)) begin
                evs.push_back(mk(EV_REJECT, c, 0, 0, REJ_NOT_FOUND));
                return 1;
            end
            if (side) begin
                e = mk(EV_CANCEL_ACK, c, ask_q[inst][idx].qty, ask_q[inst][idx].price);
                ask_q[inst].delete(idx);
            end else begin
                e = mk(EV_CANCEL_ACK, c, bid_q[inst][idx].qty, bid_q[inst][idx].price);
                bid_q[inst].delete(idx);
            end
            evs.push_back(e);
            return 1;
        end
        if (c.opcode == OP_MODIFY) begin
            if (!find_oid(c.oid, inst, side, idx)) begin
                evs.push_back(mk(EV_REJECT, c, c.qty, c.price, REJ_NOT_FOUND));
                return 1;
            end
            if (c.qty == 0) begin
                if (side) ask_q[inst].delete(idx);
                else      bid_q[inst].delete(idx);
                evs.push_back(mk(EV_CANCEL_ACK, c, 0, c.price));
                return 1;
            end
            if (side) ask_q[inst][idx].qty = c.qty;
            else      bid_q[inst][idx].qty = c.qty;
            evs.push_back(mk(EV_MODIFY_ACK, c, c.qty,
                             side ? ask_q[inst][idx].price : bid_q[inst][idx].price));
            return 1;
        end
        if (c.opcode == OP_REPLACE) begin
            if (!find_oid(c.oid, inst, side, idx)) begin
                evs.push_back(mk(EV_REJECT, c, c.qty, c.price, REJ_NOT_FOUND));
                return 1;
            end
            if (side) ask_q[inst].delete(idx);
            else      bid_q[inst].delete(idx);
            // fall through as NEW with replace ack
        end
        if (c.opcode == OP_NEW || c.opcode == OP_REPLACE) begin
            if (c.inst >= 8) begin
                evs.push_back(mk(EV_REJECT, c, c.qty, c.price, REJ_INSTRUMENT));
                return 1;
            end
            if (c.qty == 0) begin
                evs.push_back(mk(EV_REJECT, c, c.qty, c.price, REJ_QTY));
                return 1;
            end
            if (c.price == 0) begin
                evs.push_back(mk(EV_REJECT, c, c.qty, c.price, REJ_PRICE));
                return 1;
            end
            if (c.opcode == OP_NEW && find_oid(c.oid, inst, side, idx)) begin
                evs.push_back(mk(EV_REJECT, c, c.qty, c.price, REJ_DUP_OID));
                return 1;
            end
            if (c.post_only && crosses(c.inst, c.side, c.price)) begin
                evs.push_back(mk(EV_REJECT, c, c.qty, c.price, REJ_POST_ONLY));
                return 1;
            end
            if (c.tif == TIF_FOK && walk_liq(c.inst, c.side, c.price) < c.qty) begin
                evs.push_back(mk(EV_REJECT, c, c.qty, c.price, REJ_FOK));
                return 1;
            end
            rem = c.qty;
            while (rem != 0 && crosses(c.inst, c.side, c.price)) begin
                b = best_idx(c.inst, ~c.side);
                hd = (c.side == SIDE_ASK) ? bid_q[c.inst][b] : ask_q[c.inst][b];
                if (c.stp != STP_OFF && hd.firm == c.firm) begin
                    if (c.stp == STP_CANCEL_RESTING || c.stp == STP_CANCEL_BOTH)
                        erase_at(c.inst, ~c.side, b);
                    if (c.stp == STP_CANCEL_TAKER || c.stp == STP_CANCEL_BOTH) begin
                        evs.push_back(mk(EV_REJECT, c, rem, c.price, REJ_STP));
                        return evs.size();
                    end
                    continue;
                end
                f = (rem < hd.qty) ? rem : hd.qty;
                e = mk(EV_FILL, c, f, hd.price);
                e.match_lo = hd.oid[31:0];
                evs.push_back(e);
                if (c.side == SIDE_ASK) begin
                    bid_q[c.inst][b].qty -= f;
                    if (bid_q[c.inst][b].qty == 0) bid_q[c.inst].delete(b);
                end else begin
                    ask_q[c.inst][b].qty -= f;
                    if (ask_q[c.inst][b].qty == 0) ask_q[c.inst].delete(b);
                end
                rem -= f;
            end
            if (rem != 0 && (c.tif == TIF_GTC || c.tif == TIF_DAY))
                insert(c, rem);
            evs.push_back(mk((c.opcode == OP_REPLACE) ? EV_REPLACE_ACK : EV_ACK,
                             c, rem, c.price));
            return evs.size();
        end
        if (c.opcode == OP_STATUS) begin
            evs.push_back(mk(EV_STATUS, c, 0, 0));
            return 1;
        end
        evs.push_back(mk(EV_REJECT, c, c.qty, c.price, REJ_OPCODE));
        return 1;
    endfunction

    function bit invariants();
        int i, k;
        for (i = 0; i < 8; i++) begin
            for (k = 0; k < bid_q[i].size(); k++)
                if (bid_q[i][k].qty == 0 || bid_q[i][k].inst != i[7:0])
                    return 0;
            for (k = 0; k < ask_q[i].size(); k++)
                if (ask_q[i][k].qty == 0 || ask_q[i][k].inst != i[7:0])
                    return 0;
        end
        return 1;
    endfunction
endclass

`endif
