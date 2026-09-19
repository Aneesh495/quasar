# =============================================================================
# Quasar — Verilator smoke + directed book/fifo + optional UVM-lite+DPI
#
#   make smoke          core AXIS smoke (default)
#   make book           book unit test
#   make fifo           infra (FIFO/CRC/skid/encoder)
#   make uvm            UVM-lite + C++ golden scoreboard
#   make all            smoke + book + fifo
#   make loc            line counts
#
# Full UVM / covergroups: commercial simulator (Xcelium, VCS, Questa).
# See docs/verification.md.
# =============================================================================

VERILATOR ?= verilator
CXX       ?= g++

BUILD     := build
VL_COMMON := --sv --timing --assert --trace --trace-structs \
             --error-limit 20 -Wno-fatal \
             -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-UNDRIVEN \
             -Wno-WIDTHCONCAT -Wno-BLKANDNBLK -Wno-CASEINCOMPLETE \
             -Wno-PINCONNECTEMPTY -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
             -Wno-SELRANGE -Wno-TIMESCALEMOD -Wno-INITIALDLY -Wno-LATCH \
             -CFLAGS "-std=c++17 -I../model"

RTL_PKG   := rtl/pkg/quasar_pkg.sv
RTL_INFRA := rtl/infra/quasar_sync_fifo.sv \
             rtl/infra/quasar_async_fifo.sv \
             rtl/infra/quasar_skid_buffer.sv \
             rtl/infra/quasar_pipe_reg.sv \
             rtl/infra/quasar_rr_arbiter.sv \
             rtl/infra/quasar_prio_encoder.sv \
             rtl/infra/quasar_gray_cdc.sv \
             rtl/infra/quasar_rst_sync.sv \
             rtl/infra/quasar_crc32.sv \
             rtl/infra/quasar_sdp_ram.sv \
             rtl/infra/quasar_free_list.sv \
             rtl/infra/quasar_counter.sv \
             rtl/infra/quasar_axis_width.sv \
             rtl/infra/quasar_axis_if.sv \
             rtl/infra/quasar_axil_if.sv
RTL_DUT   := rtl/book/quasar_book.sv \
             rtl/match/quasar_matcher.sv \
             rtl/risk/quasar_risk_gate.sv \
             rtl/ingress/quasar_ingress.sv \
             rtl/egress/quasar_egress.sv \
             rtl/csr/quasar_csr.sv \
             rtl/csr/quasar_perf_counters.sv \
             rtl/soc/quasar_core.sv \
             rtl/soc/quasar_soc.sv

TB_PKG    := tb/common/quasar_tb_pkg.sv

.PHONY: all smoke book fifo uvm loc clean help

all: fifo book smoke

help:
	@echo "make smoke | book | fifo | uvm | all | loc | clean"

$(BUILD):
	mkdir -p $(BUILD)

# ---- FIFO / CRC / skid ------------------------------------------------
fifo: $(BUILD)
	$(VERILATOR) --binary $(VL_COMMON) --top-module tb_fifo \
	    --Mdir $(BUILD)/fifo \
	    $(RTL_PKG) $(RTL_INFRA) tb/smoke/tb_fifo.sv
	$(BUILD)/fifo/Vtb_fifo

# ---- Book unit test ---------------------------------------------------
book: $(BUILD)
	$(VERILATOR) --binary $(VL_COMMON) --top-module tb_book \
	    --Mdir $(BUILD)/book \
	    $(RTL_PKG) $(RTL_INFRA) rtl/book/quasar_book.sv tb/smoke/tb_book.sv
	$(BUILD)/book/Vtb_book

# ---- Core smoke -------------------------------------------------------
smoke: $(BUILD)
	$(VERILATOR) --binary $(VL_COMMON) --top-module tb_quasar_smoke \
	    --Mdir $(BUILD)/smoke \
	    $(RTL_PKG) $(RTL_INFRA) $(RTL_DUT) $(TB_PKG) \
	    tb/smoke/tb_quasar_smoke.sv
	$(BUILD)/smoke/Vtb_quasar_smoke

# ---- UVM-lite + DPI golden --------------------------------------------
uvm: $(BUILD)
	$(VERILATOR) --binary $(VL_COMMON) --top-module tb_uvm_lite \
	    --Mdir $(BUILD)/uvm \
	    -CFLAGS "-std=c++17 -I$(CURDIR)/model" \
	    $(RTL_PKG) $(RTL_INFRA) $(RTL_DUT) $(TB_PKG) \
	    rtl/infra/quasar_axis_if.sv rtl/infra/quasar_axil_if.sv \
	    tb/uvm_lite/quasar_agent.sv tb/uvm_lite/tb_uvm_lite.sv \
	    model/golden_book.cpp model/quasar_dpi.cpp
	$(BUILD)/uvm/Vtb_uvm_lite

loc:
	@bash scripts/loc.sh

clean:
	rm -rf $(BUILD) obj_dir *.vcd *.fst
