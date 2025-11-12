# Wire protocol

Every command and every event is a **32-byte (256-bit)** packed struct,
transmitted little-endian.

The native engine AXI-Stream interface is one message per beat
(`TKEEP` = 0xFFFFFFFF, `TLAST=1`).  A 64-bit fabric uses four beats
with `TLAST` on beat 3; the `quasar_axis_upsizer` reassembles them.

CRC-32 (IEEE, poly `0xEDB88320`, init/final XOR `0xFFFFFFFF`) covers
**bytes 0–27**.  The CRC word itself occupies bytes 28–31 and is not
included in its own digest.

---

## Ingress command (`msg_t`)

SystemVerilog packed structs declare fields MSB-first, so in the 256-bit
vector `crc32` occupies bits [255:224] and `opcode` bits [7:0].

| Bits | Width | Name | Notes |
|------|-------|------|-------|
| `[7:0]` | 8 | `opcode` | see opcode table |
| `[15:8]` | 8 | `inst` | instrument id, 0..`NUM_INSTRUMENTS`-1 |
| `[23:16]` | 8 | `firm` | firm / session id; used as STP key |
| `[24]` | 1 | `side` | 0=bid 1=ask |
| `[26:25]` | 2 | `tif` | 00=GTC 01=IOC 10=FOK 11=DAY |
| `[28:27]` | 2 | `stp` | 00=off 01=cxl-resting 10=cxl-taker 11=both |
| `[29]` | 1 | `post_only` | reject if order would take |
| `[31:30]` | 2 | reserved | send as 0 |
| `[63:32]` | 32 | `qty` | integer shares or lots |
| `[95:64]` | 32 | `price` | integer ticks |
| `[159:96]` | 64 | `oid` | client-allocated unique order id |
| `[191:160]` | 32 | `seq` | client sequence / correlation tag |
| `[223:192]` | 32 | `aux` | modify/replace hint; write 0 otherwise |
| `[255:224]` | 32 | `crc32` | IEEE CRC-32 over `[223:0]` |

### Opcodes

| Value | Name | Book effect |
|-------|------|-------------|
| `0x00` | `NOP` | Parser drops silently; no event emitted |
| `0x01` | `NEW` | Match against opposite side, rest residual per TIF |
| `0x02` | `CANCEL` | Unlink by `oid`; emits `EV_CANCEL_ACK` or `EV_REJECT` |
| `0x03` | `REPLACE` | Same price → `MODIFY qty`; different price → `CANCEL` + `NEW` |
| `0x04` | `MODIFY` | In-place qty update; `qty=0` is treated as cancel |
| `0x05` | `STATUS` | Emit `EV_STATUS` with current BBO; book unchanged |
| `0x06` | `MASS_CXL` | Remove all resting orders on `side` for `inst` |

Any other opcode value → `EV_REJECT` with `REJ_OPCODE`.

---

## Egress event (`event_t`)

| Bits | Width | Name | Notes |
|------|-------|------|-------|
| `[7:0]` | 8 | `ev` | event type |
| `[15:8]` | 8 | `inst` | |
| `[23:16]` | 8 | `firm` | |
| `[24]` | 1 | `side` | aggressor / subject side |
| `[28:25]` | 4 | `reject` | `REJ_*` code; meaningful on `EV_REJECT` |
| `[31:29]` | 3 | reserved | |
| `[63:32]` | 32 | `qty` | fill qty, residual, cancelled qty |
| `[95:64]` | 32 | `price` | fill / resting / BBO bid price |
| `[159:96]` | 64 | `oid` | aggressor or subject OID |
| `[191:160]` | 32 | `match_oid_lo` | resting OID `[31:0]` on fills; ask price on `EV_STATUS`/`EV_BBO` |
| `[223:192]` | 32 | `aux` | resting left qty on fills; ask qty on BBO/status |
| `[255:224]` | 32 | `ts` | core cycle counter at emit |

### Event types

| Value | Name | Produced when |
|-------|------|---------------|
| `0x10` | `EV_ACK` | NEW accepted (residual may be resting or IOC-discarded) |
| `0x11` | `EV_REJECT` | Command refused; book unchanged (except STP-resting cancel) |
| `0x12` | `EV_FILL` | One resting order (or partial) traded with the aggressor |
| `0x13` | `EV_CANCEL_ACK` | Cancel or mass-cancel completed |
| `0x14` | `EV_MODIFY_ACK` | Qty update committed |
| `0x15` | `EV_REPLACE_ACK` | Replace completed |
| `0x16` | `EV_BBO` | BBO snapshot (emitted after each command when `CTRL.BBO_EN`) |
| `0x17` | `EV_DELTA` | Reserved for incremental depth deltas |
| `0x18` | `EV_DROP` | Reserved (FIFO overflow counted in `DROP_EGRESS`, not always emitted) |
| `0x19` | `EV_STATUS` | Response to `OP_STATUS` query |

