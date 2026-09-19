// =============================================================================
// Pointer free list.  Initialized 0..N-1 on reset.  pop/push are mutually
// exclusive in the book FSM (the book never allocates and frees in the same
// cycle), which keeps this a cheap FWFT stack/FIFO of pointers.
// =============================================================================

module quasar_free_list #(
    parameter int N     = 256,
    parameter int PTR_W = 9
) (
    input  logic             clk,
    input  logic             rst_n,
    input  logic             pop,
    output logic [PTR_W-1:0] pop_ptr,
    output logic             empty,
    input  logic             push,
    input  logic [PTR_W-1:0] push_ptr,
    output logic             full,
    output logic [15:0]      used
);

    localparam int AW = $clog2(N);

    logic [PTR_W-1:0] mem [0:N-1];
    logic [AW:0]      wr_ptr, rd_ptr;
    logic             do_pop, do_push;

    assign do_pop  = pop  && !empty;
    assign do_push = push && !full;
    assign empty   = (wr_ptr == rd_ptr);
    assign full    = (wr_ptr[AW] != rd_ptr[AW]) && (wr_ptr[AW-1:0] == rd_ptr[AW-1:0]);
    assign pop_ptr = mem[rd_ptr[AW-1:0]];
    assign used    = 16'(N) - 16'(wr_ptr - rd_ptr);

    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= (AW+1)'(N);   // pre-filled 0..N-1
            rd_ptr <= '0;
            for (i = 0; i < N; i++)
                mem[i] = PTR_W'(i);
        end else begin
            if (do_pop)
                rd_ptr <= rd_ptr + (AW+1)'(1);
            if (do_push) begin
                mem[wr_ptr[AW-1:0]] <= push_ptr;
                wr_ptr <= wr_ptr + (AW+1)'(1);
            end
        end
    end

`ifdef QUASAR_SVA
    property p_no_double_pop;
        @(posedge clk) disable iff (!rst_n)
            !(pop && empty);
    endproperty
    assert property (p_no_double_pop);
`endif

endmodule
