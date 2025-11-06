// Bind SVA onto the live hierarchy.  Compiled when QUASAR_SVA is defined.

`ifdef QUASAR_SVA

bind quasar_core quasar_axis_sva #(.DATA_W(256)) u_sva_in (
    .clk   (clk),
    .rst_n (rst_n),
    .tvalid(s_axis_tvalid),
    .tready(s_axis_tready),
    .tdata (s_axis_tdata),
    .tlast (s_axis_tlast)
);

bind quasar_core quasar_axis_sva #(.DATA_W(256)) u_sva_out (
    .clk   (clk),
    .rst_n (rst_n),
    .tvalid(m_axis_tvalid),
    .tready(m_axis_tready),
    .tdata (m_axis_tdata),
    .tlast (m_axis_tlast)
);

bind quasar_book quasar_book_sva u_sva_book (
    .clk        (clk),
    .rst_n      (rst_n),
    .req_valid  (req_valid),
    .req_ready  (req_ready),
    .cmd        (req.cmd),
    .rsp_valid  (rsp_valid),
    .rsp_ok     (rsp.ok),
    .reject     (rsp.reject),
    .orders_used(orders_used),
    .levels_used(levels_used)
);

`endif
