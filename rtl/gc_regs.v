// gc_regs.v — AXI-Lite 寄存器接口模块
//
// 寄存器映射见 csrc/fpga_gc.h
//
// 地址译码 12 位; 根集 256 项 (0x40 ~ 0x43F), 与 root_mem 容量一致.
module gc_regs (
    input  wire        ACLK,
    input  wire        ARESETN,

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

    input  wire [11:0] ARADDR,
    input  wire        ARVALID,
    output reg         ARREADY,
    output reg  [31:0] RDATA,
    output reg  [1:0]  RRESP,
    output reg         RVALID,
    input  wire        RREADY,

    output reg  [31:0] reg_obj_base,
    output reg  [31:0] reg_obj_count,
    output reg  [31:0] reg_root_count,
    output reg         reg_start = 1'b0,       // 单周期脉冲
    output reg         reg_clear_q = 1'b0,     // 单周期脉冲 (位图由引擎每轮自动清)

    input  wire        reg_done,
    input  wire [31:0] reg_marked_count,
    input  wire [31:0] reg_cycles,
    input  wire [11:0] q_head,
    input  wire [11:0] q_tail,

    input  wire        err_ovf,       // 队列溢出
    input  wire        err_rd,        // AXI 读响应错误
    input  wire        err_ref,       // 引用流失步
    input  wire        err_hdr,       // 对象头非法 (ref_count > 4096)

    output reg  [11:0] reg_bm_addr,   // 0x24: 探针地址
    input  wire [31:0] reg_bm_data,   // 0x28: 探针数据

    output reg  [7:0]  root_wr_addr = 8'd0,
    output reg  [31:0] root_wr_data = 32'd0,
    output reg         root_we = 1'b0
);

    reg [11:0] awaddr_r = 12'd0;
    reg [11:0] araddr_r = 12'd0;
    reg        aw_pending = 1'b0;      // 地址已锁存, 等数据
    reg        w_pending  = 1'b0;      // 数据已锁存, 等发响应

    // Byte enables: each 8-bit lane is either written or held.
    wire [31:0] wmask = {{8{WSTRB[3]}}, {8{WSTRB[2]}}, {8{WSTRB[1]}}, {8{WSTRB[0]}}};

    // AWREADY 仅在地址槽为空时拉高
    assign AWREADY = ~aw_pending & ~BVALID;
    assign WREADY  = aw_pending & ~w_pending & ~BVALID;

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

            if (AWVALID && AWREADY) begin
                awaddr_r   <= AWADDR;
                aw_pending <= 1'b1;
            end

            if (WVALID && WREADY) begin
                w_pending <= 1'b1;
                case (awaddr_r)
                    12'h000: begin
                        reg_start    <= WDATA[0];
                        // WDATA[1] 未使用 (位图每轮自动清除)
                        reg_clear_q  <= WDATA[2];
                    end
                    12'h004: reg_obj_base   <= (reg_obj_base   & ~wmask) | (WDATA & wmask);
                    12'h008: reg_obj_count  <= (reg_obj_count  & ~wmask) | (WDATA & wmask);
                    12'h00C: reg_root_count <= (reg_root_count & ~wmask) | (WDATA & wmask);
                    12'h024: reg_bm_addr    <= (reg_bm_addr & ~wmask[11:0]) | (WDATA[11:0] & wmask[11:0]);
                    default: begin
                        if ((awaddr_r >= 12'h040) && (awaddr_r < 12'h440)) begin
                            root_wr_addr <= awaddr_r[9:2] - 8'h10;   // (addr>>2) - 16
                            root_wr_data <= WDATA;
                            root_we      <= 1'b1;
                        end
                    end
                endcase
            end

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
                RRESP <= 2'b00;   // OKAY unless the case overrides it (unmapped -> SLVERR)
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
                    default: begin RDATA <= 32'hDEADBEEF; RRESP <= 2'b10; end   // SLVERR
                endcase
                RVALID  <= 1'b1;
                // (RRESP already set above)
                ARREADY <= 1'b0;
            end

            if (RVALID && RREADY) begin
                RVALID <= 1'b0;
            end
        end
    end

endmodule
