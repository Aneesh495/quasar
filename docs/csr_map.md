# AXI4-Lite CSR map

Slave: 16-bit byte address, 32-bit data, `OKAY` responses, byte strobes
honoured on writes.  Independent AR and AW/W channels.  See
`rtl/csr/quasar_csr.sv`.

After power-on reset:
- `CTRL = 0x0000_0009` (engine enable + BBO events on)
- `INST_MASK = 0x0000_00FF` (all 8 instruments active)
- All risk caps at 0 (disabled)
- All counters at 0

---

## Register map

| Offset | Name | R/W | Description |
|--------|------|-----|-------------|
| `0x0000` | `CTRL` | R/W | Engine control (see CTRL bits below) |
| `0x0004` | `STATUS` | R | `[0]` engine busy `[13:8]` matcher FSM state |
| `0x0008` | `RISK_NOTIONAL` | R/W | Max `qty × price`, 0 = disabled |
| `0x000C` | `RISK_POSITION` | R/W | Max \|position\| in lots, 0 = disabled |
| `0x0010` | `RISK_RATE` | R/W | `[15:0]` token bucket depth, 0 = disabled |
| `0x0014` | `RISK_WINDOW` | R/W | Token refill interval in `clk_core` cycles (0 → 1024) |
| `0x0018` | `INST_MASK` | R/W | Bit *i* enables instrument *i* |
| `0x001C` | `STP_MODE` | R/W | `[1:0]` default STP (applied when `CTRL.STP_EN` and message STP=OFF) |
| `0x0020` | `CNT_ORDERS` | R | Accepted `OP_NEW` count (saturating 32-bit) |
| `0x0024` | `CNT_FILLS` | R | `EV_FILL` count |
| `0x0028` | `CNT_REJECTS` | R | Matcher + risk rejects |
| `0x002C` | `CNT_CANCELS` | R | `EV_CANCEL_ACK` count |
| `0x0030` | `CNT_DROPS` | R | Egress FIFO overflow count |
| `0x0034` | `CNT_ACKS` | R | `EV_ACK` + `EV_REPLACE_ACK` count |
| `0x0038` | `LAT_MIN` | R | Min (egress_ts − ingress_ts) in cycles |
| `0x003C` | `LAT_MAX` | R | Max |
| `0x0040` | `LAT_SUM_LO` | R | Sum low 32 bits (mean = sum / cnt_acks) |
| `0x0044` | `SCRATCH` | R/W | Bring-up / debug scratchpad |
| `0x0048` | `DBG_INST` | R/W | Instrument whose BBO is mirrored in `DBG_BID_*` / `DBG_ASK_*` |
| `0x004C` | `DBG_BID_PX` | R | BBO bid price for `DBG_INST` |
| `0x0050` | `DBG_ASK_PX` | R | BBO ask price |
| `0x0054` | `DBG_BID_QTY` | R | Aggregated best-level bid qty |
| `0x0058` | `DBG_ASK_QTY` | R | Aggregated best-level ask qty |
| `0x005C` | `DBG_ORD_USED` | R | Live orders in the book |
| `0x0060` | `DBG_LVL_USED` | R | Live price levels |
| `0x0064` | `VERSION` | R | `0x0001_0000` (1.0.0) |
| `0x0068` | `FEATURE` | R | `0x0000_00FF` (book + risk + STP + AXI-Lite) |
| `0x006C` | `CNT_MODIFY` | R | `EV_MODIFY_ACK` count |
| `0x0070` | `CNT_REPLACE` | R | `EV_REPLACE_ACK` count |
| `0x0074` | `CNT_STP` | R | STP events triggered |
| `0x0078` | `DROP_INGRESS` | R | Framing + CRC + cmd-FIFO overflow |
| `0x007C` | `DROP_EGRESS` | R | Event log overflow |

Unmapped addresses read `0xDEAD_BEEF` and ignore writes.

---

## CTRL bits

```
31                         5  4  3  2  1  0
+--------------------------+--+--+--+--+--+
|         reserved         |DE|BE|SE|SR|EN|
+--------------------------+--+--+--+--+--+
```

| Bit | Name | Description |
|-----|------|-------------|
| 0 | `EN` | Engine enable.  When 0, all commands get `REJ_DISABLED`. |
| 1 | `SR` | Soft reset.  Write 1 to pulse; reads back 0 (self-clearing). |
| 2 | `SE` | STP enable.  If set, commands with `stp==OFF` inherit `STP_MODE`. |
| 3 | `BE` | BBO events.  Emit `EV_BBO` after each accepted command. |
| 4 | `DE` | Delta events.  Reserved for incremental depth emission. |

---

## Risk configuration

```
RISK_NOTIONAL = 0          // disabled
RISK_NOTIONAL = 100000     // reject if qty*price > 100,000
RISK_POSITION = 0          // disabled
RISK_POSITION = 500        // reject if |net_position| would exceed ±500 lots
RISK_RATE     = 0          // disabled
RISK_RATE     = 100        // 100 tokens per window
RISK_WINDOW   = 50         // refill every 50 core cycles
```

The token bucket refills `RISK_RATE` tokens every `RISK_WINDOW` cycles.
`OP_STATUS` does not consume a token.  All other opcodes (including
`OP_CANCEL`) consume one token when the limit is active.

The position counter per instrument is signed 32-bit: buy fills add
`fill_qty`, sell fills subtract.  `RISK_POSITION` is the unsigned
magnitude cap — the check is `|pos + delta| > RISK_POSITION`.

---

## Programming sequence

1. Assert `rst_n` low for at least one `clk_core` cycle.
2. Deassert.  Wait ≥ 270 `clk_core` cycles (3 reset-sync + 256 hash-init + margin).
3. Write `INST_MASK`, risk caps, `STP_MODE` as needed.
4. Write `CTRL` with `EN=1` (and `BE` if the consumer wants BBO snapshots).
5. Begin streaming messages on AXIS.
6. Read `STATUS[0]` when you need the engine idle (e.g., before a coordinated
   instrument-mask change mid-session).
7. Read `DBG_*` for a live BBO snapshot of `DBG_INST`.
8. Read counters for session statistics; `LAT_SUM_LO / CNT_ACKS` gives mean
   latency in core cycles.

### Soft-reset mid-session

A write to `CTRL[1]=1` clears risk counters (position, token bucket),
matcher state, and performance counters.  The book SRAMs retain their
state — all resting orders survive a soft reset.  To clear the book,
either assert `rst_n` (full hardware reset, 270+ cycle wait) or issue
`OP_MASS_CXL` for every active name.
