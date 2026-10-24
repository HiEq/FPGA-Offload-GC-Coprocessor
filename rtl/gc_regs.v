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

    output reg         reg_abort,
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
    input  wire        reg_idle,      // engine_idle: state == S_IDLE

    output reg  [11:0] reg_bm_addr,   // 0x24: 探针地址
    input  wire [31:0] reg_bm_data,   // 0x28: 探针数据

    // Phase 2 free-list: 0x38 count, 0x3C pop data
    input  wire [31:0] reg_free_count,
    input  wire [11:0] reg_free_data,
    input  wire        reg_free_busy,
    output reg         reg_free_pop,

    // Phase 3A dirty set: 0x44 push/occupancy, 0x48 status, 0x4C drained
    output reg         reg_dirty_push,        // 1-cycle: push WDATA[11:0]
    output reg  [11:0] reg_dirty_push_id,
    output reg         reg_dirty_flush,       // 1-cycle: clear FIFO + overflow
    output reg         reg_bm_keep,           // level: keep the bitmap (incremental epoch)
    input  wire [8:0]  dirty_count,
    input  wire        dirty_empty,
    input  wire        dirty_ovf,
    input  wire [31:0] dirty_drained,
    input  wire [15:0] dirty_pushed,
    input  wire [15:0] dirty_popped,

    output reg  [7:0]  root_wr_addr = 8'd0,
    output reg  [31:0] root_wr_data = 32'd0,
    output reg         root_we = 1'b0
);

    reg [11:0] dirty_last_id = 12'h0;  // 最后被接受的 DIRTY_PUSH id (AGENTS #20 回执)
    reg [3:0]  dirty_tag = 4'hF;   // last accepted DIRTY_PUSH tag (reset to an
                                   // unused value so a fresh process starting at
                                   // tag 0 is accepted; NOT cleared by flush)
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
            reg_abort      <= 1'b0;
            reg_clear_q    <= 1'b0;
            reg_bm_keep    <= 1'b0;
            reg_dirty_push <= 1'b0;
            reg_dirty_flush<= 1'b0;
            reg_bm_addr    <= 12'h0;
            root_wr_addr   <= 8'h0;
            root_wr_data   <= 32'h0;
            root_we        <= 1'b0;
            dirty_tag      <= 4'hF;     // unused tag so a fresh sequence at 0 is accepted
            dirty_last_id  <= 12'h0;
            awaddr_r       <= 12'h0;
        end else begin
            // 单周期脉冲默认清零
            reg_start    <= 1'b0;
            reg_abort    <= 1'b0;
            reg_clear_q  <= 1'b0;
            reg_dirty_push  <= 1'b0;
            reg_dirty_flush <= 1'b0;
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
                        // WDATA[1] 未使用
                        reg_clear_q  <= WDATA[2];
                        reg_abort    <= WDATA[3];   // 1 = abort the running mark
                        reg_bm_keep  <= WDATA[4];   // Phase 3A: 1 = keep the bitmap across the run
                        reg_dirty_flush <= WDATA[5];// Phase 3A: clear dirty FIFO + overflow
                    end
                    12'h440: begin
                        // Phase 3A: DIRTY_PUSH -- command-with-tag.
                        // This board's AXI-Lite write path delivers every write
                        // twice (measured: any width, 2 records per store), so the
                        // push fires only when the tag WDATA[15:12] CHANGES; the
                        // duplicate delivery of the same write is ignored.  The tag
                        // is robust to any multiplicity of redelivery.
                        if (WDATA[15:12] != dirty_tag) begin
                            reg_dirty_push    <= 1'b1;
                            reg_dirty_push_id <= WDATA[11:0];
                            dirty_last_id     <= WDATA[11:0];   // id 级回执 (AGENTS #20)
                            dirty_tag         <= WDATA[15:12];
                        end
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
            ARREADY       <= 1'b0;
            RVALID        <= 1'b0;
            RDATA         <= 32'h0;
            RRESP         <= 2'b00;
            araddr_r      <= 12'h0;
            reg_free_pop  <= 1'b0;
        end else begin
            reg_free_pop <= 1'b0;
            if (ARVALID && !ARREADY && !RVALID) begin
                ARREADY  <= 1'b1;
                araddr_r <= ARADDR;
            end

            if (ARREADY && !RVALID) begin
                RRESP <= 2'b00;   // OKAY unless the case overrides it (unmapped -> SLVERR)
                case (araddr_r)
                    12'h000: RDATA <= {reg_done, 25'h0, 1'b0, reg_bm_keep, 1'b0, reg_clear_q, 1'b0, reg_start};
                    12'h004: RDATA <= reg_obj_base;
                    12'h008: RDATA <= reg_obj_count;
                    12'h00C: RDATA <= reg_root_count;
                    12'h010: RDATA <= reg_marked_count;
                    12'h014: RDATA <= reg_cycles;
                    12'h018: RDATA <= {20'h0, q_head};
                    12'h01C: RDATA <= {20'h0, q_tail};
                    12'h020: RDATA <= {26'h0, reg_free_busy, reg_idle, err_hdr, err_ref, err_rd, err_ovf};
                    12'h024: RDATA <= {20'h0, reg_bm_addr};
                    12'h028: RDATA <= reg_bm_data;
                    12'h030: RDATA <= 32'h47434343;   // 'GCCC' magic
                    12'h034: RDATA <= 32'h0004_0200;  // version 4.2 (Phase 3A dirty set)
                    12'h038: RDATA <= reg_free_count;
                    12'h03C: begin
                        RDATA        <= {20'h0, reg_free_data};
                        reg_free_pop <= 1'b1;
                    end
                    12'h440: RDATA <= {23'h0, dirty_count};                    // dirty FIFO occupancy
                    12'h444: RDATA <= {dirty_last_id, dirty_tag, 5'h0, ~dirty_empty, dirty_ovf, dirty_count}; // [31:20] id, [19:16] tag, [10] pending, [9] ovf, [8:0] occ
                    12'h448: RDATA <= dirty_drained;                            // consumed this epoch
                    12'h44C: RDATA <= {16'h0, dirty_pushed};                    // accepted since flush
                    12'h450: RDATA <= {16'h0, dirty_popped};                    // consumed since flush
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
