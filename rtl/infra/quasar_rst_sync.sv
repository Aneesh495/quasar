// =============================================================================
// Asynchronous assert, synchronous deassert reset synchronizer.  One per
// clock domain; the SoC OR-reduces the external reset with CSR soft-reset
// before feeding this block.
// =============================================================================

module quasar_rst_sync #(
    parameter int STAGES = 3
) (
    input  logic clk,
    input  logic async_rst_n,
    output logic rst_n
);

    logic [STAGES-1:0] sh;

    always_ff @(posedge clk or negedge async_rst_n) begin
        if (!async_rst_n)
            sh <= '0;
        else
            sh <= {sh[STAGES-2:0], 1'b1};
    end

    assign rst_n = sh[STAGES-1];

endmodule
