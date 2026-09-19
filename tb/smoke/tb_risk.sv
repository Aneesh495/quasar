// =============================================================================
// Risk gate directed test.
// Drives quasar_risk_gate directly and verifies every rejection code.
// =============================================================================

`timescale 1ns/1ps

module tb_risk;
    import quasar_pkg::*;

    logic clk, rst_n;
    initial clk = 0;
    always #2 clk = ~clk;

    logic          enable;
    logic [NUM_INSTRUMENTS-1:0] inst_mask;
    logic [NOTIONAL_W-1:0] max_notional;
    logic [POS_W-1:0]      max_position;
    logic [15:0]           rate_limit, rate_window;
    logic                  stp_en;
    logic [1:0]            stp_mode;
    logic                  soft_rst;

    logic          cmd_valid, cmd_ready;
    cmd_t          cmd;
    logic          out_valid, out_ready;
    cmd_t          out_cmd;
    logic          rej_valid;
    logic [REJ_W-1:0] rej_code;
    logic          pos_we;
    logic [INST_W-1:0] pos_inst;
    logic signed [POS_W-1:0] pos_delta;
    logic signed [POS_W-1:0] position [NUM_INSTRUMENTS-1:0];
    logic [15:0]   tokens_left;

    quasar_risk_gate u_risk (
        .clk(clk), .rst_n(rst_n), .soft_rst(soft_rst),
        .enable(enable),
        .inst_mask(inst_mask),
        .max_notional(max_notional),
        .max_position(max_position),
        .rate_limit(rate_limit),
        .rate_window(rate_window),
        .stp_en(stp_en),
        .stp_mode(stp_mode),
        .cmd_valid(cmd_valid),
        .cmd_ready(cmd_ready),
        .cmd(cmd),
        .out_valid(out_valid),
        .out_ready(out_ready),
        .out_cmd(out_cmd),
        .reject_valid(rej_valid),
        .reject_code(rej_code),
        .pos_we(pos_we),
        .pos_inst(pos_inst),
        .pos_delta(pos_delta),
        .position(position),
        .tokens_left(tokens_left)
    );

    int errors;
    assign out_ready = 1'b1;

    // Monitor thread: push all outputs to queues
    logic [REJ_W-1:0] rq [$];
    cmd_t             pq [$];

    initial forever begin
        @(posedge clk);
        if (rej_valid) rq.push_back(rej_code);
        if (out_valid) pq.push_back(out_cmd);
    end

    function automatic cmd_t mk_cmd(
        input logic [7:0] op, input logic [7:0] inst, input logic [7:0] firm,
        input logic side, input logic [31:0] qty, input logic [31:0] price,
        input logic [63:0] oid, input logic crc_ok_in = 1'b1
    );
        mk_cmd = '0;
        mk_cmd.opcode = op;
        mk_cmd.inst   = inst;
        mk_cmd.firm   = firm;
        mk_cmd.side   = side;
        mk_cmd.qty    = qty;
        mk_cmd.price  = price;
        mk_cmd.oid    = oid;
        mk_cmd.crc_ok = crc_ok_in;
        mk_cmd.tif    = TIF_GTC;
    endfunction

    task automatic send_cmd(input cmd_t c);
        @(negedge clk);
        cmd       = c;
        cmd_valid = 1'b1;
        @(posedge clk);
        while (!cmd_ready) @(posedge clk);
        @(negedge clk);
        cmd_valid = 1'b0;
    endtask

    task automatic wait_rej(output logic [REJ_W-1:0] code, input int tmo = 500);
        automatic int t = 0;
        while (rq.size() == 0 && t < tmo) begin @(posedge clk); t++; end
        if (rq.size() > 0) code = rq.pop_front();
        else begin $error("wait_rej timeout"); errors++; code = REJ_NONE; end
    endtask

    task automatic wait_pass(output cmd_t c, input int tmo = 500);
        automatic int t = 0;
        while (pq.size() == 0 && t < tmo) begin @(posedge clk); t++; end
        if (pq.size() > 0) c = pq.pop_front();
        else begin $error("wait_pass timeout"); errors++; c = '0; end
    endtask

    task automatic check_rej(input string tag, input logic [REJ_W-1:0] got,
                              input logic [REJ_W-1:0] want);
        if (got !== want) begin
            $error("%s: rej_code=%0d want=%0d", tag, got, want);
            errors++;
        end
    endtask

    logic [REJ_W-1:0] code;
    cmd_t c_out;

    initial begin
        rst_n       = 0;
        cmd_valid   = 0;
        soft_rst    = 0;
        enable      = 0;
        inst_mask   = 8'hFF;
        max_notional= 0;
        max_position= 0;
        rate_limit  = 0;
        rate_window = 0;
        stp_en      = 0;
        stp_mode    = STP_OFF;
        errors      = 0;
        repeat(4) @(posedge clk);
        rst_n = 1;
        repeat(4) @(posedge clk);

        // 1. Disabled
        send_cmd(mk_cmd(OP_NEW, 0, 1, SIDE_BID, 1, 10, 64'h1));
        wait_rej(code);
        check_rej("disabled", code, REJ_DISABLED);
        enable = 1'b1;
        repeat(2) @(posedge clk);

        // 2. CRC fail
        send_cmd(mk_cmd(OP_NEW, 0, 1, SIDE_BID, 1, 10, 64'h2, 1'b0));
        wait_rej(code);
        check_rej("crc", code, REJ_CRC);

        // 3. Unknown opcode
        send_cmd(mk_cmd(8'hAA, 0, 1, SIDE_BID, 1, 10, 64'h3));
        wait_rej(code);
        check_rej("opcode", code, REJ_OPCODE);

        // 4. Instrument out-of-range
        send_cmd(mk_cmd(OP_NEW, 8'h10, 1, SIDE_BID, 1, 10, 64'h4));
        wait_rej(code);
        check_rej("inst_oob", code, REJ_INSTRUMENT);

        // 5. Instrument masked
        inst_mask = 8'h01;
        send_cmd(mk_cmd(OP_NEW, 1, 1, SIDE_BID, 1, 10, 64'h5));
        wait_rej(code);
        check_rej("inst_mask", code, REJ_INSTRUMENT);
        inst_mask = 8'hFF;

        // 6. Zero qty on NEW
        send_cmd(mk_cmd(OP_NEW, 0, 1, SIDE_BID, 0, 10, 64'h6));
        wait_rej(code);
        check_rej("qty0", code, REJ_QTY);

        // 7. Zero price on NEW
        send_cmd(mk_cmd(OP_NEW, 0, 1, SIDE_BID, 5, 0, 64'h7));
        wait_rej(code);
        check_rej("price0", code, REJ_PRICE);

        // 8. Max notional
        max_notional = 64'd100;
        send_cmd(mk_cmd(OP_NEW, 0, 1, SIDE_BID, 5, 30, 64'h8)); // 150 > 100
        wait_rej(code);
        check_rej("notional", code, REJ_RISK_NOTIONAL);
        max_notional = 64'd0;

        // 9. Position limit
        max_position = 32'd4;
        send_cmd(mk_cmd(OP_NEW, 0, 1, SIDE_BID, 5, 1, 64'h9)); // +5 > 4
        wait_rej(code);
        check_rej("pos", code, REJ_RISK_POS);
        max_position = 32'd0;

        // 10. Rate limit: set short window so tokens refill quickly
        rate_limit  = 16'd2;
        rate_window = 16'd4;    // window = 4 cycles → refill every 4 cycles
        // Soft-reset to load tokens immediately
        soft_rst = 1'b1;
        @(posedge clk);
        soft_rst = 1'b0;
        repeat(2) @(posedge clk);
        // Two NEW commands consume both tokens and pass
        send_cmd(mk_cmd(OP_NEW, 0, 1, SIDE_BID, 1, 1, 64'hA1));
        wait_pass(c_out);
        send_cmd(mk_cmd(OP_NEW, 0, 1, SIDE_BID, 1, 1, 64'hA2));
        wait_pass(c_out);
        // Third NEW should be rate-rejected (no tokens left until next window)
        send_cmd(mk_cmd(OP_NEW, 0, 1, SIDE_BID, 1, 1, 64'hA3));
        wait_rej(code);
        check_rej("rate", code, REJ_RATE);
        rate_limit = 16'd0;
        rate_window = 16'd0;

        // 11. STP injection
        stp_en   = 1'b1;
        stp_mode = STP_CANCEL_RESTING;
        begin
            cmd_t ci;
            ci = mk_cmd(OP_NEW, 0, 1, SIDE_BID, 1, 1, 64'hB1);
            ci.stp = STP_OFF;
            send_cmd(ci);
        end
        wait_pass(c_out);
        if (c_out.stp !== STP_CANCEL_RESTING) begin
            $error("stp_inject got %0h", c_out.stp);
            errors++;
        end
        stp_en = 1'b0;

        // 12. Cancel and modify pass through
        send_cmd(mk_cmd(OP_CANCEL, 0, 1, SIDE_BID, 0, 0, 64'hC1));
        wait_pass(c_out);
        if (c_out.opcode !== OP_CANCEL) begin $error("cxl_pass"); errors++; end

        send_cmd(mk_cmd(OP_MODIFY, 0, 1, SIDE_ASK, 5, 0, 64'hC2));
        wait_pass(c_out);
        if (c_out.opcode !== OP_MODIFY) begin $error("mod_pass"); errors++; end

        repeat(4) @(posedge clk);
        if (errors) $fatal(1, "tb_risk FAILED (%0d)", errors);
        $display("tb_risk PASSED");
        $finish;
    end

    initial begin #2_000_000; $fatal(1, "tb_risk timeout"); end
endmodule
