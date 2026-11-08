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
//   object o -> word mem[o>>5], valid bit = o[4:0]
// The scan reads one 32-bit word and extracts every zero bit with a
// priority encoder (lowest id first), so the cost is ~2 cycles per
// word plus one per free id, instead of 3 cycles per object id.
//
// The scanner borrows the bitmap read port while `busy` is high;
// gc_top muxes the port so the engine/probe keep their own paths
// outside the scan window.
//
// Clock/reset: single clock, async active-low reset, same domain
// as the mark engine and bitmap.
//
// Scan latency: obj_count=1048576 -> 32768 words -> ~66k cycles
// (~0.7 ms at 100 MHz) when the heap is mostly live, versus 3.0M
// cycles for the per-id scan.
// ============================================================
module gc_freelist (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,        // 1-cycle: a new mark run started
    input  wire        done,         // level: mark engine reached S_DONE
    input  wire [31:0] obj_count,    // 0..1048576

    output reg  [14:0] bm_raddr,     // bitmap read address (borrowed port)
    input  wire [31:0] bm_rdata,     // 1 cycle after bm_raddr

    output reg  [31:0] free_count,   // number of ids in the list
    output wire [19:0] free_data,    // id at the pop pointer
    input  wire        pop,          // 1-cycle: software consumed one id
    output reg         busy          // 1 while the scanner owns the bitmap
);

    localparam [2:0] F_IDLE = 3'd0, F_RD = 3'd1, F_WAIT = 3'd2,
                     F_LAT  = 3'd3, F_POP = 3'd4;

    (* ram_style = "block" *)
    reg [19:0] mem [0:262143];

    reg [17:0] wr_ptr;               // scanner push pointer
    reg [17:0] rd_ptr;               // software pop pointer
    reg [18:0] cnt;                  // 0..262144
    reg [14:0] word_idx;             // bitmap word being tested
    reg [31:0] word_r;               // zero bits still to drain
    reg [2:0]  fsm;
    reg        scan_started;         // one scan per run (done is level-high)
    reg [19:0] free_data_r;

    wire [19:0] cnt20   = {1'b0, cnt};
    wire [31:0] cntw    = (obj_count + 32'd31) >> 5;   // words to scan
    wire [31:0] id20    = {word_idx, 5'd0};
    wire [4:0]  bit_idx = word_r[0] ? 5'd0 :
                          word_r[1] ? 5'd1 :
                          word_r[2] ? 5'd2 :
                          word_r[3] ? 5'd3 :
                          word_r[4] ? 5'd4 :
                          word_r[5] ? 5'd5 :
                          word_r[6] ? 5'd6 :
                          word_r[7] ? 5'd7 :
                          word_r[8] ? 5'd8 :
                          word_r[9] ? 5'd9 :
                          word_r[10] ? 5'd10 :
                          word_r[11] ? 5'd11 :
                          word_r[12] ? 5'd12 :
                          word_r[13] ? 5'd13 :
                          word_r[14] ? 5'd14 :
                          word_r[15] ? 5'd15 :
                          word_r[16] ? 5'd16 :
                          word_r[17] ? 5'd17 :
                          word_r[18] ? 5'd18 :
                          word_r[19] ? 5'd19 :
                          word_r[20] ? 5'd20 :
                          word_r[21] ? 5'd21 :
                          word_r[22] ? 5'd22 :
                          word_r[23] ? 5'd23 :
                          word_r[24] ? 5'd24 :
                          word_r[25] ? 5'd25 :
                          word_r[26] ? 5'd26 :
                          word_r[27] ? 5'd27 :
                          word_r[28] ? 5'd28 :
                          word_r[29] ? 5'd29 :
                          word_r[30] ? 5'd30 : 5'd31;

    wire [19:0] push_id = id20 | {15'd0, bit_idx};
    wire        push    = (fsm == F_POP) && (word_r != 32'd0) &&
                          (push_id < obj_count[19:0]) &&
                          (cnt20 < 20'd262144);
    wire        pop_ok  = pop && (cnt != 19'd0);

    assign free_data = free_data_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bm_raddr     <= 15'd0;
            free_count   <= 32'd0;
            busy         <= 1'b0;
            fsm          <= F_IDLE;
            wr_ptr       <= 18'd0;
            rd_ptr       <= 18'd0;
            cnt          <= 19'd0;
            word_idx     <= 15'd0;
            word_r       <= 32'd0;
            scan_started <= 1'b0;
        end else if (start) begin
            // A new mark run: drop the previous list and re-arm the scan.
            wr_ptr       <= 18'd0;
            rd_ptr       <= 18'd0;
            cnt          <= 19'd0;
            busy         <= 1'b0;
            fsm          <= F_IDLE;
            bm_raddr     <= 15'd0;
            word_idx     <= 15'd0;
            word_r       <= 32'd0;
            scan_started <= 1'b0;
        end else begin
            // Default free_count mirror.
            free_count <= {13'd0, cnt};

            if (push) begin
                wr_ptr <= wr_ptr + 18'd1;
            end
            if (pop_ok) begin
                rd_ptr <= rd_ptr + 18'd1;
            end
            if (push && !pop_ok)      cnt <= cnt + 19'd1;
            else if (!push && pop_ok) cnt <= cnt - 19'd1;

            case (fsm)
                F_IDLE: begin
                    if (done && !scan_started && cntw != 32'd0) begin
                        scan_started <= 1'b1;
                        busy     <= 1'b1;
                        word_idx <= 15'd0;
                        fsm      <= F_RD;
                    end
                end

                F_RD: begin
                    // bm_raddr must stay stable through F_WAIT.
                    bm_raddr <= word_idx;
                    fsm      <= F_WAIT;
                end

                F_WAIT: begin
                    // The bitmap output register is one cycle behind its
                    // address.
                    fsm <= F_LAT;
                end

                F_LAT: begin
                    // bm_rdata is valid for the word addressed in F_RD.
                    // Bit 1 = marked, so the free ids are the ZERO bits.
                    word_r <= ~bm_rdata;
                    fsm    <= F_POP;
                end

                F_POP: begin
                    if (word_r != 32'd0) begin
                        // Push the lowest unmarked id, then clear that bit.
                        word_r <= word_r & (word_r - 32'd1);
                    end else if ({17'd0, word_idx} + 18'd1 >= cntw[17:0]) begin
                        busy <= 1'b0;
                        fsm  <= F_IDLE;
                    end else begin
                        word_idx <= word_idx + 15'd1;
                        fsm      <= F_RD;
                    end
                end

                default: fsm <= F_IDLE;
            endcase
        end
    end

    // Clock-only ports: keeps mem inferable as block RAM.
    always @(posedge clk) begin
        if (push)
            mem[wr_ptr] <= push_id;
        free_data_r <= mem[rd_ptr];
    end

endmodule
