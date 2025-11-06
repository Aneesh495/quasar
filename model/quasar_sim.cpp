// =============================================================================
// Quasar standalone C++ simulator / test driver.
// Runs the GoldenBook through a deterministic sequence and reports results.
// Also used as a sanity check for the CRC-32 implementation.
//
// Build (outside Verilator):
//   g++ -std=c++17 -O2 -I. golden_book.cpp quasar_sim.cpp -o quasar_sim
// Run:
//   ./quasar_sim
// =============================================================================

#include "golden_book.hpp"
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

using namespace quasar;

// ---------------------------------------------------------------------------
static int g_pass = 0, g_fail = 0;

static void expect_eq(const char* tag, uint64_t got, uint64_t want) {
    if (got == want) {
        ++g_pass;
    } else {
        std::fprintf(stderr, "FAIL %-40s: got %llu want %llu\n",
                     tag, (unsigned long long)got, (unsigned long long)want);
        ++g_fail;
    }
}

static Cmd mk(uint8_t op, uint8_t inst, uint8_t firm, uint8_t side,
              uint8_t tif, uint32_t qty, uint32_t price, uint64_t oid,
              bool post_only = false, uint8_t stp = STP_OFF)
{
    Cmd c;
    c.opcode    = op;
    c.inst      = inst;
    c.firm      = firm;
    c.side      = side;
    c.tif       = tif;
    c.stp       = stp;
    c.post_only = post_only;
    c.qty       = qty;
    c.price     = price;
    c.oid       = oid;
    c.aux       = 0;
    return c;
}

// ---------------------------------------------------------------------------
static void test_crc32() {
    const uint8_t zeros[28] = {};
    uint32_t c = crc32_ieee(zeros, 28);
    // IEEE CRC32 over 28 zero bytes should not be zero.
    expect_eq("crc32_zeros_nonzero", c != 0 ? 1 : 0, 1);

    // CRC32 of "abc"
    const uint8_t abc[] = {0x61, 0x62, 0x63};
    c = crc32_ieee(abc, 3);
    expect_eq("crc32_abc", c, 0x352441C2u);
}

// ---------------------------------------------------------------------------
static void test_new_rest_bbo() {
    GoldenBook b;
    auto evs = b.apply(mk(NEW, 0, 1, BID, GTC, 10, 100, 1));
    expect_eq("rest_nevents", evs.size(), 1);
    expect_eq("rest_ev",      evs[0].ev,  EV_ACK);
    expect_eq("rest_qty",     evs[0].qty, 10);

    auto bb = b.bbo(0);
    expect_eq("bbo_bid_valid", bb.bid_valid, 1);
    expect_eq("bbo_bid_px",    bb.bid_px,    100);
    expect_eq("bbo_bid_qty",   bb.bid_qty,   10);
    expect_eq("bbo_ask_valid", bb.ask_valid, 0);

    expect_eq("orders_used", b.orders_used(), 1);
    std::string why;
    expect_eq("invariants", b.check_invariants(&why) ? 1 : 0, 1);
}

// ---------------------------------------------------------------------------
static void test_full_fill() {
    GoldenBook b;
    b.apply(mk(NEW, 0, 1, BID, GTC, 10, 100, 1));
    auto evs = b.apply(mk(NEW, 0, 2, ASK, GTC, 10, 100, 2));
    expect_eq("full_fill_ev_count", evs.size(), 2);
    expect_eq("full_fill_ev0",     evs[0].ev,  EV_FILL);
    expect_eq("full_fill_qty",     evs[0].qty, 10);
    expect_eq("full_fill_px",      evs[0].price, 100);
    expect_eq("full_fill_ack",     evs[1].ev,  EV_ACK);
    expect_eq("full_fill_rem",     evs[1].qty, 0);
    expect_eq("orders_post_fill",  b.orders_used(), 0);
}

// ---------------------------------------------------------------------------
static void test_partial_fill() {
    GoldenBook b;
    b.apply(mk(NEW, 0, 1, BID, GTC, 10, 100, 1));
    auto evs = b.apply(mk(NEW, 0, 2, ASK, GTC, 3, 100, 2));
    expect_eq("part_fill_ev0",   evs[0].ev,  EV_FILL);
    expect_eq("part_fill_qty",   evs[0].qty, 3);
    expect_eq("part_rest_qty",   b.qty_of(1), 7);

    auto bb = b.bbo(0);
    expect_eq("part_bbo_qty",    bb.bid_qty, 7);
}

