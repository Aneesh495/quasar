// =============================================================================
// Ingress path
//
// AXI4-Stream slave (256-bit native) → CRC check → field decode → cmd FIFO.
// A 64-bit upsizer may sit in front (see quasar_axis_upsizer).  The parser
// is a small FSM so framing, CRC and opcode checks are explicit states
// rather than a cloud of combinational gates on tvalid.
//
// Backpressure: tready is deasserted when the cmd FIFO is almost full or
// the parser is sitting on a rejected beat that still needs an event.
// Framing / CRC failures generate a REJ_* command with crc_ok=0 so the
// risk/matcher path emits EV_REJECT without touching the book.
// =============================================================================

module quasar_ingress
    import quasar_pkg::*;
(
    input  logic         clk,
    input  logic         rst_n,

    input  logic         s_tvalid,
    output logic         s_tready,
    input  logic [AXIS_DATA_W-1:0] s_tdata,
    input  logic [AXIS_KEEP_W-1:0] s_tkeep,
    input  logic         s_tlast,
    input  logic         framing_err_i,

    output logic         cmd_valid,
    input  logic         cmd_ready,
    output cmd_t         cmd,

    output logic [31:0]  drop_count,
    output logic [31:0]  crc_fail_count,
    input  logic [TS_W-1:0] cycle
);

    typedef enum logic [2:0] {
        P_IDLE,
        P_CRC,
        P_DECODE,
        P_PUSH,
        P_DROP
    } pst_e;

    pst_e  pst, pst_n;
    msg_t  raw, raw_n;
    cmd_t  cmd_n, cmd_q;
    logic  cmd_v, cmd_v_n;
    logic  crc_ok, crc_ok_n;
    logic [31:0] crc_exp;
    logic [31:0] drop_n, crc_fail_n;
    logic [31:0] drop_q, crc_fail_q;

    logic [223:0] body;

    quasar_crc32_comb #(.N_BYTES(28)) u_crc (
        .data (body),
        .crc  (crc_exp)
    );

    assign body      = raw[223:0];
    assign s_tready  = (pst == P_IDLE);
    assign cmd_valid = cmd_v;
    assign cmd       = cmd_q;
    assign drop_count     = drop_q;
    assign crc_fail_count = crc_fail_q;

    function automatic logic keep_full(input logic [AXIS_KEEP_W-1:0] k);
        keep_full = &k;
    endfunction

    function automatic logic opcode_known(input logic [7:0] op);
        opcode_known = (op == OP_NOP) || (op == OP_NEW) || (op == OP_CANCEL) ||
                       (op == OP_REPLACE) || (op == OP_MODIFY) ||
                       (op == OP_STATUS) || (op == OP_MASS_CXL);
    endfunction

    always_comb begin
        pst_n      = pst;
        raw_n      = raw;
        cmd_n      = cmd_q;
        cmd_v_n    = cmd_v;
        crc_ok_n   = crc_ok;
        drop_n     = drop_q;
        crc_fail_n = crc_fail_q;

        if (cmd_v && cmd_ready)
            cmd_v_n = 1'b0;

        unique case (pst)
            P_IDLE: begin
                if (s_tvalid) begin
                    raw_n = msg_t'(s_tdata);
                    if (framing_err_i || !s_tlast || !keep_full(s_tkeep)) begin
                        drop_n = drop_q + 32'd1;
                        pst_n  = P_DROP;
                    end else
                        pst_n = P_CRC;
                end
            end

            P_CRC: begin
                crc_ok_n = (crc_exp == raw.crc32);
                if (crc_exp != raw.crc32)
                    crc_fail_n = crc_fail_q + 32'd1;
                pst_n = P_DECODE;
            end

            P_DECODE: begin
                cmd_n = msg_to_cmd(raw, cycle, crc_ok);
                if (raw.opcode == OP_NOP) begin
                    pst_n = P_IDLE;
                end else if (!opcode_known(raw.opcode)) begin
                    cmd_n.crc_ok = 1'b0; // force risk reject path
                    cmd_n.opcode = raw.opcode;
                    pst_n = P_PUSH;
                end else begin
                    pst_n = P_PUSH;
                end
            end

            P_PUSH: begin
                if (!cmd_v) begin
                    cmd_v_n = 1'b1;
                    pst_n   = P_IDLE;
                end else if (cmd_v && cmd_ready) begin
                    cmd_v_n = 1'b1;
                    pst_n   = P_IDLE;
                end
            end

            P_DROP: begin
                // synthesize a CRC/framing reject so the rest of the pipeline
                // still produces an EV_REJECT the scoreboard can see
                cmd_n = '0;
                cmd_n.opcode = OP_NEW;
                cmd_n.crc_ok = 1'b0;
                cmd_n.ingress_ts = cycle;
                if (!cmd_v) begin
                    cmd_v_n = 1'b1;
                    pst_n   = P_IDLE;
                end
            end

            default: pst_n = P_IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pst        <= P_IDLE;
            raw        <= '0;
            cmd_q      <= '0;
            cmd_v      <= 1'b0;
            crc_ok     <= 1'b0;
            drop_q     <= 32'h0;
            crc_fail_q <= 32'h0;
        end else begin
            pst        <= pst_n;
            raw        <= raw_n;
            cmd_q      <= cmd_n;
            cmd_v      <= cmd_v_n;
            crc_ok     <= crc_ok_n;
            drop_q     <= drop_n;
            crc_fail_q <= crc_fail_n;
        end
    end

endmodule
