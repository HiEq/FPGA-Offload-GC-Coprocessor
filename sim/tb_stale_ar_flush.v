`timescale 1ns/1ps
// ============================================================
// tb_stale_ar_flush.v — a pending AR must not survive run_start/abort.
//
// Covered hole: a command is already on ARVALID, but ARREADY is low when
// START/ABORT pulses.  The old RTL cleared `flushing` as soon as no AR had
// handshaken, then let the pending AR complete; its response was stored as
// data for the new run.  The existing tb_cmdfifo_flush releases ARREADY in
// the pulse cycle, so it misses this window.
//
// Pass: after the pulse, the stale response produces no data0_valid; a fresh
// command still returns its own data.  Negative control: run this TB against
// the pre-fix RTL and it reports "stale beat visible".
// ============================================================
module tb_stale_ar_flush;

    reg clk = 1'b0;
    reg rstn = 1'b0;
    always #5 clk = ~clk;

    reg         c0v = 1'b0;
    reg  [31:0] c0a = 32'h0;
    wire        c0r;
    wire [31:0] d0;
    wire        d0v;
    reg         d0ready = 1'b1;

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
    reg         arready = 1'b0;

    reg  [63:0] rdata = 64'h0;
    reg  [5:0]  rid   = 6'h0;
    reg  [1:0]  rresp = 2'b00;
    reg         rlast = 1'b1;
    reg         rvalid = 1'b0;
    wire        rready;

    gc_axi_read dut (
        .ACLK        (clk),
        .ARESETN     (rstn),
        .run_start   (run_start),
        .abort       (abort),
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
    reg     watch_stale = 1'b0;
    reg     watch_fresh = 1'b0;
    reg     stale_hs    = 1'b0;
    reg     fresh_seen  = 1'b0;
    reg [31:0] fresh_val = 32'h0;

    always @(posedge clk) begin
        if (rstn && watch_stale && d0v) begin
            $display("[STALE-AR][FAIL] stale beat visible: d0=0x%08x at %0t", d0, $time);
            errors = errors + 1;
        end
        if (rstn && watch_fresh && d0v) begin
            fresh_seen = 1'b1;
            fresh_val  = d0;
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

    task automatic return_beat(input [63:0] data);
        begin
            rid   = 6'h0;
            rdata = data;
            rresp = 2'b00;
            rvalid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            rvalid = 1'b0;
        end
    endtask

    task automatic one_case(input integer use_abort);
        begin
            rstn = 1'b0;
            arready = 1'b0;
            c0v = 1'b0;
            c1v = 1'b0;
            rvalid = 1'b0;
            d0ready = 1'b1;
            watch_stale = 1'b0;
            watch_fresh = 1'b0;
            stale_hs = 1'b0;
            fresh_seen = 1'b0;
            run_start = 1'b0;
            abort = 1'b0;
            repeat (5) @(negedge clk);
            rstn = 1'b1;
            repeat (2) @(negedge clk);

            // One command is loaded onto ARVALID; leave ARREADY low so the
            // request is still pending when the pulse arrives.
            enqueue(32'h30000000);
            while (!arvalid) @(negedge clk);

            if (use_abort) abort = 1'b1; else run_start = 1'b1;
            @(posedge clk);
            @(negedge clk);
            if (use_abort) abort = 1'b0; else run_start = 1'b0;

            // The fixed RTL cancels a pending AR; the old RTL lets it
            // handshake after the flush window.  Probe for either.
            repeat (2) @(negedge clk);
            arready = 1'b1;
            repeat (6) begin
                @(posedge clk);
                if (arvalid && arready)
                    stale_hs = 1'b1;
            end
            arready = 1'b0;

            if (stale_hs) begin
                watch_stale = 1'b1;
                return_beat(64'hAAAA_BBBB_CCCC_DDDD);
                repeat (3) @(negedge clk);
                watch_stale = 1'b0;
            end

            // A fresh command must still return its own data.
            enqueue(32'h30000040);
            arready = 1'b1;
            while (!arvalid) @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            arready = 1'b0;

            watch_fresh = 1'b1;
            return_beat(64'h1111_2222_3333_4444);
            repeat (3) @(negedge clk);
            watch_fresh = 1'b0;

            if (!fresh_seen) begin
                $display("[STALE-AR][FAIL] no fresh data after the flush");
                errors = errors + 1;
            end else if (fresh_val !== 32'h3333_4444) begin
                $display("[STALE-AR][FAIL] fresh data=0x%08x, expect 0x33334444", fresh_val);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        one_case(1'b0);   // run_start
        one_case(1'b1);   // abort
        if (errors == 0)
            $display("[STALE-AR] ==================== PASS ====================");
        else
            $display("[STALE-AR][FAIL] %0d check(s) failed", errors);
        $finish;
    end

    initial begin
        #500000;
        $display("[STALE-AR][FAIL] global timeout");
        $finish;
    end

endmodule
