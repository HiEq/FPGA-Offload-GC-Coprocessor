// gc_mark_engine.v — BFS 标记引擎 (核心状态机)
//
// 对象图 DDR 格式见 csrc/fpga_gc.h
//
// 流水:
//   1) 对象头两笔读并发 (头+4 / 头+8)
//   2) 引用读边压边收; 引用命令压完后预取下一个对象的对象头
//   3) 逐引用快路径 2 拍 (读-判-置位-入队)
module gc_mark_engine (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [31:0] obj_base,
    input  wire [31:0] obj_count,
    input  wire [31:0] root_count,
    input  wire        start,
    input  wire        abort,        // 1-cycle: leave any state, clear done

    output reg  [7:0]  root_rd_addr = 8'd0,
    input  wire [31:0] root_rd_data,

    output wire        q_we,
    output wire [19:0] q_wdata,
    output reg         q_pop = 1'b0,
    input  wire        q_pop_ack,
    input  wire [19:0] q_pop_id,
    input  wire [18:0] q_tail,
    input  wire        q_empty,
    input  wire        q_full,

    // ---- Phase 3A: 屏障脏集 (gc_dirty_fifo) ----
    input  wire        dirty_empty,
    input  wire [19:0] dirty_id,
    input  wire        bm_keep,        // 1 = 保留位图 (增量 epoch)
    output reg         dirty_pop = 1'b0,       // 1-cycle: 消费一个脏 id
    output reg  [31:0] dirty_drained = 32'd0,  // 本 epoch 已消费条数 (start 清零)

    // ---- Phase 2: two ref lanes + one 2^19 queue ----
    output wire        ref_active,         // 1 = the ref stream owns the bitmap
    output wire [13:0] lane0_raddr,
    output wire [13:0] lane0_waddr,
    output wire        lane0_we,
    output wire [31:0] lane0_wdata,
    input  wire [31:0] lane0_rdata,
    output wire [13:0] lane1_raddr,
    output wire [13:0] lane1_waddr,
    output wire        lane1_we,
    output wire [31:0] lane1_wdata,
    input  wire [31:0] lane1_rdata,

    // ---- housekeeping bitmap port (clear / root / dirty) ----
    output wire [14:0] hk_raddr,           // 读地址 (组合, 1拍后 hk_rdata 有效)
    input  wire [31:0] hk_rdata,
    output reg  [14:0] bm_waddr = 15'd0,   // 写地址
    output reg  [31:0] bm_wdata = 32'd0,
    output reg         bm_we = 1'b0,

    // DDR读命令队列接口 (→ gc_axi_read 流 0: 引用读)
    // addr 为组合输出, 与 ref_word_idx 同拍
    output wire [31:0] rd_cmd_addr,
    output wire        rd_cmd_pair,
    output wire [1:0]  rd_cmd_len,     // 0 = single/pair, 3 = 4-beat burst (8 refs)
    output reg         rd_cmd_valid = 1'b0,
    input  wire        rd_cmd_ready,
    input  wire [31:0] rd_data,
    input  wire [31:0] rd_data_hi,
    input  wire        rd_data_two,
    input  wire        rd_data_valid,
    output wire        rd_data_ready,
    output wire        rd_data_take2,

    // 对象头预取接口 (→ gc_axi_read 流 1)
    output reg  [31:0] hdr_cmd_addr = 32'd0,
    output reg         hdr_cmd_valid = 1'b0,
    input  wire        hdr_cmd_ready,
    input  wire [31:0] hdr_data,
    input  wire        hdr_data_valid,
    output wire        hdr_data_ready,

    output reg         done = 1'b0,
    output reg  [31:0] marked_count = 32'd0,
    output reg  [31:0] cycles = 32'd0,

    // 错误标志 (粘滞, 每次 start 清零)
    output reg         err_ovf = 1'b0,     // 队列写满, 对象没能入队 (#1)
    output reg         err_ref = 1'b0,     // 引用流失步: 消费数 > 发出数 (#4)
    output reg         err_hdr = 1'b0,      // 对象头非法: ref_count > 1048576


    output wire        engine_idle,

    // The engine clears the object queue itself when the FSM accepts a start.
    // A spilled CLEAR_Q (this board redelivers stores, not always adjacently)
    // must not touch a running epoch; clearing the queue at the start instead
    // keeps q_tail == marked even when a spilled START re-runs the graph.
    output reg         q_clear = 1'b0
);

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
        S_ROOT_CHK   = 5'd24,   // #5: 根节点查位图去重
        S_DIRTY_RD   = 5'd25,   // Phase 3A: 脏 id 查位图
        S_DIRTY_PUSH = 5'd26;   // Phase 3A: 脏 id 置位(如未标) + 强制入队重扫

    // 25 个编码里 12 个在用, 13 个保留 (S_POP_WAIT / S_HDR_P1..P3 / S_HDR_G1..G2 /
    // S_REFS_PUSHW / S_PF_WAIT / S_PF_H1..H3 / S_PF_G1..G2). 这些分支不可达,
    // 保留只为状态名可读; 删除需重排编码并重跑全部仿真。

    reg [4:0]  state = 5'd0;

    assign engine_idle = (state == S_IDLE);
    reg [19:0] cur_obj = 20'd0;
    reg [20:0] ref_count = 21'd0;
    reg [31:0] ref_addr = 32'd0;
    reg [31:0] ref_push_idx = 32'd0;
    reg [20:0] ref_got = 21'd0;
    reg [31:0] ref_val = 32'd0;
    reg [31:0] prev_ref = 32'hFFFFFFFF;   // 上一笔被标记的引用值 (挡住"相邻重复")
    reg        ref_stop = 1'b0;
    reg [31:0] root_idx = 32'd0;
    reg [19:0] pending_obj = 20'd0;
    reg [19:0] dirty_obj = 20'd0;       // Phase 3A: 正在处理的脏 id
    reg [31:0] cycles_r;
    reg [31:0] marked_r;
    reg [14:0] clr_ptr;
    reg [19:0] pf_obj = 20'd0;
    reg        pf_valid = 1'b0;    // 已弹出且头命令已压入, 只等取回
    reg        pf_tried = 1'b0;    // 本对象已经发起过预取 (防重复弹队列)

    // Housekeeping read address (clear/root/dirty).  The ref stream drives the
    // lanes' own bank ports; ref_active tells gc_top which owner owns the banks.
    assign hk_raddr = (state == S_ROOT_CHK) ? pending_obj[19:5] :
                      (state == S_DIRTY_RD) ? dirty_id[19:5]     : 15'd0;
    assign ref_active = (state == S_REFS_LOOP);

    // 引用阶段结束: 本对象 ref_count 笔数据全部取回
    // 命令由 issuer 独立发射, 与消费解耦
    wire refs_done   = (ref_got >= ref_count);

    wire        lane0_ready, lane1_ready;
    wire        lane0_req, lane1_req;
    wire [19:0] lane0_pid, lane1_pid;
    wire        lane0_marked, lane1_marked;
    wire        lane0_ovf, lane1_ovf;
    wire        lane0_idle, lane1_idle;
    wire [3:0]  arb_grant;
    wire        arb_we;
    wire [19:0] arb_wdata;
    wire        fifo_ready, fifo_empty;
    wire        q_we_i;
    wire [19:0] q_wdata_i;
    wire [1:0]  lane_marks;
    wire        lane_idle;

    // ---- ref stream -> two banked lanes ----
    // lane k owns the ids with id[5] == k.  A 64-bit beat (two refs) is taken
    // only when both refs are in range, land in different banks, and both lanes
    // are ready.  Otherwise one ref is taken and the second is presented again
    // on the next cycle (gc_axi_read advances by one word).
    wire [20:0] refs_left = ref_count - ref_got;
    wire [31:0] rd_lo     = rd_data;
    wire [31:0] rd_hi     = rd_data_hi;
    wire        lo_in     = (rd_lo < obj_count);
    wire        hi_in     = (rd_hi < obj_count);
    wire        lo_bank   = rd_lo[5];
    wire        hi_bank   = rd_hi[5];
    wire        lo_ok     = !lo_in || (lo_bank ? lane1_ready : lane0_ready);
    wire        hi_ok     = !hi_in || (hi_bank ? lane1_ready : lane0_ready);
    wire        can2      = rd_data_two && (refs_left >= 21'd2) &&
                            lo_in && hi_in && (lo_bank != hi_bank) &&
                            lo_ok && hi_ok;
    wire        can1      = lo_ok;

    wire        ref_fire  = (state == S_REFS_LOOP) && rd_data_valid &&
                            !refs_done && (can1 || can2);
    wire [1:0] ref_inc   = can2 ? 2'd2 : 2'd1;

    assign rd_data_ready = ref_fire;
    assign rd_data_take2 = can2;

    wire        l0_valid = ref_fire && ((lo_bank == 1'b0 && lo_in) ||
                                        (can2 && hi_bank == 1'b0));
    wire        l1_valid = ref_fire && ((lo_bank == 1'b1 && lo_in) ||
                                        (can2 && hi_bank == 1'b1));
    wire [19:0] l0_in_id = (can2 && hi_bank == 1'b0) ? rd_hi[19:0] : rd_lo[19:0];
    wire [19:0] l1_in_id = (can2 && hi_bank == 1'b1) ? rd_hi[19:0] : rd_lo[19:0];

    assign lane_marks = {1'b0, lane0_marked} + {1'b0, lane1_marked};
    assign lane_idle  = lane0_idle && lane1_idle;

    // Housekeeping pushes (root / dirty) share the single queue write port.
    // The lanes are idle in these states, so the arbiter grants in one cycle.
    wire        root_push_now  = (state == S_ROOT_PUSH) && !q_full;
    wire        dirty_push_now = (state == S_DIRTY_PUSH) && !q_full &&
                                 !dirty_empty && (dirty_id < obj_count);
    wire        hk_req  = root_push_now || dirty_push_now;
    wire [19:0] hk_id   = (state == S_ROOT_PUSH) ? pending_obj : dirty_id;
    wire        hk_grant = arb_grant[2];

    gc_lane #(.SEL(1)) u_lane0 (
        .clk(clk), .rst_n(rst_n), .clear(q_clear | abort),
        .obj_count(obj_count),
        .in_valid(l0_valid), .in_id(l0_in_id), .in_ready(lane0_ready),
        .bm_raddr(lane0_raddr), .bm_waddr(lane0_waddr),
        .bm_we(lane0_we), .bm_wdata(lane0_wdata), .bm_rdata(lane0_rdata),
        .push_req(lane0_req), .push_id(lane0_pid), .push_grant(arb_grant[0]),
        .q_full(q_full),
        .marked_pulse(lane0_marked), .ovf_pulse(lane0_ovf), .idle(lane0_idle)
    );

    gc_lane #(.SEL(1)) u_lane1 (
        .clk(clk), .rst_n(rst_n), .clear(q_clear | abort),
        .obj_count(obj_count),
        .in_valid(l1_valid), .in_id(l1_in_id), .in_ready(lane1_ready),
        .bm_raddr(lane1_raddr), .bm_waddr(lane1_waddr),
        .bm_we(lane1_we), .bm_wdata(lane1_wdata), .bm_rdata(lane1_rdata),
        .push_req(lane1_req), .push_id(lane1_pid), .push_grant(arb_grant[1]),
        .q_full(q_full),
        .marked_pulse(lane1_marked), .ovf_pulse(lane1_ovf), .idle(lane1_idle)
    );

    gc_push_arb #(.LANES(4), .SEL(2)) u_push_arb (
        .clk(clk), .rst_n(rst_n), .clear(q_clear),
        .req({1'b0, hk_req, lane1_req, lane0_req}),
        .id({20'd0, hk_id, lane1_pid, lane0_pid}),
        .full(q_full | ~fifo_ready),
        .grant(arb_grant), .we(arb_we), .wdata(arb_wdata)
    );

    gc_push_fifo u_push_fifo (
        .clk(clk), .rst_n(rst_n), .clear(q_clear | abort),
        .push(arb_we), .id(arb_wdata), .ready(fifo_ready),
        .q_full(q_full), .q_we(q_we_i), .q_wdata(q_wdata_i),
        .empty(fifo_empty)
    );

    assign q_we    = q_we_i;
    assign q_wdata = q_wdata_i;

    // 独立状态机提前最多 PD 个对象读头, 结果放入 PD 深暂存环
    localparam integer PD = 8;                     // 暂存环深度 (2 的幂)

    reg [19:0] pf_id [0:PD-1];
    reg [31:0] pf_rc [0:PD-1];
    reg [31:0] pf_ra [0:PD-1];
    reg [2:0]  pf_head = 3'd0;
    reg [3:0]  pf_cnt  = 4'd0;                      // 已填好的头数
    reg [3:0]  pf_iss  = 4'd0;                      // 已发起未填好的头数
    reg        pf_take = 1'b0;                      // 主状态机取走一个头 (单拍)

    wire [2:0] pf_fill_slot = pf_head + pf_cnt[2:0];
    wire [2:0] pf_iss_slot  = pf_head + pf_cnt[2:0] + pf_iss[2:0];
    wire       pf_room      = ((pf_cnt + pf_iss) < PD[3:0]);

    reg [7:0] sc_tmo = 8'd0;      // SC_POP timeout (lost pop ack)
    localparam [2:0] SC_IDLE = 3'd0, SC_POP = 3'd1, SC_C1 = 3'd2, SC_C2 = 3'd3, SC_C3 = 3'd4;
    reg [2:0]  sc_state   = SC_IDLE;
    reg [19:0] sc_obj     = 20'd0;
    reg  [1:0] hdr_wc = 2'd0;
    reg        issue_ok   = 1'b0;

    // 引用描述符队列: 对象头填好即入队, 由下面的 issuer 独立发读命令.
    // 发引用读可领先主状态机 DQD 个对象
    localparam integer DQD = 16;
    reg [31:0] dq_ra  [0:DQD-1];
    reg [31:0] dq_rc  [0:DQD-1];
    reg [3:0]  dq_head = 4'd0;
    reg [4:0]  dq_cnt  = 5'd0;
    reg [20:0] ref_word_idx = 21'd0;   // ref words issued for the head descriptor
    reg [31:0] iss_cnt = 32'd0;      // 已发出的引用读命令总数 (#4 交叉校验用)
    wire [3:0] dq_tail = dq_head + dq_cnt[3:0];
    wire       dq_full = (dq_cnt >= DQD[4:0]);

    assign hdr_data_ready = ~dq_full;   // 描述符快满时先别收新的头

    // !abort: on the abort cycle the read engine flushes at the next edge, so a
    // beat can still be presented in the same cycle; it must not be consumed here.
    wire       hdr_hs     = hdr_data_valid && hdr_data_ready && !abort;
    wire       fill_done  = hdr_hs && (hdr_wc == 2'd2);
    wire       take_ok    = pf_take && (pf_cnt != 4'd0);
    wire [3:0] pf_cnt_nxt = pf_cnt + (fill_done ? 4'd1 : 4'd0) - (take_ok ? 4'd1 : 4'd0);

    // 对象头合法性: ref_count 不可能超过对象上限 4096 (超过 = 头被写坏).
    // 头非法时拒绝并置 err_hdr
    wire [31:0] hdr_rc_raw = pf_rc[pf_fill_slot];
    wire        hdr_rc_bad = (hdr_rc_raw > 32'd1048576);
    wire [31:0] hdr_rc_ok  = hdr_rc_bad ? 32'd0 : hdr_rc_raw;

    // 出队事件: 最后一笔已握手, 或该描述符本来就没有引用
    // Pair the reference stream: one 8-byte beat returns two 32-bit refs, so a
    // command is issued per two refs while the address stays 8-byte aligned and
    // two refs remain; a lone trailing ref uses a single-word command.
    // Per-object counters are 21 bits: the object limit is 1M, and a 32-bit
    // subtract/compare on these was the last 150 MHz critical path.
    wire [20:0] ref_rc21       = dq_rc[dq_head][20:0];
    wire [20:0] ref_words_left = (dq_cnt != 5'd0) ? (ref_rc21 - ref_word_idx) : 21'd0;
    wire [31:0] ref_addr_cur   = dq_ra[dq_head] + {ref_word_idx, 2'b00};
    wire        ref_pair_ok    = (ref_addr_cur[2] == 1'b0);
    // One command can carry 4 beats (32 B = 8 refs) when at least 8 refs remain
    // and the array is 8-byte aligned; otherwise fall back to 2 refs / 1 ref.
    wire        ref_use_quad   = (ref_words_left >= 21'd8) && ref_pair_ok;
    wire        ref_use_pair   = !ref_use_quad && (ref_words_left >= 21'd2) && ref_pair_ok;
    wire [3:0]  ref_cmd_words  = ref_use_quad ? 4'd8 : (ref_use_pair ? 4'd2 : 4'd1);

    wire iss_hs   = (dq_cnt != 5'd0) && (ref_word_idx < ref_rc21) && rd_cmd_valid && rd_cmd_ready;
    wire iss_last = iss_hs && ((ref_word_idx + ref_cmd_words) >= ref_rc21);
    wire iss_zero = (dq_cnt != 5'd0) && (ref_word_idx >= ref_rc21);
    wire iss_pop  = iss_last || iss_zero;

    // 地址组合输出: 当拍就对应正在呈现的那笔命令
    assign rd_cmd_pair = ref_use_quad || ref_use_pair;
    assign rd_cmd_len  = ref_use_quad ? 2'd3 : 2'd0;
    assign rd_cmd_addr = ((dq_cnt != 5'd0) && (ref_word_idx < ref_rc21))
                         ? ref_addr_cur : 32'd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sc_state      <= SC_IDLE;
            sc_obj        <= 20'd0;
            q_pop         <= 1'b0;
            hdr_cmd_valid <= 1'b0;
            hdr_cmd_addr  <= 32'd0;
            hdr_wc        <= 2'd0;
            issue_ok      <= 1'b0;
            dq_head       <= 4'd0;
            dq_cnt        <= 5'd0;
            ref_word_idx       <= 21'd0;
            rd_cmd_valid  <= 1'b0;
            iss_cnt       <= 32'd0;
            pf_head       <= 3'd0;
            pf_cnt        <= 4'd0;
            pf_iss        <= 4'd0;
            sc_tmo <= 8'd0;
        end else begin
            q_pop    <= 1'b0;
            issue_ok <= 1'b0;

            case (sc_state)
                SC_IDLE: if (pf_room && !q_empty) begin
                    q_pop    <= 1'b1;
                    sc_tmo   <= 8'd0;
                    sc_state <= SC_POP;
                end
                SC_POP: begin
                    sc_tmo <= sc_tmo + 8'd1;
                    if (q_pop_ack) begin
                        sc_obj             <= q_pop_id;
                        pf_id[pf_iss_slot] <= q_pop_id;
                        issue_ok           <= 1'b1;
                        sc_state           <= SC_C1;
                    end else if (sc_tmo >= 8'd63) begin
                        // CLEAR_Q drops rvalid while we wait (gc_queue's clear
                        // branch), so the ack never arrives. Give up after 64
                        // cycles and retry from IDLE instead of hanging forever.
                        sc_state <= SC_IDLE;
                    end
                end
                SC_C1: begin
                    // One 2-beat burst reads the whole 16-byte header:
                    // words 0..3 = id, ref_count, ref_addr, flags.
                    hdr_cmd_addr  <= obj_base + {12'h0, sc_obj} * 32'd16;
                    hdr_cmd_valid <= 1'b1;
                    sc_state      <= SC_C2;
                end
                SC_C2: if (hdr_cmd_ready) begin
                    hdr_cmd_valid <= 1'b0;
                    sc_state      <= SC_IDLE;
                end
                SC_C3: begin
                    hdr_cmd_valid <= 1'b0;
                    sc_state      <= SC_IDLE;
                end
                default: sc_state <= SC_IDLE;
            endcase

            if (hdr_hs) begin
                case (hdr_wc)
                    2'd0: ;                              // word 0: object id, unused
                    2'd1: pf_rc[pf_fill_slot] <= hdr_data;  // word 1: ref_count
                    2'd2: begin                          // word 2: ref_addr
                        pf_ra[pf_fill_slot] <= hdr_data;
                        dq_ra[dq_tail] <= hdr_data;
                        dq_rc[dq_tail] <= hdr_rc_ok;
                        if (hdr_rc_bad) begin
                            pf_rc[pf_fill_slot] <= 32'd0;
                            err_hdr <= 1'b1;
                        end
                    end
                    default: ;                           // word 3: flags, unused
                endcase
                hdr_wc <= hdr_wc + 2'd1;
            end

            if (iss_pop) begin
                dq_head      <= dq_head + 4'd1;
                ref_word_idx      <= 21'd0;
                rd_cmd_valid <= 1'b0;
                // The pop cycle owns the last command's handshake, so its
                // words must be counted here (the else-branch does not run).
                if (iss_last) iss_cnt <= iss_cnt + {28'd0, ref_cmd_words};
                // 最后一笔命令握手同样计数
            end else if (dq_cnt != 5'd0) begin
                if (ref_word_idx < ref_rc21) begin
                    rd_cmd_valid <= 1'b1;
                    if (rd_cmd_valid && rd_cmd_ready) begin
                        ref_word_idx <= ref_word_idx + ref_cmd_words;
                        iss_cnt      <= iss_cnt + {28'd0, ref_cmd_words};
                    end
                end else begin
                    rd_cmd_valid <= 1'b0;
                end
            end else begin
                rd_cmd_valid <= 1'b0;
            end

            pf_cnt <= pf_cnt_nxt;
            pf_iss <= pf_iss + (issue_ok ? 4'd1 : 4'd0) - (fill_done ? 4'd1 : 4'd0);
            dq_cnt <= dq_cnt + (fill_done ? 5'd1 : 5'd0) - (iss_pop ? 5'd1 : 5'd0);
            if (take_ok)
                pf_head <= pf_head + 3'd1;

            // iss_cnt 与 con_cnt 同在 start 清零; 清零留在本块以避免多驱动
    if ((start && (state == S_IDLE)) || abort) begin   // only when the FSM accepts the start
                iss_cnt <= 32'd0;
                err_hdr <= 1'b0;      // 同理: err_hdr 只在本块驱动, 清零也放这里
                // Abort must also drop what the aborted run left in the prefetch and
                // issue pipeline. Without this the next run consumes those stale
                // entries (iss_cnt was just zeroed) and reports a bogus reference
                // desync (STATUS[2]) -- and across different graphs it would mark
                // the previous graph's objects. Board test: abort_test.py T4.
                dq_cnt  <= 5'd0;
                pf_cnt  <= 4'd0;
                pf_iss  <= 4'd0;
                pf_head <= 3'd0;
                // The prefetch FSM and the issuer must return to idle as well.
                // Otherwise an abort between SC_C1 and SC_C3 leaves sc_state
                // mid-sequence (with hdr_cmd_valid asserted) and the next run
                // may never reach DONE.
                sc_state      <= SC_IDLE;
                sc_tmo        <= 8'd0;
                hdr_cmd_valid <= 1'b0;
                hdr_wc        <= 2'd0;
                dq_head       <= 4'd0;
                ref_word_idx       <= 21'd0;
                rd_cmd_valid  <= 1'b0;
                q_pop         <= 1'b0;
            end
        end
    end

    // 引用流交叉校验: 消费数 <= 发出数
    reg  [31:0] con_cnt = 32'd0;
    wire        ref_desync = (con_cnt > iss_cnt);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            done         <= 1'b0;      // #4: 复位值
            q_clear      <= 1'b0;
            marked_count <= 32'h0;
            cycles       <= 32'h0;
            cycles_r     <= 32'h0;
            marked_r     <= 32'h0;
            cur_obj      <= 20'h0;
            ref_count    <= 21'h0;
            ref_addr     <= 32'h0;
            ref_push_idx <= 32'h0;
            ref_got      <= 21'h0;
            ref_val      <= 32'h0;
            prev_ref     <= 32'hFFFFFFFF;
            ref_stop     <= 1'b0;
            root_idx     <= 32'h0;
            pending_obj  <= 20'h0;
            clr_ptr      <= 15'h0;
            pf_obj       <= 20'h0;
            pf_valid     <= 1'b0;
            pf_tried     <= 1'b0;
            bm_waddr     <= 15'h0;
            bm_wdata     <= 32'h0;
            bm_we        <= 1'b0;
            root_rd_addr <= 8'h0;
        end else begin
            bm_we    <= 1'b0;
            pf_take  <= 1'b0;
            dirty_pop<= 1'b0;
            q_clear  <= 1'b0;
            if (lane0_ovf || lane1_ovf)
                err_ovf <= 1'b1;    // 队列满: 报告而不是静默丢弃 (#1)
            if (ref_desync)
                err_ref <= 1'b1;    // registered compare, off the FIFO hot path

            if (state != S_IDLE && state != S_DONE)
                cycles_r <= cycles_r + 32'd1;

            if (abort) begin
                state <= S_IDLE;
                done  <= 1'b0;
            end else case (state)

                S_IDLE: begin
                    cycles_r <= 32'h0;
                    marked_r <= 32'h0;
                    if (start) begin
                        done     <= 1'b0;
                        root_idx <= 32'h0;
                        q_clear  <= 1'b1;      // the run clears the object queue itself
                        clr_ptr  <= 11'h0;
                        err_ovf  <= 1'b0;
                        err_ref  <= 1'b0;
                        con_cnt  <= 32'd0;
                        dirty_drained <= 32'd0;     // Phase 3A
                        prev_ref <= 32'hFFFFFFFF;   // #1: 每次 start 清空
                        // Phase 3A: bm_keep=1 保留上一轮标记 (增量 epoch)
                        state    <= bm_keep ? S_RD_ROOT : S_CLR_BM;
                    end
                end

                S_CLR_BM: begin
                    bm_waddr <= clr_ptr;
                    bm_wdata <= 32'h0;
                    bm_we    <= 1'b1;
                    if (clr_ptr == 15'd32767)
                        state <= S_RD_ROOT;
                    else
                        clr_ptr <= clr_ptr + 15'd1;
                end

                S_RD_ROOT: begin
                    // root_rd_addr is 8 bits and the root list holds 256 entries.
                    // Clamp here as well: software writing root_count > 256 must
                    // not wrap around and re-read root[0..255] for ever.
                    if (root_idx < root_count && root_idx < 32'd256) begin
                        root_rd_addr <= root_idx[7:0];
                        state        <= S_ROOT_WAIT;
                    end else begin
                        state <= S_POP;
                    end
                end

                S_ROOT_WAIT: state <= S_ROOT_DATA;

                S_ROOT_DATA: begin
                    if (root_rd_data < obj_count) begin
                        pending_obj <= root_rd_data[19:0];
                        state       <= S_ROOT_CHK;      // #5: 先查位图, 去重后再标记
                    end else begin
                        root_idx <= root_idx + 32'd1;
                        state    <= S_RD_ROOT;
                    end
                end

                S_ROOT_CHK: state <= S_ROOT_MARK;       // hk_raddr 已发出, 本拍后 hk_rdata 有效

                S_ROOT_MARK: begin
                    if (hk_rdata[pending_obj[4:0]]) begin
                        // 根集内重复 (同一个 root 写了两次) → 跳过, 不置位不入队不计数
                        root_idx <= root_idx + 32'd1;
                        state    <= S_RD_ROOT;
                    end else if (q_full) begin
                        // Queue full: do NOT set the bitmap bit. Nothing will be
                        // enqueued, and a stray bit would silently mark an object.
                        err_ovf  <= 1'b1;
                        root_idx <= root_idx + 32'd1;
                        state    <= S_RD_ROOT;
                    end else begin
                        bm_waddr <= pending_obj[19:5];
                        bm_wdata <= hk_rdata | (32'h1 << pending_obj[4:0]);
                        bm_we    <= 1'b1;
                        state    <= S_ROOT_PUSH;
                    end
                end

                S_ROOT_PUSH: begin
                    if (q_full) begin
                        err_ovf <= 1'b1;        // 队列满: 报告而不是静默丢弃 (#1)
                        root_idx <= root_idx + 32'd1;
                        state    <= S_RD_ROOT;
                    end else if (hk_grant) begin
                        marked_r <= marked_r + 32'd1;
                        root_idx <= root_idx + 32'd1;
                        state    <= S_RD_ROOT;
                    end
                end

                S_POP: begin
                    // First object: enter from the normal S_POP path.  Later
                    // objects are chained directly in S_REFS_LOOP.
                    if (pf_cnt != 4'd0) begin
                        cur_obj      <= pf_id[pf_head];
                        ref_count    <= pf_rc[pf_head][20:0];
                        ref_addr     <= pf_ra[pf_head];
                        ref_push_idx <= 32'h0;
                        ref_got      <= 21'h0;
                        ref_stop     <= 1'b0;
                        pf_take      <= 1'b1;
                        state        <= S_REFS_LOOP;
                    end else if (!dirty_empty && lane_idle) begin
                        // The dirty path writes the bitmap through the
                        // housekeeping port, which REPLACES a lane write to the
                        // same bank in that cycle (gc_top mux).  Wait for the
                        // lanes to drain so no in-flight mark is overwritten.
                        dirty_obj <= dirty_id;
                        state     <= S_DIRTY_RD;
                    end else if (q_empty && (pf_iss == 4'd0) && (sc_state == SC_IDLE) && (dq_cnt == 5'd0) && dirty_empty && fifo_empty && lane_idle) begin
                        state <= S_DONE;
                    end
                end

                S_HDR_P1, S_HDR_P2, S_HDR_P3, S_HDR_G1, S_HDR_G2: begin
                    state <= S_POP;
                end

                S_REFS_LOOP: begin
                    // The two lanes consume the ref stream; ref_fire is the
                    // AXI handshake, ref_inc is 1 or 2 (64-bit beat).
                    if (ref_fire) begin
                        ref_got <= ref_got + ref_inc;
                        con_cnt <= con_cnt + ref_inc;
                    end
                    if (lane_marks != 2'd0)
                        marked_r <= marked_r + lane_marks;
                    if (!ref_fire && refs_done && lane_idle)
                        state <= S_POP;
                end

                S_REFS_PUSHW: begin
                    state <= S_REFS_LOOP;               // 已废弃 (命令由 issuer 发)
                end

                // Retired: the old one-ref S_REF_DEC.  The lanes now do the
                // decision/bitmap write/push; this state is unreachable.
                S_REF_DEC: begin
                    state <= S_REFS_LOOP;
                end

                S_PF_WAIT, S_PF_H1, S_PF_H2, S_PF_H3, S_PF_G1, S_PF_G2: begin
                    state <= S_POP;      // 不应到达 (保留编码以免改动状态表)
                end

                // ---- Phase 3A: 脏集消费 (强制重扫) ----
                S_DIRTY_RD: begin
                    // bm_raddr 组合输出 = dirty_obj (见 assign), 下一拍 bm_rdata 有效
                    state <= S_DIRTY_PUSH;
                end

                S_DIRTY_PUSH: begin
                    // 用 FIFO 的实时队头 (dirty_id): 判决、置位、入队、pop 同拍, 不会错位.
                    dirty_obj <= dirty_id;          // 仅供观测/调试
                    if (dirty_empty) begin
                        // 队头已消失 (被消费/flush, B 并发下会真的发生): 不计不推
                        state <= S_POP;
                    end else if (q_full) begin
                        state <= S_DIRTY_PUSH;      // 停等: 屏障记录不允许静默丢
                    end else if (dirty_id >= obj_count) begin
                        // 越界脏 id: 丢弃 (软件契约: 只推合法 id)
                        dirty_pop     <= 1'b1;
                        dirty_drained <= dirty_drained + 32'd1;
                        state         <= S_POP;
                    end else if (!hk_grant) begin
                        // Wait for the single queue write port (lanes are idle
                        // here, so this is at most one cycle).
                        state <= S_DIRTY_PUSH;
                    end else begin
                        if (!hk_rdata[dirty_id[4:0]]) begin
                            // 未标记: 置位并计数 (与根路径一致)
                            bm_waddr <= dirty_id[19:5];
                            bm_wdata <= hk_rdata | (32'h1 << dirty_id[4:0]);
                            bm_we    <= 1'b1;
                            marked_r <= marked_r + 32'd1;
                        end
                        // 已标记: 强制重扫 (不重复计数)
                        dirty_pop     <= 1'b1;
                        dirty_drained <= dirty_drained + 32'd1;
                        state         <= S_POP;
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
