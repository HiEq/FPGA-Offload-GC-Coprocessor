// gc_top.v — FOGCCC GC协处理器顶层模块
// 平台: Xilinx Zynq-7000 XC7Z100
//
// 端口说明:
//   S_AXI_*    : AXI-Lite从机, 连接PS的M_AXI_GP0 (寄存器控制)
//   S_AXI_HP_* : AXI HP从机, 连接PS的S_AXI_HP0  (读DDR对象图)
//
// 时钟: 单一时钟域. S_AXI_HP_ACLK 与 S_AXI_ACLK 都接 FCLK_CLK0 (100MHz).
//
// 内部结构:
//   gc_regs        AXI-Lite寄存器接口
//   gc_mark_engine BFS标记状态机 (核心)
//   gc_bitmap      标记位图 (简单双口BRAM, 读/写地址独立)
//   gc_queue       BFS队列 (双口BRAM)
//   gc_axi_read    AXI HP读命令队列主控 (多笔未完成读)
//   gc_freelist    未标记对象 free-list 扫描 (Phase 2)
//   root_mem[]     根集存储 (分布式RAM)
module gc_top (
    input  wire        S_AXI_ACLK,
    input  wire        S_AXI_ARESETN,
    input  wire [11:0] S_AXI_AWADDR,
    input  wire        S_AXI_AWVALID,
    output wire        S_AXI_AWREADY,
    input  wire [31:0] S_AXI_WDATA,
    input  wire [3:0]  S_AXI_WSTRB,
    input  wire        S_AXI_WVALID,
    output wire        S_AXI_WREADY,
    output wire [1:0]  S_AXI_BRESP,
    output wire        S_AXI_BVALID,
    input  wire        S_AXI_BREADY,
    input  wire [11:0] S_AXI_ARADDR,
    input  wire        S_AXI_ARVALID,
    output wire        S_AXI_ARREADY,
    output wire [31:0] S_AXI_RDATA,
    output wire [1:0]  S_AXI_RRESP,
    output wire        S_AXI_RVALID,
    input  wire        S_AXI_RREADY,

    // HP 主机实为 AXI3（PS7 的 S_AXI_HP 就是 AXI3）：ID_WIDTH=6，两条读流
    // （ARID=0 引用 / ARID=1 对象头），ARSIZE=3 / ARLEN=0 / ARBURST=INCR。
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI_HP_ACLK, ASSOCIATED_BUSIF S_AXI_HP, ASSOCIATED_RESET S_AXI_HP_ARESETN" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 S_AXI_HP_ACLK CLK" *)
    input  wire        S_AXI_HP_ACLK,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 S_AXI_HP_ARESETN RST" *)
    input  wire        S_AXI_HP_ARESETN,

    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI_HP, PROTOCOL AXI3, ADDR_WIDTH 32, DATA_WIDTH 64, ID_WIDTH 6, HAS_BURST 1, NUM_READ_OUTSTANDING 8, NUM_WRITE_OUTSTANDING 1, READ_WRITE_MODE READ_WRITE, SUPPORTS_NARROW_BURST 0" *)
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP ARADDR" *)
    output wire [31:0] S_AXI_HP_ARADDR,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP ARID" *)
    output wire [5:0]  S_AXI_HP_ARID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP ARLEN" *)
    output wire [3:0]  S_AXI_HP_ARLEN,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP ARSIZE" *)
    output wire [2:0]  S_AXI_HP_ARSIZE,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP ARBURST" *)
    output wire [1:0]  S_AXI_HP_ARBURST,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP ARCACHE" *)
    output wire [3:0]  S_AXI_HP_ARCACHE,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP ARPROT" *)
    output wire [2:0]  S_AXI_HP_ARPROT,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP ARVALID" *)
    output wire        S_AXI_HP_ARVALID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP ARREADY" *)
    input  wire        S_AXI_HP_ARREADY,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP RDATA" *)
    input  wire [63:0] S_AXI_HP_RDATA,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP RID" *)
    input  wire [5:0]  S_AXI_HP_RID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP RRESP" *)
    input  wire [1:0]  S_AXI_HP_RRESP,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP RLAST" *)
    input  wire        S_AXI_HP_RLAST,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP RVALID" *)
    input  wire        S_AXI_HP_RVALID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP RREADY" *)
    output wire        S_AXI_HP_RREADY,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP AWADDR" *)
    output wire [31:0] S_AXI_HP_AWADDR,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP AWID" *)
    output wire [5:0]  S_AXI_HP_AWID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP AWLEN" *)
    output wire [3:0]  S_AXI_HP_AWLEN,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP AWSIZE" *)
    output wire [2:0]  S_AXI_HP_AWSIZE,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP AWBURST" *)
    output wire [1:0]  S_AXI_HP_AWBURST,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP AWCACHE" *)
    output wire [3:0]  S_AXI_HP_AWCACHE,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP AWPROT" *)
    output wire [2:0]  S_AXI_HP_AWPROT,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP AWVALID" *)
    output wire        S_AXI_HP_AWVALID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP AWREADY" *)
    input  wire        S_AXI_HP_AWREADY,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP WDATA" *)
    output wire [63:0] S_AXI_HP_WDATA,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP WID" *)
    output wire [5:0]  S_AXI_HP_WID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP WSTRB" *)
    output wire [7:0]  S_AXI_HP_WSTRB,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP WLAST" *)
    output wire        S_AXI_HP_WLAST,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP WVALID" *)
    output wire        S_AXI_HP_WVALID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP WREADY" *)
    input  wire        S_AXI_HP_WREADY,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP BID" *)
    input  wire [5:0]  S_AXI_HP_BID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP BRESP" *)
    input  wire [1:0]  S_AXI_HP_BRESP,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP BVALID" *)
    input  wire        S_AXI_HP_BVALID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP BREADY" *)
    output wire        S_AXI_HP_BREADY,

    output wire        irq_o
);

    wire [31:0] w_obj_base, w_obj_count, w_root_count;
    wire        w_start, w_clear_q, w_abort;
    wire        w_done;
    wire [31:0] w_marked_count, w_cycles;
    wire        w_dump, w_dump_busy, w_dump_done;
    wire [14:0] w_dump_bm_raddr;
    wire [31:0] w_dump_base = w_obj_base + 32'h03FE0000;

    // 只读 DDR; 接口为完整 AXI4, 写信号绑常量
    // HP write channel drives the bitmap dump (gc_dump); reads stay with the
    // engine / probe / free-list.

    (* ram_style = "distributed" *)
    reg  [31:0] root_mem [0:255];
    wire [7:0]  root_wr_addr;
    wire [31:0] root_wr_data;
    wire        root_we;
    wire [7:0]  root_rd_addr;
    reg  [31:0] root_rd_data;
    wire [7:0]  w_root_rd_idx;
    wire [31:0] w_root_axi_data = root_mem[w_root_rd_idx];

    always @(posedge S_AXI_ACLK) begin
        if (root_we)
            root_mem[root_wr_addr] <= root_wr_data;
    end

    always @(posedge S_AXI_ACLK) begin
        root_rd_data <= root_mem[root_rd_addr];
    end

    // An unwritten root entry must read 0, never stale/X: software may set
    // root_count larger than the number of entries it actually programmed.
    integer root_i;
    initial begin
        for (root_i = 0; root_i < 256; root_i = root_i + 1) root_mem[root_i] = 32'h0;
    end

    wire        w_q_we, w_q_pop;
    wire [19:0] w_q_wdata;
    wire        w_q_pop_ack;
    wire [19:0] w_q_pop_id;
    wire [18:0] w_q_head, w_q_tail;
    wire        w_q_empty;
    wire        w_q_full;
    wire [19:0] w_q_count;

    // Peak BFS-queue occupancy of the run: the driver reads it to choose the
    // next collection's engine (tiny peak = chain-like = CPU wins).
    // Two metrics, both snapshotted so a redelivered START cannot wipe them:
    //   0x454 Q_HWM : peak BFS-queue occupancy (debug; root injection inflates it)
    //   0x458 Q_HI  : cycles with q_count >= 64 (the decision metric)
    // The decision uses Q_HI / CYCLES, which root injection cannot move: 454
    // roots cost ~454 cycles out of a multi-million-cycle run.
    reg  [19:0] w_q_hwm;     // live peak
    reg  [31:0] w_q_hi;      // live wide-frontier cycle count
    reg  [19:0] w_q_hwm_r;   // snapshot read at 0x454 (survives a spurious restart)
    reg  [31:0] w_q_hi_r;    // snapshot read at 0x458
    wire        w_engine_idle;   // engine state == S_IDLE (declared here, used below)

    // A late redelivery of the CTRL START store can restart the engine after
    // DONE with an empty queue, and that empty run also reaches DONE.  Latch
    // one cycle after DONE (when marked_count is final) and only for a run
    // that actually marked something, so an empty restart cannot overwrite a
    // completed run's stats.
    reg  w_done_d;
    always @(posedge S_AXI_ACLK or negedge S_AXI_ARESETN) begin
        if (!S_AXI_ARESETN) begin
            w_done_d  <= 1'b0;
            w_q_hwm_r <= 20'd0;
            w_q_hi_r  <= 32'd0;
        end else begin
            w_done_d <= w_done;
            if (w_done_d && (w_marked_count != 32'd0)) begin
                w_q_hwm_r <= w_q_hwm;
                w_q_hi_r  <= w_q_hi;
            end
        end
    end

    always @(posedge S_AXI_ACLK or negedge S_AXI_ARESETN) begin
        if (!S_AXI_ARESETN) begin
            w_q_hi <= 32'd0;
        end else if (w_start && w_engine_idle) begin
            w_q_hi <= 32'd0;
        end else if (w_q_count >= 20'd64) begin
            // Unconditional: a root burst contributes at most `roots` cycles,
            // which is <0.01% of any run the decision targets.
            w_q_hi <= w_q_hi + 32'd1;
        end
    end
    always @(posedge S_AXI_ACLK or negedge S_AXI_ARESETN) begin
        if (!S_AXI_ARESETN) begin
            w_q_hwm <= 20'd0;
        end else if (w_start && w_engine_idle) begin
            w_q_hwm <= 20'd0;
        end else if (w_q_count > w_q_hwm) begin
            w_q_hwm <= w_q_count;
        end
    end
    wire        w_err_ovf, w_err_ref, w_err_hdr;

    wire [14:0] w_hk_raddr, w_bm_waddr;
    wire [14:0] w_bm_raddr_eff;
    wire [14:0] w_regs_bm_addr;
    wire [31:0] w_bm_wdata;
    wire [31:0] w_bm_rdata;          // ext read (bank selected one cycle later)
    reg  [31:0] w_bm_probe_r = 32'h0;
    wire        w_bm_we;
    wire        w_ref_active;

    // Two banked lanes: lane k owns the ids with id[5] == k.  The bank ports are
    // owned by the lanes while ref_active, and by the housekeeping path
    // (clear/root/dirty) plus the dump/free-list/probe otherwise.
    wire [13:0] w_l0_raddr, w_l0_waddr, w_l1_raddr, w_l1_waddr;
    wire        w_l0_we, w_l1_we;
    wire [31:0] w_l0_wdata, w_l1_wdata, w_l0_rdata, w_l1_rdata;

    wire [13:0] w_ext_addr = w_bm_raddr_eff[14:1];
    reg         w_ext_bank_r = 1'b0;
    always @(posedge S_AXI_ACLK) w_ext_bank_r <= w_bm_raddr_eff[0];
    wire [31:0] w_ext_rdata = w_ext_bank_r ? w_l1_rdata : w_l0_rdata;

    wire        w_hk_bank = w_bm_waddr[0];
    wire [13:0] w_hk_addr = w_bm_waddr[14:1];
    wire        w_bm_we0 = w_l0_we | (w_bm_we & ~w_hk_bank);
    wire        w_bm_we1 = w_l1_we | (w_bm_we &  w_hk_bank);
    wire [13:0] w_bm_wa0 = (w_bm_we & ~w_hk_bank) ? w_hk_addr : w_l0_waddr;
    wire [13:0] w_bm_wa1 = (w_bm_we &  w_hk_bank) ? w_hk_addr : w_l1_waddr;
    wire [31:0] w_bm_wd0 = (w_bm_we & ~w_hk_bank) ? w_bm_wdata : w_l0_wdata;
    wire [31:0] w_bm_wd1 = (w_bm_we &  w_hk_bank) ? w_bm_wdata : w_l1_wdata;
    wire [13:0] w_bm_ra0 = w_ref_active ? w_l0_raddr : w_ext_addr;
    wire [13:0] w_bm_ra1 = w_ref_active ? w_l1_raddr : w_ext_addr;

    // Write-first bypass, pipelined to match the bitmap's read latency.
    // gc_bitmap must stay a plain BRAM (see its header); the engine may read a
    // word in the same cycle it writes it, and BRAM read-first would hand back
    // the old word.  Latching the address and the write together lets the
    // cycle-N+1 consumer see the cycle-N write.
    reg  [14:0] bm_ra_r = 15'd0;
    reg  [14:0] bm_wa_r = 15'd0;
    reg  [31:0] bm_wd_r = 32'd0;
    reg         bm_we_r = 1'b0;
    always @(posedge S_AXI_ACLK) begin
        bm_ra_r <= w_bm_raddr_eff;
        bm_wa_r <= w_bm_waddr;
        bm_wd_r <= w_bm_wdata;
        bm_we_r <= w_bm_we;
    end
    wire [31:0] w_bm_rdata_eff = (bm_we_r && (bm_ra_r == bm_wa_r)) ? bm_wd_r : w_ext_rdata;

    // Phase 2 free-list
    wire [14:0] w_free_bm_raddr;
    wire [31:0] w_free_count;
    wire [19:0] w_free_data;
    wire        w_free_pop;
    wire        w_free_busy;

    // Phase 3A dirty set
    wire        w_dirty_push, w_dirty_flush, w_bm_keep;
    wire [19:0] w_dirty_push_id, w_dirty_id;
    wire [8:0]  w_dirty_count;
    wire        w_dirty_empty, w_dirty_full, w_dirty_ovf, w_dirty_pop;
    wire [31:0] w_dirty_drained;
    wire [15:0] w_dirty_pushed, w_dirty_popped;

    // Spill protection (this board redelivers stores, and the copies are not always
    // adjacent): a CLEAR_Q that arrives while the engine is mid-run must not clear
    // the BFS queue (sim T-CTRL-SPILL / T-CTRL-RESTART fail on the ungated build),
    // so the software clear only counts while the engine is idle; the engine clears
    // the queue itself when it accepts a START, which also keeps q_tail == marked
    // when a spilled START triggers a redundant re-run.
    wire        w_clear_q_eff;
    wire        w_dirty_flush_eff;
    wire        w_engine_q_clear;

    wire [31:0] w_rd_cmd_addr;
    wire        w_rd_cmd_pair;
    wire [1:0]  w_rd_cmd_len;
    wire        w_rd_cmd_valid, w_rd_cmd_ready;
    wire [31:0] w_rd_data;
    wire [31:0] w_rd_data_hi;
    wire        w_rd_data_two;
    wire        w_rd_data_take2;
    wire        w_rd_data_valid, w_rd_data_ready;
    wire        w_rd_err;

    wire _unused = &{1'b0,
                     S_AXI_WSTRB,                          // AXI-Lite字节选通(不用)
                     S_AXI_HP_AWREADY, S_AXI_HP_WREADY,    // 写通道桩(从不写)
                      S_AXI_HP_BRESP, S_AXI_HP_BVALID,      // write response (never used)
                      w_dirty_full};                        // Phase 3A: 只读状态位

    gc_regs u_regs (
        .ACLK              (S_AXI_ACLK),
        .ARESETN           (S_AXI_ARESETN),
        .AWADDR            (S_AXI_AWADDR),
        .AWVALID           (S_AXI_AWVALID),
        .AWREADY           (S_AXI_AWREADY),
        .WDATA             (S_AXI_WDATA),
        .WSTRB             (S_AXI_WSTRB),
        .WVALID            (S_AXI_WVALID),
        .WREADY            (S_AXI_WREADY),
        .BRESP             (S_AXI_BRESP),
        .BVALID            (S_AXI_BVALID),
        .BREADY            (S_AXI_BREADY),
        .ARADDR            (S_AXI_ARADDR),
        .ARVALID           (S_AXI_ARVALID),
        .ARREADY           (S_AXI_ARREADY),
        .RDATA             (S_AXI_RDATA),
        .RRESP             (S_AXI_RRESP),
        .RVALID            (S_AXI_RVALID),
        .RREADY            (S_AXI_RREADY),
        .reg_obj_base      (w_obj_base),
        .reg_obj_count     (w_obj_count),
        .reg_root_count    (w_root_count),
        .reg_start         (w_start),
        .reg_abort         (w_abort),
        .reg_clear_q       (w_clear_q),
        .reg_done          (w_done),
        .reg_marked_count  (w_marked_count),
        .reg_cycles        (w_cycles),
        .q_head            (w_q_head),
        .q_tail            (w_q_tail),
        .q_hwm             (w_q_hwm_r),
        .q_hi              (w_q_hi_r),
        .err_ovf           (w_err_ovf),
        .err_rd            (w_rd_err),
        .err_ref           (w_err_ref),
        .err_hdr           (w_err_hdr),
        .reg_idle          (w_engine_idle),
        .reg_dump          (w_dump),
        .dump_busy         (w_dump_busy),
        .dump_done         (w_dump_done),
        .root_wr_addr      (root_wr_addr),
        .root_wr_data      (root_wr_data),
        .root_we           (root_we),
        .root_rd_idx       (w_root_rd_idx),
        .root_rd_data      (w_root_axi_data),
        .reg_bm_addr       (w_regs_bm_addr),
        .reg_bm_data       (w_bm_probe_r),
        .reg_free_count    (w_free_count),
        .reg_free_data     (w_free_data),
        .reg_free_busy     (w_free_busy),
        .reg_free_pop      (w_free_pop),
        .reg_dirty_push    (w_dirty_push),
        .reg_dirty_push_id (w_dirty_push_id),
        .reg_dirty_flush   (w_dirty_flush),
        .reg_bm_keep       (w_bm_keep),
        .dirty_count       (w_dirty_count),
        .dirty_empty       (w_dirty_empty),
        .dirty_ovf         (w_dirty_ovf),
        .dirty_drained     (w_dirty_drained),
        .dirty_pushed      (w_dirty_pushed),
        .dirty_popped      (w_dirty_popped)
    );

    wire [31:0] w_hdr_cmd_addr;
    wire        w_hdr_cmd_valid;
    wire        w_hdr_cmd_ready;
    wire [31:0] w_hdr_data;
    wire        w_hdr_data_valid;
    wire        w_hdr_data_ready;

    gc_mark_engine u_engine (
        .clk            (S_AXI_ACLK),
        .rst_n          (S_AXI_ARESETN),
        .obj_base       (w_obj_base),
        .obj_count      (w_obj_count),
        .root_count     (w_root_count),
        .start          (w_start),
        .abort          (w_abort),
        .root_rd_addr   (root_rd_addr),
        .root_rd_data   (root_rd_data),
        .q_we           (w_q_we),
        .q_wdata        (w_q_wdata),
        .q_pop          (w_q_pop),
        .q_pop_ack      (w_q_pop_ack),
        .q_pop_id       (w_q_pop_id),
        .q_tail         (w_q_tail),
        .q_empty        (w_q_empty),
        .q_full         (w_q_full),
        .ref_active     (w_ref_active),
        .lane0_raddr    (w_l0_raddr),
        .lane0_waddr    (w_l0_waddr),
        .lane0_we       (w_l0_we),
        .lane0_wdata    (w_l0_wdata),
        .lane0_rdata    (w_l0_rdata),
        .lane1_raddr    (w_l1_raddr),
        .lane1_waddr    (w_l1_waddr),
        .lane1_we       (w_l1_we),
        .lane1_wdata    (w_l1_wdata),
        .lane1_rdata    (w_l1_rdata),
        .hk_raddr       (w_hk_raddr),
        .hk_rdata       (w_bm_rdata_eff),
        .bm_waddr       (w_bm_waddr),
        .bm_wdata       (w_bm_wdata),
        .bm_we          (w_bm_we),
        .rd_cmd_addr    (w_rd_cmd_addr),
        .rd_cmd_pair    (w_rd_cmd_pair),
        .rd_cmd_len     (w_rd_cmd_len),
        .rd_cmd_valid   (w_rd_cmd_valid),
        .rd_cmd_ready   (w_rd_cmd_ready),
        .rd_data        (w_rd_data),
        .rd_data_hi     (w_rd_data_hi),
        .rd_data_two    (w_rd_data_two),
        .rd_data_valid  (w_rd_data_valid),
        .rd_data_ready  (w_rd_data_ready),
        .rd_data_take2  (w_rd_data_take2),
        .hdr_cmd_addr   (w_hdr_cmd_addr),
        .hdr_cmd_valid  (w_hdr_cmd_valid),
        .hdr_cmd_ready  (w_hdr_cmd_ready),
        .hdr_data       (w_hdr_data),
        .hdr_data_valid (w_hdr_data_valid),
        .hdr_data_ready (w_hdr_data_ready),
        .done           (w_done),
        .marked_count   (w_marked_count),
        .cycles         (w_cycles),
        .err_ovf        (w_err_ovf),
        .err_ref        (w_err_ref),
        .err_hdr        (w_err_hdr),
        .engine_idle    (w_engine_idle),
        .q_clear        (w_engine_q_clear),
        .dirty_empty    (w_dirty_empty),
        .dirty_id       (w_dirty_id),
        .bm_keep        (w_bm_keep),
        .dirty_pop      (w_dirty_pop),
        .dirty_drained  (w_dirty_drained)
    );

    gc_bitmapN #(.LANES(2), .SEL(1)) u_bitmap (
        .clk   (S_AXI_ACLK),
        .we    ({w_bm_we1, w_bm_we0}),
        .waddr ({w_bm_wa1, w_bm_wa0}),
        .din   ({w_bm_wd1, w_bm_wd0}),
        .raddr ({w_bm_ra1, w_bm_ra0}),
        .dout  ({w_l1_rdata, w_l0_rdata})
    );

    assign w_bm_raddr_eff = w_dump_busy ? w_dump_bm_raddr :
                            (w_free_busy ? w_free_bm_raddr :
                            (w_engine_idle ? w_regs_bm_addr : w_hk_raddr));

    always @(posedge S_AXI_ACLK) w_bm_probe_r <= w_bm_rdata_eff;

    assign w_clear_q_eff = w_clear_q & w_engine_idle;

    // DIRTY_FLUSH is arm-and-consume: the write only ARMS it, it is applied at the
    // next accepted START with BM_KEEP=0 (a full mark, which clears the FIFO anyway)
    // and DISCARDED by an incremental start.  A flush bit in the same write as START
    // also counts.  Late store copies therefore cannot drop a pending record.
    // Evidence: sim T-DIRTY-FLUSHIDLE / T-DIRTY-FLUSHSPILL.
    reg  flush_armed;
    always @(posedge S_AXI_ACLK or negedge S_AXI_ARESETN) begin
        if (!S_AXI_ARESETN)                flush_armed <= 1'b0;
        else if (w_start && w_engine_idle) flush_armed <= w_dirty_flush;
        else if (w_dirty_flush)            flush_armed <= 1'b1;
    end

    assign w_dirty_flush_eff = (flush_armed | w_dirty_flush) & w_start & ~w_bm_keep & w_engine_idle;

    gc_freelist u_freelist (
        .clk        (S_AXI_ACLK),
        .rst_n      (S_AXI_ARESETN),
        .start      (w_start),
        .done       (w_done),
        .obj_count  (w_obj_count),
        .bm_raddr   (w_free_bm_raddr),
        .bm_rdata   (w_bm_rdata_eff),
        .free_count (w_free_count),
        .free_data  (w_free_data),
        .pop        (w_free_pop),
        .busy       (w_free_busy)
    );

    gc_dirty_fifo u_dirty (
        .clk      (S_AXI_ACLK),
        .rst_n    (S_AXI_ARESETN),
        .push     (w_dirty_push),
        .push_id  (w_dirty_push_id),
        .flush    (w_dirty_flush_eff),
        .pop      (w_dirty_pop),
        .id       (w_dirty_id),
        .count    (w_dirty_count),
        .pushed   (w_dirty_pushed),
        .popped   (w_dirty_popped),
        .empty    (w_dirty_empty),
        .full     (w_dirty_full),
        .overflow (w_dirty_ovf)
    );

    gc_queue u_queue (
        .clk    (S_AXI_ACLK),
        .rst_n  (S_AXI_ARESETN),
        .clear  (w_clear_q_eff | w_abort | w_engine_q_clear),   // abort always clears; a
                                                        // spilled CLEAR_Q does not
                                                        // touch a running epoch
        .waddr  (w_q_tail),
        .wdata  (w_q_wdata),
        .we     (w_q_we),
        .en     (w_q_pop),
        .rdata  (w_q_pop_id),
        .rvalid (w_q_pop_ack),
        .head   (w_q_head),
        .tail   (w_q_tail),
        .empty  (w_q_empty),
        .full   (w_q_full),
        .count  (w_q_count)
    );

    gc_axi_read u_axi_rd (
        .ACLK        (S_AXI_HP_ACLK),
        .ARESETN     (S_AXI_HP_ARESETN),

        .cmd0_valid  (w_rd_cmd_valid),
        .cmd0_addr   (w_rd_cmd_addr),
        .cmd0_pair   (w_rd_cmd_pair),
        .cmd0_len    (w_rd_cmd_len),
        .cmd0_ready  (w_rd_cmd_ready),
        .data0_out   (w_rd_data),
        .data0_out_hi (w_rd_data_hi),
        .data0_two   (w_rd_data_two),
        .data0_take2 (w_rd_data_take2),
        .data0_valid (w_rd_data_valid),
        .data0_ready (w_rd_data_ready),

        .cmd1_valid  (w_hdr_cmd_valid),
        .cmd1_addr   (w_hdr_cmd_addr),
        .cmd1_ready  (w_hdr_cmd_ready),
        .data1_out   (w_hdr_data),
        .data1_valid (w_hdr_data_valid),
        .data1_ready (w_hdr_data_ready),

        .run_start   (w_start & w_engine_idle),   // a START the FSM ignores must not flush
        .abort       (w_abort),     // drop the abandoned run's in-flight reads too
        .err         (w_rd_err),

        .ARADDR      (S_AXI_HP_ARADDR),
        .ARID        (S_AXI_HP_ARID),
        .ARLEN       (S_AXI_HP_ARLEN),
        .ARSIZE      (S_AXI_HP_ARSIZE),
        .ARBURST     (S_AXI_HP_ARBURST),
        .ARCACHE     (S_AXI_HP_ARCACHE),
        .ARPROT      (S_AXI_HP_ARPROT),
        .ARVALID     (S_AXI_HP_ARVALID),
        .ARREADY     (S_AXI_HP_ARREADY),
        .RDATA       (S_AXI_HP_RDATA),
        .RID         (S_AXI_HP_RID),
        .RRESP       (S_AXI_HP_RRESP),
        .RLAST       (S_AXI_HP_RLAST),
        .RVALID      (S_AXI_HP_RVALID),
        .RREADY      (S_AXI_HP_RREADY)
    );

    assign irq_o = w_done;

    // ---------------------------------------------------------------- bitmap dump
    // The PS cannot read the 128 KiB bitmap quickly over AXI-Lite; stream it to
    // DDR over the HP write channel and let the CPU memcpy it (~1 ms), instead
    // of one probe-address write + data read per word (~190 ms).
    gc_dump u_dump (
        .clk       (S_AXI_ACLK),
        .rst_n     (S_AXI_ARESETN),
        .start     (w_dump & w_engine_idle & ~w_free_busy & ~w_dump_busy),
        .base      (w_dump_base),
        .busy      (w_dump_busy),
        .done      (w_dump_done),
        .bm_raddr  (w_dump_bm_raddr),
        .bm_rdata  (w_bm_rdata_eff),
        .AWADDR    (S_AXI_HP_AWADDR),
        .AWID      (S_AXI_HP_AWID),
        .AWLEN     (S_AXI_HP_AWLEN),
        .AWSIZE    (S_AXI_HP_AWSIZE),
        .AWBURST   (S_AXI_HP_AWBURST),
        .AWCACHE   (S_AXI_HP_AWCACHE),
        .AWPROT    (S_AXI_HP_AWPROT),
        .AWVALID   (S_AXI_HP_AWVALID),
        .AWREADY   (S_AXI_HP_AWREADY),
        .WDATA     (S_AXI_HP_WDATA),
        .WID       (S_AXI_HP_WID),
        .WSTRB     (S_AXI_HP_WSTRB),
        .WLAST     (S_AXI_HP_WLAST),
        .WVALID    (S_AXI_HP_WVALID),
        .WREADY    (S_AXI_HP_WREADY),
        .BID       (S_AXI_HP_BID),
        .BRESP     (S_AXI_HP_BRESP),
        .BVALID    (S_AXI_HP_BVALID),
        .BREADY    (S_AXI_HP_BREADY)
    );

endmodule
