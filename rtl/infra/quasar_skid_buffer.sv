// =============================================================================
// 2-deep skid buffer: decouples valid/ready so a downstream stall never
// combinationally back-propagates onto the upstream ready.  Standard
// registered-ready cut used on every AXI-Stream hop in Quasar.
// =============================================================================

module quasar_skid_buffer #(
    parameter int WIDTH = 32
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

    logic             buf_valid;
    logic [WIDTH-1:0] buf_data;

    // Ready when we have a free slot in the skid flop.
    assign s_ready = !buf_valid;
    assign m_valid = s_valid || buf_valid;
    assign m_data  = buf_valid ? buf_data : s_data;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            buf_valid <= 1'b0;
            buf_data  <= '0;
        end else begin
            if (s_valid && s_ready && !m_ready) begin
                buf_valid <= 1'b1;
                buf_data  <= s_data;
            end else if (m_ready) begin
                buf_valid <= 1'b0;
            end
        end
    end

`ifdef QUASAR_SVA
    property p_no_x_valid;
        @(posedge clk) disable iff (!rst_n)
            !$isunknown(s_valid) && !$isunknown(m_ready);
    endproperty
    assert property (p_no_x_valid);

    property p_hold_data;
        @(posedge clk) disable iff (!rst_n)
            (m_valid && !m_ready) |=> $stable(m_data);
    endproperty
    assert property (p_hold_data);
`endif

endmodule
