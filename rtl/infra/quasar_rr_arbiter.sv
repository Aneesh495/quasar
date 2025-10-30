// =============================================================================
// Round-robin arbiter with grant mask.  Used by the event-log mux and any
// future multi-source ingress.  Combinational grant, registered pointer.
// =============================================================================

module quasar_rr_arbiter #(
    parameter int N = 4
) (
    input  logic         clk,
    input  logic         rst_n,
    input  logic [N-1:0] req,
    input  logic         hold,          // freeze pointer (multi-beat)
    output logic [N-1:0] gnt,
    output logic         gnt_valid,
    output logic [$clog2(N)-1:0] gnt_idx
);

    logic [N-1:0] ptr, ptr_n;
    logic [N-1:0] mask_hi, mask_lo;
    logic [N-1:0] req_hi, req_lo;
    logic [N-1:0] gnt_hi, gnt_lo;

    assign mask_hi = ptr;
    assign mask_lo = ~ptr;
    assign req_hi  = req & mask_hi;
    assign req_lo  = req & mask_lo;

    // Priority-encode: lowest index wins within each half.
    always_comb begin
        gnt_lo = '0;
        gnt_hi = '0;
        for (int i = 0; i < N; i++) begin
            if (req_lo[i] && gnt_lo == '0)
                gnt_lo[i] = 1'b1;
            if (req_hi[i] && gnt_hi == '0)
                gnt_hi[i] = 1'b1;
        end
        if (gnt_hi != '0)
            gnt = gnt_hi;
        else
            gnt = gnt_lo;
        gnt_valid = |req;
        gnt_idx   = '0;
        for (int i = 0; i < N; i++) begin
            if (gnt[i])
                gnt_idx = $clog2(N)'(i);
        end
        // Next pointer: mask everything at or below the grant.
        ptr_n = ptr;
        if (gnt_valid && !hold) begin
            ptr_n = '0;
            if (gnt_idx + 1 < N)
                for (int i = 0; i < N; i++)
                    if (i > int'(gnt_idx))
                        ptr_n[i] = 1'b1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            ptr <= {N{1'b1}}; // start with full mask → index 0 first
        else
            ptr <= ptr_n;
    end

`ifdef QUASAR_SVA
    property p_onehot_gnt;
        @(posedge clk) disable iff (!rst_n)
            gnt_valid |-> $onehot(gnt);
    endproperty
    assert property (p_onehot_gnt);
`endif

endmodule
