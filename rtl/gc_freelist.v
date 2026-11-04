// ============================================================
// gc_freelist.v - free-object list builder (Phase 2)
//
// After the mark engine asserts `done`, scan the mark bitmap once.
// Every object id in [0, obj_count) whose mark bit is 0 is pushed
// into a 4096 x 12 BRAM free-list.  Software reads FREE_COUNT and
// then pops FREE_DATA (one read per id).
//
// Bitmap layout (must match gc_mark_engine, the 0x24/0x28 probe and
// gc_test.py / fpga_gc.c):
//   object o -> word mem[o], valid bit = o[4:0]
// so the scan reads one word per object id and tests that object's
// own bit.  (A packed scan -- word o>>5, bit o&31 -- reads mem[o>>5]
// and reports garbage; sim/tb_gc_top.v T-FREE pins this layout.)
//
// The scanner borrows the bitmap read port while `busy` is high;
// gc_top muxes the port so the engine/probe keep their own paths
// outside the scan window.
//
// Clock/reset: single clock, async active-low reset, same domain
// as the mark engine and bitmap.
//
// Scan latency: 3 cycles per object id (F_RD -> F_WAIT -> F_CHK),
// i.e. obj_count=4096 -> ~12.3k cycles.
// ============================================================
module gc_freelist (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,        // 1-cycle: a new mark run started
    input  wire        done,         // level: mark engine reached S_DONE
    input  wire [31:0] obj_count,    // 0..65536

    output reg  [10:0] bm_raddr,     // bitmap read address (borrowed port)
    input  wire [31:0] bm_rdata,     // 1 cycle after bm_raddr

    output reg  [31:0] free_count,   // number of ids in the list
    output wire [15:0] free_data,    // id at the pop pointer
    input  wire        pop,          // 1-cycle: software consumed one id
    output reg         busy          // 1 while the scanner owns the bitmap
);

    localparam [1:0] F_IDLE = 2'd0, F_RD = 2'd1, F_WAIT = 2'd2, F_CHK = 2'd3;

    (* ram_style = "block" *)
    reg [15:0] mem [0:65535];

    reg [15:0] wr_ptr;               // scanner push pointer
    reg [15:0] rd_ptr;               // software pop pointer
    reg [16:0] cnt;                  // 0..65536
    reg [15:0] obj_idx;              // object id being tested
    reg        scan_started;
    reg [1:0]  fsm;
    reg [15:0] free_data_r;

    wire [16:0] idx17  = {1'b0, obj_idx};
    wire [16:0] cnt17  = obj_count[16:0];
    wire        push   = (fsm == F_CHK) && (idx17 < cnt17) &&
                         (bm_rdata[obj_idx[4:0]] == 1'b0);
    wire        pop_ok = pop && (cnt != 17'd0);

    assign free_data = free_data_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bm_raddr     <= 11'd0;
            free_count   <= 32'd0;
            busy         <= 1'b0;
            fsm          <= F_IDLE;
            wr_ptr       <= 16'd0;
            rd_ptr       <= 16'd0;
            cnt          <= 17'd0;
            obj_idx      <= 16'd0;
            scan_started <= 1'b0;
        end else if (start) begin
            // A new mark run: drop the previous list and re-arm the scan.
            wr_ptr       <= 16'd0;
            rd_ptr       <= 16'd0;
            cnt          <= 17'd0;
            busy         <= 1'b0;
            scan_started <= 1'b0;
            fsm          <= F_IDLE;
            bm_raddr     <= 11'd0;
        end else begin
            // Default free_count mirror.
            free_count <= {15'd0, cnt};

            // Push the unmarked ids; pop one id per software read.
            // The memory write itself lives in a clock-only block below:
            // an async-reset block prevents BRAM inference (65536x16 is too
            // large to dissolve into registers).
            if (push) begin
                wr_ptr      <= wr_ptr + 16'd1;
            end
            if (pop_ok) begin
                rd_ptr <= rd_ptr + 16'd1;
            end
            if (push && !pop_ok)      cnt <= cnt + 17'd1;
            else if (!push && pop_ok) cnt <= cnt - 17'd1;

            case (fsm)
                F_IDLE: begin
                    if (done && !scan_started) begin
                        scan_started <= 1'b1;
                        busy         <= 1'b1;
                        obj_idx      <= 16'd0;
                        fsm          <= F_RD;
                    end
                end

                F_RD: begin
                    // bm_raddr must stay stable through F_WAIT/F_CHK.
                    if (idx17 < cnt17)
                        bm_raddr <= obj_idx[15:5];
                    fsm <= F_WAIT;
                end

                F_WAIT: begin
                    // The bitmap output register is one cycle behind its
                    // address; wait so F_CHK sees the addressed word.
                    fsm <= F_CHK;
                end

                F_CHK: begin
                    // bm_rdata is valid for the word addressed in F_RD.
                    if (idx17 + 17'd1 >= cnt17) begin
                        busy <= 1'b0;
                        fsm  <= F_IDLE;
                    end else begin
                        obj_idx <= obj_idx + 16'd1;
                        fsm     <= F_RD;
                    end
                end

                default: fsm <= F_IDLE;
            endcase

            // Registered pop-port read (clock-only block below).
        end
    end

    // Clock-only ports: keeps mem inferable as block RAM.
    always @(posedge clk) begin
        if (push)
            mem[wr_ptr] <= obj_idx;
        free_data_r <= mem[rd_ptr];
    end

endmodule