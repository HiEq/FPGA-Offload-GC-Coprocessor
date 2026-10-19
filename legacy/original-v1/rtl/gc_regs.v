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
//   0x40+  ROOT_LIST[i]   W     根集数组: 0x40 + i*4 = 第i个根对象ID
// ============================================================
module gc_regs (
    input  wire        ACLK,
    input  wire        ARESETN,

    // ---- AXI-Lite 写通道 ----
    input  wire [7:0]  AWADDR,
    input  wire        AWVALID,
    output reg         AWREADY,
    input  wire [31:0] WDATA,
    input  wire [3:0]  WSTRB,
    input  wire        WVALID,
    output reg         WREADY,
    output reg  [1:0]  BRESP,
    output reg         BVALID,
    input  wire        BREADY,

    // ---- AXI-Lite 读通道 ----
    input  wire [7:0]  ARADDR,
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
    output reg         reg_clear_bm = 1'b0,    // 单周期脉冲
    output reg         reg_clear_q = 1'b0,     // 单周期脉冲

    // ---- 状态输入 (来自标记引擎) ----
    input  wire        reg_done,
    input  wire [31:0] reg_marked_count,
    input  wire [31:0] reg_cycles,
    input  wire [11:0] q_head,
    input  wire [11:0] q_tail,

    // ---- 根集写入端口 ----
    output reg  [7:0]  root_wr_addr = 8'd0,
    output reg  [31:0] root_wr_data = 32'd0,
    output reg         root_we = 1'b0
);

    reg [7:0] awaddr_r = 8'd0;
    reg [7:0] araddr_r = 8'd0;

    // 消除未使用WSTRB的警告 (全32位写, 不用字节选通)
    wire _unused_wstrb = &{1'b0, WSTRB};

    // ==================== 写通道状态机 ====================
    always @(posedge ACLK or negedge ARESETN) begin
        if (!ARESETN) begin
            AWREADY        <= 1'b0;
            WREADY         <= 1'b0;
            BVALID         <= 1'b0;
            BRESP          <= 2'b00;
            reg_obj_base   <= 32'h0;
            reg_obj_count  <= 32'h0;
            reg_root_count <= 32'h0;
            reg_start      <= 1'b0;
            reg_clear_bm   <= 1'b0;
            reg_clear_q    <= 1'b0;
            root_wr_addr   <= 8'h0;
            root_wr_data   <= 32'h0;
            root_we        <= 1'b0;
            awaddr_r       <= 8'h0;
        end else begin
            // 单周期脉冲默认清零
            reg_start    <= 1'b0;
            reg_clear_bm <= 1'b0;
            reg_clear_q  <= 1'b0;   // 改为脉冲: 自动清除, 不会卡住队列
            root_we      <= 1'b0;

            // 阶段1: 接收写地址
            if (AWVALID && !AWREADY && !BVALID) begin
                AWREADY  <= 1'b1;
                awaddr_r <= AWADDR;
            end

            // 阶段2: 接收写数据并解码
            if (WVALID && !WREADY && AWREADY) begin
                WREADY <= 1'b1;
                case (awaddr_r)
                    8'h00: begin
                        reg_start    <= WDATA[0];
                        reg_clear_bm <= WDATA[1];
                        reg_clear_q  <= WDATA[2];
                    end
                    8'h04: reg_obj_base   <= WDATA;
                    8'h08: reg_obj_count  <= WDATA;
                    8'h0C: reg_root_count <= WDATA;
                    default: begin
                        // 根集写入: 0x40 ~ 0xFC (最多48个根)
                        // 偏移0x40对应索引0, 需要减去16 (0x40>>2=16)
                        if (awaddr_r >= 8'h40) begin
                            root_wr_addr <= awaddr_r[7:2] - 6'h10;  // 基地址偏移修正
                            root_wr_data <= WDATA;
                            root_we      <= 1'b1;
                        end
                    end
                endcase
            end

            // 阶段3: 发送写响应
            if (AWREADY && WREADY && !BVALID) begin
                BVALID  <= 1'b1;
                BRESP   <= 2'b00;
                AWREADY <= 1'b0;
                WREADY  <= 1'b0;
            end
            if (BVALID && BREADY) begin
                BVALID <= 1'b0;
            end
        end
    end

    // ==================== 读通道状态机 ====================
    always @(posedge ACLK or negedge ARESETN) begin
        if (!ARESETN) begin
            ARREADY <= 1'b0;
            RVALID  <= 1'b0;
            RDATA   <= 32'h0;
            RRESP   <= 2'b00;
            araddr_r<= 8'h0;
        end else begin
            // 接收读地址
            if (ARVALID && !ARREADY && !RVALID) begin
                ARREADY  <= 1'b1;
                araddr_r <= ARADDR;
            end

            // 返回读数据
            if (ARREADY && !RVALID) begin
                case (araddr_r)
                    8'h00:   RDATA <= {reg_done, 28'h0, reg_clear_q, reg_clear_bm, reg_start};
                    8'h04:   RDATA <= reg_obj_base;
                    8'h08:   RDATA <= reg_obj_count;
                    8'h0C:   RDATA <= reg_root_count;
                    8'h10:   RDATA <= reg_marked_count;
                    8'h14:   RDATA <= reg_cycles;
                    8'h18:   RDATA <= {20'h0, q_head};
                    8'h1C:   RDATA <= {20'h0, q_tail};
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
