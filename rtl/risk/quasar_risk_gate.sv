// =============================================================================
// Risk gate — combinational decision + registered position / rate state.
//
// Checks (all CSR-configurable, can be disabled by writing 0):
//   1. Engine enable
//   2. Instrument mask
//   3. Qty / price sanity
//   4. Max notional  (qty * price)
//   5. Max |position| after a hypothetical full fill of a NEW order
//   6. Token-bucket rate limit (orders per window)
//
// STP is applied later in the book (needs the resting firm).  The gate only
// records the configured default STP mode onto the command if the message
// left the field at STP_OFF and CSR STP is enabled.
// =============================================================================

module quasar_risk_gate
    import quasar_pkg::*;
(
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  soft_rst,

    input  logic                  enable,
    input  logic [NUM_INSTRUMENTS-1:0] inst_mask,
    input  logic [NOTIONAL_W-1:0] max_notional,   // 0 = off
    input  logic [POS_W-1:0]      max_position,   // unsigned cap, 0 = off
    input  logic [15:0]           rate_limit,     // tokens, 0 = off
    input  logic [15:0]           rate_window,    // cycles, 0 = 1024
    input  logic                  stp_en,
    input  logic [1:0]            stp_mode,

    input  logic                  cmd_valid,
    output logic                  cmd_ready,
    input  cmd_t                  cmd,

    output logic                  out_valid,
    input  logic                  out_ready,
    output cmd_t                  out_cmd,
    output logic                  reject_valid,
    output logic [REJ_W-1:0]      reject_code,

    // Position is updated by the matcher on every fill (signed +buy / −sell).
    input  logic                  pos_we,
    input  logic [INST_W-1:0]     pos_inst,
    input  logic signed [POS_W-1:0] pos_delta,

    output logic signed [POS_W-1:0] position [NUM_INSTRUMENTS-1:0],
    output logic [15:0]           tokens_left
);

    logic signed [POS_W-1:0] pos [NUM_INSTRUMENTS-1:0];
    logic [15:0]             tokens, wnd_cnt, wnd_lim;

    assign position    = pos;
    assign tokens_left = tokens;
    assign wnd_lim     = (rate_window == 16'h0) ? 16'd1024 : rate_window;

    integer i;

    logic        take;
    logic [REJ_W-1:0] rej;
    cmd_t        cmd_q;
    logic        hold_out, hold_rej;

    assign take      = cmd_valid && cmd_ready;
    assign cmd_ready = !hold_out && !hold_rej;

    assign out_valid    = hold_out;
    assign reject_valid = hold_rej;
    assign out_cmd      = cmd_q;

    function automatic logic [REJ_W-1:0] evaluate(input cmd_t c);
        logic [REJ_W-1:0] r;
        logic [NOTIONAL_W-1:0] notion;
        logic signed [POS_W-1:0] hyp;
        logic signed [POS_W-1:0] dlt;
        r = REJ_NONE;
        if (!enable)
            r = REJ_DISABLED;
        else if (!c.crc_ok)
            r = REJ_CRC;
        else if (!(c.opcode inside {OP_NEW, OP_CANCEL, OP_REPLACE, OP_MODIFY,
                                    OP_STATUS, OP_MASS_CXL}))
            r = REJ_OPCODE;
        else if (c.inst >= INST_W'(NUM_INSTRUMENTS))
            r = REJ_INSTRUMENT;
        else if ((c.inst < INST_W'(NUM_INSTRUMENTS)) && !inst_mask[c.inst])
            r = REJ_INSTRUMENT;
        else if ((c.opcode == OP_NEW || c.opcode == OP_REPLACE ||
                  c.opcode == OP_MODIFY) && c.qty == '0 && c.opcode != OP_MODIFY)
            r = REJ_QTY;
        else if ((c.opcode == OP_NEW || c.opcode == OP_REPLACE) && c.price == '0)
            r = REJ_PRICE;
        else if (c.opcode == OP_NEW || c.opcode == OP_REPLACE) begin
            notion = notional_of(c.qty, c.price);
            if (max_notional != '0 && notion > max_notional)
                r = REJ_RISK_NOTIONAL;
            else if (max_position != '0) begin
                dlt = (c.side == SIDE_BID) ? $signed(c.qty[POS_W-1:0])
                                           : -$signed(c.qty[POS_W-1:0]);
                hyp = pos[c.inst] + dlt;
                if (hyp > $signed({1'b0, max_position[POS_W-2:0]}) ||
                    hyp < -$signed({1'b0, max_position[POS_W-2:0]}))
                    r = REJ_RISK_POS;
            end
        end
        if (r == REJ_NONE && rate_limit != 16'h0 && tokens == 16'h0 &&
            c.opcode != OP_STATUS)
            r = REJ_RATE;
        return r;
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < NUM_INSTRUMENTS; i++)
                pos[i] <= '0;
            tokens   <= 16'h0;
            wnd_cnt  <= 16'h0;
            hold_out <= 1'b0;
            hold_rej <= 1'b0;
            reject_code <= REJ_NONE;
            cmd_q    <= '0;
        end else if (soft_rst) begin
            for (i = 0; i < NUM_INSTRUMENTS; i++)
                pos[i] <= '0;
            tokens   <= rate_limit;
            wnd_cnt  <= 16'h0;
            hold_out <= 1'b0;
            hold_rej <= 1'b0;
        end else begin
            // token bucket: refill `rate_limit` tokens every window
            if (rate_limit == 16'h0) begin
                tokens  <= 16'h0;
                wnd_cnt <= 16'h0;
            end else begin
                if (wnd_cnt + 16'd1 >= wnd_lim) begin
                    wnd_cnt <= 16'h0;
                    tokens  <= rate_limit;
                end else
                    wnd_cnt <= wnd_cnt + 16'd1;
            end

            if (pos_we && pos_inst < INST_W'(NUM_INSTRUMENTS))
                pos[pos_inst] <= pos[pos_inst] + pos_delta;

            if (hold_out && out_ready)
                hold_out <= 1'b0;
            if (hold_rej && out_ready)
                hold_rej <= 1'b0;

            if (take) begin
                rej   = evaluate(cmd);
                cmd_q = cmd;
                if (stp_en && cmd.stp == STP_OFF)
                    cmd_q.stp = stp_mode;
                if (rej != REJ_NONE) begin
                    hold_rej    <= 1'b1;
                    reject_code <= rej;
                    hold_out    <= 1'b0;
                end else begin
                    hold_out    <= 1'b1;
                    hold_rej    <= 1'b0;
                    reject_code <= REJ_NONE;
                    if (rate_limit != 16'h0 && tokens != 16'h0 &&
                        cmd.opcode != OP_STATUS)
                        tokens <= tokens - 16'd1;
                end
            end
        end
    end

endmodule
