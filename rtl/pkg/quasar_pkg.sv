// =============================================================================
// Quasar — synthesizable limit-order-book matching engine
// Package: shared types, opcodes, widths, helpers
//
// All on-wire messages are 256-bit little-endian packed structs.  The engine
// is parameterized for a small multi-instrument book (default 8 names) with
// RAM-backed order and price-level free lists.  Pointer width is derived from
// the configured capacities so synthesis can infer compact SRAMs.
// =============================================================================

`ifndef QUASAR_PKG_SV
`define QUASAR_PKG_SV

package quasar_pkg;

  // ---------------------------------------------------------------------------
  // Capacities / widths
  // ---------------------------------------------------------------------------
  localparam int NUM_INSTRUMENTS = 8;
  localparam int MAX_ORDERS      = 256;
  localparam int MAX_LEVELS      = 256;
  localparam int HASH_BUCKETS    = 256;

  localparam int INST_W   = 8;
  localparam int PRICE_W  = 32;
  localparam int QTY_W    = 32;
  localparam int OID_W    = 64;
  localparam int FIRM_W   = 8;
  localparam int SEQ_W    = 32;
  localparam int PTR_W    = 9;          // 0..255 live, 9'h1FF = NULL
  localparam int HASH_W   = 8;
  localparam int TS_W     = 32;
  localparam int NOTIONAL_W = 64;
  localparam int POS_W    = 32;         // signed position, shares
  localparam int REJ_W    = 4;
  localparam int OPCODE_W = 8;
  localparam int EVENT_W  = 8;
  localparam int FLAGS_W  = 16;

  localparam logic [PTR_W-1:0] NULL_PTR = {PTR_W{1'b1}};

  localparam int AXIS_DATA_W = 256;
  localparam int AXIS_KEEP_W = AXIS_DATA_W / 8;
  localparam int AXIS_NARROW_W = 64;
  localparam int MSG_BYTES   = 32;
  localparam int BEATS_NARROW = MSG_BYTES / (AXIS_NARROW_W / 8); // 4

  localparam int AXIL_ADDR_W = 16;
  localparam int AXIL_DATA_W = 32;
  localparam int AXIL_STRB_W = AXIL_DATA_W / 8;

  localparam int FIFO_DEPTH_INGRESS = 16;
  localparam int FIFO_DEPTH_EGRESS  = 32;
  localparam int FIFO_DEPTH_EVENT   = 64;
  localparam int FIFO_DEPTH_CDC     = 16;

  // Pipeline occupancy / latency counters (cycle units at clk_core).
  localparam int LAT_W = 16;

  // ---------------------------------------------------------------------------
  // Opcodes (ingress)
  // ---------------------------------------------------------------------------
  typedef enum logic [OPCODE_W-1:0] {
    OP_NOP     = 8'h00,
    OP_NEW     = 8'h01,
    OP_CANCEL  = 8'h02,
    OP_REPLACE = 8'h03,
    OP_MODIFY  = 8'h04,
    OP_STATUS  = 8'h05,
    OP_MASS_CXL= 8'h06
  } opcode_e;

  // ---------------------------------------------------------------------------
  // Egress events
  // ---------------------------------------------------------------------------
  typedef enum logic [EVENT_W-1:0] {
    EV_NOP         = 8'h00,
    EV_ACK         = 8'h10,
    EV_REJECT      = 8'h11,
    EV_FILL        = 8'h12,
    EV_CANCEL_ACK  = 8'h13,
    EV_MODIFY_ACK  = 8'h14,
    EV_REPLACE_ACK = 8'h15,
    EV_BBO         = 8'h16,
    EV_DELTA       = 8'h17,
    EV_DROP        = 8'h18,
    EV_STATUS      = 8'h19
  } event_e;

  // ---------------------------------------------------------------------------
  // Reject reasons
  // ---------------------------------------------------------------------------
  typedef enum logic [REJ_W-1:0] {
    REJ_NONE           = 4'h0,
    REJ_CRC            = 4'h1,
    REJ_OPCODE         = 4'h2,
    REJ_INSTRUMENT     = 4'h3,
    REJ_QTY            = 4'h4,
    REJ_PRICE          = 4'h5,
    REJ_RISK_NOTIONAL  = 4'h6,
    REJ_RISK_POS       = 4'h7,
    REJ_RATE           = 4'h8,
    REJ_STP            = 4'h9,
    REJ_NOT_FOUND      = 4'hA,
    REJ_BOOK_FULL      = 4'hB,
    REJ_DUP_OID        = 4'hC,
    REJ_DISABLED       = 4'hD,
    REJ_FOK            = 4'hE,
    REJ_POST_ONLY      = 4'hF
  } reject_e;

  typedef enum logic {
    SIDE_BID = 1'b0,
    SIDE_ASK = 1'b1
  } side_e;

  typedef enum logic [1:0] {
    TIF_GTC = 2'b00,
    TIF_IOC = 2'b01,
    TIF_FOK = 2'b10,
    TIF_DAY = 2'b11
  } tif_e;

  typedef enum logic [1:0] {
    STP_OFF            = 2'b00,
    STP_CANCEL_RESTING = 2'b01,
    STP_CANCEL_TAKER   = 2'b10,
    STP_CANCEL_BOTH    = 2'b11
  } stp_e;

  // ---------------------------------------------------------------------------
  // On-wire ingress message (256 bits)
  //
  //  [  7:  0] opcode
  //  [ 15:  8] instrument
  //  [ 23: 16] firm_id
  //  [ 24    ] side          0=bid 1=ask
  //  [ 26: 25] tif
  //  [ 28: 27] stp
  //  [ 29    ] post_only
  //  [ 31: 30] reserved_flags
  //  [ 63: 32] qty
  //  [ 95: 64] price         integer ticks
  //  [159: 96] order_id
  //  [191:160] seq
  //  [223:192] aux           modify/replace qty or price
  //  [255:224] crc32         IEEE over bytes [0..27]
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic [31:0]            crc32;
    logic [31:0]            aux;
    logic [SEQ_W-1:0]       seq;
    logic [OID_W-1:0]       oid;
    logic [PRICE_W-1:0]     price;
    logic [QTY_W-1:0]       qty;
    logic [1:0]             reserved_flags;
    logic                   post_only;
    logic [1:0]             stp;
    logic [1:0]             tif;
    logic                   side;
    logic [FIRM_W-1:0]      firm;
    logic [INST_W-1:0]      inst;
    logic [OPCODE_W-1:0]    opcode;
  } msg_t;

  // ---------------------------------------------------------------------------
  // On-wire egress event (256 bits)
  //
  //  [  7:  0] event
  //  [ 15:  8] instrument
  //  [ 23: 16] firm
  //  [ 24    ] side
  //  [ 28: 25] reject
  //  [ 31: 29] reserved
  //  [ 63: 32] qty            fill/resting qty
  //  [ 95: 64] price
  //  [159: 96] order_id       aggressor or subject
  //  [191:160] match_oid_lo   resting oid[31:0] on fills
  //  [223:192] aux            remaining / bbo companion
  //  [255:224] seq / ts
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic [31:0]            ts;
    logic [31:0]            aux;
    logic [31:0]            match_oid_lo;
    logic [OID_W-1:0]       oid;
    logic [PRICE_W-1:0]     price;
    logic [QTY_W-1:0]       qty;
    logic [2:0]             reserved;
    logic [REJ_W-1:0]       reject;
    logic                   side;
    logic [FIRM_W-1:0]      firm;
    logic [INST_W-1:0]      inst;
    logic [EVENT_W-1:0]     ev;
  } event_t;

  // ---------------------------------------------------------------------------
  // Internal decoded command (ingress → risk → matcher)
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic [OPCODE_W-1:0]    opcode;
    logic [INST_W-1:0]      inst;
    logic [FIRM_W-1:0]      firm;
    logic                   side;
    logic [1:0]             tif;
    logic [1:0]             stp;
    logic                   post_only;
    logic [QTY_W-1:0]       qty;
    logic [PRICE_W-1:0]     price;
    logic [OID_W-1:0]       oid;
    logic [SEQ_W-1:0]       seq;
    logic [31:0]            aux;
    logic [TS_W-1:0]        ingress_ts;
    logic                   crc_ok;
  } cmd_t;

  // ---------------------------------------------------------------------------
  // Order RAM record
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic                   valid;
    logic [OID_W-1:0]       oid;
    logic [QTY_W-1:0]       qty;
    logic [PRICE_W-1:0]     price;
    logic [INST_W-1:0]      inst;
    logic                   side;
    logic [FIRM_W-1:0]      firm;
    logic [PTR_W-1:0]       next_ord;   // toward tail (newer)
    logic [PTR_W-1:0]       prev_ord;   // toward head (older)
    logic [PTR_W-1:0]       level_ptr;
    logic [PTR_W-1:0]       hash_next;
    logic [PTR_W-1:0]       hash_prev;
    logic [TS_W-1:0]        ts;
  } order_rec_t;

  localparam int ORDER_REC_W = $bits(order_rec_t);

  // ---------------------------------------------------------------------------
  // Price-level RAM record (sorted linked list per inst/side)
  // Bid list: best (highest) at head, next toward worse (lower).
  // Ask list: best (lowest)  at head, next toward worse (higher).
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic                   valid;
    logic [PRICE_W-1:0]     price;
    logic [QTY_W-1:0]       agg_qty;
    logic [15:0]            count;
    logic [INST_W-1:0]      inst;
    logic                   side;
    logic [PTR_W-1:0]       head;       // oldest order (time priority)
    logic [PTR_W-1:0]       tail;       // newest order
    logic [PTR_W-1:0]       next_lvl;   // worse price
    logic [PTR_W-1:0]       prev_lvl;   // better price
  } level_rec_t;

  localparam int LEVEL_REC_W = $bits(level_rec_t);

  // ---------------------------------------------------------------------------
  // Book command / response (matcher ⇄ book)
  // ---------------------------------------------------------------------------
  typedef enum logic [3:0] {
    BOOK_NOP           = 4'h0,
    BOOK_PEEK_BBO      = 4'h1,
    BOOK_LOOKUP_OID    = 4'h2,
    BOOK_MATCH_ONE     = 4'h3,   // consume min(agg, head) at opposite BBO
    BOOK_INSERT        = 4'h4,
    BOOK_CANCEL        = 4'h5,
    BOOK_MODIFY        = 4'h6,   // qty only; decrease in place, increase requeue
    BOOK_WALK_LIQ      = 4'h7,   // accumulate crossing liquidity (FOK probe)
    BOOK_UNLINK_RESTING= 4'h8,   // STP: cancel resting at BBO head
    BOOK_GET_STATUS    = 4'h9
  } book_cmd_e;

  typedef struct packed {
    logic [3:0]             cmd;
    logic [INST_W-1:0]      inst;
    logic                   side;       // aggressor side for MATCH/INSERT
    logic [PRICE_W-1:0]     price;
    logic [QTY_W-1:0]       qty;
    logic [OID_W-1:0]       oid;
    logic [FIRM_W-1:0]      firm;
    logic [TS_W-1:0]        ts;
    logic [1:0]             stp;
  } book_req_t;

  typedef struct packed {
    logic                   ok;
    logic [REJ_W-1:0]       reject;
    logic                   crossed;        // MATCH: a fill happened
    logic                   book_empty;
    logic                   would_cross;    // INSERT/PEEK: aggressor crosses BBO
    logic [QTY_W-1:0]       fill_qty;
    logic [PRICE_W-1:0]     fill_price;
    logic [OID_W-1:0]       resting_oid;
    logic [FIRM_W-1:0]      resting_firm;
    logic [QTY_W-1:0]       resting_left;
    logic [PRICE_W-1:0]     bbo_bid_px;
    logic [PRICE_W-1:0]     bbo_ask_px;
    logic [QTY_W-1:0]       bbo_bid_qty;
    logic [QTY_W-1:0]       bbo_ask_qty;
    logic                   bid_valid;
    logic                   ask_valid;
    logic [QTY_W-1:0]       walk_qty;       // WALK_LIQ result
    logic                   found;
    logic [PRICE_W-1:0]     found_price;
    logic [QTY_W-1:0]       found_qty;
    logic                   found_side;
    logic [INST_W-1:0]      found_inst;
    logic [15:0]            orders_used;
    logic [15:0]            levels_used;
  } book_rsp_t;

  // ---------------------------------------------------------------------------
  // BBO snapshot (per instrument, held in flops for 1-cycle peek)
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic                   bid_valid;
    logic                   ask_valid;
    logic [PRICE_W-1:0]     bid_px;
    logic [PRICE_W-1:0]     ask_px;
    logic [QTY_W-1:0]       bid_qty;
    logic [QTY_W-1:0]       ask_qty;
    logic [PTR_W-1:0]       bid_lvl;
    logic [PTR_W-1:0]       ask_lvl;
  } bbo_t;

  // ---------------------------------------------------------------------------
  // AXI-Lite CSR addresses (byte)
  // ---------------------------------------------------------------------------
  localparam logic [AXIL_ADDR_W-1:0] CSR_CTRL            = 16'h0000;
  localparam logic [AXIL_ADDR_W-1:0] CSR_STATUS          = 16'h0004;
  localparam logic [AXIL_ADDR_W-1:0] CSR_RISK_NOTIONAL   = 16'h0008;
  localparam logic [AXIL_ADDR_W-1:0] CSR_RISK_POSITION   = 16'h000C;
  localparam logic [AXIL_ADDR_W-1:0] CSR_RISK_RATE       = 16'h0010;
  localparam logic [AXIL_ADDR_W-1:0] CSR_RISK_WINDOW     = 16'h0014;
  localparam logic [AXIL_ADDR_W-1:0] CSR_INST_MASK       = 16'h0018;
  localparam logic [AXIL_ADDR_W-1:0] CSR_STP_MODE        = 16'h001C;
  localparam logic [AXIL_ADDR_W-1:0] CSR_CNT_ORDERS      = 16'h0020;
  localparam logic [AXIL_ADDR_W-1:0] CSR_CNT_FILLS       = 16'h0024;
  localparam logic [AXIL_ADDR_W-1:0] CSR_CNT_REJECTS     = 16'h0028;
  localparam logic [AXIL_ADDR_W-1:0] CSR_CNT_CANCELS     = 16'h002C;
  localparam logic [AXIL_ADDR_W-1:0] CSR_CNT_DROPS       = 16'h0030;
  localparam logic [AXIL_ADDR_W-1:0] CSR_CNT_ACKS        = 16'h0034;
  localparam logic [AXIL_ADDR_W-1:0] CSR_LAT_MIN         = 16'h0038;
  localparam logic [AXIL_ADDR_W-1:0] CSR_LAT_MAX         = 16'h003C;
  localparam logic [AXIL_ADDR_W-1:0] CSR_LAT_SUM_LO      = 16'h0040;
  localparam logic [AXIL_ADDR_W-1:0] CSR_SCRATCH         = 16'h0044;
  localparam logic [AXIL_ADDR_W-1:0] CSR_DBG_INST        = 16'h0048;
  localparam logic [AXIL_ADDR_W-1:0] CSR_DBG_BID_PX      = 16'h004C;
  localparam logic [AXIL_ADDR_W-1:0] CSR_DBG_ASK_PX      = 16'h0050;
  localparam logic [AXIL_ADDR_W-1:0] CSR_DBG_BID_QTY     = 16'h0054;
  localparam logic [AXIL_ADDR_W-1:0] CSR_DBG_ASK_QTY     = 16'h0058;
  localparam logic [AXIL_ADDR_W-1:0] CSR_DBG_ORD_USED    = 16'h005C;
  localparam logic [AXIL_ADDR_W-1:0] CSR_DBG_LVL_USED    = 16'h0060;
  localparam logic [AXIL_ADDR_W-1:0] CSR_VERSION         = 16'h0064;
  localparam logic [AXIL_ADDR_W-1:0] CSR_FEATURE         = 16'h0068;
  localparam logic [AXIL_ADDR_W-1:0] CSR_CNT_MODIFY      = 16'h006C;
  localparam logic [AXIL_ADDR_W-1:0] CSR_CNT_REPLACE     = 16'h0070;
  localparam logic [AXIL_ADDR_W-1:0] CSR_CNT_STP         = 16'h0074;
  localparam logic [AXIL_ADDR_W-1:0] CSR_DROP_INGRESS    = 16'h0078;
  localparam logic [AXIL_ADDR_W-1:0] CSR_DROP_EGRESS     = 16'h007C;

  localparam logic [31:0] QUASAR_VERSION = 32'h0001_0000; // 1.0.0
  localparam logic [31:0] QUASAR_FEATURE = 32'h0000_00FF; // book+risk+stp+axil

  // CTRL bits
  localparam int CTRL_ENABLE   = 0;
  localparam int CTRL_SOFT_RST = 1;
  localparam int CTRL_STP_EN   = 2;
  localparam int CTRL_BBO_EN   = 3;
  localparam int CTRL_DELTA_EN = 4;

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------
  function automatic logic [HASH_W-1:0] oid_hash(input logic [OID_W-1:0] oid);
    oid_hash = oid[7:0]
             ^ oid[15:8]
             ^ oid[23:16]
             ^ oid[31:24]
             ^ oid[39:32]
             ^ oid[47:40]
             ^ oid[55:48]
             ^ oid[63:56];
  endfunction

  function automatic logic price_better(
      input logic side_is_ask,
      input logic [PRICE_W-1:0] a,
      input logic [PRICE_W-1:0] b
  );
    // True iff price a is strictly more aggressive than b on this side.
    if (side_is_ask)
      price_better = (a < b);
    else
      price_better = (a > b);
  endfunction

  function automatic logic prices_cross(
      input logic aggressor_is_ask,
      input logic [PRICE_W-1:0] agg_px,
      input logic [PRICE_W-1:0] rest_px,
      input logic rest_valid
  );
    if (!rest_valid)
      prices_cross = 1'b0;
    else if (aggressor_is_ask)
      prices_cross = (agg_px <= rest_px); // sell lifts the bid
    else
      prices_cross = (agg_px >= rest_px); // buy hits the ask
  endfunction

  function automatic logic [QTY_W-1:0] min_qty(
      input logic [QTY_W-1:0] a,
      input logic [QTY_W-1:0] b
  );
    min_qty = (a < b) ? a : b;
  endfunction

  function automatic logic [NOTIONAL_W-1:0] notional_of(
      input logic [QTY_W-1:0] qty,
      input logic [PRICE_W-1:0] price
  );
    notional_of = NOTIONAL_W'(qty) * NOTIONAL_W'(price);
  endfunction

  function automatic logic opcode_is_book(
      input logic [OPCODE_W-1:0] op
  );
    opcode_is_book = (op == OP_NEW) || (op == OP_CANCEL) ||
                     (op == OP_REPLACE) || (op == OP_MODIFY) ||
                     (op == OP_MASS_CXL);
  endfunction

  function automatic logic [31:0] msg_payload_lo(input msg_t m);
    // Bytes [0..15] as they appear on the wire (low 128 bits of the 256).
    msg_payload_lo = 32'h0; // placeholder — CRC uses the packed vector
    void'(m);
  endfunction

  // Flatten a msg without its CRC word (low 224 bits) for CRC computation.
  function automatic logic [223:0] msg_body(input msg_t m);
    msg_t tmp;
    tmp = m;
    tmp.crc32 = 32'h0;
    msg_body = tmp[223:0];
  endfunction

  function automatic event_t mk_event(
      input logic [EVENT_W-1:0] ev,
      input logic [INST_W-1:0]  inst,
      input logic [FIRM_W-1:0]  firm,
      input logic               side,
      input logic [REJ_W-1:0]   reject,
      input logic [QTY_W-1:0]   qty,
      input logic [PRICE_W-1:0] price,
      input logic [OID_W-1:0]   oid,
      input logic [31:0]        match_lo,
      input logic [31:0]        aux,
      input logic [31:0]        ts
  );
    mk_event = '0;
    mk_event.ev           = ev;
    mk_event.inst         = inst;
    mk_event.firm         = firm;
    mk_event.side         = side;
    mk_event.reject       = reject;
    mk_event.qty          = qty;
    mk_event.price        = price;
    mk_event.oid          = oid;
    mk_event.match_oid_lo = match_lo;
    mk_event.aux          = aux;
    mk_event.ts           = ts;
  endfunction

  function automatic cmd_t msg_to_cmd(input msg_t m, input logic [TS_W-1:0] ts, input logic crc_ok);
    msg_to_cmd = '0;
    msg_to_cmd.opcode     = m.opcode;
    msg_to_cmd.inst       = m.inst;
    msg_to_cmd.firm       = m.firm;
    msg_to_cmd.side       = m.side;
    msg_to_cmd.tif        = m.tif;
    msg_to_cmd.stp        = m.stp;
    msg_to_cmd.post_only  = m.post_only;
    msg_to_cmd.qty        = m.qty;
    msg_to_cmd.price      = m.price;
    msg_to_cmd.oid        = m.oid;
    msg_to_cmd.seq        = m.seq;
    msg_to_cmd.aux        = m.aux;
    msg_to_cmd.ingress_ts = ts;
    msg_to_cmd.crc_ok     = crc_ok;
  endfunction

endpackage : quasar_pkg

`endif
