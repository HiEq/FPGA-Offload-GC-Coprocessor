// ============================================================
// gc_mark_engine.v — BFS标记引擎 (核心状态机)
//
// 对象图DDR格式:
//   对象k头 @ obj_base + k*16
//     [id:4][ref_count:4][ref_array_phys_addr:4][reserved:4]
//   引用数组 @ ref_array_phys_addr
//     [ref0][ref1]...[refN-1][0xFFFFFFFF]
//
// === 三项优化 (2026) ===
//
// (1) 对象头两笔读并发 (阶段1)
//     头+4(ref_count) 和 头+8(ref_addr) 地址互不依赖 → 同时压入 → 1 次往返.
//
// (2) 引用读"压入/取回交错" + 对象头投机预取 (阶段2)
//     引用命令边压边收, 队列满了就先收, 因此 ref_count 不限 (旧版 REF_MAX=64
//     会静默截断, 已移除). 并且在"当前对象的引用命令全部压完"之后, 立刻从队列
//     里弹下一个对象、把它的两笔头读也压进去 —— 于是**下一个对象的对象头延迟
//     被当前对象的引用处理完全掩盖**, 每个对象只剩 1 次往返暴露.
//     安全性: 预取只在"取回优先、当前无数据可取"时发起, 此刻未取回的命令数
//     上界是读主控的 MAXO(16) < 命令FIFO容量(80), 所以不会出现"压不进又取不回"
//     的死锁.
//
// (3) 逐引用快路径 (每次未标记引用 2 拍)
//     位图是读/写地址独立的简单双口 BRAM:
//       读: 取到引用值的那一拍就摆读地址(组合) → 下一拍 bm_rdata 可用
//       写: 判定那一拍同时发写地址+脉冲 → 下一拍落盘
//     于是 取-判-置位-入队 只要 2 拍 (旧版 6 拍), 且读写互不踩.
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
    output reg  [7:0]  root_rd_addr = 8'd0,
    input  wire [31:0] root_rd_data,

    // BFS队列
    output reg         q_push = 1'b0,
    output reg  [11:0] q_push_data = 12'd0,
    output reg  [11:0] q_push_addr = 12'd0,
    output reg         q_pop = 1'b0,
    input  wire        q_pop_ack,
    input  wire [11:0] q_pop_id,
    input  wire [11:0] q_tail,
    input  wire        q_empty,

    // 标记位图 (简单双口BRAM: 读口/写口地址独立)
    output wire [11:0] bm_raddr,            // 读地址 (组合, 1拍后 bm_rdata 有效)
    input  wire [31:0] bm_rdata,
    output reg  [11:0] bm_waddr = 12'd0,    // 写地址
    output reg  [31:0] bm_wdata = 32'd0,
    output reg         bm_we = 1'b0,

    // DDR读命令队列接口 (→ gc_axi_read)
    output reg  [31:0] rd_cmd_addr = 32'd0,
    output reg         rd_cmd_valid = 1'b0,
    input  wire        rd_cmd_ready,
    input  wire [31:0] rd_data,
    input  wire        rd_data_valid,
    output wire        rd_data_ready,

    // 状态输出
    output reg         done = 1'b0,
    output reg  [31:0] marked_count = 32'd0,
    output reg  [31:0] cycles = 32'd0
);

    localparam [11:0] Q_MAX = 12'd4000;

    // ==================== 状态编码 ====================
    localparam [4:0]
        S_IDLE       = 5'd0,
        S_CLR_BM     = 5'd1,
        S_RD_ROOT    = 5'd2,
        S_ROOT_WAIT  = 5'd3,
        S_ROOT_DATA  = 5'd4,
        S_ROOT_MARK  = 5'd5,
        S_ROOT_PUSH  = 5'd6,
        S_POP        = 5'd7,
        S_POP_WAIT   = 5'd8,
        S_HDR_P1     = 5'd9,   // 压入 头+4
        S_HDR_P2     = 5'd10,  // 压入 头+8
        S_HDR_P3     = 5'd11,
        S_HDR_G1     = 5'd12,  // 取 ref_count
        S_HDR_G2     = 5'd13,  // 取 ref_addr
        S_REFS_LOOP  = 5'd14,  // 引用阶段: 压入/取回 交错
        S_REFS_PUSHW = 5'd15,
        S_REF_DEC    = 5'd16,  // 判定 + 置位 + 入队 (1拍)
        S_PF_WAIT    = 5'd17,  // 预取: 弹下一个对象
        S_PF_H1      = 5'd18,  // 预取: 压 头+4
        S_PF_H2      = 5'd19,  // 预取: 压 头+8
        S_PF_H3      = 5'd20,
        S_PF_G1      = 5'd21,  // 预取: 取 ref_count
        S_PF_G2      = 5'd22,  // 预取: 取 ref_addr → 成为当前对象
        S_DONE       = 5'd23;

    reg [4:0]  state = 5'd0;
    reg [11:0] cur_obj = 12'd0;
    reg [31:0] ref_count = 32'd0;
    reg [31:0] ref_addr = 32'd0;
    reg [31:0] ref_push_idx = 32'd0;
    reg [31:0] ref_got = 32'd0;
    reg [31:0] ref_val = 32'd0;
    reg [31:0] prev_ref = 32'hFFFFFFFF;   // 上一笔被标记的引用值 (挡住"相邻重复")
    reg        ref_stop = 1'b0;
    reg [31:0] root_idx = 32'd0;
    reg [11:0] pending_obj = 12'd0;
    reg [31:0] cycles_r;
    reg [31:0] marked_r;
    reg [11:0] clr_ptr;
    // 投机预取
    reg [11:0] pf_obj = 12'd0;
    reg        pf_valid = 1'b0;    // 已弹出且头命令已压入, 只等取回
    reg        pf_tried = 1'b0;    // 本对象已经发起过预取 (防重复弹队列)

    // 位图读地址: 组合输出, 和"取到引用值"同拍发出
    assign bm_raddr = (state == S_REFS_LOOP) ? rd_data[11:0] : 12'd0;

    // 引用命令是否已全部压完 (或已见终止符)
    wire refs_pushed = (ref_stop | (ref_push_idx >= ref_count));
    // 引用阶段结束: 全部压完 且 全部取回
    wire refs_done   = refs_pushed & (ref_got >= ref_push_idx);

    // 只在需要下一笔数据时拉高 ready
    assign rd_data_ready = (state == S_HDR_G1) |
                           (state == S_HDR_G2) |
                           (state == S_PF_G1)  |
                           (state == S_PF_G2)  |
                           ((state == S_REFS_LOOP) & ~refs_done & rd_data_valid);

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
            ref_addr     <= 32'h0;
            ref_push_idx <= 32'h0;
            ref_got      <= 32'h0;
            ref_val      <= 32'h0;
            prev_ref     <= 32'hFFFFFFFF;
            ref_stop     <= 1'b0;
            root_idx     <= 32'h0;
            pending_obj  <= 12'h0;
            clr_ptr      <= 12'h0;
            pf_obj       <= 12'h0;
            pf_valid     <= 1'b0;
            pf_tried     <= 1'b0;
            bm_waddr     <= 12'h0;
            rd_cmd_addr  <= 32'h0;
            rd_cmd_valid <= 1'b0;
            q_push       <= 1'b0;
            q_pop        <= 1'b0;
            bm_wdata     <= 32'h0;
            bm_we        <= 1'b0;
            root_rd_addr <= 8'h0;
            q_push_data  <= 12'h0;
            q_push_addr  <= 12'h0;
        end else begin
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
                    bm_waddr <= clr_ptr;
                    bm_wdata <= 32'h0;
                    bm_we    <= 1'b1;
                    if (clr_ptr == 12'd4095)
                        state <= S_RD_ROOT;
                    else
                        clr_ptr <= clr_ptr + 12'd1;
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
                    bm_waddr <= pending_obj;
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
                        cur_obj  <= q_pop_id;
                        pf_tried <= 1'b0;
                        pf_valid <= 1'b0;
                        state    <= S_HDR_P1;
                    end
                end

                // ===== 阶段1: 并发读 ref_count 和 ref_addr =====
                S_HDR_P1: begin
                    rd_cmd_addr  <= obj_base + {20'h0, cur_obj} * 32'd16 + 32'd4;
                    rd_cmd_valid <= 1'b1;
                    state        <= S_HDR_P2;
                end

                S_HDR_P2: begin
                    if (rd_cmd_ready) begin
                        rd_cmd_addr <= obj_base + {20'h0, cur_obj} * 32'd16 + 32'd8;
                        state       <= S_HDR_P3;
                    end
                end

                S_HDR_P3: begin
                    if (rd_cmd_ready) begin
                        rd_cmd_valid <= 1'b0;
                        state        <= S_HDR_G1;
                    end
                end

                S_HDR_G1: begin
                    if (rd_data_valid) begin
                        ref_count <= rd_data;
                        state     <= S_HDR_G2;
                    end
                end

                S_HDR_G2: begin
                    if (rd_data_valid) begin
                        ref_addr     <= rd_data;
                        ref_push_idx <= 32'h0;
                        ref_got      <= 32'h0;
                        ref_stop     <= 1'b0;
                        pf_tried     <= 1'b0;
                        pf_valid     <= 1'b0;
                        state        <= S_REFS_LOOP;
                    end
                end

                // ===== 阶段2: 引用阶段 (压入/取回交错 + 投机预取下一个对象头) =====
                S_REFS_LOOP: begin
                    if (rd_data_valid && !refs_done) begin
                        // 取回优先: 给数据FIFO腾空间, 命令FIFO才能继续排空
                        ref_val <= rd_data;
                        ref_got <= ref_got + 32'd1;
                        state   <= S_REF_DEC;           // bm_raddr 由组合逻辑同拍发出
                    end else if (!ref_stop && ref_push_idx < ref_count && rd_cmd_ready) begin
                        rd_cmd_addr  <= ref_addr + ref_push_idx * 32'd4;
                        rd_cmd_valid <= 1'b1;
                        state        <= S_REFS_PUSHW;
                    end else if (!pf_valid && !pf_tried && refs_pushed && !q_empty) begin
                        // 投机预取: 引用命令已全部压完, 现在把下一个对象的头读也压进去
                        q_pop    <= 1'b1;
                        pf_tried <= 1'b1;
                        state    <= S_PF_WAIT;
                    end else if (refs_done) begin
                        rd_cmd_valid <= 1'b0;
                        state        <= pf_valid ? S_PF_G1 : S_POP;
                    end
                end

                // 注意: 握手后必须立刻撤销 valid, 否则下一拍(addr 尚未更新)
                //       会被主控重复接收同一笔命令.
                S_REFS_PUSHW: begin
                    if (rd_cmd_ready) begin
                        rd_cmd_valid <= 1'b0;
                        ref_push_idx <= ref_push_idx + 32'd1;
                        state        <= S_REFS_LOOP;
                    end
                end

                // 判定 + 置位 + 入队, 1 拍完成 (bm_rdata 此时有效)
                S_REF_DEC: begin
                    if (ref_stop) begin
                        state <= S_REFS_LOOP;
                    end else if (ref_val == 32'hFFFFFFFF) begin
                        ref_stop <= 1'b1;
                        state    <= S_REFS_LOOP;
                    end else if (ref_val >= obj_count) begin
                        state <= S_REFS_LOOP;                 // 越界, 跳过
                    end else if (bm_rdata[ref_val[4:0]]) begin
                        state <= S_REFS_LOOP;                 // 已标记
                    end else if (ref_val == prev_ref) begin
                        // 相邻重复引用: 位图的写脉冲是寄存器, 要**下一拍**才落盘,
                        // 而下一个引用的读采样正好落在同一拍边沿, 会读到旧值 ->
                        // 同一个对象被标记两次、重复入队、marked 多 1 (实测 ~1/3
                        // 概率的竞态). 用"上一笔标记过的引用值"兜住即可.
                        state <= S_REFS_LOOP;
                    end else begin
                        prev_ref <= ref_val;
                        bm_waddr <= ref_val[11:0];
                        bm_wdata <= 32'h1 << ref_val[4:0];
                        bm_we    <= 1'b1;
                        if (q_tail < Q_MAX) begin
                            q_push_data <= ref_val[11:0];
                            q_push_addr <= q_tail;
                            q_push      <= 1'b1;
                            marked_r    <= marked_r + 32'd1;
                        end
                        state <= S_REFS_LOOP;
                    end
                end

                // ===== 投机预取: 弹出下一个对象并压入它的两笔头读 =====
                S_PF_WAIT: begin
                    if (q_pop_ack) begin
                        pf_obj <= q_pop_id;
                        state  <= S_PF_H1;
                    end
                end

                S_PF_H1: begin
                    rd_cmd_addr  <= obj_base + {20'h0, pf_obj} * 32'd16 + 32'd4;
                    rd_cmd_valid <= 1'b1;
                    state        <= S_PF_H2;
                end

                S_PF_H2: begin
                    if (rd_cmd_ready) begin
                        rd_cmd_addr <= obj_base + {20'h0, pf_obj} * 32'd16 + 32'd8;
                        state       <= S_PF_H3;
                    end
                end

                S_PF_H3: begin
                    if (rd_cmd_ready) begin
                        rd_cmd_valid <= 1'b0;
                        pf_valid     <= 1'b1;
                        state        <= S_REFS_LOOP;
                    end
                end

                // 取回被预取对象的头 (顺序上排在当前对象所有引用之后)
                S_PF_G1: begin
                    if (rd_data_valid) begin
                        ref_count <= rd_data;
                        state     <= S_PF_G2;
                    end
                end

                S_PF_G2: begin
                    if (rd_data_valid) begin
                        ref_addr     <= rd_data;
                        cur_obj      <= pf_obj;         // 它成为"当前对象"
                        ref_push_idx <= 32'h0;
                        ref_got      <= 32'h0;
                        ref_stop     <= 1'b0;
                        pf_tried     <= 1'b0;
                        pf_valid     <= 1'b0;
                        state        <= S_REFS_LOOP;
                    end
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
