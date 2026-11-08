// gc_queue.v - BFS work queue (BRAM), P1 1M: depth 524288, 20-bit ids.
//
// Address/pointer width 19 bits (2^19 entries), payload a 20-bit object id.
// The array lives in a clock-only block so Vivado infers BRAM; an async-reset
// block would force it into flip-flops.
module gc_queue (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        clear,

    input  wire [18:0] waddr,
    input  wire [19:0] wdata,
    input  wire        we,

    input  wire        en,
    output reg  [19:0] rdata,
    output reg         rvalid,

    output reg  [18:0] head,
    output reg  [18:0] tail,
    output wire        empty,
    output wire        full,
    output reg  [19:0] count
);

    localparam integer DEPTH = 524288;

    (* ram_style = "block" *)
    reg [19:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        if (we)
            mem[waddr] <= wdata;
    end

    always @(posedge clk) begin
        rdata <= mem[head];
    end

    assign empty = (count == 20'd0);
    assign full  = (count == DEPTH[19:0]);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head   <= 19'd0;
            tail   <= 19'd0;
            rvalid <= 1'b0;
            count  <= 20'd0;
        end else if (clear) begin
            head   <= 19'd0;
            tail   <= 19'd0;
            rvalid <= 1'b0;
            count  <= 20'd0;
        end else begin
            rvalid <= en && (count != 20'd0);
            if (we && (count != DEPTH[19:0]))
                tail <= waddr + 19'd1;
            if (en && (count != 20'd0))
                head <= head + 19'd1;

            case ({we && (count != DEPTH[19:0]), en && (count != 20'd0)})
                2'b10:   count <= count + 20'd1;
                2'b01:   count <= count - 20'd1;
                default: count <= count;
            endcase
        end
    end

endmodule
