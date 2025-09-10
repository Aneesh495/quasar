// =============================================================================
// AXI4-Stream width converters: 64-bit pin fabric ↔ 256-bit engine native.
// 4-beat frame, TLAST required on beat 3.  Framing errors raise err and
// drop the packet (ingress will emit REJ_CRC/framing via a sticky flag).
// =============================================================================

module quasar_axis_upsizer (
    input  logic         clk,
    input  logic         rst_n,

    input  logic         s_tvalid,
    output logic         s_tready,
    input  logic [63:0]  s_tdata,
    input  logic [7:0]   s_tkeep,
    input  logic         s_tlast,

    output logic         m_tvalid,
    input  logic         m_tready,
    output logic [255:0] m_tdata,
    output logic [31:0]  m_tkeep,
    output logic         m_tlast,
    output logic         framing_err
);

    logic [1:0]   beat;
    logic [255:0] acc;
    logic [31:0]  keep_acc;
    logic         have;

    assign s_tready = !have;
    assign m_tvalid = have;
    assign m_tdata  = acc;
    assign m_tkeep  = keep_acc;
    assign m_tlast  = 1'b1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            beat        <= 2'd0;
            acc         <= '0;
            keep_acc    <= '0;
            have        <= 1'b0;
            framing_err <= 1'b0;
        end else begin
            framing_err <= 1'b0;
            if (have && m_tready)
                have <= 1'b0;
            if (s_tvalid && s_tready) begin
                acc[beat*64 +: 64]      <= s_tdata;
                keep_acc[beat*8 +: 8]   <= s_tkeep;
                if (beat == 2'd3) begin
                    if (!s_tlast)
                        framing_err <= 1'b1;
                    have <= 1'b1;
                    beat <= 2'd0;
                end else begin
                    if (s_tlast)
                        framing_err <= 1'b1;
                    beat <= beat + 2'd1;
                end
            end
        end
    end

endmodule

module quasar_axis_downsizer (
    input  logic         clk,
    input  logic         rst_n,

    input  logic         s_tvalid,
    output logic         s_tready,
    input  logic [255:0] s_tdata,
    input  logic [31:0]  s_tkeep,
    input  logic         s_tlast,

    output logic         m_tvalid,
    input  logic         m_tready,
    output logic [63:0]  m_tdata,
    output logic [7:0]   m_tkeep,
    output logic         m_tlast
);

    logic             busy;
    logic [1:0]       beat;
    logic [255:0]     acc;
    logic [31:0]      keep_acc;

    assign s_tready = !busy;
    assign m_tvalid = busy;
    assign m_tdata  = acc[beat*64 +: 64];
    assign m_tkeep  = keep_acc[beat*8 +: 8];
    assign m_tlast  = (beat == 2'd3);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy     <= 1'b0;
            beat     <= 2'd0;
            acc      <= '0;
            keep_acc <= '0;
        end else begin
            if (!busy && s_tvalid && s_tready) begin
                acc      <= s_tdata;
                keep_acc <= s_tkeep;
                busy     <= 1'b1;
                beat     <= 2'd0;
            end else if (busy && m_tready) begin
                if (beat == 2'd3)
                    busy <= 1'b0;
                else
                    beat <= beat + 2'd1;
            end
        end
    end

    // s_tlast is required by the 256-bit native protocol; downsizer ignores it
    // beyond packing (one message == one 256-bit beat).
    wire unused_tlast = s_tlast;

endmodule
