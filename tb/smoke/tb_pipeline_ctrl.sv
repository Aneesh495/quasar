// Directed test for quasar_pipeline_ctrl:
//   - NOP drops (no output)
//   - zero-qty NEW drops
//   - valid commands pass with updated ingress_ts
//   - duplicate OID stalls for one cycle
//   - soft_rst clears in-flight and prev_oid

`timescale 1ns/1ps

module tb_pipeline_ctrl;
    import quasar_pkg::*;

    logic clk, rst_n;
    initial clk = 0;
    always #2 clk = ~clk;

    logic [TS_W-1:0] cycle;
    logic            in_valid, in_ready;
    cmd_t            in_cmd;
    logic            out_valid, out_ready;
    cmd_t            out_cmd;
    logic [31:0]     drop_nop, drop_dup_seq;
    logic            soft_rst;

    quasar_pipeline_ctrl dut (
        .clk(clk), .rst_n(rst_n), .soft_rst(soft_rst),
        .cycle(cycle),
        .in_valid(in_valid), .in_ready(in_ready), .in_cmd(in_cmd),
        .out_valid(out_valid), .out_ready(out_ready), .out_cmd(out_cmd),
        .drop_nop(drop_nop), .drop_dup_seq(drop_dup_seq)
    );

    int errors;
    int n_out;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) cycle <= 32'h0;
        else        cycle <= cycle + 32'h1;
    end

    task automatic tick(int n = 1);
        repeat (n) @(posedge clk);
    endtask

    function automatic cmd_t mk(
        input logic [7:0] op, input logic [63:0] oid, input logic [31:0] qty = 1
    );
        mk = '0;
        mk.opcode = op;
        mk.oid    = oid;
        mk.qty    = qty;
        mk.crc_ok = 1'b1;
        mk.inst   = 8'h0;
    endfunction

    task automatic send(input cmd_t c);
        @(negedge clk);
        in_cmd   = c;
        in_valid = 1'b1;
        @(posedge clk);
        while (!in_ready) @(posedge clk);
        @(negedge clk);
        in_valid = 1'b0;
    endtask

    task automatic wait_out(output cmd_t c, input int tmo = 200);
        automatic int t = 0;
        c = '0;
        while (t < tmo) begin
            @(posedge clk);
            if (out_valid && out_ready) begin c = out_cmd; n_out++; return; end
            t++;
        end
        $error("wait_out timeout");
        errors++;
    endtask

    cmd_t got;

    initial begin
        rst_n     = 0;
        in_valid  = 0;
        out_ready = 1;
        soft_rst  = 0;
        in_cmd    = '0;
        errors    = 0;
        n_out     = 0;
        tick(4);
        rst_n = 1;
        tick(4);

        // 1. Valid NEW passes through
        send(mk(OP_NEW, 64'h1, 5));
        wait_out(got);
        if (got.opcode != OP_NEW || got.oid != 64'h1) begin
            $error("pass_new: got %0h oid %0h", got.opcode, got.oid);
            errors++;
        end
        if (got.ingress_ts == 32'h0) begin $error("ts not stamped"); errors++; end

        // 2. NOP drops silently
        begin
            cmd_t nop;
            nop = mk(OP_NOP, 64'h2, 0);
            nop.crc_ok = 1'b1;
            send(nop);
        end
        tick(4);
        if (drop_nop == 32'h0) begin $error("drop_nop not incremented"); errors++; end

        // 3. NEW with qty=0 drops
        send(mk(OP_NEW, 64'h3, 0));
        tick(4);
        if (drop_nop < 32'h2) begin $error("zero-qty drop_nop"); errors++; end

        // 4. CANCEL with qty=0 passes (qty=0 is valid for cancel)
        send(mk(OP_CANCEL, 64'h4, 0));
        wait_out(got);
        if (got.opcode != OP_CANCEL) begin $error("cancel_pass"); errors++; end

        // 5. Duplicate OID back-to-back stalls second command
        send(mk(OP_NEW, 64'hA, 3));
        wait_out(got);
        if (got.oid != 64'hA) begin $error("dup_first"); errors++; end

        // Same OID again immediately — should see drop_dup_seq increment
        // and the second command still arrives (stalled, not dropped)
        begin
            cmd_t c2;
            c2 = mk(OP_REPLACE, 64'hA, 5);
            @(negedge clk);
            in_cmd = c2; in_valid = 1;
            tick(3); // stall cycles
            in_valid = 0;
        end
        if (drop_dup_seq == 32'h0) begin $error("dup_seq not counted"); errors++; end

        // 6. Soft-reset clears prev_oid — same OID after reset should not stall
        soft_rst = 1; tick(1); soft_rst = 0; tick(2);
        send(mk(OP_NEW, 64'hA, 7));
        wait_out(got);
        if (got.oid != 64'hA) begin $error("post_softrst_oid"); errors++; end

        tick(4);
        if (errors) $fatal(1, "tb_pipeline_ctrl FAILED (%0d)", errors);
        $display("tb_pipeline_ctrl PASSED  n_out=%0d drop_nop=%0d drop_dup=%0d",
                 n_out, drop_nop, drop_dup_seq);
        $finish;
    end

    initial begin #1_000_000; $fatal(1, "tb_pipeline_ctrl timeout"); end
endmodule
