`timescale 1ns/1ps
// ============================================================
// tb_axi_read.v — gc_axi_read 专项单测 (针对 #6 未完成读上限)
//
// 目的: 整机仿真里引擎的读需求不够密, 在飞 AR 到不了 8, 无法验证 #6.
//       这里直接驱动 cmd0, 用长延迟 (LAT=40) 把 AR 堆起来,
//       行为级统计 (ar_cnt - r_cnt) 必须任何时刻都 ≤ MAXO(8).
//
// 负向验证: 把 gc_axi_read 的 h0nxt/h1nxt 回退成 h0cnt/h1cnt
//           (即"不把本拍正在握手的那笔算进去"), 峰值会变成 9 → FAIL.
// ============================================================
module tb_axi_read;

    localparam integer NCMD = 32;      // 压入的命令数
    localparam integer LAT  = 40;      // 读返回延迟 (拍) —— 故意放大, 让 AR 堆积
    localparam [31:0]  BASE = 32'h1E000000;

    reg clk = 1'b0;
    reg rstn = 1'b0;
    always #5 clk = ~clk;

    // 命令接口 (流 0 用, 流 1 空闲)
    reg         c0v = 1'b0;
    reg  [31:0] c0a = 32'h0;
    wire        c0r;
    wire [31:0] d0;
    wire        d0v;

    reg         c1v = 1'b0;
    reg  [31:0] c1a = 32'h0;
    wire        c1r;
    wire [31:0] d1;
    wire        d1v;

    wire        err;

    wire [31:0] araddr;
    wire [5:0]  arid;
    wire [3:0]  arlen;
    wire [2:0]  arsize;
    wire [1:0]  arburst;
    wire [3:0]  arcache;
    wire [2:0]  arprot;
    wire        arvalid;
    wire        arready;
    wire [63:0] rdata;
    wire [5:0]  rid;
    wire [1:0]  rresp;
    wire        rlast;
    wire        rvalid;
    wire        rready;

    gc_axi_read dut (
        .ACLK        (clk),
        .ARESETN     (rstn),
        .cmd0_valid  (c0v),
        .cmd0_addr   (c0a),
        .cmd0_ready  (c0r),
        .data0_out   (d0),
        .data0_valid (d0v),
        .data0_ready (1'b1),
        .cmd1_valid  (c1v),
        .cmd1_addr   (c1a),
        .cmd1_ready  (c1r),
        .data1_out   (d1),
        .data1_valid (d1v),
        .data1_ready (1'b1),
        .err         (err),
        .ARADDR      (araddr),
        .ARID        (arid),
        .ARLEN       (arlen),
        .ARSIZE      (arsize),
        .ARBURST     (arburst),
        .ARCACHE     (arcache),
        .ARPROT      (arprot),
        .ARVALID     (arvalid),
        .ARREADY     (arready),
        .RDATA       (rdata),
        .RID         (rid),
        .RRESP       (rresp),
        .RLAST       (rlast),
        .RVALID      (rvalid),
        .RREADY      (rready)
    );

    // ---------- AXI 协议检查器 ----------
    wire [31:0] axi_errs;
    axi_proto_check u_axi_chk (
        .clk     (clk),
        .rstn    (rstn),
        .ARADDR  (araddr),
        .ARID    (arid),
        .ARLEN   (arlen),
        .ARSIZE  (arsize),
        .ARBURST (arburst),
        .ARCACHE (arcache),
        .ARVALID (arvalid),
        .ARREADY (arready),
        .RID     (rid),
        .RRESP   (rresp),
        .RVALID  (rvalid),
        .RREADY  (rready),
        .errors  (axi_errs)
    );

    // ---------- 行为记忆模型: 固定 LAT 拍, 回显 ARID ----------
    reg  [38:0] sh [0:LAT-1];        // {valid, id[5:0], addr[31:0]}
    integer     si;
    wire        rvalid_i = sh[0][38];
    wire [5:0]  rid_i    = sh[0][37:32];
    wire [31:0] raddr_i  = sh[0][31:0];
    wire        can_shift = !(rvalid_i && !rready);

    assign rvalid  = rvalid_i;
    assign rid     = rid_i;
    assign rdata   = { raddr_i + 32'd4, raddr_i };
    assign rresp   = 2'b00;
    assign rlast   = 1'b1;
    assign arready = can_shift;
    assign rready  = 1'b1;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            for (si = 0; si < LAT; si = si + 1) sh[si] <= 39'd0;
        end else if (can_shift) begin
            for (si = 0; si < LAT-1; si = si + 1) sh[si] <= sh[si+1];
            sh[LAT-1] <= (arvalid && arready) ? {1'b1, arid, araddr} : 39'd0;
        end
    end

    // ---------- 统计: 在飞 AR = AR 握手数 - R 握手数 ----------
    integer ar_cnt = 0;
    integer r_cnt  = 0;
    integer peak   = 0;
    integer viol   = 0;              // 在飞超过 MAXO(8) 的拍数

    always @(posedge clk) begin
        if (rstn) begin
            if (arvalid && arready) ar_cnt = ar_cnt + 1;
            if (rvalid  && rready)  r_cnt  = r_cnt  + 1;
            if ((ar_cnt - r_cnt) > peak) peak = ar_cnt - r_cnt;
            if ((ar_cnt - r_cnt) > 8)    viol = viol + 1;
        end
    end

    // ---------- 驱动 ----------
    integer i, guard;
    initial begin
        rstn = 1'b0;
        repeat (10) @(negedge clk);
        rstn = 1'b1;
        repeat (5) @(negedge clk);

        // 背靠背压入 NCMD 条命令
        for (i = 0; i < NCMD; i = i + 1) begin
            @(negedge clk);
            c0a = BASE + i * 8;
            c0v = 1'b1;
            guard = 0;
            @(posedge clk);
            while (!(c0v && c0r) && guard < 200) begin @(posedge clk); guard = guard + 1; end
        end
        @(negedge clk);
        c0v = 1'b0;

        // 等所有数据回来
        guard = 0;
        while ((r_cnt < NCMD) && guard < 20000) begin @(posedge clk); guard = guard + 1; end
        repeat (20) @(negedge clk);

        $display("[AXITB] NCMD=%0d LAT=%0d | AR=%0d R=%0d | 在飞峰值=%0d (上限 8) | 超限拍数=%0d",
                 NCMD, LAT, ar_cnt, r_cnt, peak, viol);

        if (ar_cnt != NCMD) begin
            $display("[AXITB][FAIL] 发出的 AR 数 %0d != %0d", ar_cnt, NCMD);
        end else if (r_cnt != NCMD) begin
            $display("[AXITB][FAIL] 收回的 R 数 %0d != %0d (丢数据)", r_cnt, NCMD);
        end else if (viol != 0) begin
            $display("[AXITB][FAIL] 在飞 AR 超过 8 共 %0d 拍 —— #6 未修复!", viol);
        end else if (axi_errs !== 32'd0) begin
            $display("[AXITB][FAIL] AXI 协议违规 %0d 次", axi_errs);
        end else begin
            $display("[AXITB] AXI 协议检查 OK (ARSIZE=3, ARLEN=0, ARBURST=INCR, 8B 对齐)");
            $display("[AXITB] ==================== PASS ====================");
        end
        $finish;
    end

    initial begin
        #2000000;
        $display("[AXITB][FAIL] 全局超时 (AR=%0d R=%0d 峰值=%0d)", ar_cnt, r_cnt, peak);
        $finish;
    end

endmodule
