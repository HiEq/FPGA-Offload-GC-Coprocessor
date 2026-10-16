// ============================================================
// gc_top.v — FOGCCC GC协处理器顶层模块
// 平台: Xilinx Zynq-7000 XC7Z100
//
// 端口说明:
//   S_AXI_*    : AXI-Lite从机, 连接PS的M_AXI_GP0 (寄存器控制)
//   S_AXI_HP_* : AXI HP从机, 连接PS的S_AXI_HP0  (读DDR对象图)
//
// 内部结构:
//   gc_regs        AXI-Lite寄存器接口
//   gc_mark_engine BFS标记状态机 (核心)
//   gc_bitmap      标记位图 (双口BRAM)
//   gc_queue       BFS队列 (双口BRAM)
//   gc_axi_read    AXI HP读主控
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
    // 无ID信号 — 只做单次读, 不需要ID匹配
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
    // 必须存在, 否则Vivado将S_AXI_HP识别为AXI4-Lite而非AXI4
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

    // 消除未使用端口的警告
    wire _unused = &{1'b0,
                     S_AXI_WSTRB,                          // AXI-Lite字节选通(不用)
                     S_AXI_HP_RDATA[63:32],                // 64位只用低32位
                     S_AXI_HP_AWREADY, S_AXI_HP_WREADY,    // 写通道桩(从不写)
                     S_AXI_HP_BRESP, S_AXI_HP_BVALID};     // 写响应(从不写)

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

    // 位图引擎端口
    wire [11:0] w_bm_addr;
    wire [31:0] w_bm_wdata;
    wire [31:0] w_bm_rdata;
    wire        w_bm_we;

    // DDR读接口 (跨时钟域: AXI-Lite域 → AXI HP域)
    wire [31:0] w_rd_addr;
    wire        w_rd_start, w_rd_done;
    wire [31:0] w_rd_data;

    // ===== CDC同步器: AXI HP域 → AXI-Lite域 =====
    // rd_done 跨回AXI-Lite域时需要2FF同步
    reg        rd_done_sync1, rd_done_sync2;
    reg [31:0] rd_data_sync1, rd_data_sync2;

    always @(posedge S_AXI_ACLK or negedge S_AXI_ARESETN) begin
        if (!S_AXI_ARESETN) begin
            rd_done_sync1 <= 1'b1;
            rd_done_sync2 <= 1'b1;
            rd_data_sync1 <= 32'h0;
            rd_data_sync2 <= 32'h0;
        end else begin
            rd_done_sync1 <= w_rd_done;
            rd_done_sync2 <= rd_done_sync1;
            rd_data_sync1 <= w_rd_data;
            rd_data_sync2 <= rd_data_sync1;
        end
    end

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
        .clk           (S_AXI_ACLK),
        .rst_n         (S_AXI_ARESETN),
        .obj_base      (w_obj_base),
        .obj_count     (w_obj_count),
        .root_count    (w_root_count),
        .start         (w_start),
        .root_rd_addr  (root_rd_addr),
        .root_rd_data  (root_rd_data),
        .q_push        (w_q_push),
        .q_push_data   (w_q_push_data),
        .q_push_addr   (w_q_push_addr),
        .q_pop         (w_q_pop),
        .q_pop_ack     (w_q_pop_ack),
        .q_pop_id      (w_q_pop_id),
        .q_tail        (w_q_tail),
        .q_empty       (w_q_empty),
        .bm_addr       (w_bm_addr),
        .bm_wdata      (w_bm_wdata),
        .bm_rdata      (w_bm_rdata),
        .bm_we         (w_bm_we),
        .rd_addr       (w_rd_addr),
        .rd_start      (w_rd_start),
        .rd_done       (rd_done_sync2),   // 同步后的done
        .rd_data       (rd_data_sync2),   // 同步后的data
        .done          (w_done),
        .marked_count  (w_marked_count),
        .cycles        (w_cycles)
    );

    // ==================== 标记位图 (纯BRAM, 无清零逻辑) ====================
    gc_bitmap u_bitmap (
        .clk   (S_AXI_ACLK),
        .addra (w_bm_addr),
        .dina  (w_bm_wdata),
        .wea   (w_bm_we),
        .douta (w_bm_rdata)
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

    // ==================== AXI HP 读主控 ====================
    gc_axi_read u_axi_rd (
        .ACLK    (S_AXI_HP_ACLK),
        .ARESETN (S_AXI_HP_ARESETN),
        .start   (w_rd_start),
        .addr    (w_rd_addr),
        .rdata   (w_rd_data),
        .done    (w_rd_done),
        .ARADDR  (S_AXI_HP_ARADDR),
        .ARPROT  (S_AXI_HP_ARPROT),
        .ARVALID (S_AXI_HP_ARVALID),
        .ARREADY (S_AXI_HP_ARREADY),
        .RDATA   (S_AXI_HP_RDATA),
        .RRESP   (S_AXI_HP_RRESP),
        .RVALID  (S_AXI_HP_RVALID),
        .RREADY  (S_AXI_HP_RREADY)
    );

    assign irq_o = w_done;

endmodule