// ---------------------------------------------------------------------------
static void test_ioc_discard() {
    GoldenBook b;
    b.apply(mk(NEW, 0, 1, ASK, GTC, 3, 50, 10));
    auto evs = b.apply(mk(NEW, 0, 2, BID, IOC, 10, 50, 20));
    expect_eq("ioc_fill",    evs[0].ev,  EV_FILL);
    expect_eq("ioc_fill_q",  evs[0].qty, 3);
    expect_eq("ioc_ack",     evs[1].ev,  EV_ACK);
    expect_eq("ioc_rem",     evs[1].qty, 7);  // residual returned but not rested
    expect_eq("ioc_no_rest", b.exists(20),   false);
}

// ---------------------------------------------------------------------------
static void test_fok_success() {
    GoldenBook b;
    b.apply(mk(NEW, 0, 1, ASK, GTC, 5, 20, 100));
    b.apply(mk(NEW, 0, 1, ASK, GTC, 5, 20, 101));
    auto evs = b.apply(mk(NEW, 0, 2, BID, FOK, 10, 20, 200));
    // 2 fills + ack
    expect_eq("fok_ev_count", evs.size(), 3);
    expect_eq("fok_fill0",    evs[0].ev, EV_FILL);
    expect_eq("fok_fill1",    evs[1].ev, EV_FILL);
    expect_eq("fok_ack",      evs[2].ev, EV_ACK);
}

// ---------------------------------------------------------------------------
static void test_fok_fail() {
    GoldenBook b;
    b.apply(mk(NEW, 0, 1, ASK, GTC, 3, 20, 100));
    auto evs = b.apply(mk(NEW, 0, 2, BID, FOK, 10, 20, 200));
    expect_eq("fok_fail_rej",     evs[0].ev,     EV_REJECT);
    expect_eq("fok_fail_code",    evs[0].reject, REJ_FOK);
    expect_eq("fok_rest_lives",   b.exists(100), true);
}

// ---------------------------------------------------------------------------
static void test_cancel() {
    GoldenBook b;
    b.apply(mk(NEW, 0, 1, BID, GTC, 5, 80, 1));
    auto evs = b.apply(mk(CANCEL, 0, 1, BID, GTC, 0, 0, 1));
    expect_eq("cxl_ev",    evs[0].ev,  EV_CANCEL_ACK);
    expect_eq("cxl_qty",   evs[0].qty, 5);
    expect_eq("cxl_gone",  b.exists(1), false);
    expect_eq("bbo_empty", b.bbo(0).bid_valid, 0);
}

// ---------------------------------------------------------------------------
static void test_modify() {
    GoldenBook b;
    b.apply(mk(NEW, 0, 1, BID, GTC, 12, 40, 1));
    auto evs = b.apply(mk(MODIFY, 0, 1, BID, GTC, 5, 40, 1));
    expect_eq("mod_ev",    evs[0].ev,  EV_MODIFY_ACK);
    expect_eq("mod_qty",   evs[0].qty, 5);
    expect_eq("mod_live",  b.qty_of(1), 5);
}

// ---------------------------------------------------------------------------
static void test_modify_to_zero() {
    GoldenBook b;
    b.apply(mk(NEW, 0, 1, ASK, GTC, 7, 60, 1));
    b.apply(mk(MODIFY, 0, 1, ASK, GTC, 0, 60, 1));
    expect_eq("mod0_gone", b.exists(1), false);
}

// ---------------------------------------------------------------------------
static void test_replace_price_change() {
    GoldenBook b;
    b.apply(mk(NEW, 0, 1, BID, GTC, 3, 10, 1));
    auto evs = b.apply(mk(REPLACE, 0, 1, BID, GTC, 3, 14, 1));
    expect_eq("rep_ev",  evs.back().ev, EV_REPLACE_ACK);
    expect_eq("rep_px",  b.bbo(0).bid_px, 14);
}

// ---------------------------------------------------------------------------
static void test_stp_cancel_taker() {
    GoldenBook b;
    b.apply(mk(NEW, 0, 1, BID, GTC, 5, 20, 1));
    Cmd agg = mk(NEW, 0, 1, ASK, GTC, 5, 20, 2);
    agg.stp = STP_CXL_TAKE;
    auto evs = b.apply(agg);
    expect_eq("stp_rej",   evs[0].ev,     EV_REJECT);
    expect_eq("stp_code",  evs[0].reject, REJ_STP);
    expect_eq("stp_lives", b.exists(1),   true);
}

