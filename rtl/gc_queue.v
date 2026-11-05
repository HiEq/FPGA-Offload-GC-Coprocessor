// gc_queue.v - BFS work queue (BRAM), P1 256K: depth 262144, 20-bit ids.
//
// The address/pointer width is 18 bits (2^18 entries), the payload is a 20-bit
// object id.  Keep the array in a clock-only block: an async-reset block would
// force Vivado to dissolve it into flip-flops.
module gc_queue (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        clear,

    input  wire [17:0] waddr,
    input  wire [19:0] wdata,
    input  wire        we,

    input  wire        en,
    output reg  [19:0] rdata,
    output reg         rvalid,

    output reg  [17:0] head,
    output reg  [17:0] tail,
    output wire        empty,
    output wire        full,
    output reg  [18:0] count
);

    localparam integer DEPTH = 262144;

    (* ram_style = "block" *)
    reg [19:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        if (we)
            mem[waddr] <= wdata;
    end

    always @(posedge clk) begin
        rdata <= mem[head];
    end

    assign empty = (count == 19'd0);
    assign full  = (count == DEPTH[18:0]);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head   <= 18'd0;
            tail   <= 18'd0;
            rvalid <= 1'b0;
            count  <= 19'd0;
        end else if (clear) begin
            head   <= 18'd0;
            tail   <= 18'd0;
            rvalid <= 1'b0;
            count  <= 19'd0;
        end else begin
            rvalid <= en && (count != 19'd0);
            if (we && (count != DEPTH[18:0]))
                tail <= waddr + 18'd1;
            if (en && (count != 19'd0))
                head <= head + 18'd1;

            case ({we && (count != DEPTH[18:0]), en && (count != 19'd0)})
                2'b10:   count <= count + 19'd1;
                2'b01:   count <= count - 19'd1;
                default: count <= count;
            endcase
        end
    end

endmodule
