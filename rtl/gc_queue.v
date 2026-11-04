// gc_queue.v — BFS 工作队列 (BRAM)
//
// 深度 4096 条; 以 count 判空/满.
// full 由上层处理; rvalid 仅在队列非空时有效.
module gc_queue (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        clear,

    input  wire [15:0] waddr,
    input  wire [15:0] wdata,
    input  wire        we,

    input  wire        en,
    output reg  [15:0] rdata,
    output reg         rvalid,

    output reg  [15:0] head,
    output reg  [15:0] tail,
    output wire        empty,
    output wire        full,
    output reg  [16:0] count
);

    localparam integer DEPTH = 65536;

    (* ram_style = "block" *)
    reg [15:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        if (we)
            mem[waddr] <= wdata;
    end

    always @(posedge clk) begin
        rdata <= mem[head];
    end

    assign empty = (count == 17'd0);
    assign full  = (count == DEPTH[16:0]);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head   <= 16'd0;
            tail   <= 16'd0;
            rvalid <= 1'b0;
            count  <= 17'd0;
        end else if (clear) begin
            head   <= 16'd0;
            tail   <= 16'd0;
            rvalid <= 1'b0;
            count  <= 17'd0;
        end else begin
            // 队列非空才给 rvalid
            rvalid <= en && (count != 17'd0);
            if (we && (count != DEPTH[16:0]))
                tail <= waddr + 16'd1;
            if (en && (count != 17'd0))
                head <= head + 16'd1;

            // 同拍一写一读: 计数不变
            case ({we && (count != DEPTH[16:0]), en && (count != 17'd0)})
                2'b10:   count <= count + 13'd1;
                2'b01:   count <= count - 13'd1;
                default: count <= count;
            endcase
        end
    end

endmodule
