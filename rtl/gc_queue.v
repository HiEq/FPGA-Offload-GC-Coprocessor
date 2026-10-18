// ============================================================
// gc_queue.v — BFS 工作队列 (BRAM)
//
// 深度 4096 条; 以 count 判空/满.
// full 由上层处理; rvalid 仅在队列非空时有效.
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
            // 队列非空才给 rvalid
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