**Event ordering for a NEW that fills three resting orders:**
```
EV_FILL  (oldest resting, full)
EV_FILL  (next, full)
EV_FILL  (next, partial or full)
EV_ACK   (with residual qty if any was left to rest)
EV_BBO   (if CTRL.BBO_EN)
```
Each fill is emitted and accepted by the event FIFO before the next
`MATCH_ONE` book command is issued.

### Reject codes

| Code | Name | Typical cause |
|------|------|---------------|
| `0x0` | `REJ_NONE` | Not a reject |
| `0x1` | `REJ_CRC` | CRC mismatch or upsizer framing error |
| `0x2` | `REJ_OPCODE` | Unknown opcode byte |
| `0x3` | `REJ_INSTRUMENT` | `inst ≥ NUM_INSTRUMENTS` or masked in `INST_MASK` |
| `0x4` | `REJ_QTY` | `qty == 0` on NEW |
| `0x5` | `REJ_PRICE` | `price == 0` on NEW / REPLACE |
| `0x6` | `REJ_RISK_NOTIONAL` | `qty * price > MAX_NOTIONAL` |
| `0x7` | `REJ_RISK_POS` | Hypothetical |position| > `MAX_POSITION` |
| `0x8` | `REJ_RATE` | Token bucket empty |
| `0x9` | `REJ_STP` | Self-trade prevention triggered |
| `0xA` | `REJ_NOT_FOUND` | Cancel / modify / replace: OID not live |
| `0xB` | `REJ_BOOK_FULL` | Order or level free list exhausted |
| `0xC` | `REJ_DUP_OID` | NEW with an OID that already has a live order |
| `0xD` | `REJ_DISABLED` | `CTRL.EN == 0` |
| `0xE` | `REJ_FOK` | FOK: available crossing qty < order qty |
| `0xF` | `REJ_POST_ONLY` | Post-only order would cross the current BBO |

---

## Matching semantics (normative)

### Price-time priority
Bids are ordered high-to-low; asks low-to-high.  Within a price, the
**oldest** order (level head) trades first.  Trade price is the **resting**
price (maker price), regardless of the aggressor's limit.

### TIF handling
| TIF | Residual behaviour |
|-----|--------------------|
| GTC | Residual is inserted into the book at `price`; time priority is back of the queue |
| IOC | Residual is silently discarded; no insert |
| FOK | If total crossing liquidity (`WALK_LIQ`) < `qty`, reject before touching anything |
| DAY | Treated as GTC in this implementation |

### Replace
1. `LOOKUP_OID` to find live order.
2. If `found_price == req.price` → `MODIFY qty` (retains time priority).
3. If `found_price != req.price` → `CANCEL` then `INSERT` as NEW with same OID.
   The insert competes for time priority at the back of the new level's queue.

### Self-trade prevention (STP)
STP is evaluated inside `MATCH_ONE` when the book returns the resting firm.
Risk gate does not have this information.

| Mode | Behaviour |
|------|-----------|
| `STP_OFF` | No action |
| `STP_CANCEL_RESTING` | Cancel the resting head; retry matching against next order |
| `STP_CANCEL_TAKER` | Reject the incoming order (`REJ_STP`); resting order untouched |
| `STP_CANCEL_BOTH` | Cancel resting head and reject taker |

---

## 64-bit AXIS framing

Four-beat, `TLAST` on beat 3, 8-byte `TKEEP` (all ones for full frames):

```
beat 0: TDATA[63:0]   = msg[63:0]    TLAST=0
beat 1: TDATA[63:0]   = msg[127:64]  TLAST=0
beat 2: TDATA[63:0]   = msg[191:128] TLAST=0
beat 3: TDATA[63:0]   = msg[255:192] TLAST=1
```

Early `TLAST` (beats 0–2) or missing `TLAST` (beat 3) sets `framing_err`.
The ingress parser treats this as a CRC failure and emits `EV_REJECT/REJ_CRC`.

The upsizer holds `TREADY=0` while assembling a beat, so the upstream can
stall between beats without any special flow-control.

---

## CRC-32 quick reference

Polynomial: **0xEDB88320** (reflected Ethernet CRC, same as zip/zlib).
Init: `0xFFFFFFFF`.  Final XOR: `0xFFFFFFFF`.  Byte order: byte 0 is the
`opcode` byte (`msg_t[7:0]`), byte 27 is the last byte of `aux`.

```python
import struct, zlib
msg_bytes = msg_t_as_bytes[:28]          # bytes 0..27
crc = zlib.crc32(msg_bytes) & 0xFFFFFFFF
# stuff into msg bytes 28..31 little-endian
msg_bytes += struct.pack('<I', crc)
```
