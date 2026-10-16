// ============================================================
// gc_axi_read.v — AXI 读命令队列主控 (多笔未完成读 / multiple outstanding)
//
// 与旧版的区别:
//   旧版: 单笔单拍读, 引擎必须等 rd_done 才能发下一笔.
//         → 每个对象 (2 + ref_count) 次 DDR 往返延迟全部暴露.
//   新版: 命令/数据解耦. 引擎可连续压入任意多个"地址互不依赖"的读命令,
//         主控把它们流水线发给 AXI (最多 MAXO 笔未完成), 数据按序返回.
//         → 每个对象 2 次往返 (头 2 笔并发 + 引用 N 笔并发).
//
// 单时钟域 (与引擎同频 FCLK_CLK0 = 100MHz), 无 CDC 同步器.
//
// 关键 (AXI HP 是 64 位口, 只接受 8 字节对齐地址):
//   ARADDR = addr & ~7                     (8 字节对齐)
//   hi_sel = addr[2]                       (1 = 取 RDATA[63:32])
//   每笔读命令只返回 1 拍 (64 位 = 2 个 32 位字, 取其中一半)
//
// 顺序保证: 所有读使用同一个 ID (本设计无 ID 信号), AXI 要求同 ID 读按序返回,
//           因此数据返回顺序 == 命令压入顺序.
// ============================================================
module gc_axi_read #(
    parameter integer QD   = 80,   // FIFO 容量 (最多可同时容纳这么多未取回的命令)
    parameter integer MAXO = 16    // 允许的最大未完成 AR 笔数 (AXI3 习惯值)
)(
    input  wire        ACLK,
    input  wire        ARESETN,

    // ---- 命令接口 (引擎 → 主控) ----
    input  wire        cmd_valid,
    input  wire [31:0] cmd_addr,    // 4 字节对齐即可
    output wire        cmd_ready,   // 1 = FIFO 未满, 可接收

    // ---- 数据接口 (主控 → 引擎, 按命令顺序) ----
    output wire [31:0] data_out,
    output wire        data_valid,
    input  wire        data_ready,

    // ---- 状态 ----
    output reg         err,         // AXI 读错误 (粘滞, 复位清除)

    // ---- AXI4 读地址通道 ----
    output reg  [31:0] ARADDR,
    output reg  [2:0]  ARPROT,
    output reg         ARVALID,
    input  wire        ARREADY,

    // ---- AXI4 读数据通道 ----
    input  wire [63:0] RDATA,
    input  wire [1:0]  RRESP,
    input  wire        RVALID,
    output wire        RREADY
);

    // 指针宽度: 存储体必须是 2^PW 深, 指针自然而然地回绕对齐.
    // 注意: 千万不要把存储体声明成 [0:QD-1] —— 指针回绕后会越界!
    localparam integer PW  = 7;            // 128 深
    localparam integer DEP = 1 << PW;      // 128

    // ==================== 命令 FIFO (存 addr[32] + hi_sel) ====================
    reg  [32:0] cfifo [0:DEP-1];
    reg  [PW-1:0] cw = 0, cr = 0;
    wire [PW-1:0] ccnt  = cw - cr;
    wire          cfull = (ccnt >= QD[PW-1:0]);
    wire          cempty = (cw == cr);

    assign cmd_ready = ~cfull;

    // ==================== 数据 FIFO (32 位字) ====================
    reg  [31:0]  dfifo [0:DEP-1];
    reg  [PW-1:0] dw = 0, dr = 0;
    wire [PW-1:0] dcnt  = dw - dr;
    wire          dfull = (dcnt >= QD[PW-1:0]);
    wire          dempty = (dw == dr);

    assign data_out   = dfifo[dr];
    assign data_valid = ~dempty;

    // ==================== hi_sel FIFO (每笔未完成读 1 bit) ====================
    reg          hfifo [0:DEP-1];
    reg  [PW-1:0] hw = 0, hr = 0;
    wire [PW-1:0] hcnt  = hw - hr;
    wire          hfull = (hcnt >= MAXO[PW-1:0]);
    wire          hempty = (hw == hr);

    // ==================== AR 通道 ====================
    reg        ar_hi   = 1'b0;        // 当前在 AR 通道上的读的 hi_sel
    wire       ar_hs   = ARVALID && ARREADY;

    // R 通道: 每笔读只返回 1 拍
    assign RREADY = ~dfull;

    // 组合: 本拍结束后 AR 通道是否空闲 (可装载下一笔命令)
    wire ar_can_load = (~ARVALID) | ar_hs;

    always @(posedge ACLK or negedge ARESETN) begin
        if (!ARESETN) begin
            cw <= 0; cr <= 0;
            dw <= 0; dr <= 0;
            hw <= 0; hr <= 0;
            ARVALID <= 1'b0;
            ARADDR  <= 32'h0;
            ARPROT  <= 3'b000;
            ar_hi   <= 1'b0;
            err     <= 1'b0;
        end else begin
            // ---------------- 命令入队 ----------------
            if (cmd_valid && cmd_ready) begin
                cfifo[cw] <= {cmd_addr[2], cmd_addr};
                cw <= cw + 1'b1;
            end

            // ---------------- 发起 AXI 读 (流水线, 无气泡) ----------------
            if (ar_hs) begin
                // 结算已发出的那笔: 记下它的 hi_sel, 等数据回来时用
                hfifo[hw] <= ar_hi;
                hw <= hw + 1'b1;
            end

            if (ar_can_load) begin
                if (!cempty && (hcnt < MAXO[PW-1:0])) begin
                    ar_hi   <= cfifo[cr][2];
                    ARADDR  <= {cfifo[cr][31:3], 3'b000};   // 8 字节对齐
                    ARPROT  <= 3'b000;
                    ARVALID <= 1'b1;
                    cr      <= cr + 1'b1;
                end else begin
                    ARVALID <= 1'b0;
                end
            end

            // ---------------- 接收读数据 ----------------
            if (RVALID && RREADY) begin
                if (!hempty) begin
                    dfifo[dw] <= (RRESP == 2'b00)
                                 ? (hfifo[hr] ? RDATA[63:32] : RDATA[31:0])
                                 : 32'hFFFFFFFF;   // 出错 → 全1 (引擎按终止符跳过)
                    dw <= dw + 1'b1;
                    hr <= hr + 1'b1;
                end
                if (RRESP != 2'b00)
                    err <= 1'b1;
            end

            // ---------------- 数据出队 ----------------
            if (data_valid && data_ready)
                dr <= dr + 1'b1;
        end
    end

    // 抑制未使用警告 (hfull 仅用于文档/调试)
    wire _unused = &{1'b0, hfull, hempty, dfull, ar_hi};

endmodule
