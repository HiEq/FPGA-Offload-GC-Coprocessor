`timescale 1ns/1ps
// ============================================================
// tb_runstart_race.v — directed test for the 1-cycle stale-R beat
// at run_start / abort.
//
// Claim under test:
//   In the cycle where run_start (or abort) is asserted, flushing is
//   still 0, so a same-cycle RVALID/RREADY takes the normal store path:
//   d0w increments, while the flush branch sets d0r <= d0w (old value).
//   The stale beat therefore survives as the first FIFO entry and is
//   consumed as the new run's first reference.
//
// Sequence per case:
//   1. enqueue one ref read, let AR handshake, keep the response pending
//   2. assert run_start (or abort) and RVALID in the SAME cycle
//   3. after the flush drains, the data FIFO must be empty
//   4. issue a fresh read, return a fresh value
//   5. the FIRST word seen by the consumer must be the fresh value
//
// Expected: FAIL on the current RTL (stale beat survives), PASS after
// gating the discard branch with run_start/abort.
// ============================================================
module tb_runstart_race;

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
    wire        arready;
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

    // The model always accepts AR and never holds an R beat beyond one cycle.
    assign arready = 1'b1;

    wire [31:0] axi_errs;
    axi_proto_check u_chk (
        .clk     (clk),
        .rstn    (rstn),
        .ARADDR  (araddr),
        .ARID    (arid),
        .ARLEN   (arlen),
        .ARSIZE  (arsize),
        .ARBURST (arburst),
        .ARCACHE (arcache),
        .ARVALID (arvalid),
        .ARREADY (arready),
        .RID     (rid),
        .RRESP   (rresp),
        .RVALID  (rvalid),
        .RREADY  (rready),
        .errors  (axi_errs)
    );

    integer errors = 0;

    task automatic enqueue(input [31:0] a);
        integer g;
        begin
            @(negedge clk);
            c0a = a;
            c0v = 1'b1;
            @(posedge clk);
            g = 0;
            while (!(c0v && c0r) && g < 200) begin
                @(posedge clk);
                g = g + 1;
            end
            if (!(c0v && c0r)) begin
                $display("[RACE][FAIL] cmd handshake timeout");
                errors = errors + 1;
            end
            @(negedge clk);
            c0v = 1'b0;
        end
    endtask

    task automatic wait_ar();
        integer g;
        begin
            g = 0;
            while (!(arvalid && arready) && g < 200) begin
                @(posedge clk);
                g = g + 1;
            end
            if (!(arvalid && arready)) begin
                $display("[RACE][FAIL] AR handshake timeout");
                errors = errors + 1;
            end
        end
    endtask

    task automatic one_case(input integer use_abort,
                            input [31:0]  stale,
                            input [31:0]  fresh,
                            input integer tag);
        integer g;
        reg [31:0] first;
        begin
            // ---- 1. one read, response pending ----
            enqueue(32'h1E000000 + tag * 32'h1000);
            wait_ar();
            repeat (3) @(negedge clk);

            // ---- 2. flush pulse + stale R in the same cycle ----
            @(negedge clk);
            if (use_abort) abort = 1'b1; else run_start = 1'b1;
            rvalid = 1'b1;
            rid    = 6'h00;
            rresp  = 2'b00;
            rlast  = 1'b1;
            rdata  = {32'h0, stale};
            #1;
            // A window miss must fail: a PASS here would mean the TB never
            // exercised the same-cycle RREADY/flush hole it claims to test.
            if (!rready) begin
                $display("[RACE][FAIL] %s: RREADY=0 in the flush cycle; window not hit",
                         use_abort ? "abort" : "run_start");
                errors = errors + 1;
            end
            @(posedge clk);
            @(negedge clk);
            if (use_abort) abort = 1'b0; else run_start = 1'b0;
            rvalid = 1'b0;

            // ---- 3. after the flush drains, the FIFO must be empty ----
            repeat (4) @(negedge clk);
            if (d0v) begin
                $display("[RACE][FAIL] %s: stale beat survived the flush (d0=0x%08x)",
                         use_abort ? "abort" : "run_start", d0);
                errors = errors + 1;
                // drain it so the rest of the case still runs
                d0ready = 1'b1;
                @(negedge clk);
                d0ready = 1'b0;
            end else begin
                $display("[RACE][INFO] %s: data FIFO empty after flush (OK)",
                         use_abort ? "abort" : "run_start");
            end

            // ---- 4. new read + fresh response ----
            enqueue(32'h1E000800 + tag * 32'h1000);
            wait_ar();
            repeat (2) @(negedge clk);
            @(negedge clk);
            rvalid = 1'b1;
            rid    = 6'h00;
            rdata  = {32'h0, fresh};
            @(posedge clk);
            @(negedge clk);
            rvalid = 1'b0;

            // ---- 5. the first word must be the fresh one ----
            repeat (2) @(negedge clk);
            if (!d0v) begin
                $display("[RACE][FAIL] %s: no data after the fresh response",
                         use_abort ? "abort" : "run_start");
                errors = errors + 1;
            end else begin
                first = d0;
                if (first !== fresh) begin
                    $display("[RACE][FAIL] %s: first word=0x%08x, expect 0x%08x (stale beat won)",
                             use_abort ? "abort" : "run_start", first, fresh);
                    errors = errors + 1;
                end else begin
                    $display("[RACE][INFO] %s: first word=0x%08x (fresh) OK",
                             use_abort ? "abort" : "run_start", first);
                end
            end

            // pop the fresh word and make sure nothing trails it
            d0ready = 1'b1;
            @(negedge clk);
            d0ready = 1'b0;
            repeat (3) @(negedge clk);
            if (d0v) begin
                $display("[RACE][FAIL] %s: extra word left in the FIFO (0x%08x)",
                         use_abort ? "abort" : "run_start", d0);
                errors = errors + 1;
            end

            repeat (3) @(negedge clk);
        end
    endtask

    initial begin
        rstn = 1'b0;
        repeat (10) @(negedge clk);
        rstn = 1'b1;
        repeat (5) @(negedge clk);

        one_case(1'b0, 32'hDEAD0001, 32'h600D0002, 0);   // run_start
        one_case(1'b1, 32'hDEAD0003, 32'h600D0004, 1);   // abort

        repeat (10) @(negedge clk);
        if (axi_errs !== 32'd0) begin
            $display("[RACE][FAIL] AXI protocol errors: %0d", axi_errs);
            errors = errors + 1;
        end
        if (errors == 0) begin
            $display("[RACE] ==================== PASS ====================");
        end else begin
            $display("[RACE][FAIL] %0d check(s) failed", errors);
        end
        $finish;
    end

    initial begin
        #2000000;
        $display("[RACE][FAIL] global timeout");
        $finish;
    end

endmodule
