// =============================================================================
// Saturating performance counter with optional increment-by-N and snapshot
// clear.  Used for orders/fills/rejects and for the latency accumulator.
// =============================================================================

module quasar_counter #(
    parameter int WIDTH      = 32,
    parameter bit SATURATE   = 1'b1
) (
    input  logic             clk,
    input  logic             rst_n,
    input  logic             clr,
    input  logic             inc,
    input  logic [WIDTH-1:0] add,     // ignored if USE_ADD=0
    input  logic             add_en,
    output logic [WIDTH-1:0] value
);

    parameter bit USE_ADD = 1'b1;

    logic [WIDTH:0] sum;

    always_comb begin
        sum = {1'b0, value};
        if (inc)
            sum = sum + (WIDTH+1)'(1);
        if (USE_ADD && add_en)
            sum = sum + {1'b0, add};
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            value <= '0;
        else if (clr)
            value <= '0;
        else if (inc || (USE_ADD && add_en)) begin
            if (SATURATE && sum[WIDTH])
                value <= {WIDTH{1'b1}};
            else
                value <= sum[WIDTH-1:0];
        end
    end

endmodule
