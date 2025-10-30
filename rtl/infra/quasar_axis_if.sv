// =============================================================================
// AXI4-Stream interface + protocol assertions.
// Default DATA_W=256 (one Quasar message per beat).  A 64-bit adapter sits
// at the pin if the host fabric is narrower.
// =============================================================================

interface quasar_axis_if #(
    parameter int DATA_W = 256,
    parameter int USER_W = 1,
    parameter int ID_W   = 1,
    parameter int DEST_W = 1
) (
    input logic clk,
    input logic rst_n
);

    localparam int KEEP_W = DATA_W / 8;

    logic              tvalid;
    logic              tready;
    logic [DATA_W-1:0] tdata;
    logic [KEEP_W-1:0] tkeep;
    logic              tlast;
    logic [USER_W-1:0] tuser;
    logic [ID_W-1:0]   tid;
    logic [DEST_W-1:0] tdest;

    modport master (
        output tvalid, tdata, tkeep, tlast, tuser, tid, tdest,
        input  tready
    );

    modport slave (
        input  tvalid, tdata, tkeep, tlast, tuser, tid, tdest,
        output tready
    );

    modport monitor (
        input tvalid, tready, tdata, tkeep, tlast, tuser, tid, tdest
    );

    function automatic logic beat();
        return tvalid && tready;
    endfunction

`ifdef QUASAR_SVA
    // AXI4-Stream: once tvalid is asserted it must stay until tready.
    property p_valid_hold;
        @(posedge clk) disable iff (!rst_n)
            (tvalid && !tready) |=> tvalid;
    endproperty
    assert property (p_valid_hold);

    property p_data_hold;
        @(posedge clk) disable iff (!rst_n)
            (tvalid && !tready) |=> $stable(tdata) && $stable(tkeep) &&
                                     $stable(tlast) && $stable(tuser);
    endproperty
    assert property (p_data_hold);

    property p_no_x;
        @(posedge clk) disable iff (!rst_n)
            tvalid |-> !$isunknown(tdata) && !$isunknown(tkeep) &&
                       !$isunknown(tlast);
    endproperty
    assert property (p_no_x);
`endif

endinterface
