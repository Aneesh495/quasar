// Verilator / VPI DPI-C shims around GoldenBook.  One global instance is
// enough for the smoke scoreboard; multi-book TBs construct native C++.

#include "golden_book.hpp"
#include "svdpi.h"

#include <memory>
#include <string>
#include <vector>

static quasar::GoldenBook g_book;
static std::vector<quasar::Event> g_last;
static std::string g_why;

extern "C" void dpi_book_reset() {
    g_book = quasar::GoldenBook();
    g_last.clear();
}

extern "C" void dpi_book_apply(
    unsigned char opcode, unsigned char inst, unsigned char firm,
    unsigned char side, unsigned char tif, unsigned char stp,
    unsigned char post_only, unsigned int qty, unsigned int price,
    unsigned long long oid, unsigned int aux, int* n_events
) {
    quasar::Cmd c;
    c.opcode = opcode;
    c.inst = inst;
    c.firm = firm;
    c.side = side;
    c.tif = tif;
    c.stp = stp;
    c.post_only = post_only != 0;
    c.qty = qty;
    c.price = price;
    c.oid = oid;
    c.aux = aux;
    g_last = g_book.apply(c);
    *n_events = static_cast<int>(g_last.size());
}

extern "C" void dpi_book_event(
    int idx,
    unsigned char* ev, unsigned char* inst, unsigned char* firm,
    unsigned char* side, unsigned char* reject,
    unsigned int* qty, unsigned int* price,
    unsigned long long* oid, unsigned int* match_lo, unsigned int* aux
) {
    if (idx < 0 || idx >= static_cast<int>(g_last.size())) return;
    const auto& e = g_last[static_cast<size_t>(idx)];
    *ev = e.ev;
    *inst = e.inst;
    *firm = e.firm;
    *side = e.side;
    *reject = e.reject;
    *qty = e.qty;
    *price = e.price;
    *oid = e.oid;
    *match_lo = e.match_lo;
    *aux = e.aux;
}

extern "C" void dpi_book_bbo(
    unsigned char inst,
    unsigned char* bid_v, unsigned char* ask_v,
    unsigned int* bid_px, unsigned int* ask_px,
    unsigned int* bid_qty, unsigned int* ask_qty
) {
    auto b = g_book.bbo(inst);
    *bid_v = b.bid_valid;
    *ask_v = b.ask_valid;
    *bid_px = b.bid_px;
    *ask_px = b.ask_px;
    *bid_qty = b.bid_qty;
    *ask_qty = b.ask_qty;
}

extern "C" unsigned char dpi_book_invariants() {
    g_why.clear();
    return g_book.check_invariants(&g_why) ? 1 : 0;
}

extern "C" unsigned int dpi_crc32(const svOpenArrayHandle h) {
    const uint8_t* p = static_cast<const uint8_t*>(svGetArrayPtr(h));
    int n = svSize(h, 1);
    if (!p || n <= 0) return 0;
    return quasar::crc32_ieee(p, static_cast<size_t>(n));
}
