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
    localparam integer LAT    = 8;              // AXI 读固定延迟(拍)
    localparam integer MEMW   = 1 << 18;        // 1MB / 4
    localparam [31:0]  BASE   = 32'h1E000000;   // 对象图物理基地址
    localparam integer ISLAND = 50;             // 末尾 50 个对象 = 不可达孤岛

    // ---------------- 时钟 / 复位 ----------------
    reg clk = 1'b0;
    always #(CLKP/2) clk = ~clk;
    reg rstn = 1'b0;

    // ---------------- AXI-Lite 主机 ----------------
    reg  [7:0]  m_awaddr  = 8'h0;
    reg         m_awvalid = 1'b0;
    wire        m_awready;
    reg  [31:0] m_wdata   = 32'h0;
    reg  [3:0]  m_wstrb   = 4'hF;
    reg         m_wvalid  = 1'b0;
    wire        m_wready;
    wire [1:0]  m_bresp;
    wire        m_bvalid;
    reg         m_bready  = 1'b0;
    reg  [7:0]  m_araddr  = 8'h0;
    reg         m_arvalid = 1'b0;
    wire        m_arready;
    wire [31:0] m_rdata;
    wire [1:0]  m_rresp;
    wire        m_rvalid;
    reg         m_rready  = 1'b0;

    // ---------------- AXI HP ----------------
    wire [31:0] hp_araddr;
    wire [2:0]  hp_arprot;
    wire        hp_arvalid;
    wire        hp_arready;
    wire [63:0] hp_rdata;
    wire [1:0]  hp_rresp;
    wire        hp_rvalid;
    wire        hp_rready;
    wire [31:0] hp_awaddr;
    wire [2:0]  hp_awprot;
    wire        hp_awvalid;
    wire        hp_awready;
    wire [63:0] hp_wdata;
    wire [7:0]  hp_wstrb;
    wire        hp_wvalid;
    wire        hp_wready;
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
        .S_AXI_HP_ARPROT  (hp_arprot),
        .S_AXI_HP_ARVALID (hp_arvalid),
        .S_AXI_HP_ARREADY (hp_arready),
        .S_AXI_HP_RDATA   (hp_rdata),
        .S_AXI_HP_RRESP   (hp_rresp),
        .S_AXI_HP_RVALID  (hp_rvalid),
        .S_AXI_HP_RREADY  (hp_rready),
        .S_AXI_HP_AWADDR  (hp_awaddr),
        .S_AXI_HP_AWPROT  (hp_awprot),
        .S_AXI_HP_AWVALID (hp_awvalid),
        .S_AXI_HP_AWREADY (hp_awready),
        .S_AXI_HP_WDATA   (hp_wdata),
        .S_AXI_HP_WSTRB   (hp_wstrb),
        .S_AXI_HP_WVALID  (hp_wvalid),
        .S_AXI_HP_WREADY  (hp_wready),
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
    assign hp_bresp   = 2'b00;
    assign hp_bvalid  = 1'b0;

    reg  [32:0] shr [0:LAT-1];          // {valid, addr}
    integer     si;
    wire        hp_rvalid_i = shr[0][32];
    wire [31:0] hp_raddr    = shr[0][31:0];
    wire        hp_can_shift = !(hp_rvalid_i && !hp_rready);

    assign hp_arready = hp_can_shift;   // 输出被阻塞时不再收地址
    assign hp_rvalid  = hp_rvalid_i;
    assign hp_rresp   = 2'b00;

    wire [31:0] hp_widx = hp_raddr[31:2] - BASE[31:2];
    assign hp_rdata = { mem[hp_widx + 1], mem[hp_widx] };  // 小端: 低字在先

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            for (si = 0; si < LAT; si = si + 1) shr[si] <= 33'd0;
        end else if (hp_can_shift) begin
            for (si = 0; si < LAT-1; si = si + 1)
                shr[si] <= shr[si+1];
            shr[LAT-1] <= (hp_arvalid && hp_arready) ? {1'b1, hp_araddr} : 33'd0;
        end
    end

    // ================= AXI-Lite 任务 =================
    task axil_wr(input [7:0] a, input [31:0] d);
        begin
            @(negedge clk);
            m_awaddr = a; m_awvalid = 1'b1;
            m_wdata  = d; m_wstrb = 4'hF; m_wvalid = 1'b1;
            m_bready = 1'b0;
            @(negedge clk);
            while (!m_awready) @(negedge clk);
            m_awvalid = 1'b0;
            while (!m_wready)  @(negedge clk);
            m_wvalid  = 1'b0;
            while (!m_bvalid)  @(negedge clk);
            m_bready  = 1'b1;
            @(negedge clk);
            m_bready  = 1'b0;
            @(negedge clk);
        end
    endtask

    task axil_rd(input [7:0] a, output [31:0] d);
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
    localparam [7:0] R_CTRL   = 8'h00;
    localparam [7:0] R_BASE   = 8'h04;
    localparam [7:0] R_COUNT  = 8'h08;
    localparam [7:0] R_ROOTS  = 8'h0C;
    localparam [7:0] R_MARKED = 8'h10;
    localparam [7:0] R_CYCLES = 8'h14;
    localparam [7:0] R_QHEAD  = 8'h18;
    localparam [7:0] R_QTAIL  = 8'h1C;
    localparam [7:0] R_RLIST  = 8'h40;

    // ================= TB 数据结构 =================
    integer     i, j, k;
    integer     rc, cur_off, ref_base;
    integer     tgt, node, head, tail, cnt_exp;
    integer     errors, got, bitv, qtail_dut, marked_dut;
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
                     dut.u_axi_rd.hcnt, dut.u_axi_rd.cw, dut.u_axi_rd.cr,
                     dut.u_axi_rd.dw, dut.u_axi_rd.dr,
                     dut.u_axi_rd.hw, dut.u_axi_rd.hr);
            $display("      engine: rd_cmd_valid=%0d rd_cmd_ready=%0d rd_data_valid=%0d rd_data_ready=%0d",
                     dut.u_engine.rd_cmd_valid, dut.u_engine.rd_cmd_ready,
                     dut.u_engine.rd_data_valid, dut.u_engine.rd_data_ready);
            errors = errors + 1;
        end

        // ---- 读统计 ----
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

        // ---- 结论 ----
        if (errors == 0)
            $display("\n[TB] ==================== PASS ====================");
        else
            $display("\n[TB] ==================== FAIL (%0d 处) ====================", errors);

        $finish;
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
        tr_cw  [trp] <= dut.u_axi_rd.cw;
        tr_cr  [trp] <= dut.u_axi_rd.cr;
        tr_dw  [trp] <= dut.u_axi_rd.dw;
        tr_dr  [trp] <= dut.u_axi_rd.dr;
        tr_hw  [trp] <= dut.u_axi_rd.hw;
        tr_hr  [trp] <= dut.u_axi_rd.hr;
        tr_fl  [trp] <= {dut.u_engine.rd_cmd_valid, dut.u_engine.rd_cmd_ready,
                         dut.u_axi_rd.data_valid,   dut.u_engine.rd_data_ready,
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
                    dut.u_axi_rd.cw, dut.u_axi_rd.cr,
                    dut.u_axi_rd.dw, dut.u_axi_rd.dr,
                    dut.u_axi_rd.hw, dut.u_axi_rd.hr,
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
                         dut.u_axi_rd.hw, dut.u_axi_rd.hr);
                evc = evc + 1;
            end
            if (hp_rvalid && hp_rready) begin
                $display("[EV%0d] R  data=%h hfifo[%0d]=%b dw=%0d dr=%0d",
                         evc, hp_rdata, dut.u_axi_rd.hr,
                         dut.u_axi_rd.hfifo[dut.u_axi_rd.hr],
                         dut.u_axi_rd.dw, dut.u_axi_rd.dr);
                evc = evc + 1;
            end
            if (dut.u_engine.state == 5'd12 && dut.u_engine.rd_data_valid) begin
                $display("[EV%0d] G1 data=%h dr=%0d dw=%0d",
                         evc, dut.u_engine.rd_data, dut.u_axi_rd.dr, dut.u_axi_rd.dw);
                evc = evc + 1;
            end
            if (dut.u_engine.state == 5'd13 && dut.u_engine.rd_data_valid) begin
                $display("[EV%0d] G2 data=%h dr=%0d dw=%0d",
                         evc, dut.u_engine.rd_data, dut.u_axi_rd.dr, dut.u_axi_rd.dw);
                evc = evc + 1;
            end
            if (dut.u_engine.state == 5'd16 && dut.u_engine.rd_data_valid) begin
                $display("[EV%0d] GET data=%h obj=%0d dr=%0d dw=%0d",
                         evc, dut.u_engine.rd_data, dut.u_engine.cur_obj,
                         dut.u_axi_rd.dr, dut.u_axi_rd.dw);
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
