// ============================================================
// gc_mark_engine.v — BFS标记引擎 (核心状态机)
//
// 清零方案: 引擎通过写口逐拍写0到位图 (4096拍)
//   不依赖bitmap模块内部逻辑, bitmap是纯BRAM
//
// 对象图DDR格式:
//   对象k头 @ obj_base + k*16
//     [id:4][ref_count:4][ref_array_phys_addr:4][reserved:4]
//   引用数组 @ ref_array_phys_addr
//     [ref0][ref1]...[refN-1][0xFFFFFFFF]
// ============================================================
module gc_mark_engine (
    input  wire        clk,
    input  wire        rst_n,

    // 控制输入
    input  wire [31:0] obj_base,
    input  wire [31:0] obj_count,
    input  wire [31:0] root_count,
    input  wire        start,

    // 根集读取 (同步BRAM)
    output reg  [7:0]  root_rd_addr,
    input  wire [31:0] root_rd_data,

    // BFS队列
    output reg         q_push,
    output reg  [11:0] q_push_data,
    output reg  [11:0] q_push_addr,
    output reg         q_pop,
    input  wire        q_pop_ack,
    input  wire [11:0] q_pop_id,
    input  wire [11:0] q_tail,
    input  wire        q_empty,

    // 标记位图 (纯BRAM: 引擎通过写口清零)
    output reg  [11:0] bm_addr,
    output reg  [31:0] bm_wdata,
    input  wire [31:0] bm_rdata,
    output reg         bm_we,

    // DDR读接口
    output reg  [31:0] rd_addr,
    output reg         rd_start,
    input  wire        rd_done,
    input  wire [31:0] rd_data,

    // 状态输出
    output reg         done,
    output reg  [31:0] marked_count,
    output reg  [31:0] cycles
);

    localparam [11:0] Q_MAX = 12'd4000;

    // ==================== 状态编码 ====================
    localparam [4:0]
        S_IDLE       = 5'd0,
        S_CLR_BM     = 5'd1,   // 逐拍写0清位图
        S_RD_ROOT    = 5'd2,
        S_ROOT_WAIT  = 5'd3,
        S_ROOT_DATA  = 5'd4,
        S_ROOT_MARK  = 5'd5,
        S_ROOT_PUSH  = 5'd6,
        S_POP        = 5'd7,
        S_POP_WAIT   = 5'd8,
        S_RD_REFC    = 5'd9,
        S_REFC_RUN   = 5'd10,
        S_REFC_WAIT  = 5'd11,
        S_RD_REFA    = 5'd12,  // 读 ref_array_phys_addr
        S_REFA_RUN   = 5'd13,
        S_REFA_WAIT  = 5'd14,
        S_RD_REF     = 5'd15,
        S_REF_RUN    = 5'd16,
        S_REF_WAIT   = 5'd17,
        S_BM_WAIT1   = 5'd18,
        S_BM_WAIT2   = 5'd19,
        S_BM_CHECK   = 5'd20,
        S_PUSH       = 5'd21,
        S_NEXT_REF   = 5'd22,
        S_DONE       = 5'd23;

    reg [4:0]  state;
    reg [11:0] cur_obj;
    reg [31:0] ref_count;
    reg [31:0] ref_ptr;
    reg [31:0] ref_addr;      // 引用数组物理地址 (从对象头+8读取)
    reg [31:0] root_idx;
    reg [11:0] pending_obj;
    reg [31:0] cycles_r;
    reg [31:0] marked_r;
    reg [11:0] clr_ptr;       // 位图清零指针

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            done         <= 1'b1;
            marked_count <= 32'h0;
            cycles       <= 32'h0;
            cycles_r     <= 32'h0;
            marked_r     <= 32'h0;
            cur_obj      <= 12'h0;
            ref_count    <= 32'h0;
            ref_ptr      <= 32'h0;
            ref_addr     <= 32'h0;
            root_idx     <= 32'h0;
            pending_obj  <= 12'h0;
            clr_ptr      <= 12'h0;
            rd_addr      <= 32'h0;
            rd_start     <= 1'b0;
            q_push       <= 1'b0;
            q_pop        <= 1'b0;
            bm_addr      <= 12'h0;
            bm_wdata     <= 32'h0;
            bm_we        <= 1'b0;
            root_rd_addr <= 8'h0;
            q_push_data  <= 12'h0;
            q_push_addr  <= 12'h0;
        end else begin
            rd_start <= 1'b0;
            q_push   <= 1'b0;
            q_pop    <= 1'b0;
            bm_we    <= 1'b0;

            if (state != S_IDLE && state != S_DONE)
                cycles_r <= cycles_r + 32'd1;

            case (state)

                S_IDLE: begin
                    cycles_r <= 32'h0;
                    marked_r <= 32'h0;
                    if (start) begin
                        done     <= 1'b0;
                        root_idx <= 32'h0;
                        clr_ptr  <= 12'h0;
                        state    <= S_CLR_BM;
                    end
                end

                // ===== 清位图: 逐拍写0 (4096拍) =====
                S_CLR_BM: begin
                    bm_addr  <= clr_ptr;
                    bm_wdata <= 32'h0;
                    bm_we    <= 1'b1;
                    if (clr_ptr == 12'd4095) begin
                        state <= S_RD_ROOT;
                    end else begin
                        clr_ptr <= clr_ptr + 12'd1;
                    end
                end

                // ===== 加载根集 =====
                S_RD_ROOT: begin
                    if (root_idx < root_count) begin
                        root_rd_addr <= root_idx[7:0];
                        state        <= S_ROOT_WAIT;
                    end else begin
                        state <= S_POP;
                    end
                end

                S_ROOT_WAIT: state <= S_ROOT_DATA;

                S_ROOT_DATA: begin
                    if (root_rd_data < obj_count) begin
                        pending_obj <= root_rd_data[11:0];
                        state       <= S_ROOT_MARK;
                    end else begin
                        root_idx <= root_idx + 32'd1;
                        state    <= S_RD_ROOT;
                    end
                end

                S_ROOT_MARK: begin
                    bm_addr  <= pending_obj;
                    bm_wdata <= 32'h1 << pending_obj[4:0];
                    bm_we    <= 1'b1;
                    state    <= S_ROOT_PUSH;
                end

                S_ROOT_PUSH: begin
                    if (q_tail < Q_MAX) begin
                        q_push_data <= pending_obj;
                        q_push_addr <= q_tail;
                        q_push      <= 1'b1;
                        marked_r    <= marked_r + 32'd1;
                    end
                    root_idx <= root_idx + 32'd1;
                    state    <= S_RD_ROOT;
                end

                // ===== BFS主循环 =====
                S_POP: begin
                    if (q_empty)
                        state <= S_DONE;
                    else begin
                        q_pop <= 1'b1;
                        state <= S_POP_WAIT;
                    end
                end

                S_POP_WAIT: begin
                    if (q_pop_ack) begin
                        cur_obj <= q_pop_id;
                        state   <= S_RD_REFC;
                    end
                end

                S_RD_REFC: begin
                    rd_addr  <= obj_base + {20'h0, cur_obj} * 32'd16 + 32'd4;
                    rd_start <= 1'b1;
                    state    <= S_REFC_RUN;
                end

                // 等待rd_done拉低, 确认读事务已启动 (防CDC延迟误判)
                S_REFC_RUN: begin
                    if (!rd_done)
                        state <= S_REFC_WAIT;
                end

                S_REFC_WAIT: begin
                    if (rd_done) begin
                        ref_count <= rd_data;
                        ref_ptr   <= 32'h0;
                        if (rd_data == 32'h0)
                            state <= S_POP;
                        else
                            state <= S_RD_REFA;
                    end
                end

                // ===== 读引用数组物理地址 (对象头+8) =====
                S_RD_REFA: begin
                    rd_addr  <= obj_base + {20'h0, cur_obj} * 32'd16 + 32'd8;
                    rd_start <= 1'b1;
                    state    <= S_REFA_RUN;
                end

                S_REFA_RUN: begin
                    if (!rd_done)
                        state <= S_REFA_WAIT;
                end

                S_REFA_WAIT: begin
                    if (rd_done) begin
                        ref_addr <= rd_data;
                        state    <= S_RD_REF;
                    end
                end

                S_RD_REF: begin
                    // 使用ref_array_phys_addr (从对象头+8读取)
                    rd_addr  <= ref_addr + ref_ptr * 32'd4;
                    rd_start <= 1'b1;
                    state    <= S_REF_RUN;
                end

                // 等待rd_done拉低, 确认读事务已启动
                S_REF_RUN: begin
                    if (!rd_done)
                        state <= S_REF_WAIT;
                end

                S_REF_WAIT: begin
                    if (rd_done) begin
                        if (rd_data == 32'hFFFFFFFF)
                            state <= S_POP;
                        else if (rd_data >= obj_count) begin
                            ref_ptr <= ref_ptr + 32'd1;
                            state   <= S_RD_REF;
                        end else begin
                            pending_obj <= rd_data[11:0];
                            bm_addr     <= rd_data[11:0];
                            state       <= S_BM_WAIT1;
                        end
                    end
                end

                S_BM_WAIT1: state <= S_BM_WAIT2;
                S_BM_WAIT2: state <= S_BM_CHECK;

                S_BM_CHECK: begin
                    if (!bm_rdata[pending_obj[4:0]])
                        state <= S_PUSH;
                    else
                        state <= S_NEXT_REF;
                end

                S_PUSH: begin
                    bm_addr  <= pending_obj;
                    bm_wdata <= 32'h1 << pending_obj[4:0];
                    bm_we    <= 1'b1;
                    if (q_tail < Q_MAX) begin
                        q_push_data <= pending_obj;
                        q_push_addr <= q_tail;
                        q_push      <= 1'b1;
                        marked_r    <= marked_r + 32'd1;
                    end
                    state <= S_NEXT_REF;
                end

                S_NEXT_REF: begin
                    ref_ptr <= ref_ptr + 32'd1;
                    if (ref_ptr + 32'd1 >= ref_count)
                        state <= S_POP;
                    else
                        state <= S_RD_REF;
                end

                S_DONE: begin
                    done         <= 1'b1;
                    marked_count <= marked_r;
                    cycles       <= cycles_r;
                    state        <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
