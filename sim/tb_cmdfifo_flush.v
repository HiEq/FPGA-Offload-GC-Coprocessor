`timescale 1ns/1ps
// ============================================================
// tb_cmdfifo_flush.v — directed test for the command-FIFO half of the
// run_start/abort flush.
//
// The data-beat hole is covered by tb_runstart_race. This TB fills the
// command FIFO with four reads, holds ARREADY low so the first AR waits on
// the bus, then releases ARREADY in the run_start/abort cycle. On the
// unfixed RTL the issue path takes the next queued command in that same
// cycle (c0r <= c0w is overwritten by c0r <= c0r+1); the stale command
// reaches ARADDR. The fixed RTL drops the queued commands and only the
// pre-flush AR completes.
//
// Phase 2 repeats the pulse with cmd_valid asserted on both streams in the
// pulse cycle itself. The flush must own the queue pointers that cycle:
// c0r <= c0w and c0w <= c0w (no enqueue), so the same-cycle command is
// dropped. Without that gate c0w advances past c0r and the next run issues
// the aborted run's command.
// ============================================================
module tb_cmdfifo_flush;

    reg clk = 1'b0;
    reg rstn = 1'b0;
    always #5 clk = ~clk;

    reg         c0v = 1'b0;
    reg  [31:0] c0a = 32'h0;
    wire        c0r;
    wire [31:0] d0;
    wire        d0v;
    reg         d0ready = 1'b0;

    reg         c1v = 1'b0;
    reg  [31:0] c1a = 32'h0;
    wire        c1r;
    wire [31:0] d1;
    wire        d1v;

    reg         run_start = 1'b0;
    reg         abort     = 1'b0;
    wire        err;

    wire [31:0] araddr;
    wire [5:0]  arid;
    wire [3:0]  arlen;
    wire [2:0]  arsize;
    wire [1:0]  arburst;
    wire [3:0]  arcache;
    wire [2:0]  arprot;
    wire        arvalid;
    reg         arready = 1'b1;

    reg  [63:0] rdata = 64'h0;
    reg  [5:0]  rid   = 6'h00;
    reg  [1:0]  rresp = 2'b00;
    reg         rlast = 1'b1;
    reg         rvalid = 1'b0;
    wire        rready;

    gc_axi_read dut (
        .ACLK        (clk),
        .ARESETN     (rstn),
        .cmd0_valid  (c0v),
        .cmd0_addr   (c0a),
        .cmd0_ready  (c0r),
        .data0_out   (d0),
        .data0_valid (d0v),
        .data0_ready (d0ready),
        .cmd1_valid  (c1v),
        .cmd1_addr   (c1a),
        .cmd1_ready  (c1r),
        .data1_out   (d1),
        .data1_valid (d1v),
        .data1_ready (1'b1),
        .run_start   (run_start),
        .abort       (abort),
        .err         (err),
        .ARADDR      (araddr),
        .ARID        (arid),
        .ARLEN       (arlen),
        .ARSIZE      (arsize),
        .ARBURST     (arburst),
        .ARCACHE     (arcache),
        .ARPROT      (arprot),
        .ARVALID     (arvalid),
        .ARREADY     (arready),
        .RDATA       (rdata),
        .RID         (rid),
        .RRESP       (rresp),
        .RLAST       (rlast),
        .RVALID      (rvalid),
        .RREADY      (rready)
    );

    integer errors = 0;
    reg     check  = 1'b0;

    // After the pulse, these addresses are queued old commands. The first
    // address (0x30000000) is the pre-flush AR that is allowed to complete.
    // 0x30000020 / 0x30000120 are enqueued in the pulse cycle itself and must
    // be dropped by the flush.
    always @(posedge clk) begin
        if (check && arvalid && arready) begin
            if (araddr == 32'h30000008 || araddr == 32'h30000010
                || araddr == 32'h30000018 || araddr == 32'h30000020
                || araddr == 32'h30000120) begin
                $display("[CMDFIFO][FAIL] stale ARADDR=0x%08x at %0t", araddr, $time);
                errors = errors + 1;
            end
        end
    end

    task automatic enqueue(input [31:0] a);
        begin
            @(negedge clk);
            c0a = a;
            c0v = 1'b1;
            @(posedge clk);
            while (!(c0v && c0r)) @(posedge clk);
            @(negedge clk);
            c0v = 1'b0;
        end
    endtask

    task automatic one_case(input integer use_abort);
        begin
            rstn = 1'b0;
            arready = 1'b0;
            check = 1'b0;
            c0v = 1'b0;
            c1v = 1'b0;
            rvalid = 1'b0;
            d0ready = 1'b0;
            if (use_abort) abort = 1'b0; else run_start = 1'b0;
            repeat (8) @(negedge clk);
            rstn = 1'b1;
            repeat (4) @(negedge clk);

            // Hold ARREADY low: four commands queue, first AR waits on bus.
            enqueue(32'h30000000);
            enqueue(32'h30000008);
            enqueue(32'h30000010);
            enqueue(32'h30000018);
            $display("[CMDFIFO] before pulse (%s): c0r=%0d c0w=%0d",
                     use_abort ? "abort" : "run_start", dut.c0r, dut.c0w);

            @(negedge clk);
            arready = 1'b1;
            if (use_abort) abort = 1'b1; else run_start = 1'b1;
            // Same-cycle enqueue: both streams present a command in the pulse
            // cycle. The flush must drop them together with the queued ones.
            c0a = 32'h30000020;
            c1a = 32'h30000120;
            c0v = 1'b1;
            c1v = 1'b1;
            check = 1'b1;
            @(posedge clk);
            if (!(c0v && c0r) || !(c1v && c1r)) begin
                $display("[CMDFIFO][FAIL] same-cycle command was not handshaken (c0=%0b/%0b c1=%0b/%0b)",
                         c0v, c0r, c1v, c1r);
                errors = errors + 1;
            end
            @(negedge clk);
            c0v = 1'b0;
            c1v = 1'b0;
            if (use_abort) abort = 1'b0; else run_start = 1'b0;
            repeat (4) @(negedge clk);
            check = 1'b0;
            $display("[CMDFIFO] after pulse (%s): c0r=%0d c0w=%0d c1r=%0d c1w=%0d",
                     use_abort ? "abort" : "run_start",
                     dut.c0r, dut.c0w, dut.c1r, dut.c1w);
            if (dut.c0w != dut.c0r) begin
                $display("[CMDFIFO][FAIL] same-cycle c0 enqueue survived the flush");
                errors = errors + 1;
            end
            if (dut.c1w != dut.c1r) begin
                $display("[CMDFIFO][FAIL] same-cycle c1 enqueue survived the flush");
                errors = errors + 1;
            end
            repeat (4) @(negedge clk);
        end
    endtask

    initial begin
        rstn = 1'b0;
        repeat (10) @(negedge clk);
        rstn = 1'b1;
        repeat (5) @(negedge clk);

        one_case(1'b0);   // run_start
        one_case(1'b1);   // abort

        repeat (10) @(negedge clk);
        if (errors == 0) begin
            $display("[CMDFIFO] ==================== PASS ====================");
        end else begin
            $display("[CMDFIFO][FAIL] %0d check(s) failed", errors);
        end
        $finish;
    end

    initial begin
        #2000000;
        $display("[CMDFIFO][FAIL] global timeout");
        $finish;
    end

endmodule
