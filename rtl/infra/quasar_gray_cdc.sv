// =============================================================================
// Gray-code pointer CDC.  wr_bin lives in src_clk, is gray-encoded, double-
// flopped into dst_clk, then decoded.  Used by the async FIFO and by any
// sparse status bit that must cross clk_axis ↔ clk_core.
//
// Formal note: WIDTH must be the binary pointer width including the wrap bit
// (AW+1 for a DEPTH=2^AW FIFO).
// =============================================================================

module quasar_gray_cdc #(
    parameter int WIDTH = 5
) (
    input  logic             src_clk,
    input  logic             src_rst_n,
    input  logic [WIDTH-1:0] src_bin,

    input  logic             dst_clk,
    input  logic             dst_rst_n,
    output logic [WIDTH-1:0] dst_bin,
    output logic [WIDTH-1:0] dst_gray
);

    function automatic logic [WIDTH-1:0] bin2gray(input logic [WIDTH-1:0] b);
        bin2gray = b ^ {1'b0, b[WIDTH-1:1]};
    endfunction

    function automatic logic [WIDTH-1:0] gray2bin(input logic [WIDTH-1:0] g);
        logic [WIDTH-1:0] b;
        b[WIDTH-1] = g[WIDTH-1];
        for (int i = WIDTH-2; i >= 0; i--)
            b[i] = b[i+1] ^ g[i];
        gray2bin = b;
    endfunction

    logic [WIDTH-1:0] src_gray, dst_gray_m, dst_gray_q;

    always_ff @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n)
            src_gray <= '0;
        else
            src_gray <= bin2gray(src_bin);
    end

    always_ff @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            dst_gray_m <= '0;
            dst_gray_q <= '0;
        end else begin
            dst_gray_m <= src_gray;
            dst_gray_q <= dst_gray_m;
        end
    end

    assign dst_gray = dst_gray_q;
    assign dst_bin  = gray2bin(dst_gray_q);

endmodule
