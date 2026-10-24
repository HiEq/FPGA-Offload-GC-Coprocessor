`timescale 1ns/1ps
// ============================================================
// tb_flush_data.v — abort/run_start must own the data FIFO pointers.
//
// Condition: a consumer handshake and abort/run_start in the same cycle.
// Pass: data0_valid stays low after the pulse.
// Negative control: the pre-fix RTL leaves one beat visible.
// ============================================================
module tb_flush_data;

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

    initial begin
        repeat (5) @(negedge clk);
        rstn = 1'b1;
        repeat (2) @(negedge clk);

        // Two queued reads, two returned beats held in d0f (d0ready=0).
        enqueue(32'h30000000);
        enqueue(32'h30000008);
        arready = 1'b1;
        repeat (2) begin
            while (!arvalid) @(negedge clk);
            @(posedge clk);
            @(negedge clk);
        end
        arready = 1'b0;

        return_beat(64'h1111_1111_1111_1111);
        return_beat(64'h2222_2222_2222_2222);
        while ((dut.d0w - dut.d0r) < 2) @(posedge clk);

        if (!d0v) begin
            $display("[FLUSH-DATA][FAIL] setup: no buffered data");
            errors = errors + 1;
        end

        // Consumer reads and abort in the same cycle.  flush must win.
        @(negedge clk);
        d0ready = 1'b1;
        abort   = 1'b1;
        @(posedge clk);
        @(negedge clk);
        abort   = 1'b0;
        d0ready = 1'b0;

        repeat (4) @(negedge clk);
        if (d0v) begin
            $display("[FLUSH-DATA][FAIL] stale data survived abort: d0=0x%08x", d0);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("[FLUSH-DATA] ==================== PASS ====================");
        else
            $display("[FLUSH-DATA][FAIL] %0d check(s) failed", errors);
        $finish;
    end

    initial begin
        #200000;
        $display("[FLUSH-DATA][FAIL] global timeout");
        $finish;
    end

endmodule
