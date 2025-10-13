# Quasar on-wire protocol

Every command and every event is a **32-byte (256-bit)** little-endian packed
struct.  The native engine AXIS is one message per beat (`TKEEP` all-ones,
`TLAST=1`).  A 64-bit fabric uses four beats with `TLAST` on beat 3; see
`quasar_axis_upsizer` / `quasar_axis_downsizer`.

CRC-32 (IEEE, poly `0xEDB88320`, init/final XOR `0xFFFF_FFFF`) covers **bytes
0–27**.  Bytes 28–31 are the CRC themselves and are not included in the
digest.

## Ingress message (`msg_t`)

| Bits     | Width | Name            | Notes                                              |
|----------|-------|-----------------|----------------------------------------------------|
| `[7:0]`  | 8     | `opcode`        | see table below                                    |
| `[15:8]` | 8     | `inst`          | instrument id, `0 .. NUM_INSTRUMENTS-1`            |
| `[23:16]`| 8     | `firm`          | firm / session id (STP key)                        |
| `[24]`   | 1     | `side`          | `0` bid (buy), `1` ask (sell)                      |
| `[26:25]`| 2     | `tif`           | `00` GTC, `01` IOC, `10` FOK, `11` DAY             |
| `[28:27]`| 2     | `stp`           | `00` off, `01` cxl resting, `10` cxl taker, `11` both |
| `[29]`   | 1     | `post_only`     | reject if the order would take                     |
| `[31:30]`| 2     | `reserved`      | write as 0                                         |
| `[63:32]`| 32    | `qty`           | integer shares / lots                              |
| `[95:64]`| 32    | `price`         | integer ticks                                      |
| `[159:96]`| 64   | `oid`           | unique order id (client-allocated)                 |
| `[191:160]`| 32  | `seq`           | client sequence / correlation                      |
| `[223:192]`| 32  | `aux`           | reserved / replace hint                            |
| `[255:224]`| 32  | `crc32`         | IEEE over `[223:0]`                                |

SystemVerilog `struct packed` lists the **MSB field first**, so `crc32` is
declared first in `quasar_pkg.sv` and `opcode` last.  The bit ranges above
are the ones that appear on `TDATA`.

### Opcodes

| Value | Name         | Book effect |
|-------|--------------|-------------|
| `0x00`| `NOP`        | dropped in the parser |
| `0x01`| `NEW`        | match then rest (subject to TIF) |
| `0x02`| `CANCEL`     | unlink by `oid` |
| `0x03`| `REPLACE`    | same-price → modify qty; else cancel + new with same `oid` |
| `0x04`| `MODIFY`     | in-place qty change (`qty` is the **new** size) |
| `0x05`| `STATUS`     | emit `EV_STATUS` with BBO; no book mutation |
| `0x06`| `MASS_CXL`   | purge the requested side of `inst` |

`MODIFY` with `qty=0` is defined as cancel.

## Egress event (`event_t`)

| Bits        | Width | Name           | Notes |
|-------------|-------|----------------|-------|
| `[7:0]`     | 8     | `ev`           | event type |
| `[15:8]`    | 8     | `inst`         | |
| `[23:16]`   | 8     | `firm`         | |
| `[24]`      | 1     | `side`         | aggressor / subject side |
| `[28:25]`   | 4     | `reject`       | `REJ_*` (meaningful on `EV_REJECT`) |
| `[31:29]`   | 3     | reserved       | |
| `[63:32]`   | 32    | `qty`          | fill qty, residual, or cancelled qty |
| `[95:64]`   | 32    | `price`        | fill / resting / BBO bid |
| `[159:96]`  | 64    | `oid`          | aggressor or subject |
| `[191:160]` | 32    | `match_oid_lo` | resting oid `[31:0]` on fills; ask px on `EV_STATUS`/`EV_BBO` |
| `[223:192]` | 32    | `aux`          | residual resting qty on fills; ask qty on BBO/status |
| `[255:224]` | 32    | `ts`           | core cycle counter at emit |

