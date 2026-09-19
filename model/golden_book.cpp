#include "golden_book.hpp"

#include <algorithm>
#include <sstream>

namespace quasar {

GoldenBook::GoldenBook() = default;

uint32_t crc32_ieee(const uint8_t* p, size_t n) {
    uint32_t c = 0xFFFFFFFFu;
    for (size_t i = 0; i < n; ++i) {
        c ^= p[i];
        for (int b = 0; b < 8; ++b)
            c = (c >> 1) ^ ((c & 1u) ? 0xEDB88320u : 0u);
    }
    return c ^ 0xFFFFFFFFu;
}

Bbo GoldenBook::bbo(uint8_t inst) const {
    Bbo b;
    if (inst >= kNumInst) return b;
    if (!bid_[inst].empty()) {
        auto it = bid_[inst].begin();
        b.bid_valid = true;
        b.bid_px = it->first;
        uint32_t q = 0;
        for (const auto& o : it->second) q += o.qty;
        b.bid_qty = q;
    }
    if (!ask_[inst].empty()) {
        auto it = ask_[inst].begin();
        b.ask_valid = true;
        b.ask_px = it->first;
        uint32_t q = 0;
        for (const auto& o : it->second) q += o.qty;
        b.ask_qty = q;
    }
    return b;
}

uint32_t GoldenBook::qty_of(uint64_t oid) const {
    auto it = loc_.find(oid);
    if (it == loc_.end()) return 0;
    const Loc& L = it->second;
    if (L.side == BID) {
        auto lit = bid_[L.inst].find(L.price);
        if (lit == bid_[L.inst].end()) return 0;
        for (const auto& o : lit->second)
            if (o.oid == oid) return o.qty;
    } else {
        auto lit = ask_[L.inst].find(L.price);
        if (lit == ask_[L.inst].end()) return 0;
        for (const auto& o : lit->second)
            if (o.oid == oid) return o.qty;
    }
    return 0;
}

bool GoldenBook::crosses(uint8_t agg_side, uint32_t agg_px, uint8_t inst) const {
    if (agg_side == ASK) {
        if (bid_[inst].empty()) return false;
        return agg_px <= bid_[inst].begin()->first;
    }
    if (ask_[inst].empty()) return false;
    return agg_px >= ask_[inst].begin()->first;
}

uint32_t GoldenBook::walk_liq(uint8_t agg_side, uint32_t agg_px, uint8_t inst) const {
    uint32_t acc = 0;
    if (agg_side == ASK) {
        for (const auto& [px, q] : bid_[inst]) {
            if (agg_px > px) break;
            for (const auto& o : q) acc += o.qty;
        }
    } else {
        for (const auto& [px, q] : ask_[inst]) {
            if (agg_px < px) break;
            for (const auto& o : q) acc += o.qty;
        }
    }
    return acc;
}

Event GoldenBook::mk(uint8_t ev, const Cmd& c, uint32_t qty, uint32_t px, uint8_t rej) const {
    Event e;
    e.ev = ev;
    e.inst = c.inst;
    e.firm = c.firm;
    e.side = c.side;
    e.reject = rej;
    e.qty = qty;
    e.price = px;
    e.oid = c.oid;
    return e;
}

void GoldenBook::insert_resting(const Order& o) {
    if (o.side == BID) {
        auto& lvl = bid_[o.inst][o.price];
        if (lvl.empty()) ++n_levels_;
        lvl.push_back(o);
    } else {
        auto& lvl = ask_[o.inst][o.price];
        if (lvl.empty()) ++n_levels_;
        lvl.push_back(o);
    }
    loc_[o.oid] = Loc{o.inst, o.side, o.price};
    ++n_orders_;
}

void GoldenBook::erase_oid(uint64_t oid) {
    auto it = loc_.find(oid);
    if (it == loc_.end()) return;
    Loc L = it->second;
    if (L.side == BID) {
        auto lit = bid_[L.inst].find(L.price);
        if (lit != bid_[L.inst].end()) {
            auto& q = lit->second;
            q.remove_if([&](const Order& o) { return o.oid == oid; });
            if (q.empty()) {
                bid_[L.inst].erase(lit);
                --n_levels_;
            }
        }
    } else {
        auto lit = ask_[L.inst].find(L.price);
        if (lit != ask_[L.inst].end()) {
            auto& q = lit->second;
            q.remove_if([&](const Order& o) { return o.oid == oid; });
            if (q.empty()) {
                ask_[L.inst].erase(lit);
                --n_levels_;
            }
        }
    }
    loc_.erase(it);
    --n_orders_;
}

void GoldenBook::recount() {
    n_orders_ = static_cast<int>(loc_.size());
}

std::vector<Event> GoldenBook::do_new(Cmd c, bool replace) {
    std::vector<Event> evs;
    if (c.inst >= kNumInst) {
        evs.push_back(mk(EV_REJECT, c, c.qty, c.price, REJ_INSTRUMENT));
        return evs;
    }
    if (c.qty == 0) {
        evs.push_back(mk(EV_REJECT, c, c.qty, c.price, REJ_QTY));
        return evs;
    }
    if (c.price == 0) {
        evs.push_back(mk(EV_REJECT, c, c.qty, c.price, REJ_PRICE));
        return evs;
    }
    if (!replace && loc_.count(c.oid)) {
        evs.push_back(mk(EV_REJECT, c, c.qty, c.price, REJ_DUP_OID));
        return evs;
    }
    if (c.post_only && crosses(c.side, c.price, c.inst)) {
        evs.push_back(mk(EV_REJECT, c, c.qty, c.price, REJ_POST_ONLY));
        return evs;
    }
    if (c.tif == FOK && walk_liq(c.side, c.price, c.inst) < c.qty) {
        evs.push_back(mk(EV_REJECT, c, c.qty, c.price, REJ_FOK));
        return evs;
    }

    uint32_t rem = c.qty;
    while (rem && crosses(c.side, c.price, c.inst)) {
        if (c.side == ASK) {
            auto& lvl = bid_[c.inst].begin()->second;
            Order& hd = lvl.front();
            if (c.stp != STP_OFF && hd.firm == c.firm) {
                if (c.stp == STP_CXL_REST || c.stp == STP_CXL_BOTH) {
                    erase_oid(hd.oid);
                }
                if (c.stp == STP_CXL_TAKE || c.stp == STP_CXL_BOTH) {
                    evs.push_back(mk(EV_REJECT, c, rem, c.price, REJ_STP));
                    return evs;
                }
                continue;
            }
            uint32_t f = std::min(rem, hd.qty);
            Event e = mk(EV_FILL, c, f, hd.price);
            e.match_lo = static_cast<uint32_t>(hd.oid);
            evs.push_back(e);
            hd.qty -= f;
            rem -= f;
            if (hd.qty == 0) erase_oid(hd.oid);
        } else {
            auto& lvl = ask_[c.inst].begin()->second;
            Order& hd = lvl.front();
            if (c.stp != STP_OFF && hd.firm == c.firm) {
                if (c.stp == STP_CXL_REST || c.stp == STP_CXL_BOTH) {
                    erase_oid(hd.oid);
                }
                if (c.stp == STP_CXL_TAKE || c.stp == STP_CXL_BOTH) {
                    evs.push_back(mk(EV_REJECT, c, rem, c.price, REJ_STP));
                    return evs;
                }
                continue;
            }
            uint32_t f = std::min(rem, hd.qty);
            Event e = mk(EV_FILL, c, f, hd.price);
            e.match_lo = static_cast<uint32_t>(hd.oid);
            evs.push_back(e);
            hd.qty -= f;
            rem -= f;
            if (hd.qty == 0) erase_oid(hd.oid);
        }
        if (n_orders_ >= kMaxOrders) break;
    }

    if (rem && (c.tif == GTC || c.tif == DAY)) {
        if (n_orders_ >= kMaxOrders) {
            evs.push_back(mk(EV_REJECT, c, rem, c.price, REJ_BOOK_FULL));
            return evs;
        }
        Order o;
        o.oid = c.oid;
        o.qty = rem;
        o.price = c.price;
        o.inst = c.inst;
        o.side = c.side;
        o.firm = c.firm;
        insert_resting(o);
    }
    evs.push_back(mk(replace ? EV_REPLACE_ACK : EV_ACK, c, rem, c.price));
    return evs;
}

std::vector<Event> GoldenBook::do_cancel(const Cmd& c) {
    std::vector<Event> evs;
    if (!loc_.count(c.oid)) {
        evs.push_back(mk(EV_REJECT, c, 0, 0, REJ_NOT_FOUND));
        return evs;
    }
    uint32_t q = qty_of(c.oid);
    uint32_t px = loc_[c.oid].price;
    erase_oid(c.oid);
    Event e = mk(EV_CANCEL_ACK, c, q, px);
    evs.push_back(e);
    return evs;
}

std::vector<Event> GoldenBook::do_modify(const Cmd& c) {
    std::vector<Event> evs;
    if (!loc_.count(c.oid)) {
        evs.push_back(mk(EV_REJECT, c, c.qty, c.price, REJ_NOT_FOUND));
        return evs;
    }
    if (c.qty == 0) return do_cancel(c);
    Loc L = loc_[c.oid];
    if (L.side == BID) {
        for (auto& o : bid_[L.inst][L.price])
            if (o.oid == c.oid) o.qty = c.qty;
    } else {
        for (auto& o : ask_[L.inst][L.price])
            if (o.oid == c.oid) o.qty = c.qty;
    }
    evs.push_back(mk(EV_MODIFY_ACK, c, c.qty, L.price));
    return evs;
}

std::vector<Event> GoldenBook::apply(const Cmd& c) {
    switch (c.opcode) {
    case NEW:     return do_new(c, false);
    case CANCEL:  return do_cancel(c);
    case MODIFY:  return do_modify(c);
    case REPLACE: {
        if (!loc_.count(c.oid)) {
            return {mk(EV_REJECT, c, c.qty, c.price, REJ_NOT_FOUND)};
        }
        Loc L = loc_[c.oid];
        if (L.price == c.price) return do_modify(c);
        erase_oid(c.oid);
        return do_new(c, true);
    }
    case STATUS: {
        Bbo b = this->bbo(c.inst);
        Event e = mk(EV_STATUS, c, b.bid_qty, b.bid_px);
        e.match_lo = b.ask_px;
        e.aux = b.ask_qty;
        return {e};
    }
    case MASS_CXL: {
        if (c.side == BID) {
            while (!bid_[c.inst].empty()) {
                auto oid = bid_[c.inst].begin()->second.front().oid;
                erase_oid(oid);
            }
        } else {
            while (!ask_[c.inst].empty()) {
                auto oid = ask_[c.inst].begin()->second.front().oid;
                erase_oid(oid);
            }
        }
        return {mk(EV_CANCEL_ACK, c, 0, 0)};
    }
    default:
        return {mk(EV_REJECT, c, c.qty, c.price, REJ_OPCODE)};
    }
}

bool GoldenBook::check_invariants(std::string* why) const {
    auto fail = [&](const std::string& s) {
        if (why) *why = s;
        return false;
    };
    int ord = 0, lvl = 0;
    std::unordered_map<uint64_t, int> seen;
    auto scan = [&](auto& sides, uint8_t side_tag) {
        for (int i = 0; i < kNumInst; ++i) {
            for (const auto& [px, q] : sides[i]) {
                if (q.empty()) return fail("empty level retained");
                ++lvl;
                uint32_t agg = 0;
                for (const auto& o : q) {
                    if (o.qty == 0) return fail("zero-qty resting");
                    if (o.price != px) return fail("order/level price mismatch");
                    if (o.inst != static_cast<uint8_t>(i) || o.side != side_tag)
                        return fail("order inst/side mismatch");
                    if (seen[o.oid]++) return fail("duplicate oid in book");
                    auto it = loc_.find(o.oid);
                    if (it == loc_.end()) return fail("oid missing from index");
                    if (it->second.price != px || it->second.inst != i)
                        return fail("index stale");
                    agg += o.qty;
                    ++ord;
                }
                (void)agg;
            }
        }
        return true;
    };
    if (!scan(bid_, BID)) return false;
    if (!scan(ask_, ASK)) return false;
    if (ord != static_cast<int>(loc_.size())) return fail("index size != walk");
    return true;
}

} // namespace quasar