// ---------------------------------------------------------------------------
static void test_stp_cancel_resting() {
    GoldenBook b;
    b.apply(mk(NEW, 0, 1, BID, GTC, 5, 20, 1));
    Cmd agg = mk(NEW, 0, 1, ASK, GTC, 5, 20, 2);
    agg.stp = STP_CXL_REST;
    auto evs = b.apply(agg);
    // Resting is cancelled, taker continues — no more crossing so it rests or IOC
    expect_eq("stp_rest_gone", b.exists(1), false);
}

// ---------------------------------------------------------------------------
static void test_price_time_priority() {
    GoldenBook b;
    // Two bids at 10, different times (oid order = time order in golden book)
    b.apply(mk(NEW, 0, 1, BID, GTC, 2, 10, 1));
    b.apply(mk(NEW, 0, 2, BID, GTC, 2, 10, 2));
    // Single ask
    auto evs = b.apply(mk(NEW, 0, 3, ASK, GTC, 2, 10, 3));
    expect_eq("prio_fill_oid", evs[0].match_lo, 1u); // oid 1 first
}

// ---------------------------------------------------------------------------
static void test_multi_instrument_isolation() {
    GoldenBook b;
    b.apply(mk(NEW, 0, 1, BID, GTC, 1, 50, 10));
    b.apply(mk(NEW, 1, 1, ASK, GTC, 1, 60, 20));
    expect_eq("iso_bbo0_ask_empty",  b.bbo(0).ask_valid, 0);
    expect_eq("iso_bbo1_bid_empty",  b.bbo(1).bid_valid, 0);
    std::string why;
    expect_eq("iso_invariants", b.check_invariants(&why) ? 1 : 0, 1);
}

// ---------------------------------------------------------------------------
static void test_dup_oid() {
    GoldenBook b;
    b.apply(mk(NEW, 0, 1, BID, GTC, 1, 10, 777));
    auto evs = b.apply(mk(NEW, 0, 1, BID, GTC, 1, 11, 777));
    expect_eq("dup_rej",  evs[0].ev,     EV_REJECT);
    expect_eq("dup_code", evs[0].reject, REJ_DUP_OID);
}

// ---------------------------------------------------------------------------
static void test_post_only() {
    GoldenBook b;
    b.apply(mk(NEW, 0, 1, ASK, GTC, 5, 20, 1));
    Cmd po = mk(NEW, 0, 2, BID, GTC, 5, 20, 2);
    po.post_only = true;
    auto evs = b.apply(po);
    expect_eq("po_rej",  evs[0].ev,     EV_REJECT);
    expect_eq("po_code", evs[0].reject, REJ_POST_ONLY);
}

// ---------------------------------------------------------------------------
static void test_mass_cancel() {
    GoldenBook b;
    for (int i = 0; i < 8; i++)
        b.apply(mk(NEW, 0, 1, BID, GTC, 1, uint32_t(10 + i), uint64_t(i + 1)));
    expect_eq("mass_pre", b.orders_used(), 8);

    Cmd mc;
    mc.opcode = MASS_CXL;
    mc.inst   = 0;
    mc.side   = BID;
    b.apply(mc);
    expect_eq("mass_post", b.orders_used(), 0);
    expect_eq("mass_bbo",  b.bbo(0).bid_valid, 0);
}

// ---------------------------------------------------------------------------
int main() {
    std::printf("Quasar golden-book simulator\n");
    std::printf("=============================\n");

    test_crc32();
    test_new_rest_bbo();
    test_full_fill();
    test_partial_fill();
    test_ioc_discard();
    test_fok_success();
    test_fok_fail();
    test_cancel();
    test_modify();
    test_modify_to_zero();
    test_replace_price_change();
    test_stp_cancel_taker();
    test_stp_cancel_resting();
    test_price_time_priority();
    test_multi_instrument_isolation();
    test_dup_oid();
    test_post_only();
    test_mass_cancel();

    std::printf("\n%d passed, %d failed\n", g_pass, g_fail);
    if (g_fail > 0) {
        std::fprintf(stderr, "RESULT: FAIL\n");
        return 1;
    }
    std::printf("RESULT: PASS\n");
    return 0;
}
