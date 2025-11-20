// =============================================================================
// Pipeline flow controller
//
// A thin register stage between the command FIFO and the risk gate that
// provides:
//   1. Command coalescing: a NOP or zero-qty command is dropped here
//      before consuming a risk-gate slot.
//   2. OID sequence validation: detects duplicate OIDs in consecutive
//      commands (same-cycle replace-then-new race from a buggy upstream)
//      and stalls the second command for one cycle.
//   3. Soft-reset synchronisation: ensures the risk gate sees a clean
//      command boundary — no command is in-flight when soft_rst propagates.
//   4. Latency tagging: stamps ingress_ts on every command that passes,
//      using the core cycle counter, so downstream latency tracking is
//      authoritative.
//
// This module is purely combinational + one pipeline register.  It does
// not add to the critical path if retimed properly; it is the natural place
// to put any future command preprocessing (e.g., per-firm priority shaping).
// =============================================================================

module quasar_pipeline_ctrl
    import quasar_pkg::*;
(
    input  logic         clk,
    input  logic         rst_n,
    input  logic         soft_rst,
    input  logic [TS_W-1:0] cycle,

    input  logic         in_valid,
    output logic         in_ready,
    input  cmd_t         in_cmd,

    output logic         out_valid,
    input  logic         out_ready,
    output cmd_t         out_cmd,

    output logic [31:0]  drop_nop,
    output logic [31:0]  drop_dup_seq
);

    logic        pass_through;
    logic        stall_dup;
    logic [63:0] prev_oid;
    logic        prev_oid_valid;

    // A command is dropped here if:
    //  - it is OP_NOP
    //  - it has qty==0 AND opcode is NEW (not CANCEL/MODIFY where qty=0 is valid)
    wire drop_cmd = in_valid && (
        in_cmd.opcode == OP_NOP ||
        (in_cmd.opcode == OP_NEW && in_cmd.qty == '0 && in_cmd.crc_ok)
    );

    // Stall for one cycle if same OID appears back-to-back (replace race)
    assign stall_dup = in_valid && prev_oid_valid &&
                       (in_cmd.oid == prev_oid) &&
                       (in_cmd.opcode == OP_NEW || in_cmd.opcode == OP_REPLACE) &&
                       !soft_rst;

    assign pass_through = in_valid && !drop_cmd && !stall_dup;
    assign in_ready     = out_ready && !stall_dup;

    cmd_t cmd_q;
    logic v_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_q           <= 1'b0;
            cmd_q         <= '0;
            prev_oid      <= '0;
            prev_oid_valid <= 1'b0;
            drop_nop      <= 32'h0;
            drop_dup_seq  <= 32'h0;
        end else if (soft_rst) begin
            v_q            <= 1'b0;
            prev_oid_valid <= 1'b0;
        end else begin
            if (out_ready || !v_q) begin
                v_q   <= pass_through;
                if (pass_through) begin
                    cmd_q              = in_cmd;
                    cmd_q.ingress_ts   = cycle;
                    cmd_q              = cmd_q;
                end
            end

            if (in_valid && drop_cmd)
                drop_nop <= drop_nop + 32'd1;
            if (stall_dup)
                drop_dup_seq <= drop_dup_seq + 32'd1;

            if (pass_through) begin
                prev_oid       <= in_cmd.oid;
                prev_oid_valid <= 1'b1;
            end else if (!in_valid)
                prev_oid_valid <= 1'b0;
        end
    end

    assign out_valid = v_q;
    assign out_cmd   = cmd_q;

`ifdef QUASAR_SVA
    property p_no_nop_out;
        @(posedge clk) disable iff (!rst_n)
            (out_valid && out_ready) |-> (out_cmd.opcode != OP_NOP);
    endproperty
    a_no_nop: assert property (p_no_nop_out);

    property p_ts_set;
        @(posedge clk) disable iff (!rst_n)
            (out_valid) |-> (out_cmd.ingress_ts != '0 || cycle == '0);
    endproperty
    a_ts: assert property (p_ts_set);
`endif

endmodule
