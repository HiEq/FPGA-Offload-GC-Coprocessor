// tb_gc_dump.v - end-to-end check of the bitmap DMA dump.
//
// The bitmap is filled with a unique pattern per word; the dump runs to
// completion into a DDR model; every dumped 32-bit word must equal the bitmap
// word at the same index.  A one-word address lag (the dump capturing the
// previous word's read data) fails on the shifted words.
//
// Run: iverilog -g2012 -o tb_gc_dump.vvp sim/tb_gc_dump.v rtl/gc_dump.v rtl/gc_bitmap.v
`timescale 1ns/1ps
module tb_gc_dump;

    localparam integer WORDS = 32768;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;

    // ---------------- bitmap under test ----------------
    wire [14:0] bm_raddr;
    wire [31:0] bm_rdata;

    gc_bitmap u_bm (
        .clk   (clk),
        .waddr (15'd0),
        .din   (32'd0),
        .we    (1'b0),
        .raddr (bm_raddr),
        .dout  (bm_rdata)
    );

    // ---------------- dump ----------------
    reg         start = 1'b0;
    reg  [31:0] base  = 32'd0;
    wire        busy, done;

    wire [31:0] AWADDR;
    wire [5:0]  AWID;
    wire [3:0]  AWLEN;
    wire [2:0]  AWSIZE;
    wire [1:0]  AWBURST;
    wire [3:0]  AWCACHE;
    wire [2:0]  AWPROT;
    wire        AWVALID;
    reg         AWREADY = 1'b1;

    wire [63:0] WDATA;
    wire [5:0]  WID;
    wire [7:0]  WSTRB;
    wire        WLAST;
    wire        WVALID;
    reg         WREADY = 1'b1;

    wire [5:0]  BID;
    wire [1:0]  BRESP;
    wire        BVALID;
    wire        BREADY;

    gc_dump u_dut (
        .clk   (clk),
        .rst_n (rst_n),
        .start (start),
        .base  (base),
        .busy  (busy),
        .done  (done),
        .bm_raddr (bm_raddr),
        .bm_rdata (bm_rdata),
        .AWADDR (AWADDR),
        .AWID   (AWID),
        .AWLEN  (AWLEN),
        .AWSIZE (AWSIZE),
        .AWBURST(AWBURST),
        .AWCACHE(AWCACHE),
        .AWPROT (AWPROT),
        .AWVALID(AWVALID),
        .AWREADY(AWREADY),
        .WDATA  (WDATA),
        .WID    (WID),
        .WSTRB  (WSTRB),
        .WLAST  (WLAST),
        .WVALID (WVALID),
        .WREADY (WREADY),
        .BID    (BID),
        .BRESP  (BRESP),
        .BVALID (BVALID),
        .BREADY (BREADY)
    );

    // ---------------- DDR write model ----------------
    reg  [31:0] ddr [0:WORDS-1];
    reg  [31:0] wa;
    reg         bpend;

    assign BID    = 6'd2;
    assign BRESP  = 2'b00;
    assign BVALID = bpend;

    integer i;
    initial begin
        for (i = 0; i < WORDS; i = i + 1) begin
            u_bm.mem[i] = 32'h1000_0000 + i[31:0];
            ddr[i]      = 32'hDEADBEEF;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            wa    <= 32'd0;
            bpend <= 1'b0;
        end else begin
            if (AWVALID && AWREADY)
                wa <= AWADDR;
            if (WVALID && WREADY) begin
                ddr[wa[16:2]]     <= WDATA[31:0];
                ddr[wa[16:2] + 1] <= WDATA[63:32];
                wa <= wa + 32'd8;
                if (WLAST)
                    bpend <= 1'b1;
            end
            if (bpend && BREADY)
                bpend <= 1'b0;
        end
    end

    // ---------------- run ----------------
    integer k, errs;

    initial begin
        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);
        @(negedge clk) start = 1'b1;
        @(negedge clk) start = 1'b0;

        wait (done === 1'b1);
        repeat (5) @(posedge clk);

        errs = 0;
        for (k = 0; k < WORDS; k = k + 1) begin
            if (ddr[k] !== u_bm.mem[k]) begin
                if (errs < 8)
                    $display("[DUMP][FAIL] word %0d expected %08x got %08x",
                             k, u_bm.mem[k], ddr[k]);
                errs = errs + 1;
            end
        end
        if (errs == 0)
            $display("DUMP_RESULT OK (%0d words)", WORDS);
        else
            $display("DUMP_RESULT FAIL (%0d/%0d words differ)", errs, WORDS);
        $finish;
    end

    initial begin
        #2000000;
        $display("DUMP_RESULT TIMEOUT busy=%b done=%b", busy, done);
        $finish;
    end

endmodule
