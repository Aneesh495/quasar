// =============================================================================
// IEEE CRC-32 (poly 0x04C11DB7, reflected 0xEDB88320), init 0xFFFF_FFFF,
// final XOR 0xFFFF_FFFF.  Byte-parallel over N_BYTES combinational — used by
// the ingress checker on the 28-byte message body.  A 1-byte-per-cycle
// streaming variant is provided for the 64-bit AXIS downsizer path.
// =============================================================================

module quasar_crc32_comb #(
    parameter int N_BYTES = 28
) (
    input  logic [N_BYTES*8-1:0] data,   // byte0 in [7:0] (wire order)
    output logic [31:0]          crc
);

    function automatic logic [31:0] crc32_byte(input logic [31:0] c, input logic [7:0] b);
        logic [31:0] t;
        t = c ^ {24'h0, b};
        for (int i = 0; i < 8; i++) begin
            if (t[0])
                t = (t >> 1) ^ 32'hEDB88320;
            else
                t = t >> 1;
        end
        crc32_byte = t;
    endfunction

    logic [31:0] acc;
    always_comb begin
        acc = 32'hFFFF_FFFF;
        for (int i = 0; i < N_BYTES; i++)
            acc = crc32_byte(acc, data[i*8 +: 8]);
        crc = acc ^ 32'hFFFF_FFFF;
    end

endmodule

module quasar_crc32_stream (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        init,
    input  logic        valid,
    input  logic [7:0]  data,
    input  logic        finish,
    output logic [31:0] crc,
    output logic        crc_valid
);

    logic [31:0] acc, acc_n;

    function automatic logic [31:0] step(input logic [31:0] c, input logic [7:0] b);
        logic [31:0] t;
        t = c ^ {24'h0, b};
        for (int i = 0; i < 8; i++)
            t = t[0] ? ((t >> 1) ^ 32'hEDB88320) : (t >> 1);
        step = t;
    endfunction

    always_comb begin
        acc_n = acc;
        if (init)
            acc_n = 32'hFFFF_FFFF;
        else if (valid)
            acc_n = step(acc, data);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc       <= 32'hFFFF_FFFF;
            crc       <= 32'h0;
            crc_valid <= 1'b0;
        end else begin
            acc       <= acc_n;
            crc_valid <= finish && valid;
            if (finish && valid)
                crc <= acc_n ^ 32'hFFFF_FFFF;
        end
    end

endmodule
