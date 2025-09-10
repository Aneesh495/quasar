// =============================================================================
// Synchronous FWFT FIFO with occupancy, almost-full, and drop-on-full option.
// Pointers are extra-wide so full/empty decode as classic MSB-xor.
// =============================================================================

module quasar_sync_fifo #(
    parameter int WIDTH      = 32,
    parameter int DEPTH      = 16,
    parameter bit FWFT       = 1'b1,
    parameter bit DROP_ON_FULL = 1'b0
) (
    input  logic             clk,
    input  logic             rst_n,

    input  logic             wr_en,
    input  logic [WIDTH-1:0] wr_data,
    output logic             full,
    output logic             almost_full,

    input  logic             rd_en,
    output logic [WIDTH-1:0] rd_data,
    output logic             empty,

    output logic [$clog2(DEPTH+1)-1:0] count,
    output logic [31:0]      drop_count
);

    localparam int AW = $clog2(DEPTH);

    logic [WIDTH-1:0] mem [0:DEPTH-1];
    logic [AW:0]      wr_ptr, rd_ptr;
    logic [AW:0]      wr_ptr_n, rd_ptr_n;
    logic             do_wr, do_rd;

    // When DROP_ON_FULL and full, we neither write nor increment — just count drop.
    wire drop_now = wr_en && full && DROP_ON_FULL;

    always_comb begin
        do_wr    = wr_en && !full;
        do_rd    = rd_en && !empty;
        wr_ptr_n = wr_ptr + (do_wr ? (AW+1)'(1) : '0);
        rd_ptr_n = rd_ptr + (do_rd ? (AW+1)'(1) : '0);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr     <= '0;
            rd_ptr     <= '0;
            drop_count <= 32'h0;
        end else begin
            wr_ptr <= wr_ptr_n;
            rd_ptr <= rd_ptr_n;
            if (drop_now)
                drop_count <= drop_count + 32'h1;
        end
    end

    always_ff @(posedge clk) begin
        if (do_wr)
            mem[wr_ptr[AW-1:0]] <= wr_data;
    end

    if (FWFT) begin : g_fwft
        assign rd_data = mem[rd_ptr[AW-1:0]];
    end else begin : g_std
        logic [WIDTH-1:0] rd_q;
        always_ff @(posedge clk) begin
            if (do_rd)
                rd_q <= mem[rd_ptr[AW-1:0]];
        end
        assign rd_data = rd_q;
    end

    wire [AW:0] used = wr_ptr - rd_ptr;
    assign count  = used[$clog2(DEPTH+1)-1:0];
    assign empty  = (wr_ptr == rd_ptr);
    assign full   = (wr_ptr[AW] != rd_ptr[AW]) && (wr_ptr[AW-1:0] == rd_ptr[AW-1:0]);
    assign almost_full = (used >= (AW+1)'(DEPTH-2));

`ifdef QUASAR_SVA
    // No write when full (unless drop mode).
    property p_no_overflow;
        @(posedge clk) disable iff (!rst_n || DROP_ON_FULL)
            !(wr_en && full);
    endproperty
    assert property (p_no_overflow);

    property p_no_underflow;
        @(posedge clk) disable iff (!rst_n)
            !(rd_en && empty);
    endproperty
    assert property (p_no_underflow);

    property p_count_bound;
        @(posedge clk) disable iff (!rst_n)
            used <= (AW+1)'(DEPTH);
    endproperty
    assert property (p_count_bound);
`endif

endmodule
