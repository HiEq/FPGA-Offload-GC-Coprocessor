// gc_push_fifo.v - two-entry push queue between the lane arbiter and the
// object queue.
//
// The 150 MHz timing report's worst path ran from the bitmap BRAM output,
// through the lane decision + arbiter, straight into the object queue's write
// enable (7.9 ns, 5.7 ns of it routing).  The single-lane design had a
// registered q_push between those two memories; this FIFO restores that stage.
//
// The head is presented to the object queue combinationally (q_we/q_wdata) and
// is popped at the edge; the tail accepts one push per cycle while cnt < 2.
// `ready` is the arbiter's grant condition, so a full FIFO back-pressures the
// lanes instead of dropping an object.
module gc_push_fifo (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        clear,

    input  wire        push,
    input  wire [19:0] id,
    output wire        ready,

    input  wire        q_full,
    output wire        q_we,
    output wire [19:0] q_wdata,
    output wire        empty
);

    reg  [20:0] mem [0:1];       // {valid, id}; valid is bit 20
    reg  [1:0]  cnt;
    reg  [1:0]  head;

    wire [1:0] tail = head + cnt;
    wire       pop  = (cnt != 2'd0) && !q_full;
    wire       put  = push && (cnt != 2'd2);

    assign q_we    = pop;
    assign q_wdata = mem[head[0]][19:0];
    assign ready   = (cnt != 2'd2);
    assign empty   = (cnt == 2'd0);

    always @(posedge clk) begin
        if (put)
            mem[tail[0]] <= {1'b1, id};
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt  <= 2'd0;
            head <= 2'd0;
        end else if (clear) begin
            cnt  <= 2'd0;
            head <= 2'd0;
        end else begin
            if (pop)
                head <= head + 2'd1;
            cnt <= cnt + (put ? 2'd1 : 2'd0) - (pop ? 2'd1 : 2'd0);
        end
    end

endmodule
