// gc_lane.v - one reference-decision lane.
//
// Throughput: one reference per cycle.  Three-stage pipeline:
//   A : accept a ref, latch its bank-relative word address (addr_a)
//   D : bitmap data for that ref is valid; compute marked/want
//   C : commit -- register the new word, then write the bitmap and offer the
//       id to gc_push_arb one cycle later
//
// The extra C stage exists for timing: the 150 MHz report's long path ran from
// the bitmap BRAM output through the decision and arbiter straight into another
// BRAM.  The bitmap write now comes from C's registers; the bitmap read only
// feeds D's local decision logic.  The push FIFO (gc_push_fifo) breaks the other
// half of that path.
//
// Read-after-write: D's read may have been latched before C's write, so D
// forwards C's pending word when the addresses match (c_hit), and keeps the
// older commit in we_r/wa_r/wd_r for one more cycle.
//
// Back-pressure: when C needs a push and the arbiter does not grant, the whole
// pipeline freezes and C keeps push_req/push_id asserted.  q_full is different:
// the object cannot be queued at all, so C drops it, pulses ovf, and advances.
//
// Lane k must only be fed ids whose bank bits select bank k:
//   SEL=1 (2 lanes): bank = id[5]
//   SEL=2 (4 lanes): bank = id[6:5]
module gc_lane #(
    parameter integer SEL = 1,          // log2(LANES)
    parameter integer AW  = 15 - SEL    // bank address width
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        clear,

    input  wire [31:0] obj_count,      // ids >= obj_count are skipped

    input  wire        in_valid,
    input  wire [19:0] in_id,
    output wire        in_ready,

    output wire [AW-1:0] bm_raddr,     // read address (word >> SEL)
    output wire [AW-1:0] bm_waddr,
    output wire        bm_we,
    output wire [31:0] bm_wdata,
    input  wire [31:0] bm_rdata,

    output wire        push_req,
    output wire [19:0] push_id,
    input  wire        push_grant,

    input  wire        q_full,
    output wire        marked_pulse,   // 1 cycle per newly marked object
    output wire        ovf_pulse,      // 1 cycle per dropped object

    output wire        idle            // nothing accepted/in flight
);

    // A: accept
    reg  [19:0]   id_a;
    reg  [AW-1:0] addr_a;
    reg           dv_a;

    // D: decision
    reg  [19:0]   id_d;
    reg  [AW-1:0] addr_d;
    reg           dv_d;

    // C: commit
    reg  [19:0]   id_c;
    reg  [AW-1:0] addr_c;
    reg           c_valid;
    reg           c_push;
    reg  [31:0]   c_word;

    // older commit (one cycle behind C)
    reg           we_r;
    reg  [AW-1:0] wa_r;
    reg  [31:0]   wd_r;

    // D's read word, captured if C stalls
    reg           hold;
    reg  [31:0]   bmd_hold;

    wire [31:0] dec_word = hold ? bmd_hold : bm_rdata;
    wire        c_hit    = c_valid && c_push && !q_full && (addr_c == addr_d);
    wire [31:0] rd_eff   = c_hit ? c_word :
                           ((we_r && (wa_r == addr_d)) ? wd_r : dec_word);
    wire [4:0]  bit_sel  = id_d[4:0];
    wire        marked   = rd_eff[bit_sel];
    wire        in_range = (id_d < obj_count);

    wire        want     = dv_d && in_range && !marked;
    wire        c_stall  = c_push && !q_full && !push_grant;
    wire        issue    = c_push && !q_full && push_grant;
    wire        drop     = c_push && q_full;
    wire        adv      = !c_stall;

    assign in_ready = adv;

    assign bm_raddr  = addr_a;
    assign bm_waddr  = addr_c;
    assign bm_we     = issue;
    assign bm_wdata  = c_word;

    assign push_req     = c_push && !q_full;
    assign push_id      = id_c;
    assign marked_pulse = issue;
    assign ovf_pulse    = drop;
    assign idle         = !dv_a && !dv_d && !c_valid && !c_stall;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            id_a <= 20'd0;
            addr_a <= {AW{1'b0}};
            dv_a <= 1'b0;
            id_d <= 20'd0;
            addr_d <= {AW{1'b0}};
            dv_d <= 1'b0;
            id_c <= 20'd0;
            addr_c <= {AW{1'b0}};
            c_valid <= 1'b0;
            c_push <= 1'b0;
            c_word <= 32'd0;
            we_r <= 1'b0;
            wa_r <= {AW{1'b0}};
            wd_r <= 32'd0;
            hold <= 1'b0;
            bmd_hold <= 32'd0;
        end else if (clear) begin
            dv_a <= 1'b0;
            dv_d <= 1'b0;
            c_valid <= 1'b0;
            c_push <= 1'b0;
            we_r <= 1'b0;
            hold <= 1'b0;
        end else if (c_stall) begin
            // Freeze A/D/C; keep D's read word and C's pending push.
            if (!hold) begin
                hold <= 1'b1;
                bmd_hold <= rd_eff;
            end
        end else begin
            hold <= 1'b0;

            // C retires this cycle (write/push are combinational above).
            we_r <= issue;
            if (issue) begin
                wa_r <= addr_c;
                wd_r <= c_word;
            end

            // D -> C
            id_c    <= id_d;
            addr_c  <= addr_d;
            c_valid <= dv_d;
            c_push  <= want;
            c_word  <= rd_eff | (32'd1 << bit_sel);

            // A -> D
            id_d   <= id_a;
            addr_d <= addr_a;
            dv_d   <= dv_a;

            // accept
            if (in_valid && in_ready) begin
                id_a   <= in_id;
                addr_a <= in_id[19:5 + SEL];
                dv_a   <= 1'b1;
            end else begin
                dv_a   <= 1'b0;
            end
        end
    end

endmodule
