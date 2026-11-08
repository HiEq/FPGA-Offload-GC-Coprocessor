// gc_push_arb.v - N:1 round-robin push arbiter for the single BFS queue.
//
// The lanes decide in parallel but the queue has one write port.  This
// arbiter grants one push per cycle, round-robin, so no lane can starve the
// others.  A lane that is not granted holds its id (back-pressure).
//
// Keeping one 2^19 queue preserves the depth of the single-lane design and
// avoids per-lane overflow when the frontier is skewed.
module gc_push_arb #(
    parameter integer LANES = 2,
    parameter integer SEL   = 1        // log2(LANES)
) (
    input  wire                clk,
    input  wire                rst_n,
    input  wire                clear,

    input  wire [LANES-1:0]    req,
    input  wire [20*LANES-1:0] id,
    input  wire                full,

    output wire [LANES-1:0]    grant,
    output wire                we,
    output wire [19:0]         wdata
);

    reg  [SEL-1:0] rr;
    reg  [SEL-1:0] sel;
    reg  [SEL-1:0] idx;
    integer i;

    // First requester at/after rr: reverse loop so the smallest offset wins.
    always @(*) begin
        sel = rr;
        for (i = LANES - 1; i >= 0; i = i - 1) begin
            idx = rr + i[SEL-1:0];
            if (req[idx])
                sel = idx;
        end
    end

    assign grant = (|req && !full) ? ({{(LANES-1){1'b0}}, 1'b1} << sel) : {LANES{1'b0}};
    assign we    = |grant;
    assign wdata = id[20*sel +: 20];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rr <= {SEL{1'b0}};
        else if (clear)
            rr <= {SEL{1'b0}};
        else if (we)
            rr <= sel + 1'b1;
    end

endmodule
