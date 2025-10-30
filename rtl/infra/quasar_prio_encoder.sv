// =============================================================================
// MSB-first and LSB-first priority encoders.  BBO tracking uses the MSB-first
// flavour on a price bitmap (highest set bit = best bid).  Also exported as
// a find-first-set used by free-list fallback scans.
// =============================================================================

module quasar_prio_encoder #(
    parameter int N        = 64,
    parameter bit MSB_FIRST = 1'b1
) (
    input  logic [N-1:0]           bits,
    output logic                   valid,
    output logic [$clog2(N)-1:0]   index
);

    localparam int IW = $clog2(N);

    always_comb begin
        valid = |bits;
        index = '0;
        if (MSB_FIRST) begin
            for (int i = N-1; i >= 0; i--) begin
                if (bits[i]) begin
                    index = IW'(i);
                    break;
                end
            end
        end else begin
            for (int i = 0; i < N; i++) begin
                if (bits[i]) begin
                    index = IW'(i);
                    break;
                end
            end
        end
    end

endmodule
