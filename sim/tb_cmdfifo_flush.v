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
    always @(posedge clk) begin
        if (check && arvalid && arready) begin
            if (araddr == 32'h30000008 || araddr == 32'h30000010
                || araddr == 32'h30000018) begin
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
            check = 1'b1;
            @(posedge clk);
            @(negedge clk);
            if (use_abort) abort = 1'b0; else run_start = 1'b0;
            repeat (4) @(negedge clk);
            check = 1'b0;
            $display("[CMDFIFO] after pulse (%s): c0r=%0d c0w=%0d",
                     use_abort ? "abort" : "run_start", dut.c0r, dut.c0w);
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
