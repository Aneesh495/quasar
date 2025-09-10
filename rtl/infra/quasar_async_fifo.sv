// =============================================================================
// Dual-clock FWFT FIFO.  Gray-coded pointers, two-flop synchronizers, power-
// of-two depth.  Even when smoke simulation ties both clocks together this
// path is the production CDC between clk_axis_in / clk_core / clk_axis_out.
//
// Constraints (implementation):
//   set_max_delay / set_false_path on the gray buses (single-bit-at-a-time
//   change is the safety property; see docs/architecture.md).
// =============================================================================

module quasar_async_fifo #(
    parameter int WIDTH = 32,
    parameter int DEPTH = 16   // must be power of two
) (
    input  logic             wr_clk,
    input  logic             wr_rst_n,
    input  logic             wr_en,
    input  logic [WIDTH-1:0] wr_data,
    output logic             wr_full,
    output logic             wr_almost_full,

    input  logic             rd_clk,
    input  logic             rd_rst_n,
    input  logic             rd_en,
    output logic [WIDTH-1:0] rd_data,
    output logic             rd_empty,

    output logic [31:0]      wr_drop_count
);

    localparam int AW = $clog2(DEPTH);

    logic [WIDTH-1:0] mem [0:DEPTH-1];

    logic [AW:0] wr_bin, rd_bin;
    logic [AW:0] wr_bin_n, rd_bin_n;
    logic [AW:0] wr_bin_in_rd, rd_bin_in_wr;
    logic [AW:0] wr_gray_unused, rd_gray_unused;

    logic do_wr, do_rd;

    assign do_wr = wr_en && !wr_full;
    assign do_rd = rd_en && !rd_empty;

    always_comb begin
        wr_bin_n = wr_bin + (do_wr ? (AW+1)'(1) : '0);
        rd_bin_n = rd_bin + (do_rd ? (AW+1)'(1) : '0);
    end

    always_ff @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_bin         <= '0;
            wr_drop_count  <= 32'h0;
        end else begin
            wr_bin <= wr_bin_n;
            if (wr_en && wr_full)
                wr_drop_count <= wr_drop_count + 32'h1;
        end
    end

    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n)
            rd_bin <= '0;
        else
            rd_bin <= rd_bin_n;
    end

    always_ff @(posedge wr_clk) begin
        if (do_wr)
            mem[wr_bin[AW-1:0]] <= wr_data;
    end

    assign rd_data = mem[rd_bin[AW-1:0]];

    quasar_gray_cdc #(.WIDTH(AW+1)) u_w2r (
        .src_clk  (wr_clk),
        .src_rst_n(wr_rst_n),
        .src_bin  (wr_bin),
        .dst_clk  (rd_clk),
        .dst_rst_n(rd_rst_n),
        .dst_bin  (wr_bin_in_rd),
        .dst_gray (wr_gray_unused)
    );

    quasar_gray_cdc #(.WIDTH(AW+1)) u_r2w (
        .src_clk  (rd_clk),
        .src_rst_n(rd_rst_n),
        .src_bin  (rd_bin),
        .dst_clk  (wr_clk),
        .dst_rst_n(wr_rst_n),
        .dst_bin  (rd_bin_in_wr),
        .dst_gray (rd_gray_unused)
    );

    // Full when next write would collide with the synced read pointer.
    wire [AW:0] wr_next = wr_bin + (AW+1)'(1);
    assign wr_full = (wr_next[AW] != rd_bin_in_wr[AW]) &&
                     (wr_next[AW-1:0] == rd_bin_in_wr[AW-1:0]);
    assign wr_almost_full = wr_full ||
        ((wr_bin + (AW+1)'(2)) - rd_bin_in_wr) >= (AW+1)'(DEPTH);

    assign rd_empty = (rd_bin == wr_bin_in_rd);

endmodule
