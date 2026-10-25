// ============================================================
// tb_gc_top.v — FOGCCC 行为级仿真 (Vivado xsim)
//
// 目的: 不上板就验证"多笔未完成读"改造后的
//       gc_axi_read(读命令队列) + gc_mark_engine(两阶段并发读) 功能是否正确.
//
// 结构:
//   1. 行为级 AXI-Lite 主机  : 配置寄存器 + 轮询 DONE
//   2. 行为级 AXI HP  从机   : 固定延迟、支持多笔未完成、按序返回的读模型
//   3. 在 mem[] 里构造对象图 (含一个不可达"孤岛", 用于检测多标记)
//   4. TB 内跑一遍 BFS 得到期望活跃集, 再逐位对比 DUT 的位图 BRAM
//
// 通过判据 (全部满足):
//   - DONE 置位, 队列排空后 q_tail == 期望活跃对象数 (12 位指针, 4096 时回绕为 0)
//   - MARKED 寄存器 == 期望活跃对象数
//   - 位图逐位与期望一致 (既不多标, 也不少标)
//   - CYCLES 有效 (>0)
//
// 白盒说明: 部分定向用例 (T7 队列溢出、T-ABORT 卡死) 直接引用内部信号并
// 使用 force, 这是有意为之; RTL 改名时这些用例需要同步修改。
// ============================================================
`timescale 1ns/1ps

module tb_gc_top;

    // ---------------- 参数 ----------------
    localparam integer CLKP   = 10;             // 100MHz
    localparam integer N      = 300;            // 对象总数
    parameter integer LAT    = 8;              // AXI 读固定延迟(拍); 可用 xelab -generic_top "LAT=n" 扫参
    localparam integer MEMW   = 1 << 18;        // 1MB / 4
    localparam [31:0]  BASE   = 32'h1E000000;   // 对象图物理基地址
    localparam integer ISLAND = 50;             // 末尾 50 个对象 = 不可达孤岛

    // ---------------- 时钟 / 复位 ----------------
    reg clk = 1'b0;
    always #(CLKP/2) clk = ~clk;
    reg rstn = 1'b0;

    // ---------------- AXI-Lite 主机 ----------------
    reg  [11:0] m_awaddr  = 12'h0;
    reg         m_awvalid = 1'b0;
    wire        m_awready;
    reg  [31:0] m_wdata   = 32'h0;
    reg  [3:0]  m_wstrb   = 4'hF;

    // RRESP monitor: latches if the slave ever answers with a non-OKAY read response.
    reg rresp_seen = 1'b0;
    always @(posedge clk) if (dut.S_AXI_RVALID && dut.S_AXI_RRESP !== 2'b00) rresp_seen <= 1'b1;
    reg         m_wvalid  = 1'b0;
    wire        m_wready;
    wire [1:0]  m_bresp;
    wire        m_bvalid;
    reg         m_bready  = 1'b0;
    reg  [11:0] m_araddr  = 12'h0;
    reg         m_arvalid = 1'b0;
    wire        m_arready;
    wire [31:0] m_rdata;
    wire [1:0]  m_rresp;
    wire        m_rvalid;
    reg         m_rready  = 1'b0;

    // ---------------- AXI HP ----------------
    wire [31:0] hp_araddr;
    wire [5:0]  hp_arid;
    wire [3:0]  hp_arlen;
    wire [2:0]  hp_arsize;
    wire [1:0]  hp_arburst;
    wire [3:0]  hp_arcache;
    wire [2:0]  hp_arprot;
    wire        hp_arvalid;
    wire        hp_arready;
    wire [63:0] hp_rdata;
    wire [5:0]  hp_rid;
    wire [1:0]  hp_rresp;
    wire        hp_rlast;
    wire        hp_rvalid;
    wire        hp_rready;
    wire [31:0] hp_awaddr;
    wire [5:0]  hp_awid;
    wire [3:0]  hp_awlen;
    wire [2:0]  hp_awsize;
    wire [1:0]  hp_awburst;
    wire [3:0]  hp_awcache;
    wire [2:0]  hp_awprot;
    wire        hp_awvalid;
    wire        hp_awready;
    wire [63:0] hp_wdata;
    wire [5:0]  hp_wid;
    wire [7:0]  hp_wstrb;
    wire        hp_wlast;
    wire        hp_wvalid;
    wire        hp_wready;
    wire [5:0]  hp_bid;
    wire [1:0]  hp_bresp;
    wire        hp_bvalid;
    wire        hp_bready;
    wire        irq;

    // ---------------- DUT ----------------
    gc_top dut (
        .S_AXI_ACLK       (clk),
        .S_AXI_ARESETN    (rstn),
        .S_AXI_AWADDR     (m_awaddr),
        .S_AXI_AWVALID    (m_awvalid),
        .S_AXI_AWREADY    (m_awready),
        .S_AXI_WDATA      (m_wdata),
        .S_AXI_WSTRB      (m_wstrb),
        .S_AXI_WVALID     (m_wvalid),
        .S_AXI_WREADY     (m_wready),
        .S_AXI_BRESP      (m_bresp),
        .S_AXI_BVALID     (m_bvalid),
        .S_AXI_BREADY     (m_bready),
        .S_AXI_ARADDR     (m_araddr),
        .S_AXI_ARVALID    (m_arvalid),
        .S_AXI_ARREADY    (m_arready),
        .S_AXI_RDATA      (m_rdata),
        .S_AXI_RRESP      (m_rresp),
        .S_AXI_RVALID     (m_rvalid),
        .S_AXI_RREADY     (m_rready),
        .S_AXI_HP_ACLK    (clk),
        .S_AXI_HP_ARESETN (rstn),
        .S_AXI_HP_ARADDR  (hp_araddr),
        .S_AXI_HP_ARID    (hp_arid),
        .S_AXI_HP_ARLEN   (hp_arlen),
        .S_AXI_HP_ARSIZE  (hp_arsize),
        .S_AXI_HP_ARBURST (hp_arburst),
        .S_AXI_HP_ARCACHE (hp_arcache),
        .S_AXI_HP_ARPROT  (hp_arprot),
        .S_AXI_HP_ARVALID (hp_arvalid),
        .S_AXI_HP_ARREADY (hp_arready),
        .S_AXI_HP_RDATA   (hp_rdata),
        .S_AXI_HP_RID     (hp_rid),
        .S_AXI_HP_RRESP   (hp_rresp),
        .S_AXI_HP_RLAST   (hp_rlast),
        .S_AXI_HP_RVALID  (hp_rvalid),
        .S_AXI_HP_RREADY  (hp_rready),
        .S_AXI_HP_AWADDR  (hp_awaddr),
        .S_AXI_HP_AWID    (hp_awid),
        .S_AXI_HP_AWLEN   (hp_awlen),
        .S_AXI_HP_AWSIZE  (hp_awsize),
        .S_AXI_HP_AWBURST (hp_awburst),
        .S_AXI_HP_AWCACHE (hp_awcache),
        .S_AXI_HP_AWPROT  (hp_awprot),
        .S_AXI_HP_AWVALID (hp_awvalid),
        .S_AXI_HP_AWREADY (hp_awready),
        .S_AXI_HP_WDATA   (hp_wdata),
        .S_AXI_HP_WID     (hp_wid),
        .S_AXI_HP_WSTRB   (hp_wstrb),
        .S_AXI_HP_WLAST   (hp_wlast),
        .S_AXI_HP_WVALID  (hp_wvalid),
        .S_AXI_HP_WREADY  (hp_wready),
        .S_AXI_HP_BID     (hp_bid),
        .S_AXI_HP_BRESP   (hp_bresp),
        .S_AXI_HP_BVALID  (hp_bvalid),
        .S_AXI_HP_BREADY  (hp_bready),
        .irq_o            (irq)
    );

    // ================= 内存模型 =================
    reg [31:0] mem [0:MEMW-1];

    // ================= AXI HP 从机 (流水线读模型) =================
    assign hp_awready = 1'b1;
    assign hp_wready  = 1'b1;
    assign hp_bid     = 6'h00;
    assign hp_bresp   = 2'b00;
    assign hp_bvalid  = 1'b0;
    assign hp_rlast   = 1'b1;          // 每笔 AR 只有 1 拍

    // {valid, id[5:0], addr[31:0]} —— ID 必须跟着请求走, 返回时回显成 RID
    reg  [38:0] shr [0:LAT-1];
    integer     si;
    wire        hp_rvalid_i = shr[0][38];
    wire [5:0]  hp_rid_o    = shr[0][37:32];
    wire [31:0] hp_raddr    = shr[0][31:0];
    wire        hp_can_shift = !(hp_rvalid_i && !hp_rready);

    assign hp_arready = hp_can_shift;   // 输出被阻塞时不再收地址
    assign hp_rvalid  = hp_rvalid_i;
    assign hp_rid     = hp_rid_o;       // 回显请求的 ID
    reg  inject_err = 1'b0;
    assign hp_rresp   = inject_err ? 2'b10 : 2'b00;

    wire [31:0] hp_widx = hp_raddr[31:2] - BASE[31:2];
    assign hp_rdata = { mem[hp_widx + 1], mem[hp_widx] };  // 小端: 低字在先

    // ---------------- AXI 协议检查器 (AGENTS.md 缺口 #1) ----------------
    // 行为级存储模型不是协议检查器: 它对 ARSIZE/ARLEN/ARBURST 错误照常应答,
    // 只有数据看起来不对劲. 这里直接盯住主端口, 数清每一次违约.
    wire [31:0] axi_errs;
    axi_proto_check u_axi_chk (
        .clk     (clk),
        .rstn    (rstn),
        .ARADDR  (hp_araddr),
        .ARID    (hp_arid),
        .ARLEN   (hp_arlen),
        .ARSIZE  (hp_arsize),
        .ARBURST (hp_arburst),
        .ARCACHE (hp_arcache),
        .ARVALID (hp_arvalid),
        .ARREADY (hp_arready),
        .RID     (hp_rid),
        .RRESP   (hp_rresp),
        .RVALID  (hp_rvalid),
        .RREADY  (hp_rready),
        .errors  (axi_errs)
    );

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            for (si = 0; si < LAT; si = si + 1) shr[si] <= 39'd0;
        end else if (hp_can_shift) begin
            for (si = 0; si < LAT-1; si = si + 1)
                shr[si] <= shr[si+1];
            shr[LAT-1] <= (hp_arvalid && hp_arready) ? {1'b1, hp_arid, hp_araddr} : 39'd0;
        end
    end

    // ================= AXI-Lite 任务 =================
    task axil_wr(input [11:0] a, input [31:0] d);
        begin
            @(negedge clk);
            m_awaddr = a; m_awvalid = 1'b1;
            m_wdata  = d; m_wstrb = 4'hF; m_wvalid = 1'b1;
            m_bready = 1'b0;
            // 握手必须在 posedge 采样: ready 可能是组合信号,
            // negedge 会错过已经发生的握手。
            @(posedge clk);
            while (!(m_awvalid && m_awready)) @(posedge clk);
            @(negedge clk); m_awvalid = 1'b0;
            while (!(m_wvalid && m_wready)) @(posedge clk);
            @(negedge clk); m_wvalid = 1'b0;
            while (!m_bvalid) @(posedge clk);
            @(negedge clk); m_bready = 1'b1;
            @(negedge clk); m_bready = 1'b0;
            @(negedge clk);
        end
    endtask

    // Command writes carry their destination in WDATA[31:20]:
    // CTRL = 0xA50, DIRTY_PUSH = 0xA54.  gc_regs drops a beat whose marker
    // does not match, so a W beat mispaired with another store's AW is inert.
    task ctrl_wr(input [31:0] d);
        begin axil_wr(12'h000, 32'hA500_0000 | d); end
    endtask
    task dpush_wr(input [31:0] d);
        begin axil_wr(12'h440, 32'hA540_0000 | d); end
    endtask

    task axil_rd(input [11:0] a, output [31:0] d);
        begin
            @(negedge clk);
            m_araddr = a; m_arvalid = 1'b1; m_rready = 1'b0;
            @(negedge clk);
            while (!m_arready) @(negedge clk);
            m_arvalid = 1'b0;
            while (!m_rvalid)  @(negedge clk);
            d = m_rdata;
            m_rready = 1'b1;
            @(negedge clk);
            m_rready = 1'b0;
            @(negedge clk);
        end
    endtask

    // ================= 寄存器偏移 =================
    localparam [11:0] R_CTRL   = 12'h00;
    localparam [11:0] R_BASE   = 12'h04;
    localparam [11:0] R_COUNT  = 12'h08;
    localparam [11:0] R_ROOTS  = 12'h0C;
    localparam [11:0] R_MARKED = 12'h10;
    localparam [11:0] R_CYCLES = 12'h14;
    localparam [11:0] R_QHEAD  = 12'h18;
    localparam [11:0] R_QTAIL  = 12'h1C;
    localparam [11:0] R_STATUS = 12'h20;
    localparam [11:0] R_BMADDR = 12'h24;
    localparam [11:0] R_BMDATA = 12'h28;
    localparam [11:0] R_FCOUNT = 12'h38;
    localparam [11:0] R_FDATA  = 12'h3C;
    localparam [11:0] R_DPUSH  = 12'h440;  // Phase 3A: write pushes a dirty id (root list ends at 0x43F)
    localparam [11:0] R_DSTAT  = 12'h444;  // [8:0] occupancy, [9] overflow, [10] pending
    localparam [11:0] R_DDRAIN = 12'h448;  // ids consumed this epoch
    localparam [11:0] R_DPUSHED= 12'h44C;  // ids accepted since the last flush
    localparam [11:0] R_DPOPPED= 12'h450;  // ids consumed since the last flush
    localparam [11:0] R_RLIST  = 12'h40;

    // ================= TB 数据结构 =================
    integer     i, j, k;
    integer     rc, cur_off, ref_base;
    integer     tgt, node, head, tail, cnt_exp;
    integer     errors, got, bitv, qtail_dut, marked_dut;
    integer     rr;
    integer     err_ho = 0;          // #6: 未完成读事务超过 8 的次数
    reg [31:0]  rcs [0:N-1];
    reg [31:0]  roff [0:N-1];
    reg [31:0]  expb [0:N-1];      // 期望位图 (1=活跃)
    reg [31:0]  bq [0:N-1];
    reg [31:0]  rd_val;
    integer     guard;
    reg         race_injected = 1'b0;   // T-DIRTY-RACE: 记录已注入

    // Phase 3A: 带标签推送. 板上写路径把每次 store 投递两遍 (探针实测, 任意位宽),
    // 标签变化才入队 -> 重复投递被忽略. 标签 4 位, 逐次递增.
    integer     dtag = 0;
    task push_dirty(input [11:0] id);
        begin
            dpush_wr({16'h0, dtag[3:0], id});
            dtag = (dtag + 1) & 4'hF;
        end
    endtask

    // Phase 3A: the sanctioned way to clear the dirty FIFO - exactly what the driver does
    // (CTRL = CLEAR_Q|DIRTY_FLUSH, then a full-mark START).
    task dirty_flush_now;
        begin
            ctrl_wr(32'h20);             // arm
            ctrl_wr(32'h1);              // full-mark START consumes it
            guard = 0; rd_val = 32'hFFFFFFFF;
            while (rd_val[31] && guard < 2000) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
            guard = 0; rd_val = 32'h0;
            while (!rd_val[31] && guard < 200000) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        end
    endtask

    // ================= T-DIRTY-QFULL observation plumbing =================
    // The deadlock hypothesis: the BFS queue is FULL while a barrier record is pending
    // and the FSM reaches S_DIRTY_PUSH (5'd26).  Observe it instead of arguing:
    //  - qf_danger: cycles with q_full && a pending record (the precondition)
    //  - qf_wait  : cycles with the FSM in S_DIRTY_PUSH while q_full (the actual wait)
    //  - qf_maxcnt: peak BFS-queue occupancy (gc_queue exposes count/full)
    reg         qf_mon = 1'b0;
    integer     qf_danger = 0;
    integer     qf_wait   = 0;
    integer     qf_maxcnt = 0;
    always @(posedge clk) begin
        if (qf_mon) begin
            if (dut.u_queue.count > qf_maxcnt) qf_maxcnt = dut.u_queue.count;
            if (dut.u_queue.full && !dut.u_dirty.empty) qf_danger = qf_danger + 1;
            if ((dut.u_engine.state == 5'd26) && dut.u_queue.full) qf_wait = qf_wait + 1;
        end
    end

    // ================= T-DIRTY 临时时序探针 (Phase 3A 调试) =================
    reg dtrace_en = 1'b0;
    integer dtrace = 0;
    reg [8:0] dcnt_prev = 9'd0;
    always @(posedge clk) begin
        if (dtrace_en && dtrace < 40 &&
            (dut.u_engine.state >= 5'd25 || dut.u_dirty.cnt != dcnt_prev)) begin
            $display("[DRT] t=%0t st=%0d pop=%b cnt=%0d(obj=%0d) pushed=%0d popped=%0d drained=%0d empty=%b qcnt=%0d",
                     $time, dut.u_engine.state, dut.u_engine.dirty_pop,
                     dut.u_dirty.cnt, dut.u_engine.dirty_obj, dut.u_dirty.pushed,
                     dut.u_dirty.popped, dut.u_engine.dirty_drained, dut.u_dirty.empty,
                     dut.u_queue.count);
            dtrace = dtrace + 1;
        end
        dcnt_prev = dut.u_dirty.cnt;
    end

    initial begin
        errors = 0;

        // ---- 复位 ----
        rstn = 1'b0;
        repeat (20) @(negedge clk);
        rstn = 1'b1;
        repeat (5)  @(negedge clk);

        // #4: 复位后 DONE 必须为 0
        axil_rd(R_CTRL, rd_val);
        if (rd_val[31] !== 1'b0) begin
            $display("[TB][FAIL] DONE=%0d after reset, expected 0 (#4)", rd_val[31]);
            errors = errors + 1;
        end else begin
            $display("[TB] DONE=0 after reset OK (#4)");
        end

        // ---- 构造对象图 ----
        for (i = 0; i < MEMW; i = i + 1) mem[i] = 32'h0;

        ref_base = (N*16 + 4095) & ~4095;
        cur_off  = ref_base;
        for (i = 0; i < N; i = i + 1) begin
            if (i == 0)          rc = 3;          // 根对象有 3 条引用, 图才连通
            else if (i == 1)     rc = 200;        // rc > REF_MAX(64): 截断回归
            else if (i < N-ISLAND) rc = i % 8;    // 0..7, 覆盖 ref_count=0 的路径
            else                 rc = (i % 3) + 1;
            rcs[i]  = rc;
            roff[i] = cur_off;
            cur_off = cur_off + rc*4 + 4;
        end

        for (i = 0; i < N; i = i + 1) begin
            mem[(i*16)/4 + 0] = i;
            mem[(i*16)/4 + 1] = rcs[i];
            mem[(i*16)/4 + 2] = BASE + roff[i];
            mem[(i*16)/4 + 3] = 32'h0;
        end

        for (i = 0; i < N; i = i + 1) begin
            for (j = 0; j < rcs[i]; j = j + 1) begin
                if (i < N-ISLAND) begin
                    tgt = (i + 1 + j*13 + 7) % (N-ISLAND);
                    // 在根对象上造一个"相邻重复引用"(ref1 == ref0), 一定被访问到,
                    // 回归 prev_ref 跨运行残留
                    if (i == 0 && j == 1) tgt = mem[roff[0]/4 + 0];
                    if (tgt == i) tgt = (tgt + 1) % (N-ISLAND);
                end else begin
                    tgt = (N-ISLAND) + ((i + j + 1) % ISLAND);
                end
                mem[roff[i]/4 + j] = tgt;
            end
            mem[roff[i]/4 + rcs[i]] = 32'hFFFFFFFF;
        end

        // ---- TB 侧 BFS: 期望活跃集 ----
        for (i = 0; i < N; i = i + 1) expb[i] = 32'h0;
        head = 0; tail = 0; cnt_exp = 0;
        expb[0] = 32'h1; bq[tail] = 0; tail = tail + 1; cnt_exp = 1;
        while (head < tail) begin
            node = bq[head]; head = head + 1;
            for (j = 0; j < rcs[node]; j = j + 1) begin
                tgt = mem[roff[node]/4 + j];
                if (tgt != 32'hFFFFFFFF && tgt < N &&
                    expb[tgt] == 32'h0) begin
                    expb[tgt] = 32'h1;
                    bq[tail] = tgt; tail = tail + 1; cnt_exp = cnt_exp + 1;
                end
            end
        end
        $display("[TB] graph: N=%0d, live=%0d, island=%0d", N, cnt_exp, ISLAND);

        // ---- 配置寄存器 ----
        axil_wr(R_BASE,  BASE);
        axil_wr(R_COUNT, N);
        axil_wr(R_ROOTS, 1);
        // v4.5: the root list is readable; a write is verified by reading it back.
        axil_wr(R_RLIST + 8'h00, 32'd7);
        axil_rd(R_RLIST + 8'h00, rd_val);
        if (rd_val !== 32'd7) begin
            $display("[TB][FAIL] root readback=%0d (wrote 7) -- root read path", rd_val);
            errors = errors + 1;
        end else begin
            $display("[TB] root readback OK (7)");
        end
        axil_wr(R_RLIST + 8'h00, 32'd0);          // root[0] = 0
        $display("[TB] registers configured");

        // ---- 清零位图/队列, 然后启动 ----
        ctrl_wr(32'h6);                   // clear_bm | clear_q
        repeat (3000) @(negedge clk);
        ctrl_wr(32'h1);                   // start
        $display("[TB] write START");

        // 等 DONE 拉低 (确认 start 已被引擎接收)
        guard = 0;
        rd_val = 32'hFFFFFFFF;
        while (rd_val[31] && guard < 200) begin
            axil_rd(R_CTRL, rd_val);
            guard = guard + 1;
        end
        if (rd_val[31]) begin
            $display("[TB][FAIL] start ignored (DONE stuck at 1) state=%0d",
                     dut.u_engine.state);
            errors = errors + 1;
        end else begin
            $display("[TB] DONE raised, marking started");
        end

        // 等 DONE 拉高
        guard = 0;
        rd_val = 32'h0;
        while (!rd_val[31] && guard < 20000) begin
            axil_rd(R_CTRL, rd_val);
            guard = guard + 1;
        end
        if (!rd_val[31]) begin
            $display("[TB][FAIL] timeout: DONE not set");
            $display("      engine state=%0d cur_obj=%0d qh=%0d qt=%0d",
                     dut.u_engine.state, dut.u_engine.cur_obj,
                     dut.u_queue.head, dut.u_queue.tail);
            $display("      axi: ARVALID=%0d ARADDR=%h hcnt=%0d cw=%0d cr=%0d dw=%0d dr=%0d hw=%0d hr=%0d",
                     dut.u_axi_rd.ARVALID, dut.u_axi_rd.ARADDR,
                     dut.u_axi_rd.h0cnt, dut.u_axi_rd.c0w, dut.u_axi_rd.c0r,
                     dut.u_axi_rd.d0w, dut.u_axi_rd.d0r,
                     dut.u_axi_rd.h0w, dut.u_axi_rd.h0r);
            $display("      engine: rd_cmd_valid=%0d rd_cmd_ready=%0d rd_data_valid=%0d rd_data_ready=%0d",
                     dut.u_engine.rd_cmd_valid, dut.u_engine.rd_cmd_ready,
                     dut.u_engine.rd_data_valid, dut.u_engine.rd_data_ready);
            $display("      scout : st=%0d pf_cnt=%0d pf_iss=%0d pf_head=%0d dq_cnt=%0d dq_head=%0d iss_idx=%0d hdr_sec=%0d",
                     dut.u_engine.sc_state, dut.u_engine.pf_cnt, dut.u_engine.pf_iss,
                     dut.u_engine.pf_head, dut.u_engine.dq_cnt, dut.u_engine.dq_head,
                     dut.u_engine.iss_idx, dut.u_engine.hdr_second);
            $display("      dq_rc[0..3]=%0d %0d %0d %0d   dq_ra[0]=%h   ref_count=%0d ref_got=%0d cur=%0d",
                     dut.u_engine.dq_rc[0], dut.u_engine.dq_rc[1],
                     dut.u_engine.dq_rc[2], dut.u_engine.dq_rc[3],
                     dut.u_engine.dq_ra[0], dut.u_engine.ref_count,
                     dut.u_engine.ref_got, dut.u_engine.cur_obj);
            errors = errors + 1;
        end

        // ---- 读统计 ----
        $display("[TB] DONE @cycles=%0d | scout st=%0d pf_cnt=%0d pf_iss=%0d pf_head=%0d dq_cnt=%0d dq_head=%0d iss_idx=%0d qh=%0d qt=%0d",
                 dut.u_engine.cycles_r, dut.u_engine.sc_state, dut.u_engine.pf_cnt,
                 dut.u_engine.pf_iss, dut.u_engine.pf_head, dut.u_engine.dq_cnt,
                 dut.u_engine.dq_head, dut.u_engine.iss_idx,
                 dut.u_queue.head, dut.u_queue.tail);
        $display("[TB] DONE detail | cur=%0d ref_count=%0d ref_got=%0d pf_rc=%0d,%0d,%0d,%0d pf_id=%0d,%0d,%0d,%0d dq_rc=%0d,%0d,%0d,%0d",
                 dut.u_engine.cur_obj, dut.u_engine.ref_count, dut.u_engine.ref_got,
                 dut.u_engine.pf_rc[0], dut.u_engine.pf_rc[1], dut.u_engine.pf_rc[2], dut.u_engine.pf_rc[3],
                 dut.u_engine.pf_id[0], dut.u_engine.pf_id[1], dut.u_engine.pf_id[2], dut.u_engine.pf_id[3],
                 dut.u_engine.dq_rc[0], dut.u_engine.dq_rc[1], dut.u_engine.dq_rc[2], dut.u_engine.dq_rc[3]);
        // 新增: STATUS 的错误位必须为 0, 且引擎已回到 idle (bit4)
        axil_rd(8'h20, rd_val);
        if ((rd_val & 32'h1F) !== 32'h10) begin
            $display("[TB][FAIL] STATUS=%h (errors must be 0 and bit4=1)", rd_val);
            errors = errors + 1;
        end else begin
            $display("[TB] STATUS=0x10 OK (no errors, idle)");
        end
        axil_rd(R_MARKED, rd_val); marked_dut = rd_val;
        axil_rd(R_QTAIL,  rd_val); qtail_dut  = rd_val & 32'hFFF;
        axil_rd(R_CYCLES, rd_val);
        $display("[TB] HW: marked=%0d q_tail=%0d cycles=%0d", marked_dut, qtail_dut, rd_val);

        if (marked_dut != cnt_exp) begin
            $display("[TB][FAIL] MARKED=%0d != expected %0d", marked_dut, cnt_exp);
            errors = errors + 1;
        end
        if (qtail_dut != cnt_exp) begin
            $display("[TB][FAIL] q_tail=%0d != expected %0d", qtail_dut, cnt_exp);
            errors = errors + 1;
        end
        if (rd_val == 32'h0) begin
            $display("[TB][FAIL] CYCLES=0 (engine did not run)");
            errors = errors + 1;
        end

        // ---- 逐位对比位图 ----
        // 位图映射: 对象 x → mem[x] 的第 (x%32) 位
        got = 0;
        for (i = 0; i < N; i = i + 1) begin
            bitv = (dut.u_bitmap.mem[i] >> (i % 32)) & 32'h1;
            if (bitv !== expb[i]) begin
                if (errors < 20)
                    $display("[TB][FAIL] object %0d bitmap=%0d expected=%0d", i, bitv, expb[i]);
                errors = errors + 1;
            end
            if (bitv) got = got + 1;
        end
        $display("[TB] bitmap: live=%0d expected=%0d", got, cnt_exp);

        // 孤岛必须全 0 (多标记检测)
        for (i = N-ISLAND; i < N; i = i + 1) begin
            bitv = (dut.u_bitmap.mem[i] >> (i % 32)) & 32'h1;
            if (bitv) begin
                $display("[TB][FAIL] island object %0d marked", i);
                errors = errors + 1;
            end
        end

        // ============================================================
        $display("[TB] ===== T1: two consecutive runs =====");
        mem[(0*16)/4 + 1] = 32'd1;                 // obj0 ref_count = 1
        mem[(0*16)/4 + 2] = BASE + ref_base;       // obj0 ref_addr
        mem[ref_base/4 + 0] = 32'd1;               // ref[0] = obj1
        mem[ref_base/4 + 1] = 32'hFFFFFFFF;        // 终止符
        mem[(1*16)/4 + 1] = 32'd0;                 // obj1 ref_count = 0
        mem[(1*16)/4 + 2] = BASE + ref_base + 32'd8;

        axil_wr(R_BASE,  BASE);
        axil_wr(R_COUNT, 32'd2);
        axil_wr(R_ROOTS, 32'd1);
        axil_wr(R_RLIST, 32'd0);

        for (rr = 0; rr < 2; rr = rr + 1) begin
            ctrl_wr(32'h6);                // clear_bm | clear_q
            repeat (200) @(negedge clk);
            ctrl_wr(32'h1);                // start

            // 先等 DONE 落低 (确认 start 被接收), 再等它抬高
            guard = 0; rd_val = 32'hFFFFFFFF;
            while (rd_val[31] && guard < 500) begin
                axil_rd(R_CTRL, rd_val); guard = guard + 1;
            end
            guard = 0; rd_val = 32'h0;
            while (!rd_val[31] && guard < 20000) begin
                axil_rd(R_CTRL, rd_val); guard = guard + 1;
            end

            axil_rd(R_MARKED, rd_val);
            $display("[TB] T1 run%0d: marked=%0d (expect 2)", rr+1, rd_val);
            if (rd_val !== 32'd2) begin
                $display("[TB][FAIL] T1 run%0d marked=%0d != 2 (prev_ref leak?)", rr+1, rd_val);
                errors = errors + 1;
            end
        end

        // ============================================================
        // T2: 重复根 —— 同一个 root 写两次, 必须只计一次 (#5)
        // ============================================================
        $display("[TB] ===== T2: duplicate root =====");
        // 根 ID >= 32: 落在不同的位图字上, 位图字 0 不会掩盖重复检测。
        mem[(33*16)/4 + 1] = 32'd0;          // obj33 ref_count = 0 (在 +4, 字索引 +1)
        axil_wr(R_RLIST,     32'd33);
        axil_wr(R_RLIST + 4, 32'd33);        // 同一个根再写一次
        axil_wr(R_COUNT, 32'd64);
        axil_wr(R_ROOTS, 32'd2);             // root_count = 2

        ctrl_wr(32'h6);
        repeat (200) @(negedge clk);
        ctrl_wr(32'h1);
        guard = 0; rd_val = 32'hFFFFFFFF;
        while (rd_val[31] && guard < 500) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        guard = 0; rd_val = 32'h0;
        while (!rd_val[31] && guard < 20000) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        axil_rd(R_MARKED, rd_val);
        $display("[TB] T2 duplicate-root: marked=%0d (expect 1)", rd_val);
        if (rd_val !== 32'd1) begin
            $display("[TB][FAIL] T2 marked=%0d != 1 (duplicate root counted?)", rd_val);
            errors = errors + 1;
        end

        // ============================================================
        // T3: 流水 AW —— 背靠背两笔写, 两笔都必须落到正确地址 (#2)
        // ============================================================
        $display("[TB] ===== T3: pipelined AW (back-to-back writes) =====");
        begin : t3
            integer e0;
            e0 = errors;
            @(negedge clk);
            m_bready = 1'b1;
            fork
                begin : aw_th
                    m_awaddr = 12'h004; m_awvalid = 1'b1;
                    @(posedge clk); while (!(m_awvalid && m_awready)) @(posedge clk);
                    @(negedge clk); m_awaddr = 12'h008;
                    @(posedge clk); while (!(m_awvalid && m_awready)) @(posedge clk);
                    @(negedge clk); m_awvalid = 1'b0;
                end
                begin : w_th
                    m_wdata = 32'hA5A50001; m_wstrb = 4'hF; m_wvalid = 1'b1;
                    @(posedge clk); while (!(m_wvalid && m_wready)) @(posedge clk);
                    @(posedge clk); while (!m_bvalid) @(posedge clk);
                    @(negedge clk); m_wdata = 32'h5A5A0002;
                    @(posedge clk); while (!(m_wvalid && m_wready)) @(posedge clk);
                    @(negedge clk); m_wvalid = 1'b0;
                end
            join
            repeat (20) @(negedge clk);
            m_bready = 1'b0;
            @(negedge clk);

            axil_rd(8'h04, rd_val);
            if (rd_val !== 32'hA5A50001) begin
                $display("[TB][FAIL] T3 reg04=%h != A5A50001 (first write lost)", rd_val);
                errors = errors + 1;
            end
            axil_rd(8'h08, rd_val);
            if (rd_val !== 32'h5A5A0002) begin
                $display("[TB][FAIL] T3 reg08=%h != 5A5A0002 (second AW not delivered)", rd_val);
                errors = errors + 1;
            end
            if (errors == e0) $display("[TB] T3 pipelined-AW OK");
        end

        // ============================================================
        // T4: 非法对象头 —— ref_count = 0xFFFFFFFF 必须被拒, 不能挂死
        // ============================================================
        $display("[TB] ===== T4: corrupt ref_count guard =====");
        mem[(0*16)/4 + 1] = 32'hFFFFFFFF;        // obj0 的 ref_count 写坏 (+4)
        axil_wr(R_BASE,  BASE);
        axil_wr(R_COUNT, 32'd2);
        axil_wr(R_ROOTS, 32'd1);
        axil_wr(R_RLIST, 32'd0);
        ctrl_wr(32'h6);
        repeat (200) @(negedge clk);
        ctrl_wr(32'h1);
        guard = 0; rd_val = 32'hFFFFFFFF;
        while (rd_val[31] && guard < 500) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        guard = 0; rd_val = 32'h0;
        while (!rd_val[31] && guard < 20000) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        axil_rd(R_MARKED, rd_val);
        $display("[TB] T4 marked=%0d (expect 1)", rd_val);
        if (rd_val !== 32'd1) begin
            $display("[TB][FAIL] T4 marked=%0d != 1 (bad header accepted)", rd_val);
            errors = errors + 1;
        end
        axil_rd(8'h20, rd_val);
        if (rd_val[3] !== 1'b1) begin
            $display("[TB][FAIL] T4 STATUS[3]=%b, expected 1 (err_hdr not set)", rd_val[3]);
            errors = errors + 1;
        end else begin
            $display("[TB] T4 err_hdr=1 OK (bad header rejected)");
        end

        // ============================================================
        // T5: 12 位寄存器地址 —— 写 root[60] (地址 0x40+60*4 = 0x130 > 0xFF)
        //   构造: obj_count=61, root[0..59] 全填 200 (>= obj_count, 会被跳过),
        //         root[60]=60。root_count=61 保证引擎确实会读到 root[60]。
        //   期望: marked=1 (只有 obj60);
        //   若地址被截断(8 位): root[60] 写不进去 -> 全是无效根 -> marked=0.
        // ============================================================
        $display("[TB] ===== T5: 12-bit register address =====");
        mem[(60*16)/4 + 1] = 32'd0;              // obj60 ref_count = 0
        axil_wr(R_BASE,  BASE);
        axil_wr(R_COUNT, 32'd61);                // id >= 61 视为越界 -> 跳过
        for (rr = 0; rr < 60; rr = rr + 1)
            axil_wr(R_RLIST + rr * 4, 32'd200);  // root[0..59] 全无效
        axil_wr(R_RLIST + 12'd60 * 12'd4, 32'd60); // root[60] = obj60 (地址 0x130)
        axil_wr(R_ROOTS, 32'd61);
        ctrl_wr(32'h6);
        repeat (200) @(negedge clk);
        ctrl_wr(32'h1);
        guard = 0; rd_val = 32'hFFFFFFFF;
        while (rd_val[31] && guard < 500) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        guard = 0; rd_val = 32'h0;
        while (!rd_val[31] && guard < 20000) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        axil_rd(R_MARKED, rd_val);
        $display("[TB] T5 root60: marked=%0d (expect 1)", rd_val);
        if (rd_val !== 32'd1) begin
            $display("[TB][FAIL] T5 marked=%0d != 1 (root[60] address truncated?)", rd_val);
            errors = errors + 1;
        end

        // ============================================================
        // T6: bitmap readback (0x24 BM_ADDR / 0x28 BM_DATA)
        //   T5 just finished and marked only obj60. The probe must read the
        //   same word the engine wrote. Before the probe existed, 0x28 read
        //   back 0xDEADBEEF.
        // ============================================================
        $display("[TB] ===== T6: bitmap readback =====");
        // Phase 2: the free-list scanner borrows the bitmap read port while
        // STATUS[5] is set; wait for it to finish before probing.
        i = 0;
        axil_rd(R_STATUS, rd_val);
        while (((rd_val & 32'h20) != 0) && (i < 20000)) begin
            i = i + 1;
            axil_rd(R_STATUS, rd_val);
        end
        axil_wr(R_BMADDR, 32'd60);
        axil_rd(R_BMDATA, rd_val);
        $display("[TB] T6 probe[60]=%h (bit28=%0d) bram=%h", rd_val, rd_val[28], dut.u_bitmap.mem[60]);
        if (rd_val[28] !== 1'b1) begin
            $display("[TB][FAIL] T6 BM_DATA[60] bit28 != 1 (probe did not see the bit)");
            errors = errors + 1;
        end
        if (rd_val !== dut.u_bitmap.mem[60]) begin
            $display("[TB][FAIL] T6 probe %h != bram %h", rd_val, dut.u_bitmap.mem[60]);
            errors = errors + 1;
        end
        axil_wr(R_BMADDR, 32'd61);
        axil_rd(R_BMDATA, rd_val);
        if (rd_val !== 32'h0) begin
            $display("[TB][FAIL] T6 BM_DATA[61]=%h, expect 0", rd_val);
            errors = errors + 1;
        end
        $display("[TB] T6 bitmap probe OK");

        // ============================================================
        // T-FREE: free-list end-to-end (engine -> bitmap -> scanner -> pop)
        //   Star graph, obj_count=64: root 0 -> refs 1..31 (rc=0 on 1..31).
        //   The engine marks {0..31}; the scanner must push exactly {32..63},
        //   and popping FREE_DATA must return that set, no duplicates.
        //   This pins the bitmap layout: the scanner must test word mem[o],
        //   bit o[4:0] -- the same layout the engine writes and the 0x24
        //   probe reads.  A packed-word scanner (o>>5, o&31) reads mem[0..1]
        //   = {1,2} and reports a wrong count/set here.
        // ============================================================
        $display("[TB] ===== T-FREE: free-list end-to-end =====");
        begin : t_free_gen
            integer i;
            for (i = 0; i < 64; i = i + 1) begin
                mem[(i*16)/4 + 0] = i;
                mem[(i*16)/4 + 1] = (i == 0) ? 31 : 0;
                mem[(i*16)/4 + 2] = BASE + ref_base;
            end
            for (i = 0; i < 31; i = i + 1)
                mem[ref_base/4 + i] = i + 1;
            mem[ref_base/4 + 31] = 32'hFFFFFFFF;
        end
        axil_wr(R_BASE,  BASE);
        axil_wr(R_COUNT, 32'd64);
        axil_wr(R_ROOTS, 32'd1);
        axil_wr(R_RLIST, 32'd0);
        ctrl_wr(32'h6);
        repeat (200) @(negedge clk);
        ctrl_wr(32'h1);
        guard = 0; rd_val = 32'hFFFFFFFF;
        while (rd_val[31] && guard < 500) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        guard = 0; rd_val = 32'h0;
        while (!rd_val[31] && guard < 20000) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        // Phase 2: the scanner borrows the bitmap read port; wait for it.
        guard = 0;
        axil_rd(R_STATUS, rd_val);
        while (((rd_val & 32'h20) != 0) && (guard < 20000)) begin
            guard = guard + 1;
            axil_rd(R_STATUS, rd_val);
        end
        axil_rd(R_MARKED, rd_val);
        if (rd_val !== 32'd32) begin
            $display("[TB][FAIL] T-FREE marked=%0d != 32", rd_val);
            errors = errors + 1;
        end
        axil_rd(R_FCOUNT, rd_val);
        $display("[TB] T-FREE FREE_COUNT=%0d (expect 32)", rd_val);
        if (rd_val !== 32'd32) begin
            $display("[TB][FAIL] T-FREE FREE_COUNT=%0d != 32 (bitmap layout?)", rd_val);
            errors = errors + 1;
        end
        begin : t_free_pop
            integer i, v, seen_lo, seen_hi, dup, rng;
            reg [63:0] got;
            seen_lo = 0; seen_hi = 0; dup = 0; rng = 0; got = 64'd0;
            for (i = 0; i < 32; i = i + 1) begin
                axil_rd(R_FDATA, rd_val);
                v = rd_val[5:0];
                if ((rd_val & 32'hFFFFF000) != 0) rng = rng + 1;
                if (v < 32) seen_lo = seen_lo + 1;
                else        seen_hi = seen_hi + 1;
                if ((v < 64) && got[v]) dup = dup + 1;
                if (v < 64) got[v] = 1'b1;
            end
            $display("[TB] T-FREE popped: lo(<32)=%0d hi=%0d dup=%0d out_of_range=%0d",
                     seen_lo, seen_hi, dup, rng);
            if (seen_lo != 0 || seen_hi != 32 || dup != 0 || rng != 0) begin
                $display("[TB][FAIL] T-FREE free set wrong (expect exactly 32..63)");
                errors = errors + 1;
            end
        end

        // ============================================================
        // T-DIRTY: Phase 3A barrier dirty set as a work source
        //   A0 negative control: no dirty pushes -> a root-less run marks 0.
        //   A  dirty = {0,40,41}; obj0 -> {1,2,3} -> marks {0,1,2,3,40,41},
        //      DIRTY_DRAINED=3, free list = the other 58 ids.
        //   B  BM_KEEP + obj0 gained ref 10, dirty = {0} -> the already
        //      marked container is re-scanned (a dedup would leave 10
        //      unmarked); epoch count = 1, cumulative bitmap = 7 ids.
        //   C  overflow: 300 pushes into a 256-deep FIFO latch the flag,
        //      and CTRL[5] clears it.
        // ============================================================
        $display("[TB] ===== T-DIRTY: barrier dirty set =====");
        begin : t_dirty_gen
            integer i;
            for (i = 0; i < 64; i = i + 1) begin
                mem[(i*16)/4 + 0] = i;
                mem[(i*16)/4 + 1] = (i == 0) ? 3 : 0;
                mem[(i*16)/4 + 2] = BASE + ref_base;
            end
            for (i = 0; i < 3; i = i + 1) mem[ref_base/4 + i] = i + 1;
            mem[ref_base/4 + 3] = 32'hFFFFFFFF;
        end
        axil_wr(R_BASE,  BASE);
        axil_wr(R_COUNT, 32'd64);
        axil_wr(R_ROOTS, 32'd0);                 // no roots at all
        // A0: no barrier, no roots -> nothing may be marked
        dirty_flush_now;
        repeat (200) @(negedge clk);
        ctrl_wr(32'h1);
        guard = 0; rd_val = 32'hFFFFFFFF;
        while (rd_val[31] && guard < 500) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        guard = 0; rd_val = 32'h0;
        while (!rd_val[31] && guard < 20000) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        guard = 0; axil_rd(R_STATUS, rd_val);
        while (((rd_val & 32'h20) != 0) && (guard < 20000)) begin guard = guard + 1; axil_rd(R_STATUS, rd_val); end
        axil_rd(R_MARKED, rd_val);
        $display("[TB] T-DIRTY A0 (no barrier): marked=%0d (expect 0)", rd_val);
        if (rd_val !== 32'd0) begin
            $display("[TB][FAIL] T-DIRTY A0 marked=%0d without any dirty push (negative control)", rd_val);
            errors = errors + 1;
        end
        axil_rd(R_DDRAIN, rd_val);
        $display("[TB] T-DIRTY A0 drained=%0d (expect 0)", rd_val);
        if (rd_val !== 32'd0) begin
            $display("[TB][FAIL] T-DIRTY A0 drained=%0d != 0 (phantom drain)", rd_val);
            errors = errors + 1;
        end
        // A: dirty-driven, no roots
        dirty_flush_now;
        repeat (200) @(negedge clk);
        push_dirty(12'd0);
        push_dirty(12'd40);
        push_dirty(12'd41);
        dtrace_en = 1'b1;
        axil_rd(R_DSTAT, rd_val);
        $display("[TB] T-DIRTY A pre-run: occupancy=%0d pending=%b ovf=%b (expect 3/1/0)",
                 rd_val[8:0], rd_val[10], rd_val[9]);
        if (rd_val[8:0] !== 9'd3 || rd_val[10] !== 1'b1) begin
            $display("[TB][FAIL] T-DIRTY A FIFO not holding exactly the 3 pushed ids");
            errors = errors + 1;
        end
        ctrl_wr(32'h1);
        guard = 0; rd_val = 32'hFFFFFFFF;
        while (rd_val[31] && guard < 500) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        guard = 0; rd_val = 32'h0;
        while (!rd_val[31] && guard < 20000) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        guard = 0; axil_rd(R_STATUS, rd_val);
        while (((rd_val & 32'h20) != 0) && (guard < 20000)) begin guard = guard + 1; axil_rd(R_STATUS, rd_val); end
        axil_rd(R_MARKED, rd_val);
        if (rd_val !== 32'd6) begin
            $display("[TB][FAIL] T-DIRTY A marked=%0d != 6 (dirty work source)", rd_val);
            errors = errors + 1;
        end
        axil_rd(R_DDRAIN, rd_val);
        $display("[TB] T-DIRTY A drained=%0d", rd_val);
        if (rd_val !== 32'd3) begin
            $display("[TB][FAIL] T-DIRTY A drained=%0d != 3", rd_val);
            errors = errors + 1;
        end
        axil_rd(R_DPUSHED, rd_val);
        $display("[TB] T-DIRTY A pushed=%0d (expect 3)", rd_val);
        if (rd_val !== 32'd3) begin
            $display("[TB][FAIL] T-DIRTY A pushed=%0d != 3 (stray push?)", rd_val);
            errors = errors + 1;
        end
        axil_rd(R_DPOPPED, rd_val);
        $display("[TB] T-DIRTY A popped=%0d (expect 3)", rd_val);
        if (rd_val !== 32'd3) begin
            $display("[TB][FAIL] T-DIRTY A popped=%0d != 3", rd_val);
            errors = errors + 1;
        end
        axil_rd(R_FCOUNT, rd_val);
        if (rd_val !== 32'd58) begin
            $display("[TB][FAIL] T-DIRTY A free_count=%0d != 58", rd_val);
            errors = errors + 1;
        end
        begin : t_dirty_free
            integer i, v;
            reg [63:0] got;
            got = 64'd0;
            for (i = 0; i < 58; i = i + 1) begin
                axil_rd(R_FDATA, rd_val);
                v = rd_val[5:0];
                if (v < 64) got[v] = 1'b1;
            end
            // free = everything except {0,1,2,3,40,41}
            if (got[0] || got[1] || got[2] || got[3] || got[40] || got[41]) begin
                $display("[TB][FAIL] T-DIRTY A free list contains a marked object");
                errors = errors + 1;
            end
        end
        $display("[TB] T-DIRTY A: marked=6 drained=3 free=58 OK");
        // B: BM_KEEP + forced re-scan of an already marked container
        begin : t_dirty_edit
            integer i;
            for (i = 0; i < 4; i = i + 1) mem[ref_base/4 + i] = 0;
            mem[(0*16)/4 + 1] = 32'd4;           // obj0 -> {1,2,3,10}
            mem[ref_base/4 + 0] = 32'd1;
            mem[ref_base/4 + 1] = 32'd2;
            mem[ref_base/4 + 2] = 32'd3;
            mem[ref_base/4 + 3] = 32'd10;
            mem[ref_base/4 + 4] = 32'hFFFFFFFF;
        end
        ctrl_wr(32'h4);                  // clear_q only: the bitmap must SURVIVE into the
        repeat (200) @(negedge clk);             // BM_KEEP epoch (under arm-and-consume a flush needs a full mark)
        push_dirty(12'd0);                       // already marked -> must be re-scanned
        ctrl_wr(32'h11);                 // START | BM_KEEP
        guard = 0; rd_val = 32'hFFFFFFFF;
        while (rd_val[31] && guard < 500) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        guard = 0; rd_val = 32'h0;
        while (!rd_val[31] && guard < 20000) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        guard = 0; axil_rd(R_STATUS, rd_val);
        while (((rd_val & 32'h20) != 0) && (guard < 20000)) begin guard = guard + 1; axil_rd(R_STATUS, rd_val); end
        axil_rd(R_MARKED, rd_val);
        if (rd_val !== 32'd1) begin
            $display("[TB][FAIL] T-DIRTY B epoch marked=%0d != 1 (only obj10 is new)", rd_val);
            errors = errors + 1;
        end
        begin : t_dirty_bm
            integer i, hb, cnt, bad;
            cnt = 0; bad = 0;
            for (i = 0; i < 64; i = i + 1) begin
                axil_wr(R_BMADDR, i);
                axil_rd(R_BMDATA, rd_val);
                hb = (rd_val >> (i & 31)) & 1;
                if (hb) cnt = cnt + 1;
                // expected cumulative set = {0,1,2,3,10,40,41}
                if (hb !== ((i == 0) || (i == 1) || (i == 2) || (i == 3) ||
                            (i == 10) || (i == 40) || (i == 41))) bad = bad + 1;
            end
            $display("[TB] T-DIRTY B bitmap: marked=%0d bad=%0d (expect 7 / 0)", cnt, bad);
            if (cnt !== 7 || bad !== 0) begin
                $display("[TB][FAIL] T-DIRTY B forced re-scan failed (bitmap)");
                errors = errors + 1;
            end
        end
        // C: FIFO overflow flag (no silent loss of the record)
        dirty_flush_now;
        repeat (50) @(negedge clk);
        begin : t_dirty_ovf
            integer i;
            for (i = 0; i < 300; i = i + 1) push_dirty(i % 64);
        end
        axil_rd(R_DSTAT, rd_val);
        $display("[TB] T-DIRTY C status=%h (expect bit9=1, occupancy=256)", rd_val);
        if (rd_val[9] !== 1'b1) begin
            $display("[TB][FAIL] T-DIRTY C overflow flag not set");
            errors = errors + 1;
        end
        if (rd_val[8:0] !== 9'd256) begin
            $display("[TB][FAIL] T-DIRTY C occupancy=%0d != 256", rd_val[8:0]);
            errors = errors + 1;
        end
        dirty_flush_now;
        repeat (50) @(negedge clk);
        axil_rd(R_DSTAT, rd_val);
        if (rd_val[9] !== 1'b0 || rd_val[8:0] !== 9'd0) begin
            $display("[TB][FAIL] T-DIRTY C flush did not clear (status=%h)", rd_val);
            errors = errors + 1;
        end
        $display("[TB] T-DIRTY C overflow flag OK");

        // ---- T-DIRTY-FLUSHSPILL: this board redelivers every AXI-Lite store and the
        //      copies are not always adjacent, so a full-mark's DIRTY_FLUSH can arrive
        //      again while a later epoch is running.  gc_top now honours DIRTY_FLUSH
        //      only while the engine is idle (same treatment as CLEAR_Q).  The engine
        //      spends the first ~4096 cycles of a run clearing the bitmap, so a flush
        //      injected right after START lands well before the dirty record is read.
        //      Ungated RTL: the record is dropped -> drained=0, marked=0.
        //      Gated RTL:   the flush is ignored -> drained=1, marked=2 (obj0,obj1).
        // ----
        dirty_flush_now;
        repeat (50) @(negedge clk);
        begin : t_dirty_spill_cfg
            integer i;
            for (i = 0; i < 64; i = i + 1) begin
                mem[(i*16)/4 + 0] = i;
                mem[(i*16)/4 + 1] = (i == 0) ? 32'd512 : 32'd0;
                mem[(i*16)/4 + 2] = BASE + ref_base;
            end
            for (i = 0; i < 512; i = i + 1) mem[ref_base/4 + i] = 32'd1;
            mem[ref_base/4 + 512] = 32'hFFFFFFFF;
        end
        axil_wr(R_BASE,  BASE);
        axil_wr(R_COUNT, 32'd64);
        axil_wr(R_ROOTS, 32'd0);
        push_dirty(12'd0);                       // one pending barrier record
        ctrl_wr(32'h1);                  // START (no flush, no bm_keep)
        ctrl_wr(32'h20);                 // spilled full-mark flush, mid-run
        guard = 0; rd_val = 32'hFFFFFFFF;
        while (rd_val[31] && guard < 500) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        guard = 0; rd_val = 32'h0;
        while (!rd_val[31] && guard < 400000) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        guard = 0; axil_rd(R_STATUS, rd_val);
        while (((rd_val & 32'h20) != 0) && (guard < 400000)) begin guard = guard + 1; axil_rd(R_STATUS, rd_val); end
        axil_rd(R_DDRAIN, rd_val);
        $display("[TB] T-DIRTY-FLUSHSPILL drained=%0d (expect 1: the record survived)", rd_val);
        if (rd_val !== 32'd1) begin
            $display("[TB][FAIL] T-DIRTY-FLUSHSPILL a mid-run flush dropped the pending barrier record");
            errors = errors + 1;
        end
        axil_rd(R_MARKED, rd_val);
        $display("[TB] T-DIRTY-FLUSHSPILL marked=%0d (expect 2: obj0 + obj1)", rd_val);
        if (rd_val !== 32'd2) begin
            $display("[TB][FAIL] T-DIRTY-FLUSHSPILL marked=%0d != 2", rd_val);
            errors = errors + 1;
        end
        // the sanctioned clear must still work: arm + a full-mark START (dirty_flush_now)
        push_dirty(12'd5);
        axil_rd(R_DSTAT, rd_val);
        if (rd_val[8:0] !== 9'd1) begin
            $display("[TB][FAIL] T-DIRTY-FLUSHSPILL setup occupancy=%0d != 1", rd_val[8:0]);
            errors = errors + 1;
        end
        dirty_flush_now;
        axil_rd(R_DSTAT, rd_val);
        $display("[TB] T-DIRTY-FLUSHSPILL sanctioned clear occupancy=%0d (expect 0)", rd_val[8:0]);
        if (rd_val[8:0] !== 9'd0 || rd_val[9] !== 1'b0) begin
            $display("[TB][FAIL] T-DIRTY-FLUSHSPILL the sanctioned clear (arm + full-mark START) must empty the FIFO");
            errors = errors + 1;
        end
        $display("[TB] T-DIRTY-FLUSHSPILL done");

        // ---- T-DIRTY-FLUSHIDLE: a bare idle flush only arms the next full mark.
        //      A late copy of a full-mark's DIRTY_FLUSH can arrive while the engine is
        //      IDLE - after the full mark finished and the mutator has already pushed
        //      records for the next epoch.  Under "arm-and-consume" the CTRL write only
        //      arms the flush; it is applied at the next BM_KEEP=0 START and DISCARDED
        //      by an incremental (BM_KEEP=1) start.
        //      Idle-gated-only RTL: the bare write clears immediately -> parts 1 and 3 fail.
        // ----
        dirty_flush_now;                         // clean slate (valid on both semantics)
        axil_wr(R_COUNT, 32'd64);
        axil_wr(R_ROOTS, 32'd0);
        push_dirty(12'd7);
        axil_rd(R_DSTAT, rd_val);
        $display("[TB] T-DIRTY-FLUSHIDLE setup: occupancy=%0d (expect 1)", rd_val[8:0]);
        if (rd_val[8:0] !== 9'd1) begin
            $display("[TB][FAIL] T-DIRTY-FLUSHIDLE setup occupancy=%0d != 1", rd_val[8:0]);
            errors = errors + 1;
        end
        ctrl_wr(32'h20);                 // the late/bare flush, while idle
        repeat (50) @(negedge clk);
        axil_rd(R_DSTAT, rd_val);
        $display("[TB] T-DIRTY-FLUSHIDLE after a bare idle flush: occupancy=%0d (expect 1: armed, not applied)", rd_val[8:0]);
        if (rd_val[8:0] !== 9'd1) begin
            $display("[TB][FAIL] T-DIRTY-FLUSHIDLE a bare idle flush dropped a pushed record");
            errors = errors + 1;
        end
        ctrl_wr(32'h1);                  // the next full-mark START applies it
        guard = 0; rd_val = 32'hFFFFFFFF;
        while (rd_val[31] && guard < 2000) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        guard = 0; rd_val = 32'h0;
        while (!rd_val[31] && guard < 200000) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        axil_rd(R_DSTAT, rd_val);
        $display("[TB] T-DIRTY-FLUSHIDLE after a full-mark start: occupancy=%0d (expect 0)", rd_val[8:0]);
        if (rd_val[8:0] !== 9'd0) begin
            $display("[TB][FAIL] T-DIRTY-FLUSHIDLE the armed flush was not applied at the full-mark start");
            errors = errors + 1;
        end
        push_dirty(12'd8);
        ctrl_wr(32'h20);                 // arm again
        repeat (20) @(negedge clk);
        ctrl_wr(32'h11);                 // INCREMENTAL start: must NOT flush
        guard = 0; rd_val = 32'hFFFFFFFF;
        while (rd_val[31] && guard < 2000) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        guard = 0; rd_val = 32'h0;
        while (!rd_val[31] && guard < 200000) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        axil_rd(R_DDRAIN, rd_val);
        $display("[TB] T-DIRTY-FLUSHIDLE after an incremental start: drained=%0d (expect 1: the record was processed, not flushed)", rd_val);
        if (rd_val !== 32'd1) begin
            $display("[TB][FAIL] T-DIRTY-FLUSHIDLE an incremental start must not apply an armed flush");
            errors = errors + 1;
        end

        // ---- T-DIRTY-QFULL: can a GENUINELY full BFS queue plus a pending barrier
        //      record deadlock the engine?  S_DIRTY_PUSH waits while q_full; the
        //      scanner only pops while pf_room; and only S_POP drains the prefetch
        //      ring - so once the ring fills, q_full can never clear.  T7 only
        //      *forces* q_full, so this combination was never exercised.
        //      Construction: 4096-object star (occupancy reaches 4095) + four dirty
        //      records pointing at an ALREADY MARKED id - the dirty path enqueues a
        //      forced re-scan unconditionally, which pushes occupancy to the depth.
        //      Observed: no hang (marked=4096).  Occupancy
        //      never reaches the queue depth at the current limits (a push needs an
        //      unmarked target, <= 4096 ids, and a pop precedes every enqueue burst),
        //      so the q_full wait is never entered.  Kept as a GUARD: if the queue
        //      depth or the object limit ever change so occupancy can hit the depth,
        //      this test hangs and the deadlock becomes real.
        //      See AGENTS #19 and tools/logs/xsim_qfull_dirty_20261023.log.
        // ----
        dirty_flush_now;
        repeat (50) @(negedge clk);
        begin : t_qfull_cfg
            integer i;
            reg [31:0] rbase;
            rbase = BASE + 32'h40000;
            for (i = 0; i < 4096; i = i + 1) begin
                mem[(i*16)/4 + 0] = i;
                mem[(i*16)/4 + 1] = (i == 0) ? 4095 : 0;
                mem[(i*16)/4 + 2] = (i == 0) ? rbase : 0;
            end
            for (i = 0; i < 4095; i = i + 1)
                mem[(rbase - BASE)/4 + i] = i + 1;
        end
        axil_wr(R_BASE,  BASE);
        axil_wr(R_COUNT, 32'd4096);
        axil_wr(R_ROOTS, 32'd1);
        axil_wr(R_RLIST, 32'd0);
        push_dirty(12'd1);
        push_dirty(12'd1);
        push_dirty(12'd1);
        push_dirty(12'd1);
        qf_mon = 1'b1; qf_danger = 0; qf_wait = 0; qf_maxcnt = 0;
        ctrl_wr(32'h1);                  // START
        guard = 0; rd_val = 32'h0;
        while (!rd_val[31] && guard < 600000) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        if (!rd_val[31]) begin
            $display("[TB][FAIL] T-DIRTY-QFULL DONE never asserted (q_full + dirty looks like a deadlock)");
            errors = errors + 1;
            ctrl_wr(32'h8);              // abort so the rest of the TB can run
            repeat (200) @(negedge clk);
        end else begin
            axil_rd(R_MARKED, rd_val);
            $display("[TB] T-DIRTY-QFULL done: marked=%0d (expect 4096)", rd_val);
            if (rd_val !== 32'd4096) begin
                $display("[TB][FAIL] T-DIRTY-QFULL marked=%0d != 4096", rd_val);
                errors = errors + 1;
            end
        end
        qf_mon = 1'b0;
        $display("[TB] T-DIRTY-QFULL observed: peak occupancy=%0d/4096  q_full&&dirty cycles=%0d  S_DIRTY_PUSH waits=%0d",
                 qf_maxcnt, qf_danger, qf_wait);
        if (qf_danger !== 0 || qf_wait !== 0) begin
            $display("[TB][FAIL] T-DIRTY-QFULL the deadlock precondition DID occur (q_full with a pending record)");
            errors = errors + 1;
        end
        if (qf_maxcnt >= 4096) begin
            $display("[TB][FAIL] T-DIRTY-QFULL occupancy reached the queue depth (%0d)", qf_maxcnt);
            errors = errors + 1;
        end
        dirty_flush_now;
        repeat (50) @(negedge clk);

        // ---- T-DIRTY-QFULLNEG: prove the S_DIRTY_PUSH wait is a REAL deadlock given
        //      the precondition, so that "unreachable" rests on the observation above
        //      rather than on the path being harmless.  Force the queue full with one
        //      pending record and no roots: the FSM must take the dirty branch, spin,
        //      and never assert DONE.  Then release + abort to let the TB continue. ----
        axil_wr(R_COUNT, 32'd64);
        axil_wr(R_ROOTS, 32'd0);
        push_dirty(12'd3);
        force dut.u_engine.q_full = 1'b1;
        ctrl_wr(32'h1);                  // START
        guard = 0; rd_val = 32'h0;
        while (!rd_val[31] && guard < 20000) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        $display("[TB] T-DIRTY-QFULLNEG q_full forced + 1 pending record: DONE=%b after %0d polls (expect 0 = it must hang)",
                 rd_val[31], guard);
        if (rd_val[31] === 1'b1) begin
            $display("[TB][FAIL] T-DIRTY-QFULLNEG the engine completed with the queue forced full - the wait is not a deadlock");
            errors = errors + 1;
        end else begin
            $display("[TB] T-DIRTY-QFULLNEG hung as predicted (the wait is a real deadlock)");
        end
        release dut.u_engine.q_full;
        ctrl_wr(32'h8);                  // abort out of the wait
        repeat (300) @(negedge clk);
        axil_rd(R_STATUS, rd_val);
        $display("[TB] T-DIRTY-QFULLNEG recovered: STATUS=%h (expect 0x10: idle, no errors)", rd_val);
        dirty_flush_now;
        repeat (50) @(negedge clk);

        // ---- T-DIRTY-TAG: this board's write path may deliver a store twice;
        //      the tag rule must make the duplicate a no-op (one record per
        //      logical push) while a changed tag is accepted. ----
        dirty_flush_now;
        repeat (50) @(negedge clk);
        axil_rd(R_DSTAT, rd_val);                // current hardware tag
        dpush_wr({16'h0, (rd_val[19:16] + 4'd1), 12'd7});
        dpush_wr({16'h0, (rd_val[19:16] + 4'd1), 12'd7});  // duplicate delivery
        axil_rd(R_DPUSHED, rd_val);
        $display("[TB] T-DIRTY-TAG duplicate delivery: pushed=%0d (expect 1)", rd_val);
        if (rd_val !== 32'd1) begin
            $display("[TB][FAIL] T-DIRTY-TAG duplicate write enqueued twice");
            errors = errors + 1;
        end
        axil_rd(R_DSTAT, rd_val);
        if (rd_val[8:0] !== 9'd1) begin
            $display("[TB][FAIL] T-DIRTY-TAG occupancy=%0d != 1", rd_val[8:0]);
            errors = errors + 1;
        end
        dpush_wr({16'h0, (rd_val[19:16] + 4'd1), 12'd7});  // changed tag -> accepted
        axil_rd(R_DPUSHED, rd_val);
        $display("[TB] T-DIRTY-TAG changed tag: pushed=%0d (expect 2)", rd_val);
        if (rd_val !== 32'd2) begin
            $display("[TB][FAIL] T-DIRTY-TAG a changed tag was not accepted");
            errors = errors + 1;
        end
        axil_rd(R_DSTAT, rd_val);
        dtag = rd_val[19:16] + 4'd3;             // keep the helper in sync with hw
        dirty_flush_now;
        repeat (50) @(negedge clk);
        $display("[TB] T-DIRTY-TAG tag rule OK");

        // ============================================================
        // T-DIRTY-RACE (Phase 3B): a barrier record that lands in the very
        //   cycle the engine decides to finish must SURVIVE in the FIFO and be
        //   consumed by the remark epoch (BM_KEEP, no flush).
        //   RACE2 is the negative control: flushing before the remark loses
        //   the record -- the target stays unmarked.
        // ============================================================
        $display("[TB] ===== T-DIRTY-RACE: record at the DONE cycle =====");
        begin : t_race_gen
            integer i;
            for (i = 0; i < 64; i = i + 1) begin
                mem[(i*16)/4 + 0] = i;
                mem[(i*16)/4 + 1] = 0;
                mem[(i*16)/4 + 2] = BASE + ref_base;
            end
            mem[(50*16)/4 + 1] = 32'd1;      // obj50 -> {51}
            mem[ref_base/4 + 0] = 32'd51;
            mem[ref_base/4 + 1] = 32'hFFFFFFFF;
        end
        axil_wr(R_BASE,  BASE);
        axil_wr(R_COUNT, 32'd64);
        axil_wr(R_ROOTS, 32'd0);
        begin : t_race_run
            integer rc2;
            for (rc2 = 0; rc2 < 2; rc2 = rc2 + 1) begin
                // epoch 1: dirty = {50} only; inject 60 exactly at the
                // terminal S_POP cycle (the record arrives "too late")
                dirty_flush_now;
                repeat (200) @(negedge clk);
                push_dirty(12'd50);
                ctrl_wr(32'h1);      // START (bm_keep = 0)
                guard = 0;
                race_injected = 1'b0;
                while (!race_injected && guard < 20000) begin
                    @(negedge clk);
                    if (dut.u_engine.state == 5'd7 && dut.u_engine.pf_cnt == 3'd0 &&
                        dut.u_engine.q_empty == 1'b1 && dut.u_engine.pf_iss == 3'd0 &&
                        dut.u_engine.dq_cnt == 4'd0 && dut.u_engine.sc_state == 3'd0 &&
                        dut.u_dirty.empty == 1'b1) begin
                        force dut.u_dirty.push    = 1'b1;
                        force dut.u_dirty.push_id = 12'd60;
                        @(negedge clk);
                        release dut.u_dirty.push;
                        release dut.u_dirty.push_id;
                        race_injected = 1'b1;
                    end
                    guard = guard + 1;
                end
                guard = 0; rd_val = 32'hFFFFFFFF;
                while (rd_val[31] && guard < 500) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
                guard = 0; rd_val = 32'h0;
                while (!rd_val[31] && guard < 20000) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
                guard = 0; axil_rd(R_STATUS, rd_val);
                while (((rd_val & 32'h20) != 0) && (guard < 20000)) begin guard = guard + 1; axil_rd(R_STATUS, rd_val); end
                axil_rd(R_DSTAT, rd_val);
                if (rc2 == 0) begin
                    $display("[TB] T-DIRTY-RACE epoch1: injected=%b occupancy=%0d (expect 1/1)",
                             race_injected, rd_val[8:0]);
                    if (!race_injected || rd_val[8:0] !== 9'd1) begin
                        $display("[TB][FAIL] T-DIRTY-RACE: late record not kept in the FIFO");
                        errors = errors + 1;
                    end
                    axil_rd(R_MARKED, rd_val);
                    if (rd_val !== 32'd2) begin   // 50 + 51
                        $display("[TB][FAIL] T-DIRTY-RACE epoch1 marked=%0d != 2", rd_val);
                        errors = errors + 1;
                    end
                end
                // remark epoch: BM_KEEP; rc2=1 adds a bare "late" flush.  That write
                // only ARMS the flush; this incremental start must DISCARD it and the
                // deferred record survives.
                if (rc2 == 1) begin
                    ctrl_wr(32'h20);     // arm only
                    repeat (20) @(negedge clk);
                end
                ctrl_wr(32'h11);         // START | BM_KEEP
                guard = 0; rd_val = 32'hFFFFFFFF;
                while (rd_val[31] && guard < 500) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
                guard = 0; rd_val = 32'h0;
                while (!rd_val[31] && guard < 20000) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
                guard = 0; axil_rd(R_STATUS, rd_val);
                while (((rd_val & 32'h20) != 0) && (guard < 20000)) begin guard = guard + 1; axil_rd(R_STATUS, rd_val); end
                axil_rd(R_DDRAIN, rd_val);
                $display("[TB] T-DIRTY-RACE remark (rc2=%0d) drained=%0d (expect 1, the deferred record)", rc2, rd_val);
                if (rd_val !== 32'd1) begin
                    $display("[TB][FAIL] T-DIRTY-RACE remark did not consume the deferred record");
                    errors = errors + 1;
                end
                // cumulative bitmap
                begin : t_race_bm
                    integer i2, hb;
                    hb = 0;
                    axil_wr(R_BMADDR, 32'd60);
                    axil_rd(R_BMDATA, rd_val);
                    hb = (rd_val >> (60 & 31)) & 1;
                    $display("[TB] T-DIRTY-RACE remark (rc2=%0d) obj60 marked=%0d (expect 1: arm-and-consume keeps it)", rc2, hb);
                    if (hb !== 1'b1) begin
                        $display("[TB][FAIL] T-DIRTY-RACE deferred record lost (obj60 unmarked)");
                        errors = errors + 1;
                    end
                end
                // leave a clean bitmap for the next block
                dirty_flush_now;
                repeat (20) @(negedge clk);
            end
        end

        // ============================================================
        // ---- T-ID / T-ABORT: MAGIC+VERSION, and abort must leave a reusable engine ----
        axil_rd(12'h030, rd_val);
        $display("[TB] T-ID magic=%h (expect 47434343)", rd_val);
        if (rd_val !== 32'h47434343) begin $display("[TB][FAIL] T-ID magic=%h", rd_val); errors = errors + 1; end
        axil_rd(12'h034, rd_val);
        $display("[TB] T-ID version=%h (expect 00040300)", rd_val);
        if (rd_val !== 32'h0004_0301) begin $display("[TB][FAIL] T-ID version=%h", rd_val); errors = errors + 1; end

        // ---- T-ABORT: abort must pull a hung engine back to IDLE and stay reusable ----
        // Star graph: object 0 points at 1..31; each of 1..31 has exactly one ref.
        // The refs matter: a stale queue entry with rc>0 is popped but never issued,
        // which is the desync this test needs (consume-with-nothing-issued).
        // A chain would keep the queue at depth 0..1 and leave nothing to inherit.
        begin : t_ab_gen
            integer i, w;
            for (i = 0; i < 32; i = i + 1) begin
                mem[(i*16)/4 + 0] = i;
                mem[(i*16)/4 + 1] = (i == 0) ? 31 : 1;
                mem[(i*16)/4 + 2] = (i == 0) ? (BASE + ref_base)
                                             : (BASE + ref_base + (32 + (i-1)*2)*4);
            end
            for (i = 0; i < 31; i = i + 1)
                mem[ref_base/4 + i] = i + 1;
            mem[ref_base/4 + 31] = 32'hFFFFFFFF;
            for (i = 1; i < 32; i = i + 1) begin
                w = ref_base/4 + 32 + (i-1)*2;
                mem[w]     = (i < 31) ? (i + 1) : 1;
                mem[w + 1] = 32'hFFFFFFFF;
            end
        end
        axil_wr(R_BASE,  BASE);
        axil_wr(R_COUNT, 32'd32);
        axil_wr(R_ROOTS, 32'd1);
        axil_wr(R_RLIST, 32'd0);
        ctrl_wr(32'h6);
        repeat (200) @(negedge clk);
        ctrl_wr(32'h1);                   // START
        // Wait for real marking activity: the bitmap clear alone takes 4096 cycles,
        // so aborting at 200 cycles leaves the queue empty and masks the failure.
        guard = 0;
        while ((dut.u_queue.count < 8) && guard < 20000) begin
            @(negedge clk); guard = guard + 1;
        end
        $display("[TB] T-ABORT queue fill = %0d when the stall is applied", dut.u_queue.count);
        force dut.u_engine.q_pop_ack = 1'b0;      // hang the prefetcher, like T-HANG
        repeat (200) @(negedge clk);
        $display("[TB] T-ABORT state while hung = %0d", dut.u_engine.state);
        ctrl_wr(32'h8);                   // CTRL[3] = abort
        repeat (10) @(negedge clk);
        $display("[TB] T-ABORT state after abort = %0d (expect 0 = S_IDLE)", dut.u_engine.state);
        if (dut.u_engine.state !== 5'd0) begin
            $display("[TB][FAIL] T-ABORT engine still in state %0d after abort", dut.u_engine.state);
            errors = errors + 1;
        end
        // An abort must not manufacture status bits out of the abandoned run's
        // in-flight reads (board: abort_sweep.py saw STATUS[1]/STATUS[3] here).
        axil_rd(R_STATUS, rd_val);
        $display("[TB] T-ABORT status right after abort = %h (expect 0x10: idle, no errors)", rd_val);
        if ((rd_val & 32'h1F) !== 32'h10) begin
            $display("[TB][FAIL] T-ABORT status=%h after abort (expect idle + no errors)", rd_val);
            errors = errors + 1;
        end
        release dut.u_engine.q_pop_ack;
        // New graph with the SAME object count (32) but a different expectation:
        // root 0 has no refs, so exactly 1 object must be marked. The stale queue
        // entries each still carry one ref, and with COUNT=32 those refs pass the
        // `ref_val >= obj_count` filter -- so inheriting them shows up as a wrong
        // count. (A smaller COUNT would filter them and mask the failure.)
        begin : t_ab_b
            integer i;
            mem[(0*16)/4 + 0] = 0;
            mem[(0*16)/4 + 1] = 0;                        // root: no refs
            mem[(0*16)/4 + 2] = BASE + ref_base;
            for (i = 1; i < 32; i = i + 1) begin
                mem[(i*16)/4 + 0] = i;
                mem[(i*16)/4 + 1] = 1;                    // stale objects keep one ref
                mem[(i*16)/4 + 2] = BASE + ref_base + (32 + (i-1)*2)*4;
            end
        end
        axil_wr(R_BASE,  BASE);
        axil_wr(R_COUNT, 32'd32);
        axil_wr(R_ROOTS, 32'd1);
        axil_wr(R_RLIST, 32'd0);

        // ---- T-ABORT2: START alone (no CLEAR_Q) must not inherit the aborted run ----
        // The driver writes only CTRL[0]; CLEAR_Q is a separate register. abort
        // therefore has to flush the work queue and the prefetch/issue pipeline.
        $display("[TB] T-ABORT2 queue count before START = %0d (expect the aborted run's leftovers)",
                 dut.u_queue.count);
        ctrl_wr(32'h1);                   // START, deliberately no CLEAR_Q
        guard = 0; rd_val = 32'h0;
        while (!rd_val[31] && guard < 20000) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        axil_rd(R_MARKED, rd_val);
        $display("[TB] T-ABORT2 marked=%0d after abort+START without CLEAR_Q (expect 1)", rd_val);
        if (rd_val !== 32'd1) begin
            $display("[TB][FAIL] T-ABORT2 marked=%0d != 1 (stale queue/pipeline survives abort)", rd_val);
            errors = errors + 1;
        end
        $display("[TB] T-ABORT2 internals: qcount=%0d pf_cnt=%0d dq_cnt=%0d iss=%0d con=%0d marked_r=%0d err_ref=%b",
                 dut.u_queue.count, dut.u_engine.pf_cnt, dut.u_engine.dq_cnt,
                 dut.u_engine.iss_cnt, dut.u_engine.con_cnt, dut.u_engine.marked_r,
                 dut.u_engine.err_ref);
        axil_rd(R_STATUS, rd_val);
        $display("[TB] T-ABORT2 status=%h (expect 0x10: idle, no errors)", rd_val);
        if ((rd_val & 32'h1F) !== 32'h10) begin
            $display("[TB][FAIL] T-ABORT2 status=%h (aborted run leaked into the next run)", rd_val);
            errors = errors + 1;
        end

        // ---- and the documented path: CLEAR_Q + START on a 3-object chain ----
        begin : t_ab_c
            integer i;
            for (i = 0; i < 3; i = i + 1) begin
                mem[(i*16)/4 + 0] = i;
                mem[(i*16)/4 + 1] = 1;
                mem[(i*16)/4 + 2] = BASE + ref_base + i*8;
                mem[(ref_base + i*8)/4 + 0] = (i < 2) ? (i + 1) : 32'hFFFFFFFF;
                mem[(ref_base + i*8)/4 + 1] = 32'hFFFFFFFF;
            end
        end
        axil_wr(R_BASE,  BASE);
        axil_wr(R_COUNT, 32'd3);
        axil_wr(R_ROOTS, 32'd1);
        axil_wr(R_RLIST, 32'd0);
        ctrl_wr(32'h6);
        repeat (200) @(negedge clk);
        ctrl_wr(32'h1);
        guard = 0; rd_val = 32'h0;
        while (!rd_val[31] && guard < 20000) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        axil_rd(R_MARKED, rd_val);
        $display("[TB] T-ABORT marked=%0d after abort+restart (expect 3)", rd_val);
        if (rd_val !== 32'd3) begin
            $display("[TB][FAIL] T-ABORT marked=%0d != 3 (not reusable after abort)", rd_val);
            errors = errors + 1;
        end
// ---- T-REG: an unmapped register read must answer SLVERR ----
        // 0x02C is still unmapped after Phase 2 (0x038/0x03C are FREE_COUNT/FREE_DATA).
        rresp_seen = 1'b0;
        axil_rd(12'h02C, rd_val);
        $display("[TB] T-REG unmapped read(0x02C): rresp_seen=%b (expect 1)", rresp_seen);
        if (!rresp_seen) begin
            $display("[TB][FAIL] T-REG unmapped read returned OKAY (should be SLVERR)");
            errors = errors + 1;
        end

        // ---- T-HANG: CLEAR_Q while the prefetcher waits for a pop ack ----
        // 64-object chain. Mid-run the test clears the queue (CTRL[2]) and holds
        // q_pop_ack low, which is what CLEAR_Q does to gc_queue: it drops rvalid,
        // so the ack the prefetcher waits for never arrives. Without a timeout in
        // SC_POP the prefetcher never returns to IDLE, the main FSM never sees the
        // queue empty, and DONE never asserts (only a bitstream reload recovered).
        begin : t_hang
            integer i;
            for (i = 0; i < 64; i = i + 1) begin
                mem[(i*16)/4 + 0] = i;
                mem[(i*16)/4 + 1] = (i < 63) ? 1 : 0;
                mem[(i*16)/4 + 2] = BASE + ref_base + i*8;
            end
            for (i = 0; i < 64; i = i + 1) begin
                mem[(ref_base + i*8)/4 + 0] = (i < 63) ? (i + 1) : 32'hFFFFFFFF;
                mem[(ref_base + i*8)/4 + 1] = 32'hFFFFFFFF;
            end
        end
        axil_wr(R_BASE,  BASE);
        axil_wr(R_COUNT, 32'd64);
        axil_wr(R_ROOTS, 32'd1);
        axil_wr(R_RLIST, 32'd0);
        ctrl_wr(32'h6);
        repeat (200) @(negedge clk);
        force dut.u_engine.q_pop_ack = 1'b0;
        ctrl_wr(32'h1);
        repeat (300) @(negedge clk);
        ctrl_wr(32'h4);                 // CLEAR_Q
        guard = 0; rd_val = 32'h0;
        while (!rd_val[31] && guard < 20000) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        release dut.u_engine.q_pop_ack;
        $display("[TB] T-HANG done=%b after CLEAR_Q mid-pop (expect 1)", rd_val[31]);
        if (!rd_val[31]) begin
            $display("[TB][FAIL] T-HANG DONE never asserted: prefetcher stuck in SC_POP");
            errors = errors + 1;
        end

        // T7: queue overflow must be reported (STATUS[0]), not silent
        //   Force q_full while starting: the root cannot be enqueued, so
        //   marked stays 0 and err_ovf must latch.
        // ============================================================
        $display("[TB] ===== T7: queue overflow -> STATUS[0] =====");
        mem[(0*16)/4 + 1] = 32'd0;                 // obj0 has no refs
        axil_wr(R_BASE,  BASE);
        axil_wr(R_COUNT, 32'd1);
        axil_wr(R_ROOTS, 32'd1);
        axil_wr(R_RLIST, 32'd0);
        ctrl_wr(32'h6);
        repeat (200) @(negedge clk);
        force dut.u_engine.q_full = 1'b1;
        ctrl_wr(32'h1);
        guard = 0; rd_val = 32'hFFFFFFFF;
        while (rd_val[31] && guard < 500) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        guard = 0; rd_val = 32'h0;
        while (!rd_val[31] && guard < 20000) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        release dut.u_engine.q_full;
        if (!rd_val[31]) begin
            $display("[TB][FAIL] T7 DONE never asserted (engine hung with q_full)");
            errors = errors + 1;
        end
        axil_rd(R_STATUS, rd_val);
        $display("[TB] T7 STATUS=%h (expect bit0=1)", rd_val);
        if (rd_val[0] !== 1'b1) begin
            $display("[TB][FAIL] T7 STATUS[0]=%b, queue full but not reported", rd_val[0]);
            errors = errors + 1;
        end
        axil_rd(R_MARKED, rd_val);
        if (rd_val !== 32'd0) begin
            $display("[TB][FAIL] T7 marked=%0d, expected 0 when the root is refused", rd_val);
            errors = errors + 1;
        end

        // ---- T7b: overflow must not leave a stray bitmap bit ----
        // T7 forced q_full, so nothing was enqueued; the bitmap must agree.
        i = 0;
        axil_rd(R_STATUS, rd_val);
        while (((rd_val & 32'h20) != 0) && (i < 20000)) begin
            i = i + 1;
            axil_rd(R_STATUS, rd_val);
        end
        axil_wr(R_BMADDR, 32'h0);
        repeat (4) @(negedge clk);
        axil_rd(R_BMDATA, rd_val);
        $display("[TB] T7b bitmap[0]=%h (expect 0: nothing was enqueued)", rd_val);
        if (rd_val !== 32'h0) begin
            $display("[TB][FAIL] T7b bitmap[0]=%h after overflow (bit set without a queue entry)", rd_val);
            errors = errors + 1;
        end
        // ============================================================
        // T8: AXI read error must be reported (STATUS[1]) and must not hang
        //   inject_err makes the slave answer SLVERR; the read master turns
        //   the beat into 0xFFFFFFFF (list terminator) and sets err.
        // ============================================================
        $display("[TB] ===== T8: AXI RRESP error -> STATUS[1] =====");
        mem[(0*16)/4 + 1] = 32'd1;
        mem[(0*16)/4 + 2] = BASE + ref_base;
        mem[ref_base/4 + 0] = 32'd1;
        mem[ref_base/4 + 1] = 32'hFFFFFFFF;
        mem[(1*16)/4 + 1] = 32'd0;
        axil_wr(R_BASE,  BASE);
        axil_wr(R_COUNT, 32'd2);
        axil_wr(R_ROOTS, 32'd1);
        axil_wr(R_RLIST, 32'd0);
        ctrl_wr(32'h6);
        repeat (200) @(negedge clk);
        inject_err = 1'b1;
        ctrl_wr(32'h1);
        guard = 0; rd_val = 32'hFFFFFFFF;
        while (rd_val[31] && guard < 500) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        guard = 0; rd_val = 32'h0;
        while (!rd_val[31] && guard < 20000) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        inject_err = 1'b0;
        if (!rd_val[31]) begin
            $display("[TB][FAIL] T8 DONE never asserted (engine hung on AXI error)");
            errors = errors + 1;
        end
        axil_rd(R_STATUS, rd_val);
        $display("[TB] T8 STATUS=%h (expect bit1=1)", rd_val);
        if (rd_val[1] !== 1'b1) begin
            $display("[TB][FAIL] T8 STATUS[1]=%b, AXI error not reported", rd_val[1]);
            errors = errors + 1;
        end
        // ---- T8b: a clean start must clear the latched read-error bit ----
        // STATUS[1] is cleared on every start (not sticky until reset).
        ctrl_wr(32'h1);
        repeat (300) @(negedge clk);
        axil_rd(R_STATUS, rd_val);
        $display("[TB] T8b STATUS=%h (expect bit1=0)", rd_val);
        if (rd_val[1] !== 1'b0) begin
            $display("[TB][FAIL] T8b STATUS[1]=%b still set after a clean start", rd_val[1]);
            errors = errors + 1;
        end

        // ---- T-MAXFAN: one object with ref_count = 4095 ----
        // The reference and header data FIFOs share the R channel. Push the ref
        // FIFO to its limit with one huge reference list and check that the
        // header stream still drains (no head-of-line deadlock) and that the
        // engine still finishes with the exact mark count.
        begin : t_maxfan
            integer i;
            for (i = 0; i < 300; i = i + 1) begin
                mem[(i*16)/4 + 0] = i;
                mem[(i*16)/4 + 1] = (i == 0) ? 4095 : 0;
                mem[(i*16)/4 + 2] = BASE + 32'h8000;
            end
            for (i = 0; i < 4095; i = i + 1)
                mem[32'h8000/4 + i] = (i % 299) + 1;
            mem[32'h8000/4 + 4095] = 32'hFFFFFFFF;
        end
        axil_wr(R_BASE,  BASE);
        axil_wr(R_COUNT, 32'd300);
        axil_wr(R_ROOTS, 32'd1);
        axil_wr(R_RLIST, 32'd0);
        ctrl_wr(32'h6);
        repeat (200) @(negedge clk);
        ctrl_wr(32'h1);
        guard = 0; rd_val = 32'h0;
        while (!rd_val[31] && guard < 200000) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        if (!rd_val[31]) begin
            $display("[TB][FAIL] T-MAXFAN DONE never asserted (head-of-line deadlock?)");
            errors = errors + 1;
        end
        axil_rd(R_MARKED, rd_val);
        $display("[TB] T-MAXFAN marked=%0d (expect 300, ref_count=4095)", rd_val);
        if (rd_val !== 32'd300) begin
            $display("[TB][FAIL] T-MAXFAN marked=%0d != 300", rd_val);
            errors = errors + 1;
        end
        axil_rd(R_STATUS, rd_val);
        $display("[TB] T-MAXFAN STATUS=%h (expect 0x10: idle, no errors)", rd_val);
        if ((rd_val & 32'h1F) !== 32'h10) begin
            $display("[TB][FAIL] T-MAXFAN STATUS=%h", rd_val);
            errors = errors + 1;
        end

        // ---- T-ROOTCLAMP: root_count > 256 must not wrap around ----
        // Without the clamp the engine re-reads root[0..255] about 16M times and
        // the run never finishes; the guard below turns that into a failure.
        begin : t_clamp
            integer i;
            for (i = 0; i < 300; i = i + 1) begin
                mem[(i*16)/4 + 0] = i;
                mem[(i*16)/4 + 1] = 0;
                mem[(i*16)/4 + 2] = BASE + 32'h8000;
            end
        end
        for (i = 0; i < 256; i = i + 1)
            axil_wr(R_RLIST + (i * 4), i[11:0]);
        axil_wr(R_BASE,  BASE);
        axil_wr(R_COUNT, 32'd300);
        axil_wr(R_ROOTS, 32'hFFFFFFFF);
        ctrl_wr(32'h6);
        repeat (200) @(negedge clk);
        ctrl_wr(32'h1);
        guard = 0; rd_val = 32'h0;
        while (!rd_val[31] && guard < 200000) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        if (!rd_val[31]) begin
            $display("[TB][FAIL] T-ROOTCLAMP DONE never asserted (root_count not clamped)");
            errors = errors + 1;
        end
        axil_rd(R_MARKED, rd_val);
        $display("[TB] T-ROOTCLAMP marked=%0d (expect 256, root_count=0xFFFFFFFF)", rd_val);
        if (rd_val !== 32'd256) begin
            $display("[TB][FAIL] T-ROOTCLAMP marked=%0d != 256", rd_val);
            errors = errors + 1;
        end

        // ---- T-STAR: root 0 -> 1..4095, 4096 objects, one ref each ----
        // Full object range and full-depth queue; q_tail wraps to 0.
        begin : t_star
            integer i;
            reg [31:0] rbase;
            rbase = BASE + 32'h40000;          // after 4096 * 16 bytes of headers
            for (i = 0; i < 4096; i = i + 1) begin
                mem[(i*16)/4 + 0] = i;
                mem[(i*16)/4 + 1] = (i == 0) ? 4095 : 0;
                mem[(i*16)/4 + 2] = (i == 0) ? rbase : 0;
            end
            for (i = 0; i < 4095; i = i + 1)
                mem[(rbase - BASE)/4 + i] = i + 1;
        end
        axil_wr(R_BASE,  BASE);
        axil_wr(R_COUNT, 32'd4096);
        axil_wr(R_ROOTS, 32'd1);
        axil_wr(R_RLIST, 32'd0);
        ctrl_wr(32'h6);
        repeat (200) @(negedge clk);
        ctrl_wr(32'h1);
        guard = 0; rd_val = 32'h0;
        while (!rd_val[31] && guard < 2000000) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        if (!rd_val[31]) begin
            $display("[TB][FAIL] T-STAR DONE never asserted");
            errors = errors + 1;
        end
        axil_rd(R_MARKED, rd_val);
        $display("[TB] T-STAR marked=%0d (expect 4096)", rd_val);
        if (rd_val !== 32'd4096) begin
            $display("[TB][FAIL] T-STAR marked=%0d != 4096", rd_val);
            errors = errors + 1;
        end
        axil_rd(R_QTAIL, rd_val);
        $display("[TB] T-STAR q_tail=%0d (expect 0: 4096 pushes wrap the 12-bit pointer)", rd_val);
        if (rd_val !== 32'd0) begin
            $display("[TB][FAIL] T-STAR q_tail=%0d (4096 & 0xFFF = 0)", rd_val);
            errors = errors + 1;
        end
        axil_rd(R_STATUS, rd_val);
        $display("[TB] T-STAR STATUS=%h (expect bit4=1, errors=0)", rd_val);
        if ((rd_val & 32'h1F) !== 32'h10) begin
            $display("[TB][FAIL] T-STAR STATUS=%h (expect 0x10: idle, no errors)", rd_val);
            errors = errors + 1;
        end

        // ---- T-CTRL-SPILL: a spilled CLEAR_Q must not truncate a running epoch ----
        // This platform redelivers stores and the copies are not always adjacent, so
        // the driver's `CTRL = CLEAR_Q` can arrive again while the engine is mid-run.
        // Clearing the BFS queue then loses work: the run would finish with fewer
        // marks than the oracle.  Only a clear the engine can still act on (one seen
        // while it is idle) may be honoured.
        begin : t_spill
            integer i;
            // a 200-long chain: object i is discovered only by reading i-1 from the
            // BFS queue, so clearing that queue mid-run strands the rest of the chain
            for (i = 0; i < 200; i = i + 1) begin
                mem[(i*16)/4 + 0] = i;
                mem[(i*16)/4 + 1] = (i < 199) ? 1 : 0;
                mem[(i*16)/4 + 2] = BASE + 32'h9000 + (i * 4);
            end
            for (i = 0; i < 199; i = i + 1)
                mem[32'h9000/4 + i] = i + 1;
        end
        axil_wr(R_BASE,  BASE);
        axil_wr(R_COUNT, 32'd200);
        axil_wr(R_ROOTS, 32'd1);
        axil_wr(R_RLIST, 32'd0);
        ctrl_wr(32'h6);
        repeat (200) @(negedge clk);
        ctrl_wr(32'h1);
        // wait until the fan-out has actually queued work, then spill a CLEAR_Q
        guard = 0;
        begin : t_spill_wait
            reg [31:0] qh, qt;
            qh = 32'd0; qt = 32'd0;
            while ((qh == qt) && (guard < 20000)) begin
                axil_rd(R_QHEAD, qh);
                axil_rd(R_QTAIL, qt);
                guard = guard + 1;
            end
        end
        ctrl_wr(32'h4);
        guard = 0; rd_val = 32'h0;
        while (!rd_val[31] && guard < 200000) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        if (!rd_val[31]) begin
            $display("[TB][FAIL] T-CTRL-SPILL DONE never asserted");
            errors = errors + 1;
        end
        axil_rd(R_MARKED, rd_val);
        $display("[TB] T-CTRL-SPILL marked=%0d (expect 200: a mid-run CLEAR_Q must be ignored)", rd_val);
        if (rd_val !== 32'd200) begin
            $display("[TB][FAIL] T-CTRL-SPILL marked=%0d != 200 (the spilled clear truncated the run)", rd_val);
            errors = errors + 1;
        end
        axil_rd(R_STATUS, rd_val);
        if ((rd_val & 32'h1F) !== 32'h10) begin
            $display("[TB][FAIL] T-CTRL-SPILL STATUS=%h (expect 0x10)", rd_val);
            errors = errors + 1;
        end
        axil_rd(R_QTAIL, rd_val);
        $display("[TB] T-CTRL-SPILL q_tail=%0d (expect 200 == marked)", rd_val);
        if (rd_val !== 32'd200) begin
            $display("[TB][FAIL] T-CTRL-SPILL q_tail=%0d != 200 (the spilled clear reset the queue)", rd_val);
            errors = errors + 1;
        end

        // ---- T-CTRL-RESTART: a spilled START keeps q_tail == marked ----
        // The engine clears the object queue itself when it accepts a START, so a
        // second START with no intervening CLEAR_Q re-runs the same graph and still
        // leaves q_tail == marked; without that the tail accumulates (the C API's
        // q_tail invariant would fail).
        axil_rd(R_QTAIL, rd_val);
        $display("[TB] T-CTRL-RESTART first run q_tail=%0d (expect 200)", rd_val);
        if (rd_val !== 32'd200) begin
            $display("[TB][FAIL] T-CTRL-RESTART first run q_tail=%0d != 200", rd_val);
            errors = errors + 1;
        end
        ctrl_wr(32'h1);                        // spilled START, no CLEAR_Q
        guard = 0; rd_val = 32'h0;
        while (!rd_val[31] && guard < 200000) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        axil_rd(R_MARKED, rd_val);
        $display("[TB] T-CTRL-RESTART re-run marked=%0d (expect 200)", rd_val);
        if (rd_val !== 32'd200) begin
            $display("[TB][FAIL] T-CTRL-RESTART re-run marked=%0d != 200", rd_val);
            errors = errors + 1;
        end
        axil_rd(R_QTAIL, rd_val);
        $display("[TB] T-CTRL-RESTART re-run q_tail=%0d (expect 200 == marked, not 400)", rd_val);
        if (rd_val !== 32'd200) begin
            $display("[TB][FAIL] T-CTRL-RESTART re-run q_tail=%0d != 200", rd_val);
            errors = errors + 1;
        end

        // ---- #6 汇总 ----
        if (err_ho != 0) begin
            $display("[TB][FAIL] #6 outstanding-read violations: %0d", err_ho);
            errors = errors + 1;
        end else begin
            $display("[TB] #6 outstanding reads never exceeded 8 OK");
        end

        // ---- AXI 协议检查 (#1) ----
        if (axi_errs !== 32'd0) begin
            $display("[TB][FAIL] AXI protocol violations: %0d (ARSIZE/ARLEN/ARBURST/align/VALID)", axi_errs);
            errors = errors + 1;
        end else begin
            $display("[TB] AXI protocol check OK (ARSIZE=3, ARLEN=0, ARBURST=INCR, 8B align, VALID stable)");
        end

        // ---- 结论 ----
        if (errors == 0)
            $display("\n[TB] ==================== PASS ====================");
        else
            $display("\n[TB] ==================== FAIL (%0d errors) ====================", errors);

        $finish;
    end

    // #6 监视: 两条流合计的未完成读事务数, 任何时刻都不得超过 8 (= 声明值 MAXO)
    always @(posedge clk) begin
        if ((dut.u_axi_rd.h0cnt + dut.u_axi_rd.h1cnt) > 8)
            err_ho = err_ho + 1;
    end

    // ================= 环形轨迹缓冲 (超时时倒出来看) =================
    localparam TR_N = 160;
    reg [4:0]  tr_st  [0:TR_N-1];
    reg [11:0] tr_cur [0:TR_N-1];
    reg [31:0] tr_rc  [0:TR_N-1];
    reg [31:0] tr_rpi [0:TR_N-1];
    reg [31:0] tr_rgot[0:TR_N-1];
    reg [5:0]  tr_cw  [0:TR_N-1];
    reg [5:0]  tr_cr  [0:TR_N-1];
    reg [5:0]  tr_dw  [0:TR_N-1];
    reg [5:0]  tr_dr  [0:TR_N-1];
    reg [5:0]  tr_hw  [0:TR_N-1];
    reg [5:0]  tr_hr  [0:TR_N-1];
    reg [4:0]  tr_fl  [0:TR_N-1];
    reg [31:0] tr_ara [0:TR_N-1];
    integer    trp = 0;

    always @(posedge clk) begin
        tr_st  [trp] <= dut.u_engine.state;
        tr_cur [trp] <= dut.u_engine.cur_obj;
        tr_rc  [trp] <= dut.u_engine.ref_count;
        tr_rpi [trp] <= dut.u_engine.ref_push_idx;
        tr_rgot[trp] <= dut.u_engine.ref_got;
        tr_cw  [trp] <= dut.u_axi_rd.c0w;
        tr_cr  [trp] <= dut.u_axi_rd.c0r;
        tr_dw  [trp] <= dut.u_axi_rd.d0w;
        tr_dr  [trp] <= dut.u_axi_rd.d0r;
        tr_hw  [trp] <= dut.u_axi_rd.h0w;
        tr_hr  [trp] <= dut.u_axi_rd.h0r;
        tr_fl  [trp] <= {dut.u_engine.rd_cmd_valid, dut.u_engine.rd_cmd_ready,
                         dut.u_axi_rd.data0_valid,   dut.u_engine.rd_data_ready,
                         hp_rvalid};
        tr_ara [trp] <= dut.u_axi_rd.ARADDR;
        trp = trp + 1;
        if (trp >= TR_N) trp = 0;
    end

    // 状态监视 (每 20000 拍打印一次, 最多 12 次)
    integer mon_cnt = 0;
    initial begin
        forever begin
            repeat (20000) @(negedge clk);
            if (mon_cnt < 12) begin
                $display("[MON] t=%0t st=%0d cur=%0d qh=%0d qt=%0d ARV=%0d ARA=%h cw=%0d cr=%0d dw=%0d dr=%0d hw=%0d hr=%0d drdy=%0d dval=%0d",
                    $time, dut.u_engine.state, dut.u_engine.cur_obj,
                    dut.u_queue.head, dut.u_queue.tail,
                    dut.u_axi_rd.ARVALID, dut.u_axi_rd.ARADDR,
                    dut.u_axi_rd.c0w, dut.u_axi_rd.c0r,
                    dut.u_axi_rd.d0w, dut.u_axi_rd.d0r,
                    dut.u_axi_rd.h0w, dut.u_axi_rd.h0r,
                    dut.u_engine.rd_data_ready, dut.u_engine.rd_data_valid);
                mon_cnt = mon_cnt + 1;
            end
        end
    end

    // 倒出环形轨迹
    task dump_ring;
        begin
            $display("      --- cycle %0d (readable) ---", TR_N);
            for (k = 0; k < TR_N; k = k + 1) begin
                j = trp + k;
                if (j >= TR_N) j = j - TR_N;
                $display("      [%0d] st=%0d cur=%0d rc=%0d rpi=%0d rgot=%0d cw=%0d cr=%0d dw=%0d dr=%0d hw=%0d hr=%0d cv/rdy/dv/dy/rv=%b ARA=%h",
                         k, tr_st[j], tr_cur[j], tr_rc[j], tr_rpi[j], tr_rgot[j],
                         tr_cw[j], tr_cr[j], tr_dw[j], tr_dr[j], tr_hw[j], tr_hr[j],
                         tr_fl[j], tr_ara[j]);
            end
        end
    endtask

    // ================= 事件日志 (定位 X / 握手问题) =================
    integer evc = 0;
    always @(posedge clk) begin
        if (evc < 200) begin
            if (dut.u_axi_rd.ARVALID && hp_arready) begin
                $display("[EV%0d] AR addr=%h hi=%0d hw=%0d hr=%0d",
                         evc, dut.u_axi_rd.ARADDR, dut.u_axi_rd.ar_hi,
                         dut.u_axi_rd.h0w, dut.u_axi_rd.h0r);
                evc = evc + 1;
            end
            if (hp_rvalid && hp_rready) begin
                $display("[EV%0d] R  data=%h hfifo[%0d]=%b dw=%0d dr=%0d",
                         evc, hp_rdata, dut.u_axi_rd.h0r,
                         dut.u_axi_rd.h0f[dut.u_axi_rd.h0r],
                         dut.u_axi_rd.d0w, dut.u_axi_rd.d0r);
                evc = evc + 1;
            end
            if (dut.u_engine.state == 5'd12 && dut.u_engine.rd_data_valid) begin
                $display("[EV%0d] G1 data=%h dr=%0d dw=%0d",
                         evc, dut.u_engine.rd_data, dut.u_axi_rd.d0r, dut.u_axi_rd.d0w);
                evc = evc + 1;
            end
            if (dut.u_engine.state == 5'd13 && dut.u_engine.rd_data_valid) begin
                $display("[EV%0d] G2 data=%h dr=%0d dw=%0d",
                         evc, dut.u_engine.rd_data, dut.u_axi_rd.d0r, dut.u_axi_rd.d0w);
                evc = evc + 1;
            end
            if (dut.u_engine.state == 5'd16 && dut.u_engine.rd_data_valid) begin
                $display("[EV%0d] GET data=%h obj=%0d dr=%0d dw=%0d",
                         evc, dut.u_engine.rd_data, dut.u_engine.cur_obj,
                         dut.u_axi_rd.d0r, dut.u_axi_rd.d0w);
                evc = evc + 1;
            end
        end
    end

    // 卡死检测: 在 S_REFS_PUSHW 连续 >40 拍 → 立即倒轨迹并结束
    integer pushw_run = 0;
    reg     dumped = 1'b0;
    always @(posedge clk) begin
        if (dut.u_engine.state == 5'd14) pushw_run = pushw_run + 1;   // S_REFS_LOOP (reachable)
        else pushw_run = 0;
        if (pushw_run > 2000 && !dumped) begin
            dumped = 1'b1;
            $display("[TB][FAIL] stuck: S_REFS_LOOP held for %0d cycles", pushw_run);
            $display("      engine cur=%0d rc=%0d rpi=%0d got=%0d cmd_valid=%0d cmd_ready=%0d",
                     dut.u_engine.cur_obj, dut.u_engine.ref_count,
                     dut.u_engine.ref_push_idx, dut.u_engine.ref_got,
                     dut.u_engine.rd_cmd_valid, dut.u_engine.rd_cmd_ready);
            dump_ring;
            $finish;
        end
    end

    // 看门狗
    initial begin
        #5_000_000;
        $display("[TB][FAIL] global timeout");
        $display("      engine state=%0d cur_obj=%0d qh=%0d qt=%0d",
                 dut.u_engine.state, dut.u_engine.cur_obj,
                 dut.u_queue.head, dut.u_queue.tail);
        dump_ring;
        $finish;
    end

endmodule
