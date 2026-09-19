// =============================================================================
// Pipeline watchdog — counts consecutive cycles where a command has been
// accepted but no terminal event (ack/reject/fill/cancel-ack) has been
// emitted.  If the counter exceeds the CSR-configured threshold (default
// disabled = 0) it raises a sticky interrupt flag visible in STATUS.
//
// This is an optional satellite register.  Main use: detect hardware lockup
// in integration; in simulation it fires assertions on stuck pipelines.
//
// Reset/clear: soft-reset or a CSR write to the threshold register while
// the watchdog is armed clears the counter and the flag.
// =============================================================================

module quasar_watchdog
    import quasar_pkg::*;
(
    input  logic         clk,
    input  logic         rst_n,
    input  logic         soft_rst,

    input  logic [31:0]  threshold,      // 0 = disabled

    input  logic         cmd_fire,       // a command was accepted this cycle
    input  logic         ev_fire,        // a terminal event was emitted
    input  logic [7:0]   ev_type,        // event type when ev_fire

    output logic         wdt_armed,      // a cmd is in-flight
    output logic [31:0]  wdt_count,      // live cycle count
    output logic         wdt_trip,       // sticky flag, cleared by soft_rst or wr
    input  logic         wdt_trip_clr    // single-cycle clear pulse from CSR
);

    logic [31:0] cnt, cnt_n;
    logic        armed, armed_n;
    logic        trip_r, trip_n;

    function automatic logic is_terminal(input logic [7:0] ev);
        is_terminal = ev inside {EV_ACK, EV_REJECT, EV_CANCEL_ACK,
                                  EV_MODIFY_ACK, EV_REPLACE_ACK, EV_STATUS};
    endfunction

    always_comb begin
        armed_n = armed;
        cnt_n   = cnt;
        trip_n  = trip_r;

        if (wdt_trip_clr || soft_rst)
            trip_n = 1'b0;

        if (cmd_fire && !ev_fire)
            armed_n = 1'b1;
        else if (ev_fire && is_terminal(ev_type))
            armed_n = 1'b0;

        if (armed && !ev_fire) begin
            cnt_n = cnt + 32'd1;
            if (threshold != 32'd0 && cnt_n > threshold)
                trip_n = 1'b1;
        end else
            cnt_n = '0;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            armed  <= 1'b0;
            cnt    <= 32'd0;
            trip_r <= 1'b0;
        end else begin
            armed  <= armed_n;
            cnt    <= cnt_n;
            trip_r <= trip_n;
        end
    end

    assign wdt_armed = armed;
    assign wdt_count = cnt;
    assign wdt_trip  = trip_r;

`ifdef QUASAR_SVA
    property p_count_clears;
        @(posedge clk) disable iff (!rst_n)
            (ev_fire && is_terminal(ev_type)) |=> (wdt_count == 32'd0);
    endproperty
    a_cnt_clear: assert property (p_count_clears);

    property p_armed_follows_cmd;
        @(posedge clk) disable iff (!rst_n)
            cmd_fire |=> wdt_armed;
    endproperty
    a_armed: assert property (p_armed_follows_cmd);
`endif

endmodule
