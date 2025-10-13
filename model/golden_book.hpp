// Golden software limit-order-book.  Semantics match rtl/book + rtl/match:
// price-time priority, GTC/IOC/FOK/post-only, cancel/modify/replace, STP.
#pragma once

#include <cstdint>
#include <list>
#include <map>
#include <string>
#include <unordered_map>
#include <vector>

namespace quasar {

enum Side : uint8_t { BID = 0, ASK = 1 };
enum Tif  : uint8_t { GTC = 0, IOC = 1, FOK = 2, DAY = 3 };
enum Stp  : uint8_t { STP_OFF = 0, STP_CXL_REST = 1, STP_CXL_TAKE = 2, STP_CXL_BOTH = 3 };
enum Op   : uint8_t { NOP = 0, NEW = 1, CANCEL = 2, REPLACE = 3, MODIFY = 4, STATUS = 5, MASS_CXL = 6 };
enum Ev   : uint8_t {
    EV_NOP = 0x00, EV_ACK = 0x10, EV_REJECT = 0x11, EV_FILL = 0x12,
    EV_CANCEL_ACK = 0x13, EV_MODIFY_ACK = 0x14, EV_REPLACE_ACK = 0x15,
    EV_BBO = 0x16, EV_STATUS = 0x19
};
enum Rej : uint8_t {
    REJ_NONE = 0, REJ_CRC = 1, REJ_OPCODE = 2, REJ_INSTRUMENT = 3,
    REJ_QTY = 4, REJ_PRICE = 5, REJ_NOTIONAL = 6, REJ_POS = 7, REJ_RATE = 8,
    REJ_STP = 9, REJ_NOT_FOUND = 0xA, REJ_BOOK_FULL = 0xB, REJ_DUP_OID = 0xC,
    REJ_DISABLED = 0xD, REJ_FOK = 0xE, REJ_POST_ONLY = 0xF
};

constexpr int kNumInst   = 8;
constexpr int kMaxOrders = 256;
constexpr int kMaxLevels = 256;

struct Order {
    uint64_t oid = 0;
    uint32_t qty = 0;
    uint32_t price = 0;
    uint8_t  inst = 0;
    uint8_t  side = BID;
    uint8_t  firm = 0;
};

struct Event {
    uint8_t  ev = EV_NOP;
    uint8_t  inst = 0;
    uint8_t  firm = 0;
    uint8_t  side = 0;
    uint8_t  reject = REJ_NONE;
    uint32_t qty = 0;
    uint32_t price = 0;
    uint64_t oid = 0;
    uint32_t match_lo = 0;
    uint32_t aux = 0;
};

struct Bbo {
    bool     bid_valid = false, ask_valid = false;
    uint32_t bid_px = 0, ask_px = 0, bid_qty = 0, ask_qty = 0;
};

struct Cmd {
    uint8_t  opcode = NEW;
    uint8_t  inst = 0;
    uint8_t  firm = 0;
    uint8_t  side = BID;
    uint8_t  tif = GTC;
    uint8_t  stp = STP_OFF;
    bool     post_only = false;
    uint32_t qty = 0;
    uint32_t price = 0;
    uint64_t oid = 0;
    uint32_t aux = 0;
};

class GoldenBook {
public:
    GoldenBook();

    std::vector<Event> apply(const Cmd& c);

    Bbo bbo(uint8_t inst) const;
    int orders_used() const { return n_orders_; }
    int levels_used() const { return n_levels_; }
    bool exists(uint64_t oid) const { return loc_.count(oid) != 0; }
    uint32_t qty_of(uint64_t oid) const;

    // Invariants used by the scoreboard / TB.
    bool check_invariants(std::string* why = nullptr) const;

private:
    using LevelMap = std::map<uint32_t, std::list<Order>, std::greater<uint32_t>>; // bid
    using LevelMapAsk = std::map<uint32_t, std::list<Order>, std::less<uint32_t>>;

    LevelMap     bid_[kNumInst];
    LevelMapAsk  ask_[kNumInst];
    struct Loc { uint8_t inst, side; uint32_t price; };
    std::unordered_map<uint64_t, Loc> loc_;
    int n_orders_ = 0;
    int n_levels_ = 0;

    bool crosses(uint8_t agg_side, uint32_t agg_px, uint8_t inst) const;
    uint32_t walk_liq(uint8_t agg_side, uint32_t agg_px, uint8_t inst) const;
    Event mk(uint8_t ev, const Cmd& c, uint32_t qty, uint32_t px, uint8_t rej = REJ_NONE) const;

    std::vector<Event> do_new(Cmd c, bool replace);
    std::vector<Event> do_cancel(const Cmd& c);
    std::vector<Event> do_modify(const Cmd& c);
    void insert_resting(const Order& o);
    void erase_oid(uint64_t oid);
    void recount();
};

uint32_t crc32_ieee(const uint8_t* p, size_t n);

} // namespace quasar
