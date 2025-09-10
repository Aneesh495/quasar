// =============================================================================
// Optional valid/ready pipeline register.  BYPASS=1 is a wire.  BYPASS=0
// inserts a skid-backed cut so timing can be closed between stages without
// changing functional latency of ready (only valid is registered).
// =============================================================================

module quasar_pipe_reg #(
    parameter int WIDTH  = 32,
    parameter bit BYPASS = 1'b0
) (
    input  logic             clk,
    input  logic             rst_n,
    input  logic             s_valid,
    output logic             s_ready,
    input  logic [WIDTH-1:0] s_data,
    output logic             m_valid,
    input  logic             m_ready,
    output logic [WIDTH-1:0] m_data
);

    if (BYPASS) begin : g_bypass
        assign m_valid = s_valid;
        assign s_ready = m_ready;
        assign m_data  = s_data;
    end else begin : g_cut
        logic             v_q;
        logic [WIDTH-1:0] d_q;
        assign s_ready = !v_q || m_ready;
        assign m_valid = v_q;
        assign m_data  = d_q;
        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                v_q <= 1'b0;
                d_q <= '0;
            end else if (s_ready) begin
                v_q <= s_valid;
                if (s_valid)
                    d_q <= s_data;
            end
        end
    end

endmodule
