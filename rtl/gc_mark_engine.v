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
    input  wire        q_full,

    // 标记位图 (简单双口BRAM: 读口/写口地址独立)
    output wire [11:0] bm_raddr,            // 读地址 (组合, 1拍后 bm_rdata 有效)
    input  wire [31:0] bm_rdata,
    output reg  [11:0] bm_waddr = 12'd0,    // 写地址
    output reg  [31:0] bm_wdata = 32'd0,
    output reg         bm_we = 1'b0,

    // DDR读命令队列接口 (→ gc_axi_read 流 0: 引用读)
    // 注意: addr 必须是组合输出 —— 若用寄存器, 地址会比 iss_idx 慢一拍,
    //       握手后会以旧地址再发一次 (实测会多读一笔, 把引用流冲错位).
    output wire [31:0] rd_cmd_addr,
    output reg         rd_cmd_valid = 1'b0,
    input  wire        rd_cmd_ready,
    input  wire [31:0] rd_data,
    input  wire        rd_data_valid,
    output wire        rd_data_ready,

    // 对象头预取接口 (→ gc_axi_read 流 1)
    output reg  [31:0] hdr_cmd_addr = 32'd0,
    output reg         hdr_cmd_valid = 1'b0,
    input  wire        hdr_cmd_ready,
    input  wire [31:0] hdr_data,
    input  wire        hdr_data_valid,
    output wire        hdr_data_ready,

    // 状态输出
    output reg         done = 1'b0,
    output reg  [31:0] marked_count = 32'd0,
    output reg  [31:0] cycles = 32'd0,

    // 错误标志 (粘滞, 每次 start 清零)
    output reg         err_ovf = 1'b0,     // 队列写满, 对象没能入队 (#1)
    output reg         err_ref = 1'b0,     // 引用流失步: 消费数 > 发出数 (#4)
    output reg         err_hdr = 1'b0      // 对象头非法: ref_count > 4096
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
        S_DONE       = 5'd23,
        S_ROOT_CHK   = 5'd24;   // #5: 根节点查位图去重

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
    assign bm_raddr = (state == S_REFS_LOOP) ? rd_data[11:0] :
                      (state == S_ROOT_CHK)  ? pending_obj  : 12'd0;

    // 引用阶段结束: 本对象 ref_count 笔数据全部取回
    // (命令由 issuer 独立发射, 与这里的消费解耦 —— 所以不再看"压了几笔")
    wire refs_done   = (ref_got >= ref_count);

    // 只在需要下一笔数据时拉高 ready
    assign rd_data_ready = (state == S_HDR_G1) |
                           (state == S_HDR_G2) |
                           (state == S_PF_G1)  |
                           (state == S_PF_G2)  |
                           ((state == S_REFS_LOOP) & ~refs_done & rd_data_valid);

    // ==================== 对象头预取 ("侦察兵") ====================
    // 目的: 把 DDR 读延迟从"每对象暴露约 1 次往返"变成"几乎不暴露".
    // 做法: 独立小状态机提前最多 PD 个对象弹出队列、在流 1 上读它们的头,
    //       结果放进 PD 深暂存环; 主状态机直接从环里取, 不用等 DDR.
    localparam integer PD = 4;                      // 暂存环深度 (2 的幂)

    reg [11:0] pf_id [0:PD-1];
    reg [31:0] pf_rc [0:PD-1];
    reg [31:0] pf_ra [0:PD-1];
    reg [1:0]  pf_head = 2'd0;
    reg [2:0]  pf_cnt  = 3'd0;                      // 已填好的头数
    reg [2:0]  pf_iss  = 3'd0;                      // 已发起未填好的头数
    reg        pf_take = 1'b0;                      // 主状态机取走一个头 (单拍)

    wire [1:0] pf_fill_slot = pf_head + pf_cnt[1:0];
    wire [1:0] pf_iss_slot  = pf_head + pf_cnt[1:0] + pf_iss[1:0];
    wire       pf_room      = ((pf_cnt + pf_iss) < PD[2:0]);

    localparam [2:0] SC_IDLE = 3'd0, SC_POP = 3'd1, SC_C1 = 3'd2, SC_C2 = 3'd3, SC_C3 = 3'd4;
    reg [2:0]  sc_state   = SC_IDLE;
    reg [11:0] sc_obj     = 12'd0;
    reg        hdr_second = 1'b0;
    reg        issue_ok   = 1'b0;

    // 引用描述符队列: 对象头填好即入队, 由下面的 issuer 独立发读命令.
    // 这样"发引用读"可以领先主状态机最多 DQD 个对象 —— 引用读延迟就被后续对象的处理盖住了.
    localparam integer DQD = 8;
    reg [31:0] dq_ra  [0:DQD-1];
    reg [31:0] dq_rc  [0:DQD-1];
    reg [2:0]  dq_head = 3'd0;
    reg [3:0]  dq_cnt  = 4'd0;
    reg [31:0] iss_idx = 32'd0;
    reg [31:0] iss_cnt = 32'd0;      // 已发出的引用读命令总数 (#4 交叉校验用)
    wire [2:0] dq_tail = dq_head + dq_cnt[2:0];
    wire       dq_full = (dq_cnt >= DQD[3:0]);

    assign hdr_data_ready = ~dq_full;   // 描述符快满时先别收新的头

    wire       fill_done  = hdr_data_valid && hdr_data_ready && hdr_second;
    wire       take_ok    = pf_take && (pf_cnt != 3'd0);
    wire [2:0] pf_cnt_nxt = pf_cnt + (fill_done ? 3'd1 : 3'd0) - (take_ok ? 3'd1 : 3'd0);

    // 对象头合法性: ref_count 不可能超过对象上限 4096 (超过 = 头被写坏).
    // 守卫放在"填头"这一拍, 拒绝这个头并把 err_hdr 置起来 —— 避免引擎按一个
    // 垃圾 ref_count 发出上亿笔读命令而卡死.
    wire [31:0] hdr_rc_raw = pf_rc[pf_fill_slot];
    wire        hdr_rc_bad = (hdr_rc_raw > 32'd4096);
    wire [31:0] hdr_rc_ok  = hdr_rc_bad ? 32'd0 : hdr_rc_raw;

    // 出队事件: 最后一笔已握手, 或该描述符本来就没有引用
    wire iss_hs   = (dq_cnt != 4'd0) && (iss_idx < dq_rc[dq_head]) && rd_cmd_valid && rd_cmd_ready;
    wire iss_last = iss_hs && (iss_idx + 32'd1 >= dq_rc[dq_head]);
    wire iss_zero = (dq_cnt != 4'd0) && (iss_idx >= dq_rc[dq_head]);
    wire iss_pop  = iss_last || iss_zero;

    // 地址组合输出: 当拍就对应正在呈现的那笔命令
    assign rd_cmd_addr = ((dq_cnt != 4'd0) && (iss_idx < dq_rc[dq_head]))
                         ? (dq_ra[dq_head] + iss_idx * 32'd4) : 32'd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sc_state      <= SC_IDLE;
            sc_obj        <= 12'd0;
            q_pop         <= 1'b0;
            hdr_cmd_valid <= 1'b0;
            hdr_cmd_addr  <= 32'd0;
            hdr_second    <= 1'b0;
            issue_ok      <= 1'b0;
            dq_head       <= 3'd0;
            dq_cnt        <= 4'd0;
            iss_idx       <= 32'd0;
            rd_cmd_valid  <= 1'b0;
            iss_cnt       <= 32'd0;
            pf_head       <= 2'd0;
            pf_cnt        <= 3'd0;
            pf_iss        <= 3'd0;
        end else begin
            q_pop    <= 1'b0;
            issue_ok <= 1'b0;

            // ---- 侦察兵: 弹队列 + 在流 1 上发两笔头读 ----
            case (sc_state)
                SC_IDLE: if (pf_room && !q_empty) begin
                    q_pop    <= 1'b1;
                    sc_state <= SC_POP;
                end
                SC_POP: if (q_pop_ack) begin
                    sc_obj             <= q_pop_id;
                    pf_id[pf_iss_slot] <= q_pop_id;
                    issue_ok           <= 1'b1;
                    sc_state           <= SC_C1;
                end
                SC_C1: begin
                    hdr_cmd_addr  <= obj_base + {20'h0, sc_obj} * 32'd16 + 32'd4;
                    hdr_cmd_valid <= 1'b1;
                    sc_state      <= SC_C2;
                end
                SC_C2: if (hdr_cmd_ready) begin
                    hdr_cmd_addr <= obj_base + {20'h0, sc_obj} * 32'd16 + 32'd8;
                    sc_state     <= SC_C3;
                end
                SC_C3: if (hdr_cmd_ready) begin
                    hdr_cmd_valid <= 1'b0;
                    sc_state      <= SC_IDLE;
                end
                default: sc_state <= SC_IDLE;
            endcase

            // ---- 填暂存环 + 描述符入队 ----
            if (hdr_data_valid && hdr_data_ready) begin
                if (!hdr_second) begin
                    pf_rc[pf_fill_slot] <= hdr_data;
                    hdr_second <= 1'b1;
                end else begin
                    pf_ra[pf_fill_slot] <= hdr_data;
                    hdr_second <= 1'b0;
                    // 头填好 → 立刻把 {ref_addr, ref_count} 塞进引用描述符队列
                    dq_ra[dq_tail] <= hdr_data;
                    dq_rc[dq_tail] <= hdr_rc_ok;
                    if (hdr_rc_bad) begin
                        pf_rc[pf_fill_slot] <= 32'd0;   // 拒绝这个头 (0 个引用)
                        err_hdr <= 1'b1;                // 上报, 不静默
                    end
                end
            end

            // ---- issuer: 描述符 → 引用读命令 (独立于主状态机) ----
            if (iss_pop) begin
                dq_head      <= dq_head + 3'd1;
                iss_idx      <= 32'd0;
                rd_cmd_valid <= 1'b0;
                // 这一拍正是"最后一笔命令握手"时, 也要计数 (#4 校验不能少算一笔)
                if (iss_last) iss_cnt <= iss_cnt + 32'd1;
            end else if (dq_cnt != 4'd0) begin
                if (iss_idx < dq_rc[dq_head]) begin
                    rd_cmd_valid <= 1'b1;
                    if (rd_cmd_valid && rd_cmd_ready) begin
                        iss_idx <= iss_idx + 32'd1;
                        iss_cnt <= iss_cnt + 32'd1;
                    end
                end else begin
                    rd_cmd_valid <= 1'b0;
                end
            end else begin
                rd_cmd_valid <= 1'b0;
            end

            // ---- 计数: 同拍可能"填好一个 + 取走一个", 用 next 值一次算清 ----
            pf_cnt <= pf_cnt_nxt;
            pf_iss <= pf_iss + (issue_ok ? 3'd1 : 3'd0) - (fill_done ? 3'd1 : 3'd0);
            dq_cnt <= dq_cnt + (fill_done ? 4'd1 : 4'd0) - (iss_pop ? 4'd1 : 4'd0);
            if (take_ok)
                pf_head <= pf_head + 2'd1;

            // #3: iss_cnt 必须和 con_cnt 一起在 start 时清零 (否则流失步检测跨运行失效).
            //     它在本块里递增, 所以清零也必须留在本块 —— 放到主状态机会造成多驱动.
            if (start) begin
                iss_cnt <= 32'd0;
                err_hdr <= 1'b0;      // 同理: err_hdr 只在本块驱动, 清零也放这里
            end
        end
    end

    // 引用流交叉校验 (#4): 消费数绝不能超过发出数
    reg  [31:0] con_cnt = 32'd0;
    wire        ref_desync = (con_cnt > iss_cnt);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            done         <= 1'b0;      // #4: 复位后不应"已完成", 否则软件会读到 marked=0 的假结果
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
            q_push       <= 1'b0;
            bm_wdata     <= 32'h0;
            bm_we        <= 1'b0;
            root_rd_addr <= 8'h0;
            q_push_data  <= 12'h0;
            q_push_addr  <= 12'h0;
        end else begin
            q_push   <= 1'b0;
            bm_we    <= 1'b0;
            pf_take  <= 1'b0;

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
                        err_ovf  <= 1'b0;
                        err_ref  <= 1'b0;
                        con_cnt  <= 32'd0;
                        prev_ref <= 32'hFFFFFFFF;   // #1: 必须清, 否则第二次运行会静默漏标记
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
                        state       <= S_ROOT_CHK;      // #5: 先查位图, 去重后再标记
                    end else begin
                        root_idx <= root_idx + 32'd1;
                        state    <= S_RD_ROOT;
                    end
                end

                S_ROOT_CHK: state <= S_ROOT_MARK;       // bm_raddr 已发出, 本拍后 bm_rdata 有效

                S_ROOT_MARK: begin
                    if (bm_rdata[pending_obj[4:0]]) begin
                        // 根集内重复 (同一个 root 写了两次) → 跳过, 不置位不入队不计数
                        root_idx <= root_idx + 32'd1;
                        state    <= S_RD_ROOT;
                    end else begin
                        bm_waddr <= pending_obj;
                        bm_wdata <= 32'h1 << pending_obj[4:0];
                        bm_we    <= 1'b1;
                        state    <= S_ROOT_PUSH;
                    end
                end

                S_ROOT_PUSH: begin
                    if (!q_full) begin
                        q_push_data <= pending_obj;
                        q_push_addr <= q_tail;
                        q_push      <= 1'b1;
                        marked_r    <= marked_r + 32'd1;
                    end else begin
                        err_ovf <= 1'b1;        // 队列满: 报告而不是静默丢弃 (#1)
                    end
                    root_idx <= root_idx + 32'd1;
                    state    <= S_RD_ROOT;
                end

                // ===== BFS主循环: 从预取暂存环取一个已经读好的对象 =====
                // (对象头由下面的"侦察兵"提前 4 个对象读好, 这里不再自己发读命令)
                S_POP: begin
                    if (pf_cnt != 3'd0) begin
                        cur_obj      <= pf_id[pf_head];
                        ref_count    <= pf_rc[pf_head];
                        ref_addr     <= pf_ra[pf_head];
                        ref_push_idx <= 32'h0;
                        ref_got      <= 32'h0;
                        ref_stop     <= 1'b0;
                        pf_take      <= 1'b1;
                        state        <= S_REFS_LOOP;
                    end else if (q_empty && (pf_iss == 3'd0) && (sc_state == SC_IDLE) && (dq_cnt == 4'd0)) begin
                        state <= S_DONE;
                    end
                end

                // ===== 对象头改由"侦察兵"读: 这些状态已废弃 =====
                S_HDR_P1, S_HDR_P2, S_HDR_P3, S_HDR_G1, S_HDR_G2: begin
                    state <= S_POP;
                end

                // ===== 阶段2: 只负责"消费"引用数据 (发命令已交给 issuer) =====
                S_REFS_LOOP: begin
                    if (rd_data_valid && !refs_done) begin
                        ref_val <= rd_data;
                        ref_got <= ref_got + 32'd1;
                        con_cnt <= con_cnt + 32'd1;
                        if (con_cnt >= iss_cnt) err_ref <= 1'b1;   // 消费超过发出 → 流失步
                        state   <= S_REF_DEC;           // bm_raddr 由组合逻辑同拍发出
                    end else if (refs_done) begin
                        state <= S_POP;
                    end
                end

                S_REFS_PUSHW: begin
                    state <= S_REFS_LOOP;               // 已废弃 (命令由 issuer 发)
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
                        if (!q_full) begin
                            q_push_data <= ref_val[11:0];
                            q_push_addr <= q_tail;
                            q_push      <= 1'b1;
                            marked_r    <= marked_r + 32'd1;
                        end else begin
                            err_ovf <= 1'b1;    // 队列满: 报告而不是静默丢弃 (#1)
                        end
                        state <= S_REFS_LOOP;
                    end
                end

                // ===== 投机预取已移到独立的"侦察兵"状态机 (见文件前半部分) =====
                S_PF_WAIT, S_PF_H1, S_PF_H2, S_PF_H3, S_PF_G1, S_PF_G2: begin
                    state <= S_POP;      // 不应到达 (保留编码以免改动状态表)
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
