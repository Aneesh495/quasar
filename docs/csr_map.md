# AXI4-Lite CSR map

Slave: 16-bit byte address, 32-bit data, `OKAY` responses, byte strobes
honoured on writes.  Independent AR and AW/W channels.  See
`rtl/csr/quasar_csr.sv`.

Reset defaults: `CTRL = 0x0000_0009` (enable + BBO events),
`INST_MASK = 0x0000_00FF`, all risk caps `0` (disabled), all counters `0`.

## Registers

| Offset | Name              | R/W | Description |
|--------|-------------------|-----|-------------|
| `0x0000` | `CTRL`          | R/W | `[0]` enable `[1]` soft-rst (self-clear) `[2]` STP enable `[3]` BBO events `[4]` delta events |
| `0x0004` | `STATUS`        | R   | `[0]` busy `[13:8]` matcher FSM |
| `0x0008` | `RISK_NOTIONAL` | R/W | max `qty*price` (0 = off) |
| `0x000C` | `RISK_POSITION` | R/W | max \|position\| (0 = off) |
| `0x0010` | `RISK_RATE`     | R/W | `[15:0]` tokens per window (0 = off) |
| `0x0014` | `RISK_WINDOW`   | R/W | window length in `clk_core` cycles (0 → 1024) |
| `0x0018` | `INST_MASK`     | R/W | bit *i* enables instrument *i* |
| `0x001C` | `STP_MODE`      | R/W | `[1:0]` default STP if the message left it `OFF` and `CTRL[2]` |
| `0x0020` | `CNT_ORDERS`    | R   | accepted `OP_NEW` (saturating) |
| `0x0024` | `CNT_FILLS`     | R   | `EV_FILL` count |
| `0x0028` | `CNT_REJECTS`   | R   | matcher + risk rejects |
| `0x002C` | `CNT_CANCELS`   | R   | `EV_CANCEL_ACK` |
| `0x0030` | `CNT_DROPS`     | R   | egress FIFO drops |
| `0x0034` | `CNT_ACKS`      | R   | `EV_ACK` / `EV_REPLACE_ACK` |
| `0x0038` | `LAT_MIN`       | R   | min (egress_ts − ingress_ts), cycles |
| `0x003C` | `LAT_MAX`       | R   | max |
| `0x0040` | `LAT_SUM_LO`    | R   | sum, low 32 (for mean = sum / acks) |
| `0x0044` | `SCRATCH`       | R/W | bring-up |
| `0x0048` | `DBG_INST`      | R/W | instrument whose BBO is mirrored below |
| `0x004C` | `DBG_BID_PX`    | R   | |
| `0x0050` | `DBG_ASK_PX`    | R   | |
| `0x0054` | `DBG_BID_QTY`   | R   | aggregated best-level qty |
| `0x0058` | `DBG_ASK_QTY`   | R   | |
| `0x005C` | `DBG_ORD_USED`  | R   | live orders |
| `0x0060` | `DBG_LVL_USED`  | R   | live levels |
| `0x0064` | `VERSION`       | R   | `0x0001_0000` (1.0.0) |
| `0x0068` | `FEATURE`       | R   | `0x0000_00FF` book+risk+stp+axil |
| `0x006C` | `CNT_MODIFY`    | R   | |
| `0x0070` | `CNT_REPLACE`   | R   | |
| `0x0074` | `CNT_STP`       | R   | STP events |
| `0x0078` | `DROP_INGRESS`  | R   | framing + CRC + cmd-FIFO |
| `0x007C` | `DROP_EGRESS`   | R   | event-log overflow |

Unmapped addresses read `0xDEAD_BEEF` and ignore writes.

## CTRL bits

```
31                             5  4  3  2  1  0
+------------------------------+--+--+--+--+--+
|            reserved          |DE|BE|SE|SR|EN|
+------------------------------+--+--+--+--+--+
```

* `EN` — risk + matcher accept commands.
* `SR` — write `1` to pulse soft reset (bit reads back 0).
* `SE` — if set, a message with `stp==OFF` inherits `STP_MODE`.
* `BE` — matcher emits `EV_BBO` after each command.
* `DE` — reserved for incremental deltas.

## Programming sequence

1. Pulse `rst_n` (or power-on).  Wait ≥ 256 + 8 `clk_core` cycles for
   hash-table init and reset sync.
2. Write `INST_MASK`, risk caps, `STP_MODE`.
3. Write `CTRL` with `EN=1` (and `BE` if the consumer wants snapshots).
4. Stream `msg_t` on AXIS.
5. Poll `STATUS[0]` if you need the engine idle (e.g. before a
   coordinated mask change).
6. Read counters / `DBG_*` for a live BBO of `DBG_INST`.
