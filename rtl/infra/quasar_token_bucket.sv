// =============================================================================
// Token bucket rate limiter — extracted from quasar_risk_gate as a reusable
// primitive.  Used independently wherever you need a configurable burst
// allowance: ingress bandwidth shaping, per-firm rate limiting, CSR write
// throttle, etc.
//
// Parameters
//   WIDTH      — token counter width
//   SIGNED_CAP — if 1, the bucket can run negative (credit-based variant)
//
// Semantics
//   Refill: on the first cycle of each window (wnd_cnt wraps), tokens is
//     set to capacity.  If capacity is 0 the bucket is disabled and consume
//     is always ignored.
//   Consume: if consume_en and tokens > 0, decrement by consume_qty (capped
//     at the current balance so tokens never underflows).
//   blocked: asserted when a consume_en was presented but tokens == 0.
//
// The risk gate's own token logic is kept inline for historical reasons;
// this module is used by quasar_ingress_mux for per-session rate shaping.
// =============================================================================

module quasar_token_bucket #(
    parameter int WIDTH      = 16,
    parameter bit SIGNED_CAP = 1'b0
) (
    input  logic             clk,
    input  logic             rst_n,
    input  logic             soft_rst,

    input  logic [WIDTH-1:0] capacity,     // tokens per window; 0 = disabled
    input  logic [WIDTH-1:0] window,       // cycles per refill; 0 = 1024
    input  logic             consume_en,
    input  logic [WIDTH-1:0] consume_qty,  // how many to take (typically 1)

    output logic [WIDTH-1:0] tokens,
    output logic             blocked       // consume_en && tokens == 0
);

    logic [WIDTH-1:0] wnd_cnt, wnd_lim;
    logic [WIDTH-1:0] tokens_n, wnd_cnt_n;

    assign wnd_lim = (window == '0) ? WIDTH'(1024) : window;
    assign blocked = consume_en && (tokens == '0) && (capacity != '0);

    always_comb begin
        wnd_cnt_n = wnd_cnt + WIDTH'(1);
        tokens_n  = tokens;
        if (capacity == '0) begin
            tokens_n  = '0;
            wnd_cnt_n = '0;
        end else begin
            if (wnd_cnt_n >= wnd_lim) begin
                wnd_cnt_n = '0;
                tokens_n  = capacity;
            end
            if (consume_en && tokens != '0) begin
                logic [WIDTH-1:0] take;
                take = (consume_qty > tokens) ? tokens : consume_qty;
                tokens_n = tokens_n - take;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tokens  <= '0;
            wnd_cnt <= '0;
        end else if (soft_rst) begin
            tokens  <= capacity;
            wnd_cnt <= '0;
        end else begin
            tokens  <= tokens_n;
            wnd_cnt <= wnd_cnt_n;
        end
    end

`ifdef QUASAR_SVA
    property p_no_underflow;
        @(posedge clk) disable iff (!rst_n || capacity == '0)
            tokens <= capacity;
    endproperty
    a_bound: assert property (p_no_underflow);
`endif

endmodule
