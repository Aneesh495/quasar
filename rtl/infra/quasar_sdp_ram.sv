// =============================================================================
// Simple dual-port RAM (1W + 1R), 1-cycle read latency, no-change on
// collision (write-first optional).  Inferred as BRAM on Xilinx / Agilex.
// =============================================================================

module quasar_sdp_ram #(
    parameter int WIDTH      = 32,
    parameter int DEPTH      = 256,
    parameter bit WRITE_FIRST = 1'b1
) (
    input  logic                     clk,
    input  logic                     we,
    input  logic [$clog2(DEPTH)-1:0] waddr,
    input  logic [WIDTH-1:0]         wdata,
    input  logic                     re,
    input  logic [$clog2(DEPTH)-1:0] raddr,
    output logic [WIDTH-1:0]         rdata
);

    logic [WIDTH-1:0] mem [0:DEPTH-1];

    always_ff @(posedge clk) begin
        if (we)
            mem[waddr] <= wdata;
        if (re) begin
            if (WRITE_FIRST && we && (waddr == raddr))
                rdata <= wdata;
            else
                rdata <= mem[raddr];
        end
    end

endmodule
