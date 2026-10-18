// gc_axi_read.v — AXI3 读命令队列主控 (双流 / dual stream)
// 协议: AXI3 , ID 宽 6, 单拍读.
//   ARADDR = addr & ~7       (8 字节对齐)
//   hi_sel = addr[2]         (1 = 取 RDATA[63:32])
//   每笔读只返回 1 拍, 取其中一半.
module gc_axi_read #(
    parameter integer QD   = 80,   // 每条流的命令 FIFO 容量
    parameter integer MAXO = 8     // 允许的最大未完成 AR 笔数 (HP0 就是 8)
)(
    input  wire        ACLK,
    input  wire        ARESETN,

    input  wire        cmd0_valid,
    input  wire [31:0] cmd0_addr,
    output wire        cmd0_ready,
    output wire [31:0] data0_out,
    output wire        data0_valid,
    input  wire        data0_ready,

    input  wire        cmd1_valid,
    input  wire [31:0] cmd1_addr,
    output wire        cmd1_ready,
    output wire [31:0] data1_out,
    output wire        data1_valid,
    input  wire        data1_ready,

    output reg         err,        // AXI 读错误 (粘滞, 复位清除)

    output reg  [31:0] ARADDR,
    output reg  [5:0]  ARID,       // 0 = 引用流, 1 = 对象头流
    output reg  [3:0]  ARLEN,      // 恒 0 (单拍)
    output reg  [2:0]  ARSIZE,     // 3'b011 = 8 字节
    output reg  [1:0]  ARBURST,    // 2'b01 = INCR
    output reg  [3:0]  ARCACHE,
    output reg  [2:0]  ARPROT,
    output reg         ARVALID,
    input  wire        ARREADY,

    input  wire [63:0] RDATA,
    input  wire [5:0]  RID,
    input  wire [1:0]  RRESP,
    input  wire        RLAST,      // 未使用 (每笔只 1 拍)
    input  wire        RVALID,
    output wire        RREADY
);

    localparam integer PW  = 7;        // 128 深
    localparam integer DEP = 1 << PW;

    reg  [32:0] c0f [0:DEP-1];
    reg  [PW-1:0] c0w = 0, c0r = 0;
    wire [PW-1:0] c0cnt = c0w - c0r;
    wire          c0full = (c0cnt >= QD[PW-1:0]);
    wire          c0empty = (c0w == c0r);
    assign cmd0_ready = ~c0full;

    reg  [32:0] c1f [0:DEP-1];
    reg  [PW-1:0] c1w = 0, c1r = 0;
    wire [PW-1:0] c1cnt = c1w - c1r;
    wire          c1full = (c1cnt >= QD[PW-1:0]);
    wire          c1empty = (c1w == c1r);
    assign cmd1_ready = ~c1full;

    reg  [31:0] d0f [0:DEP-1];
    reg  [PW-1:0] d0w = 0, d0r = 0;
    wire [PW-1:0] d0cnt = d0w - d0r;
    wire          d0full = (d0cnt >= QD[PW-1:0]);
    wire          d0empty = (d0w == d0r);
    assign data0_out   = d0f[d0r];
    assign data0_valid = ~d0empty;

    reg  [31:0] d1f [0:DEP-1];
    reg  [PW-1:0] d1w = 0, d1r = 0;
    wire [PW-1:0] d1cnt = d1w - d1r;
    wire          d1full = (d1cnt >= QD[PW-1:0]);
    wire          d1empty = (d1w == d1r);
    assign data1_out   = d1f[d1r];
    assign data1_valid = ~d1empty;

    reg          h0f [0:DEP-1];
    reg  [PW-1:0] h0w = 0, h0r = 0;
    wire [PW-1:0] h0cnt = h0w - h0r;
    wire          h0empty = (h0w == h0r);

    reg          h1f [0:DEP-1];
    reg  [PW-1:0] h1w = 0, h1r = 0;
    wire [PW-1:0] h1cnt = h1w - h1r;
    wire          h1empty = (h1w == h1r);

    // 总未完成数 (AXI 实际限制是 8 笔, 两条流合起来不能超)
    // 总未完成数在 AR 段之后声明 (它依赖本拍握手的增量计数)

    reg        ar_hi  = 1'b0;      // 当前在 AR 通道上的读的 hi_sel
    reg        ar_sel = 1'b0;      // 0 = 引用流, 1 = 对象头流
    wire       ar_hs  = ARVALID && ARREADY;

    wire ar_can_load = (~ARVALID) | ar_hs;

    // 仲裁: 两条流轮转
    reg  last_served = 1'b0;          // 0 = 上次服务的是引用流, 1 = 对象头流
    // 计数包含本拍正在握手的请求 (ar_hs 入账晚一拍)
    wire [PW-1:0] h0nxt = h0cnt + ((ar_hs && !ar_sel) ? 1'b1 : 1'b0);
    wire [PW-1:0] h1nxt = h1cnt + ((ar_hs &&  ar_sel) ? 1'b1 : 1'b0);
    wire [PW-1:0] ho_cnt = h0nxt + h1nxt;
    wire          ho_full = (ho_cnt >= MAXO[PW-1:0]);
    wire ready0 = !c0empty && (h0nxt < MAXO[PW-1:0]);
    wire ready1 = !c1empty && (h1nxt < MAXO[PW-1:0]);
    wire issue0 = ready0 && (ready1 ? (last_served == 1'b1) : 1'b1);
    wire issue1 = ready1 && (ready0 ? (last_served == 1'b0) : 1'b1);
    wire issue_any = (issue0 || issue1) && !ho_full;

    // RID 在 RVALID 有效时可用; 按 ID 分流
    wire r_is1  = (RID[0] == 1'b1);
    wire r_full = r_is1 ? d1full : d0full;
    assign RREADY = ~r_full;

    always @(posedge ACLK or negedge ARESETN) begin
        if (!ARESETN) begin
            c0w <= 0; c0r <= 0;
            c1w <= 0; c1r <= 0;
            d0w <= 0; d0r <= 0;
            d1w <= 0; d1r <= 0;
            h0w <= 0; h0r <= 0;
            h1w <= 0; h1r <= 0;
            ARVALID <= 1'b0;
            ARADDR  <= 32'h0;
            ARID    <= 6'h00;
            ARLEN   <= 4'h0;
            ARSIZE  <= 3'b011;
            ARBURST <= 2'b01;
            ARCACHE <= 4'b0011;
            ARPROT  <= 3'b000;
            ar_hi   <= 1'b0;
            ar_sel  <= 1'b0;
            last_served <= 1'b0;
            err     <= 1'b0;
        end else begin
            if (cmd0_valid && cmd0_ready) begin
                c0f[c0w] <= {cmd0_addr[2], cmd0_addr};
                c0w <= c0w + 1'b1;
            end
            if (cmd1_valid && cmd1_ready) begin
                c1f[c1w] <= {cmd1_addr[2], cmd1_addr};
                c1w <= c1w + 1'b1;
            end

            if (ar_hs) begin
                // 结算已发出的那笔: 记下它属于哪条流
                if (ar_sel) begin
                    h1f[h1w] <= ar_hi;
                    h1w <= h1w + 1'b1;
                end else begin
                    h0f[h0w] <= ar_hi;
                    h0w <= h0w + 1'b1;
                end
            end

            if (ar_can_load) begin
                if (issue_any) begin
                    if (issue0) begin
                        ar_sel  <= 1'b0;
                        ar_hi   <= c0f[c0r][2];
                        ARID    <= 6'd0;
                        ARADDR  <= {c0f[c0r][31:3], 3'b000};   // 8 字节对齐
                        c0r     <= c0r + 1'b1;
                    end else begin
                        ar_sel  <= 1'b1;
                        ar_hi   <= c1f[c1r][2];
                        ARID    <= 6'd1;
                        ARADDR  <= {c1f[c1r][31:3], 3'b000};
                        c1r     <= c1r + 1'b1;
                    end
                    ARVALID <= 1'b1;
                    last_served <= issue0 ? 1'b0 : 1'b1;
                end else begin
                    ARVALID <= 1'b0;
                end
            end

            if (RVALID && RREADY) begin
                if (RRESP != 2'b00)
                    err <= 1'b1;
                if (r_is1) begin
                    if (!h1empty) begin
                        d1f[d1w] <= (RRESP == 2'b00)
                                    ? (h1f[h1r] ? RDATA[63:32] : RDATA[31:0])
                                    : 32'hFFFFFFFF;
                        d1w <= d1w + 1'b1;
                        h1r <= h1r + 1'b1;
                    end
                end else begin
                    if (!h0empty) begin
                        d0f[d0w] <= (RRESP == 2'b00)
                                    ? (h0f[h0r] ? RDATA[63:32] : RDATA[31:0])
                                    : 32'hFFFFFFFF;
                        d0w <= d0w + 1'b1;
                        h0r <= h0r + 1'b1;
                    end
                end
            end

            if (data0_valid && data0_ready)
                d0r <= d0r + 1'b1;
            if (data1_valid && data1_ready)
                d1r <= d1r + 1'b1;
        end
    end

    wire _unused = &{1'b0, c0cnt, c1cnt, d0cnt, d1cnt, ho_cnt, RLAST};

endmodule
