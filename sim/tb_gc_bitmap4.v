// tb_gc_bitmap4.v - the four banks must be independent and hold their data.
`timescale 1ns/1ps
module tb_gc_bitmap4;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg  [3:0]   we = 4'd0;
    reg  [51:0]  waddr = 52'd0;
    reg  [127:0] din = 128'd0;
    reg  [51:0]  raddr = 52'd0;
    wire [127:0] dout;

    gc_bitmapN #(.LANES(4), .SEL(2)) dut (
        .clk   (clk),
        .we    (we),
        .waddr (waddr),
        .din   (din),
        .raddr (raddr),
        .dout  (dout)
    );

    integer i, k, errs = 0;
    reg [127:0] expd;

    initial begin
        for (i = 0; i < 16; i = i + 1) begin
            @(negedge clk);
            we = 4'b1111;
            for (k = 0; k < 4; k = k + 1) begin
                waddr[13*k +: 13] = i;
                din[32*k +: 32] = 32'hA0000000 + (k << 16) + i;
            end
            @(negedge clk);
            we = 4'd0;
        end

        for (i = 0; i < 16; i = i + 1) begin
            @(negedge clk);
            for (k = 0; k < 4; k = k + 1)
                raddr[13*k +: 13] = i;
            @(negedge clk);
            for (k = 0; k < 4; k = k + 1) begin
                expd = 32'hA0000000 + (k << 16) + i;
                if (dout[32*k +: 32] !== expd) begin
                    $display("[BM4][FAIL] bank %0d addr %0d exp %08x got %08x",
                             k, i, expd, dout[32*k +: 32]);
                    errs = errs + 1;
                end
            end
        end

        if (errs == 0)
            $display("BM4_RESULT OK");
        else
            $display("BM4_RESULT FAIL %0d", errs);
        $finish;
    end

endmodule
