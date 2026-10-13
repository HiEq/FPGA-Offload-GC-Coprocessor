// ============================================================
// gc_queue.v — BFS工作队列 (强制BRAM推断)
//
// 修复:
//   1. ram_style="block" 强制映射BRAM
//   2. 读口无条件读取 (去掉 if(en) 包裹, 避免被综合器识别为寄存器)
//   3. 写口/读口完全分离在独立always块
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
    output reg  [11:0] tail
);

    // 强制BRAM
    (* ram_style = "block" *)
    reg [11:0] mem [0:4095];

    // ===== 写口: 干净的BRAM模板 =====
    always @(posedge clk) begin
        if (we)
            mem[waddr] <= wdata;
    end

    // ===== 读口: 无条件同步读 (不要包if) =====
    always @(posedge clk) begin
        rdata <= mem[head];
    end

    // ===== 控制逻辑 (不影响mem) =====
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head   <= 12'd0;
            tail   <= 12'd0;
            rvalid <= 1'b0;
        end else if (clear) begin
            head   <= 12'd0;
            tail   <= 12'd0;
            rvalid <= 1'b0;
        end else begin
            rvalid <= en;
            if (we)
                tail <= waddr + 12'd1;
            if (en)
                head <= head + 12'd1;
        end
    end

endmodule
