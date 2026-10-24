`timescale 1ns/1ps
// ============================================================
// tb_regs_aww.v — AW/W pairing contract of the AXI-Lite register block.
//
// Why this exists (AGENTS #20): on this board a DIRTY_PUSH record can be
// forged or lost.  One hypothesis was that gc_regs pairs a W beat with the
// wrong AW ("last latched address wins" + the platform's non-adjacent
// redelivery).  This TB pins what the block actually guarantees:
//
//   P1  a matched AW+W pair writes its register / fires its push with the
//       id it carried;
//   P2  the platform's normal duplication (the same store twice, adjacent)
//       fires the push exactly once (the command tag rule);
//   P3  a W beat is NEVER consumed without a pending AW: WREADY stays low and
//       no register changes (so addresses cannot run ahead of data);
//   P4  (INFO only) a foreign WDATA that lands after a DPUSH AW is accepted
//       as a record carrying that foreign id, and a W beat held while no AW
//       was pending is attributed to the NEXT accepted AW;
//   P5  DIRTY_STAT[31:20]/[19:16] report the accepted push (id-level ack);
//   P6  a forged push is visible in that ack, i.e. the software can detect it.
//
// P4 is the pins-level limit, not a fixable defect: a slave cannot tell which
// master-side store a W beat belongs to, and the block already allows only one
// transaction at a time (AWREADY = ~aw_pending & ~BVALID), i.e. it applies the
// standard AXI requirement that write data is ordered like write addresses.
// If the interconnect ever breaks that order, the software contract must treat
// a dirty record as advisory (AGENTS #20 records the residual risk).
//
// Unfixed/fixed distinction: this TB is GREEN on the current RTL -- it is the
// evidence for the attribution above, and a guard against an "AW FIFO" style
// refactor that would weaken the one-transaction-at-a-time pairing.
// ============================================================
module tb_regs_aww;

    reg clk = 1'b0;
    reg rstn = 1'b1;
    always #5 clk = ~clk;              // 100 MHz, same as the PL

    // watchdog: a hang must report as a failed test, not as a stalled run
    initial begin
        #200000;
        $display("[AW-W][FAIL] watchdog fired: the TB did not reach its verdict");
        $finish;
    end

    // ---- AXI-Lite write channel ----
    reg  [11:0] AWADDR  = 12'h0;
    reg         AWVALID = 1'b0;
    wire        AWREADY;
    reg  [31:0] WDATA   = 32'h0;
    reg  [3:0]  WSTRB   = 4'h0;
    reg         WVALID  = 1'b0;
    wire        WREADY;
    wire [1:0]  BRESP;
    wire        BVALID;
    reg         BREADY  = 1'b0;

    // ---- AXI-Lite read channel (unused here) ----
    reg  [11:0] ARADDR  = 12'h0;
    reg         ARVALID = 1'b0;
    wire        ARREADY;
    wire [31:0] RDATA;
    wire [1:0]  RRESP;
    wire        RVALID;
    reg         RREADY  = 1'b0;

    // ---- register block outputs ----
    wire        reg_abort;
    wire [31:0] reg_obj_base;
    wire [31:0] reg_obj_count;
    wire [31:0] reg_root_count;
    wire        reg_start;
    wire        reg_clear_q;
    wire        reg_bm_keep;
    wire [11:0] reg_bm_addr;
    wire        reg_free_pop;
    wire        reg_dirty_push;
    wire [11:0] reg_dirty_push_id;
    wire        reg_dirty_flush;
    wire [7:0]  root_wr_addr;
    wire [31:0] root_wr_data;
    wire        root_we;

    gc_regs dut (
        .ACLK            (clk),
        .ARESETN         (rstn),
        .AWADDR          (AWADDR),
        .AWVALID         (AWVALID),
        .AWREADY         (AWREADY),
        .WDATA           (WDATA),
        .WSTRB           (WSTRB),
        .WVALID          (WVALID),
        .WREADY          (WREADY),
        .BRESP           (BRESP),
        .BVALID          (BVALID),
        .BREADY          (BREADY),
        .ARADDR          (ARADDR),
        .ARVALID         (ARVALID),
        .ARREADY         (ARREADY),
        .RDATA           (RDATA),
        .RRESP           (RRESP),
        .RVALID          (RVALID),
        .RREADY          (RREADY),
        .reg_abort       (reg_abort),
        .reg_obj_base    (reg_obj_base),
        .reg_obj_count   (reg_obj_count),
        .reg_root_count  (reg_root_count),
        .reg_start       (reg_start),
        .reg_clear_q     (reg_clear_q),
        .reg_done        (1'b0),
        .reg_marked_count(32'h0),
        .reg_cycles      (32'h0),
        .q_head          (12'h0),
        .q_tail          (12'h0),
        .err_ovf         (1'b0),
        .err_rd          (1'b0),
        .err_ref         (1'b0),
        .err_hdr         (1'b0),
        .reg_idle        (1'b1),
        .reg_bm_addr     (reg_bm_addr),
        .reg_bm_data     (32'h0),
        .reg_free_count  (32'h0),
        .reg_free_data   (12'h0),
        .reg_free_busy   (1'b0),
        .reg_free_pop    (reg_free_pop),
        .reg_dirty_push  (reg_dirty_push),
        .reg_dirty_push_id(reg_dirty_push_id),
        .reg_dirty_flush (reg_dirty_flush),
        .reg_bm_keep     (reg_bm_keep),
        .dirty_count     (9'h0),
        .dirty_empty     (1'b1),
        .dirty_ovf       (1'b0),
        .dirty_drained   (32'h0),
        .dirty_pushed    (16'h0),
        .dirty_popped    (16'h0),
        .root_wr_addr    (root_wr_addr),
        .root_wr_data    (root_wr_data),
        .root_we         (root_we)
    );

    // ---- push monitor ----
    integer    npush   = 0;
    reg [11:0] last_id = 12'h0;
    integer    fails   = 0;

    always @(posedge clk) begin
        if (reg_dirty_push) begin
            npush   = npush + 1;
            last_id = reg_dirty_push_id;
            $display("[AW-W][INFO] push #%0d: id=%0d", npush, reg_dirty_push_id);
        end
    end

    task fail(input [1023:0] what);
        begin
            fails = fails + 1;
            $display("[AW-W][FAIL] %0s", what);
        end
    endtask

    // one AW beat: drive at a negedge, sample READY mid-cycle (before the edge)
    task aw(input [11:0] a);
        begin
            AWADDR = a; AWVALID = 1'b1;
            while (AWREADY !== 1'b1) @(negedge clk);
            @(posedge clk);                 // the transfer happens here
            @(negedge clk);
            AWVALID = 1'b0;
        end
    endtask

    // one W beat
    task w(input [31:0] d);
        begin
            WDATA = d; WSTRB = 4'hF; WVALID = 1'b1;
            while (WREADY !== 1'b1) @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            WVALID = 1'b0;
        end
    endtask

    // wait for the write response and retire it
    task resp;
        begin
            while (BVALID !== 1'b1) @(negedge clk);
            BREADY = 1'b1;
            @(posedge clk);
            @(negedge clk);
            BREADY = 1'b0;
        end
    endtask

    // one AXI read
    reg [31:0] rd_data;
    integer    ack_tag, ack_id;

    task rd(input [11:0] a);
        begin
            ARADDR = a; ARVALID = 1'b1;
            while (ARREADY !== 1'b1) @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            ARVALID = 1'b0;
            while (RVALID !== 1'b1) @(negedge clk);
            rd_data = RDATA;
            RREADY = 1'b1;
            @(posedge clk);
            @(negedge clk);
            RREADY = 1'b0;
        end
    endtask

    task aw_w(input [11:0] a, input [31:0] d);
        begin
            aw(a); w(d); resp;
        end
    endtask

    integer p1_npush;
    integer p2_npush;

    initial begin
        $display("[AW-W] tb_regs_aww: AW/W pairing contract of gc_regs");
        rstn = 1'b0;                        // real 1->0 edge so the reset branch runs
        repeat (4) @(negedge clk);
        rstn = 1'b1;
        repeat (2) @(negedge clk);

        // ---- P1: matched pairs do what they say -------------------------
        aw_w(12'h440, 32'h0000_1028);           // DPUSH tag=1 id=0x028 (40)
        aw_w(12'h008, 32'd64);                  // OBJ_COUNT = 64
        p1_npush = npush;
        if (p1_npush != 1)      fail("P1: a matched DPUSH pair must fire exactly one push");
        if (last_id != 12'd40)  fail("P1: the push must carry the id the store wrote (40)");
        if (reg_obj_count != 32'd64) fail("P1: a matched OBJ_COUNT pair must write 64");
        $display("[AW-W] P1 matched pairs: pushes=%0d last_id=%0d obj_count=%0d (expect 1/40/64)",
                 p1_npush, last_id, reg_obj_count);

        // ---- P2: the platform's duplication is ignored by the tag rule --
        aw_w(12'h440, 32'h0000_2029);           // new tag (2), id=41
        aw_w(12'h440, 32'h0000_2029);           // the duplicate delivery
        p2_npush = npush - p1_npush;
        if (p2_npush != 1)     fail("P2: the duplicate delivery of one store must not double the record");
        if (last_id != 12'd41) fail("P2: the accepted record must be the new one (41)");
        $display("[AW-W] P2 duplicated store: pushes=%0d last_id=%0d (expect 1/41)", p2_npush, last_id);

        // ---- P3: no W beat without a pending AW -------------------------
        WDATA = 32'h0000_00AA; WSTRB = 4'hF; WVALID = 1'b1;
        repeat (3) begin
            @(negedge clk);
            if (WREADY !== 1'b0)          fail("P3: WREADY must stay low with no pending AW");
            if (reg_obj_count !== 32'd64) fail("P3: no register may change before an AW is accepted");
        end
        WVALID = 1'b0;
        @(negedge clk);
        $display("[AW-W] P3 W held with no pending AW: WREADY stayed low, obj_count=%0d (expect 64)",
                 reg_obj_count);

        // ---- P4: INFO -- what a channel mismatch does -------------------
        // (a) a foreign WDATA on the DPUSH address becomes a record;
        aw(12'h440);
        w(32'h0000_0040);                       // 64: a COUNT-shaped WDATA
        resp;
        $display("[AW-W][INFO] foreign WDATA on 0x440 -> push #%0d id=%0d (a forged record)",
                 npush, last_id);
        // (b) a W beat held with no pending AW is attributed to the next AW.
        WDATA = 32'h0000_BEEF; WSTRB = 4'hF; WVALID = 1'b1;
        repeat (2) @(negedge clk);
        aw(12'h008);
        w(32'h0000_BEEF);
        resp;
        $display("[AW-W][INFO] held W attributed to the next AW -> obj_count=0x%08X (a mismatched write)",
                 reg_obj_count);

        // ---- P5: the id-level ack reports what the FIFO accepted --------
        aw_w(12'h440, 32'h0000_302A);               // tag 3, id 42
        rd(12'h444);
        ack_tag = (rd_data >> 16) & 15;
        ack_id  = (rd_data >> 20) & 4095;
        if (ack_tag !== 3 || ack_id !== 42)
            fail("P5: DIRTY_STAT[31:20]/[19:16] must report the accepted push");
        $display("[AW-W] P5 ack: tag=%0d id=%0d (expect 3/42)", ack_tag, ack_id);

        // ---- P6: a forged push becomes VISIBLE in the ack (the detector) --
        aw(12'h440);
        w(32'h0000_0040);                           // foreign WDATA: tag 0, id 64
        resp;
        rd(12'h444);
        ack_tag = (rd_data >> 16) & 15;
        ack_id  = (rd_data >> 20) & 4095;
        if (ack_id !== 64)
            fail("P6: the ack must expose the forged id so the software can react");
        $display("[AW-W] P6 forged push visible in the ack: tag=%0d id=%0d (expect 0/64)",
                 ack_tag, ack_id);

        // ---- verdict ----------------------------------------------------
        if (fails == 0) $display("[AW-W] ==================== PASS ====================");
        else            $display("[AW-W] %0d assertion(s) failed", fails);
        $finish;
    end

endmodule