### Event types

| Value  | Name             | When |
|--------|------------------|------|
| `0x10` | `EV_ACK`         | NEW accepted (residual may be resting) |
| `0x11` | `EV_REJECT`      | command refused; book unchanged (except STP-resting) |
| `0x12` | `EV_FILL`        | one resting order was traded |
| `0x13` | `EV_CANCEL_ACK`  | cancel or mass-cancel completed |
| `0x14` | `EV_MODIFY_ACK`  | qty updated |
| `0x15` | `EV_REPLACE_ACK` | replace completed |
| `0x16` | `EV_BBO`         | optional top-of-book snapshot (CSR `CTRL[3]`) |
| `0x17` | `EV_DELTA`       | reserved for incremental book deltas |
| `0x18` | `EV_DROP`        | reserved (FIFO drop is counted, not always emitted) |
| `0x19` | `EV_STATUS`      | explicit status request |

A single `NEW` that walks three resting orders produces **three `EV_FILL`
then one `EV_ACK`**, then optionally `EV_BBO`.  The matcher will not issue
the next book command until the current event has been accepted, so a stalled
egress cannot lose a fill.

### Reject reasons (`reject_e`)

| Code | Name               | Typical cause |
|------|--------------------|---------------|
| `0x0`| `REJ_NONE`         | |
| `0x1`| `REJ_CRC`          | CRC or framing |
| `0x2`| `REJ_OPCODE`       | unknown opcode |
| `0x3`| `REJ_INSTRUMENT`   | id ≥ N or masked off |
| `0x4`| `REJ_QTY`          | zero qty on NEW |
| `0x5`| `REJ_PRICE`        | zero price on NEW |
| `0x6`| `REJ_RISK_NOTIONAL`| `qty*price` > CSR cap |
| `0x7`| `REJ_RISK_POS`     | hypothetical \|position\| > cap |
| `0x8`| `REJ_RATE`         | token bucket empty |
| `0x9`| `REJ_STP`          | self-trade prevention |
| `0xA`| `REJ_NOT_FOUND`    | cancel/modify/replace oid miss |
| `0xB`| `REJ_BOOK_FULL`    | order or level free list empty |
| `0xC`| `REJ_DUP_OID`      | NEW with live oid |
| `0xD`| `REJ_DISABLED`     | `CTRL[0]=0` |
| `0xE`| `REJ_FOK`          | not enough crossing liquidity |
| `0xF`| `REJ_POST_ONLY`    | would take |

## Matching semantics (normative)

1. **Price-time priority.**  Bids are walked high-to-low; asks low-to-high.
   Within a price, the **oldest** order (level head) trades first.
2. **Trade price** is the **resting** price (maker price).
3. **GTC / DAY.**  Match while the residual crosses, then insert the rest
   at the back of the level (or create the level).
4. **IOC.**  Match while it crosses; discard any residual (no insert).
5. **FOK.**  `BOOK_WALK_LIQ` sums crossing size.  If `walk_qty < order.qty`
   the command is rejected and the book is untouched.  Otherwise match
   exactly as GTC (residual will be zero).
6. **Post-only.**  `BOOK_PEEK_BBO`; if `would_cross`, reject.
7. **Replace.**  Lookup oid.  Same price → `BOOK_MODIFY`.  Different
   price → `BOOK_CANCEL` then treat as `NEW` with the same oid.
8. **STP.**  Compared on `firm`.  Modes: cancel resting and continue,
   cancel taker (reject), or both.

## 64-bit AXIS framing

```
beat 0: TDATA = msg[63:0]     TLAST = 0
beat 1: TDATA = msg[127:64]   TLAST = 0
beat 2: TDATA = msg[191:128]  TLAST = 0
beat 3: TDATA = msg[255:192]  TLAST = 1
```

Early or missing `TLAST` sets `framing_err` and the parser emits `REJ_CRC`.
