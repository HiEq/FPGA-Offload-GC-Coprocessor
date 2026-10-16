// ============================================================
// gc_top.v — FOGCCC GC协处理器顶层模块
// 平台: Xilinx Zynq-7000 XC7Z100
//
// 端口说明:
//   S_AXI_*    : AXI-Lite从机, 连接PS的M_AXI_GP0 (寄存器控制)
//   S_AXI_HP_* : AXI HP从机, 连接PS的S_AXI_HP0  (读DDR对象图)
//
// 时钟: 单一时钟域. S_AXI_HP_ACLK 与 S_AXI_ACLK 都接 FCLK_CLK0 (100MHz).
//       (旧版 HP 跑 FCLK_CLK1=200MHz, 需要 2FF CDC 同步 rd_done/rd_data;
//        现在读主控带命令/数据 FIFO, 流式数据无法简单 2FF 跨域, 故统一时钟域.)
//
// 内部结构:
//   gc_regs        AXI-Lite寄存器接口
//   gc_mark_engine BFS标记状态机 (核心)
//   gc_bitmap      标记位图 (简单双口BRAM, 读/写地址独立)
//   gc_queue       BFS队列 (双口BRAM)
//   gc_axi_read    AXI HP读命令队列主控 (多笔未完成读)
//   root_mem[]     根集存储 (分布式RAM)
// ============================================================
module gc_top (
    // ---- AXI-Lite 从机 (PS → PL 寄存器控制) ----
    input  wire        S_AXI_ACLK,
    input  wire        S_AXI_ARESETN,
    input  wire [7:0]  S_AXI_AWADDR,
    input  wire        S_AXI_AWVALID,
    output wire        S_AXI_AWREADY,
    input  wire [31:0] S_AXI_WDATA,
    input  wire [3:0]  S_AXI_WSTRB,
    input  wire        S_AXI_WVALID,
    output wire        S_AXI_WREADY,
    output wire [1:0]  S_AXI_BRESP,
    output wire        S_AXI_BVALID,
    input  wire        S_AXI_BREADY,
    input  wire [7:0]  S_AXI_ARADDR,
    input  wire        S_AXI_ARVALID,
    output wire        S_AXI_ARREADY,
    output wire [31:0] S_AXI_RDATA,
    output wire [1:0]  S_AXI_RRESP,
    output wire        S_AXI_RVALID,
    input  wire        S_AXI_RREADY,

    // ---- AXI HP 从机 (PL读DDR中的对象图) ----
    // 无ID信号 — 所有读同ID, 保证按序返回
    input  wire        S_AXI_HP_ACLK,
    input  wire        S_AXI_HP_ARESETN,
    output wire [31:0] S_AXI_HP_ARADDR,
    output wire [2:0]  S_AXI_HP_ARPROT,
    output wire        S_AXI_HP_ARVALID,
    input  wire        S_AXI_HP_ARREADY,
    input  wire [63:0] S_AXI_HP_RDATA,
    input  wire [1:0]  S_AXI_HP_RRESP,
    input  wire        S_AXI_HP_RVALID,
    output wire        S_AXI_HP_RREADY,

    // ---- AXI HP 写通道 (桩: 只应答, 不实际写DDR) ----
    output wire [31:0] S_AXI_HP_AWADDR,
    output wire [2:0]  S_AXI_HP_AWPROT,
    output wire        S_AXI_HP_AWVALID,
    input  wire        S_AXI_HP_AWREADY,
    output wire [63:0] S_AXI_HP_WDATA,
    output wire [7:0]  S_AXI_HP_WSTRB,
    output wire        S_AXI_HP_WVALID,
    input  wire        S_AXI_HP_WREADY,
    input  wire [1:0]  S_AXI_HP_BRESP,
    input  wire        S_AXI_HP_BVALID,
    output wire        S_AXI_HP_BREADY,

    // ---- 中断输出 ----
    output wire        irq_o
);

    // ==================== 内部连线 ====================
    wire [31:0] w_obj_base, w_obj_count, w_root_count;
    wire        w_start, w_clear_bm, w_clear_q;
    wire        w_done;
    wire [31:0] w_marked_count, w_cycles;

    // ===== AXI HP 写通道桩 =====
    // 本设计只读DDR, 从不发起写。
    assign S_AXI_HP_AWADDR  = 32'h0;
    assign S_AXI_HP_AWPROT  = 3'b000;
    assign S_AXI_HP_AWVALID = 1'b0;

    assign S_AXI_HP_WDATA   = 64'h0;
    assign S_AXI_HP_WSTRB   = 8'h0;
    assign S_AXI_HP_WVALID  = 1'b0;

    assign S_AXI_HP_BREADY  = 1'b1;

    // 根集存储 (256条目, 8Kb → 分布式RAM即可)
    (* ram_style = "distributed" *)
    reg  [31:0] root_mem [0:255];
    wire [7:0]  root_wr_addr;
    wire [31:0] root_wr_data;
    wire        root_we;
    wire [7:0]  root_rd_addr;
    reg  [31:0] root_rd_data;

    // 写口 — 独立always块 (BRAM推断要求)
    always @(posedge S_AXI_ACLK) begin
        if (root_we)
            root_mem[root_wr_addr] <= root_wr_data;
    end

    // 读口 — 独立always块 (BRAM推断要求)
    always @(posedge S_AXI_ACLK) begin
        root_rd_data <= root_mem[root_rd_addr];
    end

    // 队列接口
    wire        w_q_push, w_q_pop;
    wire [11:0] w_q_push_data, w_q_push_addr;
    wire        w_q_pop_ack;
    wire [11:0] w_q_pop_id;
    wire [11:0] w_q_head, w_q_tail;
    wire        w_q_empty = (w_q_head == w_q_tail);

    // 位图引擎端口 (读口/写口地址独立)
    wire [11:0] w_bm_raddr, w_bm_waddr;
    wire [31:0] w_bm_wdata;
    wire [31:0] w_bm_rdata;
    wire        w_bm_we;

    // DDR读命令队列接口 (同一时钟域, 无CDC)
    wire [31:0] w_rd_cmd_addr;
    wire        w_rd_cmd_valid, w_rd_cmd_ready;
    wire [31:0] w_rd_data;
    wire        w_rd_data_valid, w_rd_data_ready;
    wire        w_rd_err;

    // 消除未使用端口/信号的警告
    wire _unused = &{1'b0,
                     S_AXI_WSTRB,                          // AXI-Lite字节选通(不用)
                     S_AXI_HP_AWREADY, S_AXI_HP_WREADY,    // 写通道桩(从不写)
                     S_AXI_HP_BRESP, S_AXI_HP_BVALID,      // 写响应(从不写)
                     w_rd_err};                            // 读错误标志(仅诊断)

    // ==================== AXI-Lite 寄存器 ====================
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
        .reg_clear_bm      (w_clear_bm),
        .reg_clear_q       (w_clear_q),
        .reg_done          (w_done),
        .reg_marked_count  (w_marked_count),
        .reg_cycles        (w_cycles),
        .q_head            (w_q_head),
        .q_tail            (w_q_tail),
        .root_wr_addr      (root_wr_addr),
        .root_wr_data      (root_wr_data),
        .root_we           (root_we)
    );

    // ==================== 标记引擎 ====================
    gc_mark_engine u_engine (
        .clk            (S_AXI_ACLK),
        .rst_n          (S_AXI_ARESETN),
        .obj_base       (w_obj_base),
        .obj_count      (w_obj_count),
        .root_count     (w_root_count),
        .start          (w_start),
        .root_rd_addr   (root_rd_addr),
        .root_rd_data   (root_rd_data),
        .q_push         (w_q_push),
        .q_push_data    (w_q_push_data),
        .q_push_addr    (w_q_push_addr),
        .q_pop          (w_q_pop),
        .q_pop_ack      (w_q_pop_ack),
        .q_pop_id       (w_q_pop_id),
        .q_tail         (w_q_tail),
        .q_empty        (w_q_empty),
        .bm_raddr       (w_bm_raddr),
        .bm_rdata       (w_bm_rdata),
        .bm_waddr       (w_bm_waddr),
        .bm_wdata       (w_bm_wdata),
        .bm_we          (w_bm_we),
        .rd_cmd_addr    (w_rd_cmd_addr),
        .rd_cmd_valid   (w_rd_cmd_valid),
        .rd_cmd_ready   (w_rd_cmd_ready),
        .rd_data        (w_rd_data),
        .rd_data_valid  (w_rd_data_valid),
        .rd_data_ready  (w_rd_data_ready),
        .done           (w_done),
        .marked_count   (w_marked_count),
        .cycles         (w_cycles)
    );

    // ==================== 标记位图 (简单双口BRAM, 读写地址独立) ====================
    gc_bitmap u_bitmap (
        .clk   (S_AXI_ACLK),
        .waddr (w_bm_waddr),
        .din   (w_bm_wdata),
        .we    (w_bm_we),
        .raddr (w_bm_raddr),
        .dout  (w_bm_rdata)
    );

    // ==================== BFS队列 ====================
    gc_queue u_queue (
        .clk    (S_AXI_ACLK),
        .rst_n  (S_AXI_ARESETN),
        .clear  (w_clear_q),
        .waddr  (w_q_push_addr),
        .wdata  (w_q_push_data),
        .we     (w_q_push),
        .en     (w_q_pop),
        .rdata  (w_q_pop_id),
        .rvalid (w_q_pop_ack),
        .head   (w_q_head),
        .tail   (w_q_tail)
    );

    // ==================== AXI HP 读命令队列主控 ====================
    gc_axi_read u_axi_rd (
        .ACLK        (S_AXI_HP_ACLK),
        .ARESETN     (S_AXI_HP_ARESETN),
        .cmd_valid   (w_rd_cmd_valid),
        .cmd_addr    (w_rd_cmd_addr),
        .cmd_ready   (w_rd_cmd_ready),
        .data_out    (w_rd_data),
        .data_valid  (w_rd_data_valid),
        .data_ready  (w_rd_data_ready),
        .err         (w_rd_err),
        .ARADDR      (S_AXI_HP_ARADDR),
        .ARPROT      (S_AXI_HP_ARPROT),
        .ARVALID     (S_AXI_HP_ARVALID),
        .ARREADY     (S_AXI_HP_ARREADY),
        .RDATA       (S_AXI_HP_RDATA),
        .RRESP       (S_AXI_HP_RRESP),
        .RVALID      (S_AXI_HP_RVALID),
        .RREADY      (S_AXI_HP_RREADY)
    );

    assign irq_o = w_done;

endmodule
