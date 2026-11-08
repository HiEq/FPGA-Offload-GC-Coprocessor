// tb_gc_bitmap2.v - the two banks are independent AND the bank address is the
// full 14 bits (word >> 1).  A 13-bit address would alias 0x3FFF onto 0x1FFF.
`timescale 1ns/1ps
module tb_gc_bitmap2;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg  [1:0]   we = 2'd0;
    reg  [27:0]  waddr = 28'd0;
    reg  [63:0]  din = 64'd0;
    reg  [27:0]  raddr = 28'd0;
    wire [63:0]  dout;

    gc_bitmapN #(.LANES(2), .SEL(1)) dut (
        .clk   (clk),
        .we    (we),
        .waddr (waddr),
        .din   (din),
        .raddr (raddr),
        .dout  (dout)
    );

    integer errs = 0;

    task wr(input integer bank, input [13:0] addr, input [31:0] data);
        begin
            @(negedge clk);
            we = (2'd1 << bank);
            waddr[14*bank +: 14] = addr;
            din[32*bank +: 32] = data;
            @(negedge clk);
            we = 2'd0;
        end
    endtask

    task rd(input integer bank, input [13:0] addr, input [31:0] exp);
        begin
            @(negedge clk);
            raddr = {14'd0, 14'd0};
            raddr[14*bank +: 14] = addr;
            @(negedge clk);
            if (dout[32*bank +: 32] !== exp) begin
                $display("[BM2][FAIL] bank %0d addr %04x exp %08x got %08x",
                         bank, addr, exp, dout[32*bank +: 32]);
                errs = errs + 1;
            end
        end
    endtask

    initial begin
        repeat (2) @(posedge clk);

        // high address and address 0 in each bank, with distinct data
        wr(0, 14'h3FFF, 32'hA0A0_0000);
        wr(1, 14'h3FFF, 32'hB0B0_0000);
        wr(0, 14'h0000, 32'hA0A0_0001);
        wr(1, 14'h0000, 32'hB0B0_0001);

        rd(0, 14'h3FFF, 32'hA0A0_0000);
        rd(1, 14'h3FFF, 32'hB0B0_0000);
        rd(0, 14'h0000, 32'hA0A0_0001);
        rd(1, 14'h0000, 32'hB0B0_0001);

        // write bank 0 high address again; bank 1's same address must not change
        wr(0, 14'h3FFF, 32'hA0A0_0002);
        rd(1, 14'h3FFF, 32'hB0B0_0000);
        rd(0, 14'h3FFF, 32'hA0A0_0002);

        if (errs == 0) $display("BM2_RESULT OK");
        else           $display("BM2_RESULT FAIL %0d", errs);
        $finish;
    end

endmodule
