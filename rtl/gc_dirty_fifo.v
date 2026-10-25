// ============================================================
// gc_dirty_fifo.v — Phase 3A: 屏障脏集入口 (write-barrier dirty set)
//
// Software/the mutator's barrier pushes the ID of every object it wrote to;
// the mark engine treats the FIFO as a work-queue source, so that object is
// re-scanned even when its bitmap bit is already set (forced re-scan).
//
// Depth 256.  A push while full is dropped and latched in `overflow`; the
// software must treat overflow as "the barrier overflowed" and fall back to a
// full mark.  A record is never lost silently without the flag.
//
// The interface is deliberately B-ready: while marking runs concurrently the
// mutator can push at any time and the engine pops whenever it is ready; the
// only extra requirement on the engine side is that termination also waits
// for `empty` (see gc_mark_engine S_POP).
//
// pop is a 1-cycle pulse taken together with the id read; `id` is a
// combinational read of the read pointer, which only advances on pop.
// ============================================================
module gc_dirty_fifo (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        push,
    input  wire [11:0] push_id,
    input  wire        flush,        // 1-cycle: clear contents + overflow

    input  wire        pop,          // 1-cycle: the engine consumed one id
    output wire [11:0] id,           // head id (combinational)
    output wire [8:0]  count,
    output reg  [15:0] pushed = 16'd0, // accepted since the last flush (R: 0x44C)
    output reg  [15:0] popped = 16'd0, // consumed since the last flush (R: 0x450)
    output wire        empty,
    output wire        full,
    output reg         overflow      // sticky until flush
);

    localparam integer DEPTH = 256;
    localparam integer AW    = 8;
    localparam [8:0]   DEPTH9 = DEPTH[8:0];

    (* ram_style = "distributed" *)
    reg [11:0]   mem [0:DEPTH-1];
    reg [AW-1:0] wptr = 8'd0;
    reg [AW-1:0] rptr = 8'd0;
    reg [8:0]    cnt  = 9'd0;

    assign id    = mem[rptr];
    assign count = cnt;
    assign empty = (cnt == 9'd0);
    assign full  = (cnt == DEPTH9);

    wire do_push = push && (cnt != DEPTH9);
    wire do_pop  = pop  && (cnt != 9'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wptr     <= 8'd0;
            rptr     <= 8'd0;
            cnt      <= 9'd0;
            overflow <= 1'b0;
            pushed   <= 16'd0;
            popped   <= 16'd0;
        end else if (flush) begin
            wptr     <= 8'd0;
            rptr     <= 8'd0;
            cnt      <= 9'd0;
            overflow <= 1'b0;
            pushed   <= 16'd0;
            popped   <= 16'd0;
        end else begin
            if (do_push) begin
                mem[wptr] <= push_id;
                wptr      <= wptr + 8'd1;
                pushed    <= pushed + 16'd1;
            end else if (push) begin
                overflow  <= 1'b1;          // full: drop + report
            end

            if (do_pop)
                rptr <= rptr + 8'd1;
            if (do_pop)
                popped <= popped + 16'd1;

            case ({do_push, do_pop})
                2'b10:   cnt <= cnt + 9'd1;
                2'b01:   cnt <= cnt - 9'd1;
                default: cnt <= cnt;
            endcase
        end
    end

endmodule