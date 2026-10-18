// ============================================================
// gc_regs.v — AXI-Lite 寄存器接口模块
//
// 寄存器映射表:
//   偏移    名称           R/W   位域说明
//   0x00   CTRL           R/W   [0]=start [1]=clear_bm [2]=clear_q [31]=done
//   0x04   OBJ_BASE       R/W   对象图DDR物理基地址
//   0x08   OBJ_COUNT      R/W   对象总数
//   0x0C   ROOT_COUNT     R/W   根集数量
//   0x10   MARKED         R     标记对象数 (只读)
//   0x14   CYCLES         R     硬件周期计数 (只读)
//   0x18   Q_HEAD         R     BFS队列头指针 (只读)
//   0x1C   Q_TAIL         R     BFS队列尾指针 (只读)
//   0x20   STATUS         R     [0]=队列溢出 [1]=AXI读错误 [2]=引用流失步 [3]=非法对象头
//   0x24   BM_ADDR        R/W   位图探针地址 (0~4095, 引擎空闲时有效)
//   0x28   BM_DATA        R     位图探针数据 = mem[BM_ADDR] (1 拍延迟后更新)
//   0x40+  ROOT_LIST[i]   W     根集数组: 0x40 + i*4 = 第i个根对象ID (最多256个)
//
// 地址译码 12 位; 根集 256 项 (0x40 ~ 0x43F), 与 root_mem 容量一致.
// ============================================================
module gc_regs (
    input  wire        ACLK,
    input  wire        ARESETN,

    // ---- AXI-Lite 写通道 ----
    input  wire [11:0] AWADDR,
    input  wire        AWVALID,
    output wire        AWREADY,
    input  wire [31:0] WDATA,
    input  wire [3:0]  WSTRB,
    input  wire        WVALID,
    output wire        WREADY,
    output reg  [1:0]  BRESP,
    output reg         BVALID,
    input  wire        BREADY,

    // ---- AXI-Lite 读通道 ----
    input  wire [11:0] ARADDR,
    input  wire        ARVALID,
    output reg         ARREADY,
    output reg  [31:0] RDATA,
    output reg  [1:0]  RRESP,
    output reg         RVALID,
    input  wire        RREADY,

    // ---- 控制输出 (到标记引擎) ----
    output reg  [31:0] reg_obj_base,
    output reg  [31:0] reg_obj_count,
    output reg  [31:0] reg_root_count,
    output reg         reg_start = 1'b0,       // 单周期脉冲
    output reg         reg_clear_q = 1'b0,     // 单周期脉冲 (位图由引擎每轮自动清)

    // ---- 状态输入 (来自标记引擎) ----
    input  wire        reg_done,
    input  wire [31:0] reg_marked_count,
    input  wire [31:0] reg_cycles,
    input  wire [11:0] q_head,
    input  wire [11:0] q_tail,

    // ---- 错误输入 (粘滞, 由引擎/读主控提供) ----
    input  wire        err_ovf,       // 队列溢出
    input  wire        err_rd,        // AXI 读响应错误
    input  wire        err_ref,       // 引用流失步
    input  wire        err_hdr,       // 对象头非法 (ref_count > 4096)

    // ---- 位图探针 (软件读回标记位) ----
    output reg  [11:0] reg_bm_addr,   // 0x24: 探针地址
    input  wire [31:0] reg_bm_data,   // 0x28: 探针数据

    // ---- 根集写入端口 ----
    output reg  [7:0]  root_wr_addr = 8'd0,
    output reg  [31:0] root_wr_data = 32'd0,
    output reg         root_we = 1'b0
);

    reg [11:0] awaddr_r = 12'd0;
    reg [11:0] araddr_r = 12'd0;
    reg        aw_pending = 1'b0;      // 地址已锁存, 等数据
    reg        w_pending  = 1'b0;      // 数据已锁存, 等发响应

    // 未使用 WSTRB (全 32 位写)
    wire _unused_wstrb = &{1'b0, WSTRB};

    // AWREADY 仅在地址槽为空时拉高
    assign AWREADY = ~aw_pending & ~BVALID;
    assign WREADY  = aw_pending & ~w_pending & ~BVALID;

    // ==================== 写通道 ====================
    always @(posedge ACLK or negedge ARESETN) begin
        if (!ARESETN) begin
            BVALID         <= 1'b0;
            BRESP          <= 2'b00;
            aw_pending     <= 1'b0;
            w_pending      <= 1'b0;
            reg_obj_base   <= 32'h0;
            reg_obj_count  <= 32'h0;
            reg_root_count <= 32'h0;
            reg_start      <= 1'b0;
            reg_clear_q    <= 1'b0;
            reg_bm_addr    <= 12'h0;
            root_wr_addr   <= 8'h0;
            root_wr_data   <= 32'h0;
            root_we        <= 1'b0;
            awaddr_r       <= 12'h0;
        end else begin
            // 单周期脉冲默认清零
            reg_start    <= 1'b0;
            reg_clear_q  <= 1'b0;
            root_we      <= 1'b0;

            // 阶段1: 地址槽空 → 接收写地址
            if (AWVALID && AWREADY) begin
                awaddr_r   <= AWADDR;
                aw_pending <= 1'b1;
            end

            // 阶段2: 地址到手且数据槽空 → 接收写数据并解码
            if (WVALID && WREADY) begin
                w_pending <= 1'b1;
                case (awaddr_r)
                    12'h000: begin
                        reg_start    <= WDATA[0];
                        // WDATA[1] 未使用 (位图每轮自动清除)
                        reg_clear_q  <= WDATA[2];
                    end
                    12'h004: reg_obj_base   <= WDATA;
                    12'h008: reg_obj_count  <= WDATA;
                    12'h00C: reg_root_count <= WDATA;
                    12'h024: reg_bm_addr    <= WDATA[11:0];
                    default: begin
                        // 根集写入: 0x40 ~ 0x43F (256 项)
                        if ((awaddr_r >= 12'h040) && (awaddr_r < 12'h440)) begin
                            root_wr_addr <= awaddr_r[9:2] - 8'h10;   // (addr>>2) - 16
                            root_wr_data <= WDATA;
                            root_we      <= 1'b1;
                        end
                    end
                endcase
            end

            // 阶段3: 地址+数据都到齐 → 发写响应
            if (aw_pending && w_pending && !BVALID) begin
                BVALID     <= 1'b1;
                BRESP      <= 2'b00;
                aw_pending <= 1'b0;
                w_pending  <= 1'b0;
            end
            if (BVALID && BREADY) begin
                BVALID <= 1'b0;
            end
        end
    end

    // ==================== 读通道 ====================
    always @(posedge ACLK or negedge ARESETN) begin
        if (!ARESETN) begin
            ARREADY <= 1'b0;
            RVALID  <= 1'b0;
            RDATA   <= 32'h0;
            RRESP   <= 2'b00;
            araddr_r<= 12'h0;
        end else begin
            if (ARVALID && !ARREADY && !RVALID) begin
                ARREADY  <= 1'b1;
                araddr_r <= ARADDR;
            end

            if (ARREADY && !RVALID) begin
                case (araddr_r)
                    12'h000: RDATA <= {reg_done, 28'h0, reg_clear_q, 1'b0, reg_start};
                    12'h004: RDATA <= reg_obj_base;
                    12'h008: RDATA <= reg_obj_count;
                    12'h00C: RDATA <= reg_root_count;
                    12'h010: RDATA <= reg_marked_count;
                    12'h014: RDATA <= reg_cycles;
                    12'h018: RDATA <= {20'h0, q_head};
                    12'h01C: RDATA <= {20'h0, q_tail};
                    12'h020: RDATA <= {28'h0, err_hdr, err_ref, err_rd, err_ovf};
                    12'h024: RDATA <= {20'h0, reg_bm_addr};
                    12'h028: RDATA <= reg_bm_data;
                    default: RDATA <= 32'hDEADBEEF;
                endcase
                RVALID  <= 1'b1;
                RRESP   <= 2'b00;
                ARREADY <= 1'b0;
            end

            if (RVALID && RREADY) begin
                RVALID <= 1'b0;
            end
        end
    end

endmodule
