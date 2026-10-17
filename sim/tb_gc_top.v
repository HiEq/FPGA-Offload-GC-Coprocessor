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
//   - DONE 置位, 队列排空后 q_tail == 期望活跃对象数
//   - MARKED 寄存器 == 期望活跃对象数
//   - 位图逐位与期望一致 (既不多标, 也不少标)
//   - CYCLES 有效 (>0)
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
    assign hp_rresp   = 2'b00;

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
            // 注意: 必须在 posedge 采样握手 —— ready 可能是组合信号,
            //       在 negedge 采样会错过已经发生的握手 (旧 RTL 的"高两拍"掩盖了这个问题)
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
    localparam [11:0] R_RLIST  = 12'h40;

    // ================= TB 数据结构 =================
    integer     i, j, k;
    integer     rc, cur_off, ref_base;
    integer     tgt, node, head, tail, cnt_exp;
    integer     errors, got, bitv, qtail_dut, marked_dut;
    integer     rr;
    integer     err_ho = 0;          // #6: 在飞 AR 超过 8 的次数
    reg [31:0]  rcs [0:N-1];
    reg [31:0]  roff [0:N-1];
    reg [31:0]  expb [0:N-1];      // 期望位图 (1=活跃)
    reg [31:0]  bq [0:N-1];
    reg [31:0]  rd_val;
    integer     guard;

    initial begin
        errors = 0;

        // ---- 复位 ----
        rstn = 1'b0;
        repeat (20) @(negedge clk);
        rstn = 1'b1;
        repeat (5)  @(negedge clk);

        // #4: 复位后 DONE 必须为 0 —— 否则软件轮询会立刻读到 marked=0 的假结果
        axil_rd(R_CTRL, rd_val);
        if (rd_val[31] !== 1'b0) begin
            $display("[TB][FAIL] 复位后 DONE=%0d, 应为 0 (#4)", rd_val[31]);
            errors = errors + 1;
        end else begin
            $display("[TB] 复位后 DONE=0 OK (#4)");
        end

        // ---- 构造对象图 ----
        for (i = 0; i < MEMW; i = i + 1) mem[i] = 32'h0;

        ref_base = (N*16 + 4095) & ~4095;
        cur_off  = ref_base;
        for (i = 0; i < N; i = i + 1) begin
            if (i == 0)          rc = 3;          // 根对象有 3 条引用, 图才连通
            else if (i == 1)     rc = 200;        // >> 旧版 REF_MAX(64): 静默截断的回归测试
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
                    // 用于回归 gc_mark_engine 里的 prev_ref 修复
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
        $display("[TB] 图: N=%0d, 活跃=%0d, 孤岛=%0d", N, cnt_exp, ISLAND);

        // ---- 配置寄存器 ----
        axil_wr(R_BASE,  BASE);
        axil_wr(R_COUNT, N);
        axil_wr(R_ROOTS, 1);
        axil_wr(R_RLIST + 8'h00, 32'd0);          // root[0] = 0
        $display("[TB] 寄存器配置完成");

        // ---- 清零位图/队列, 然后启动 ----
        axil_wr(R_CTRL, 32'h6);                   // clear_bm | clear_q
        repeat (3000) @(negedge clk);
        axil_wr(R_CTRL, 32'h1);                   // start
        $display("[TB] 已写入 START");

        // 等 DONE 拉低 (确认 start 已被引擎接收)
        guard = 0;
        rd_val = 32'hFFFFFFFF;
        while (rd_val[31] && guard < 200) begin
            axil_rd(R_CTRL, rd_val);
            guard = guard + 1;
        end
        if (rd_val[31]) begin
            $display("[TB][FAIL] start 未生效 (DONE 始终为 1) state=%0d",
                     dut.u_engine.state);
            errors = errors + 1;
        end else begin
            $display("[TB] DONE 已拉低, 引擎开始运行");
        end

        // 等 DONE 拉高
        guard = 0;
        rd_val = 32'h0;
        while (!rd_val[31] && guard < 20000) begin
            axil_rd(R_CTRL, rd_val);
            guard = guard + 1;
        end
        if (!rd_val[31]) begin
            $display("[TB][FAIL] 超时: DONE 未置位");
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
        // 新增: STATUS 寄存器必须为 0 (无溢出/无总线错误/无流失步)
        axil_rd(8'h20, rd_val);
        if (rd_val !== 32'h0) begin
            $display("[TB][FAIL] STATUS=%h (err_ovf/err_rd/err_ref 应全为 0)", rd_val);
            errors = errors + 1;
        end else begin
            $display("[TB] STATUS=0 OK (无溢出/总线错误/流失步)");
        end
        axil_rd(R_MARKED, rd_val); marked_dut = rd_val;
        axil_rd(R_QTAIL,  rd_val); qtail_dut  = rd_val & 32'hFFF;
        axil_rd(R_CYCLES, rd_val);
        $display("[TB] HW: marked=%0d q_tail=%0d cycles=%0d", marked_dut, qtail_dut, rd_val);

        if (marked_dut != cnt_exp) begin
            $display("[TB][FAIL] MARKED=%0d != 期望 %0d", marked_dut, cnt_exp);
            errors = errors + 1;
        end
        if (qtail_dut != cnt_exp) begin
            $display("[TB][FAIL] q_tail=%0d != 期望 %0d", qtail_dut, cnt_exp);
            errors = errors + 1;
        end
        if (rd_val == 32'h0) begin
            $display("[TB][FAIL] CYCLES=0 (疑似引擎没真正运行)");
            errors = errors + 1;
        end

        // ---- 逐位对比位图 ----
        // 位图映射: 对象 x → mem[x] 的第 (x%32) 位
        got = 0;
        for (i = 0; i < N; i = i + 1) begin
            bitv = (dut.u_bitmap.mem[i] >> (i % 32)) & 32'h1;
            if (bitv !== expb[i]) begin
                if (errors < 20)
                    $display("[TB][FAIL] 对象 %0d 位图=%0d 期望=%0d", i, bitv, expb[i]);
                errors = errors + 1;
            end
            if (bitv) got = got + 1;
        end
        $display("[TB] 位图统计: 活跃=%0d 期望=%0d", got, cnt_exp);

        // 孤岛必须全 0 (多标记检测)
        for (i = N-ISLAND; i < N; i = i + 1) begin
            bitv = (dut.u_bitmap.mem[i] >> (i % 32)) & 32'h1;
            if (bitv) begin
                $display("[TB][FAIL] 孤岛对象 %0d 被误标记", i);
                errors = errors + 1;
            end
        end

        // ============================================================
        // T1: 连续两次运行 —— 回归 #1 prev_ref / #3 iss_cnt 跨运行残留
        //   小图: 0 -> [1];  1 -> 无引用;  其余不可达
        //   两次运行 marked 必须都是 2。
        //   若 prev_ref 未在 start 时清零: run2 的第一个引用(1) == run1 最后
        //   标记的引用(1) → 被"相邻重复"保护分支跳过 → marked=1 (静默漏标记)。
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
            axil_wr(R_CTRL, 32'h6);                // clear_bm | clear_q
            repeat (200) @(negedge clk);
            axil_wr(R_CTRL, 32'h1);                // start

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
                $display("[TB][FAIL] T1 run%0d marked=%0d != 2 (prev_ref 跨运行残留?)", rr+1, rd_val);
                errors = errors + 1;
            end
        end

        // ============================================================
        // T2: 重复根 —— 同一个 root 写两次, 必须只计一次 (#5)
        // ============================================================
        $display("[TB] ===== T2: duplicate root =====");
        // 用一个 ID >= 32 的根 —— 让它落在**不同的位图字**上。
        // 否则"跳过 S_ROOT_CHK 后偶然读到位图字 0"会掩盖重复检测, 反向验证无效.
        mem[(33*16)/4 + 1] = 32'd0;          // obj33 ref_count = 0 (在 +4, 字索引 +1)
        axil_wr(R_RLIST,     32'd33);
        axil_wr(R_RLIST + 4, 32'd33);        // 同一个根再写一次
        axil_wr(R_COUNT, 32'd64);
        axil_wr(R_ROOTS, 32'd2);             // root_count = 2

        axil_wr(R_CTRL, 32'h6);
        repeat (200) @(negedge clk);
        axil_wr(R_CTRL, 32'h1);
        guard = 0; rd_val = 32'hFFFFFFFF;
        while (rd_val[31] && guard < 500) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        guard = 0; rd_val = 32'h0;
        while (!rd_val[31] && guard < 20000) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        axil_rd(R_MARKED, rd_val);
        $display("[TB] T2 duplicate-root: marked=%0d (expect 1)", rd_val);
        if (rd_val !== 32'd1) begin
            $display("[TB][FAIL] T2 marked=%0d != 1 (重复根被重复计数?)", rd_val);
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
                $display("[TB][FAIL] T3 reg04=%h != A5A50001 (第一笔写丢失/写错)", rd_val);
                errors = errors + 1;
            end
            axil_rd(8'h08, rd_val);
            if (rd_val !== 32'h5A5A0002) begin
                $display("[TB][FAIL] T3 reg08=%h != 5A5A0002 (第二笔 AW 未锁存)", rd_val);
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
        axil_wr(R_CTRL, 32'h6);
        repeat (200) @(negedge clk);
        axil_wr(R_CTRL, 32'h1);
        guard = 0; rd_val = 32'hFFFFFFFF;
        while (rd_val[31] && guard < 500) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        guard = 0; rd_val = 32'h0;
        while (!rd_val[31] && guard < 20000) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        axil_rd(R_MARKED, rd_val);
        $display("[TB] T4 marked=%0d (expect 1)", rd_val);
        if (rd_val !== 32'd1) begin
            $display("[TB][FAIL] T4 marked=%0d != 1 (非法头未被拒)", rd_val);
            errors = errors + 1;
        end
        axil_rd(8'h20, rd_val);
        if (rd_val[3] !== 1'b1) begin
            $display("[TB][FAIL] T4 STATUS[3]=%b, 应为 1 (err_hdr 没置)", rd_val[3]);
            errors = errors + 1;
        end else begin
            $display("[TB] T4 err_hdr=1 OK (非法头被拒并上报)");
        end

        // ============================================================
        // T5: 12 位寄存器地址 —— 写 root[60] (地址 0x40+60*4 = 0x130 > 0xFF)
        //   构造: obj_count=61, root[0..59] 全填 200 (>= obj_count, 会被跳过),
        //         root[60]=60。root_count=61 保证引擎确实会读到 root[60]。
        //   修复后: marked=1 (只有 obj60);
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
        axil_wr(R_CTRL, 32'h6);
        repeat (200) @(negedge clk);
        axil_wr(R_CTRL, 32'h1);
        guard = 0; rd_val = 32'hFFFFFFFF;
        while (rd_val[31] && guard < 500) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        guard = 0; rd_val = 32'h0;
        while (!rd_val[31] && guard < 20000) begin axil_rd(R_CTRL, rd_val); guard = guard + 1; end
        axil_rd(R_MARKED, rd_val);
        $display("[TB] T5 root60: marked=%0d (expect 1)", rd_val);
        if (rd_val !== 32'd1) begin
            $display("[TB][FAIL] T5 marked=%0d != 1 (root[60] 地址被截断?)", rd_val);
            errors = errors + 1;
        end

        // ---- #6 汇总 ----
        if (err_ho != 0) begin
            $display("[TB][FAIL] #6 在飞 AR 超过 8 的次数: %0d", err_ho);
            errors = errors + 1;
        end else begin
            $display("[TB] #6 在飞 AR 从未超过 8 OK");
        end

        // ---- AXI 协议检查 (#1) ----
        if (axi_errs !== 32'd0) begin
            $display("[TB][FAIL] AXI 协议违规 %0d 次 (ARSIZE/ARLEN/ARBURST/对齐/VALID 稳定性)", axi_errs);
            errors = errors + 1;
        end else begin
            $display("[TB] AXI 协议检查 OK (ARSIZE=3, ARLEN=0, ARBURST=INCR, 8B 对齐, VALID 稳定)");
        end

        // ---- 结论 ----
        if (errors == 0)
            $display("\n[TB] ==================== PASS ====================");
        else
            $display("\n[TB] ==================== FAIL (%0d 处) ====================", errors);

        $finish;
    end

    // #6 监视: 两条流合计的在飞 AR 数, 任何时刻都不得超过 8 (= 声明值 MAXO)
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
            $display("      --- 最近 %0d 拍 (旧→新) ---", TR_N);
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
        if (dut.u_engine.state == 5'd15) pushw_run = pushw_run + 1;
        else pushw_run = 0;
        if (pushw_run > 40 && !dumped) begin
            dumped = 1'b1;
            $display("[TB][FAIL] 检测到卡死: S_REFS_PUSHW 持续 %0d 拍", pushw_run);
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
        $display("[TB][FAIL] 全局超时");
        $display("      engine state=%0d cur_obj=%0d qh=%0d qt=%0d",
                 dut.u_engine.state, dut.u_engine.cur_obj,
                 dut.u_queue.head, dut.u_queue.tail);
        dump_ring;
        $finish;
    end

endmodule
