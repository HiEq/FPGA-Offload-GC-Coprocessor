// tb_gc_lane.v - directed tests for one ref lane (SEL=1, bank 0 only).
//
// Covers: fresh mark, duplicate (bitmap + bypass), same-word consecutive bits,
// exact-duplicate stream, out-of-range ids, queue-full drop, and push
// back-pressure (the lane must hold its decision and stop accepting).
//
// Bank-0 ids have id[5]=0; the lane's word address is id[19:6] (SEL=1), so the
// test memory is indexed by id>>6 and the bit is id[4:0].
`timescale 1ns/1ps
module tb_gc_lane;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;
    reg clear = 1'b0;

    reg  [31:0] obj_count = 32'h0000_1000;
    reg  [19:0] refs [0:63];
    integer     n_refs = 0;
    integer     sent = 0;
    reg         stream_en = 1'b0;

    wire        in_valid = stream_en && (sent < n_refs);
    wire [19:0] in_id    = refs[sent];
    wire        in_ready;

    wire [13:0] bm_raddr, bm_waddr;
    wire        bm_we;
    wire [31:0] bm_wdata;

    reg  [31:0] bm [0:16383];
    reg  [31:0] rd_q;
    wire [31:0] bm_rdata = rd_q;
    always @(posedge clk) rd_q <= bm[bm_raddr];
    always @(posedge clk) if (bm_we) bm[bm_waddr] <= bm_wdata;

    wire        push_req;
    wire [19:0] push_id;
    reg         grant_en = 1'b1;
    wire        push_grant = grant_en && push_req;
    reg         q_full = 1'b0;

    wire        marked_pulse, ovf_pulse, idle;

    gc_lane #(.SEL(1)) dut (
        .clk(clk), .rst_n(rst_n), .clear(clear),
        .obj_count(obj_count),
        .in_valid(in_valid), .in_id(in_id), .in_ready(in_ready),
        .bm_raddr(bm_raddr), .bm_waddr(bm_waddr),
        .bm_we(bm_we), .bm_wdata(bm_wdata), .bm_rdata(bm_rdata),
        .push_req(push_req), .push_id(push_id), .push_grant(push_grant),
        .q_full(q_full),
        .marked_pulse(marked_pulse), .ovf_pulse(ovf_pulse), .idle(idle)
    );

    integer pushes = 0;
    integer ovfs = 0;
    always @(posedge clk) begin
        if (bm_we) begin
            pushes = pushes + 1;
`ifdef LANE_DBG
            $display("  push id=%h addr=%h data=%h", push_id, bm_waddr, bm_wdata);
`endif
        end
        if (ovf_pulse) ovfs = ovfs + 1;
        if (in_valid && in_ready) sent <= sent + 1;
    end

    integer errs = 0;
    integer p0, o0;
    integer i;

    task chk(input cond, input [255:0] msg);
        begin
            if (!cond) begin
                $display("[LANE][FAIL] %0s", msg);
                errs = errs + 1;
            end
        end
    endtask

    task idle_clear;
        begin
            @(negedge clk); clear = 1'b1;
            @(negedge clk); clear = 1'b0;
            @(negedge clk);
        end
    endtask

    task run(input integer n);
        begin
            @(negedge clk);
            n_refs = n;
            sent = 0;
            stream_en = 1'b1;
            wait (sent == n_refs);
            @(posedge clk);
            wait (idle);
            @(negedge clk);
            stream_en = 1'b0;
        end
    endtask

    initial begin
        for (i = 0; i < 16384; i = i + 1) bm[i] = 32'd0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ---- P1: fresh + duplicate + same word ----
        idle_clear;
        refs[0] = 20'h00020; refs[1] = 20'h00021; refs[2] = 20'h00040;
        refs[3] = 20'h00020; refs[4] = 20'h00021;
        p0 = pushes;
        run(5);
        chk(pushes - p0 == 3, "P1 push count != 3");
        chk(bm[0] === 32'h0000_0003, "P1 addr0 != 0x3");
        chk(bm[1] === 32'h0000_0001, "P1 addr1 != 0x1");

        // ---- P2: three consecutive bits in one word ----
        idle_clear;
        refs[0] = 20'h00080; refs[1] = 20'h00081; refs[2] = 20'h00082;
        p0 = pushes;
        run(3);
        chk(pushes - p0 == 3, "P2 push count != 3");
        chk(bm[2] === 32'h0000_0007, "P2 addr2 != 0x7 (bypass)");

        // ---- P3: 32 consecutive bits, one word ----
        idle_clear;
        for (i = 0; i < 32; i = i + 1) refs[i] = 20'h00100 + i;
        p0 = pushes;
        run(32);
        chk(pushes - p0 == 32, "P3 push count != 32");
        chk(bm[4] === 32'hFFFF_FFFF, "P3 addr4 != 0xFFFFFFFF (bypass)");

        // ---- P4: alternating duplicates, same word ----
        idle_clear;
        for (i = 0; i < 16; i = i + 1) refs[i] = (i[0]) ? 20'h00141 : 20'h00140;
        p0 = pushes;
        run(16);
        chk(pushes - p0 == 2, "P4 push count != 2 (duplicate)");
        chk(bm[5] === 32'h0000_0003, "P4 addr5 != 0x3");

        // ---- P5: out-of-range ids are skipped, no write ----
        idle_clear;
        refs[0] = 20'h01000; refs[1] = 20'hFFFFF; refs[2] = 20'h01001;
        p0 = pushes;
        run(3);
        chk(pushes - p0 == 0, "P5 out-of-range pushed");
        chk(bm[64] === 32'd0, "P5 out-of-range wrote bitmap");
        chk(bm[16383] === 32'd0, "P5 sentinel wrote bitmap");

        // ---- P6: queue full drops, then the same id marks ----
        idle_clear;
        p0 = pushes; o0 = ovfs;
        q_full = 1'b1;
        refs[0] = 20'h00180;
        run(1);
        chk(pushes - p0 == 0, "P6 full still pushed");
        chk(ovfs - o0 == 1, "P6 full did not pulse ovf");
        chk(bm[6] === 32'd0, "P6 full wrote bitmap");
        q_full = 1'b0;
        p0 = pushes;
        refs[0] = 20'h00180;
        run(1);
        chk(pushes - p0 == 1, "P6 retry did not push");
        chk(bm[6] === 32'h1, "P6 retry did not set bit");

        // ---- P7: push back-pressure freezes the lane ----
        idle_clear;
        for (i = 0; i < 5; i = i + 1) refs[i] = 20'h001C0 + i;
        n_refs = 5; sent = 0; stream_en = 1'b1;
        grant_en = 1'b0;
        p0 = pushes;
        wait (sent == 3);
        repeat (4) @(posedge clk);
        chk(sent == 3, "P7 accepted while stalled");
        chk(push_req === 1'b1, "P7 push_req not held");
        chk(pushes - p0 == 0, "P7 push escaped without grant");
        grant_en = 1'b1;
        wait (sent == n_refs);
        @(posedge clk);
        wait (idle);
        @(negedge clk);
        stream_en = 1'b0;
        chk(pushes - p0 == 5, "P7 push count != 5 after grant");
        chk(bm[7] === 32'h0000_001F, "P7 addr7 != 0x1F");

        @(posedge clk);
        chk(idle === 1'b1, "P8 not idle at end");

        if (errs == 0) $display("LANE_RESULT OK");
        else           $display("LANE_RESULT FAIL %0d", errs);
        $finish;
    end

endmodule
