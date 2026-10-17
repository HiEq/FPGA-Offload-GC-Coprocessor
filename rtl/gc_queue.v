// ============================================================
// gc_queue.v — BFS工作队列 (强制BRAM推断)
//
// 修复 (#1/#6):
//   旧版用绝对 12 位 head/tail 指针, 写满 4096 条时 head==tail 会被误判为"空",
//   所以旧版把 Q_MAX 卡在 4000, 且超限时**静默丢弃** (对象被标记但不入队 →
//   它的引用永远不会被追踪 → 静默漏标记, 结果错但不报错).
//   现在:
//     - 用 count 判空/满, head==tail 不再有歧义, 可以安全用满 4096 条
//     - full 直接输出, 由上层决定怎么处理 (上层会置错误标志)
//     - rvalid 只在真的有数据时拉高
// ============================================================
module gc_queue (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        clear,

    // 写端口 (push)
    input  wire [11:0] waddr,
    input  wire [11:0] wdata,
    input  wire        we,

    // 读端口 (pop)
    input  wire        en,
    output reg  [11:0] rdata,
    output reg         rvalid,

    // 状态
    output reg  [11:0] head,
    output reg  [11:0] tail,
    output wire        empty,
    output wire        full,
    output reg  [12:0] count
);

    localparam integer DEPTH = 4096;

    (* ram_style = "block" *)
    reg [11:0] mem [0:DEPTH-1];

    // ===== 写口: 干净的BRAM模板 =====
    always @(posedge clk) begin
        if (we)
            mem[waddr] <= wdata;
    end

    // ===== 读口: 无条件同步读 (不要包if) =====
    always @(posedge clk) begin
        rdata <= mem[head];
    end

    assign empty = (count == 13'd0);
    assign full  = (count == DEPTH[12:0]);

    // ===== 控制逻辑 (不影响mem) =====
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head   <= 12'd0;
            tail   <= 12'd0;
            rvalid <= 1'b0;
            count  <= 13'd0;
        end else if (clear) begin
            head   <= 12'd0;
            tail   <= 12'd0;
            rvalid <= 1'b0;
            count  <= 13'd0;
        end else begin
            // 只有在真的有数据时才回应
            rvalid <= en && (count != 13'd0);
            if (we && (count != DEPTH[12:0]))
                tail <= waddr + 12'd1;
            if (en && (count != 13'd0))
                head <= head + 12'd1;

            // 同拍一写一读: 计数不变
            case ({we && (count != DEPTH[12:0]), en && (count != 13'd0)})
                2'b10:   count <= count + 13'd1;
                2'b01:   count <= count - 13'd1;
                default: count <= count;
            endcase
        end
    end

endmodule
