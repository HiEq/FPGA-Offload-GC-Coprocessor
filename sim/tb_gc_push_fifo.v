// tb_gc_push_fifo.v - two-entry push FIFO: order, full back-pressure, pop to a
// full object queue, and clear.
`timescale 1ns/1ps
module tb_gc_push_fifo;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;
    reg clear = 1'b0;

    reg         push = 1'b0;
    reg  [19:0] id = 20'd0;
    wire        ready;
    reg         q_full = 1'b0;
    wire        q_we;
    wire [19:0] q_wdata;
    wire        empty;

    gc_push_fifo dut (
        .clk(clk), .rst_n(rst_n), .clear(clear),
        .push(push), .id(id), .ready(ready),
        .q_full(q_full), .q_we(q_we), .q_wdata(q_wdata), .empty(empty)
    );

    integer errs = 0;
    integer i;
    reg [19:0] got [0:7];
    integer ngot = 0;

    always @(posedge clk) if (q_we) begin
        got[ngot] = q_wdata;
        ngot = ngot + 1;
    end

    task chk(input cond, input [255:0] msg);
        begin
            if (!cond) begin
                $display("[PFIFO][FAIL] %0s", msg);
                errs = errs + 1;
            end
        end
    endtask

    task put(input [19:0] v);
        begin
            @(negedge clk);
            push = 1'b1; id = v;
            @(negedge clk);
            push = 1'b0;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // fill both entries with the object queue blocked; the third push must
        // back-pressure
        q_full = 1'b1;
        put(20'h00A);
        put(20'h00B);
        chk(ready === 1'b0, "ready should be 0 when full");
        chk(empty === 1'b0, "not empty after two pushes");

        // object queue full: nothing pops, FIFO stays full
        repeat (2) @(posedge clk);
        chk(q_we === 1'b0, "q_we must be 0 while q_full");
        chk(ngot == 0, "nothing may be written while q_full");
        chk(ready === 1'b0, "ready must stay 0 while full");

        // drain: A then B
        q_full = 1'b0;
        repeat (2) @(posedge clk); @(negedge clk);
        chk(ngot == 2, "two entries should drain in two cycles");
        chk(got[0] === 20'h00A && got[1] === 20'h00B, "FIFO order != A,B");
        chk(empty === 1'b1, "empty after drain");

        // push while draining (both a pop and a put in the same cycle)
        @(negedge clk);
        push = 1'b1; id = 20'h00C;
        @(negedge clk);
        push = 1'b0;
        repeat (2) @(posedge clk); @(negedge clk);
        chk(ngot == 3 && got[2] === 20'h00C, "push-while-pop lost the entry");

        // clear drops a pending entry (block the queue so it stays pending)
        q_full = 1'b1;
        put(20'h00D);
        @(negedge clk); clear = 1'b1;
        @(negedge clk); clear = 1'b0;
        repeat (2) @(posedge clk); @(negedge clk);
        chk(empty === 1'b1, "clear did not empty the FIFO");
        chk(ngot == 3, "cleared entry must not reach the queue");

        if (errs == 0) $display("PFIFO_RESULT OK");
        else           $display("PFIFO_RESULT FAIL %0d", errs);
        $finish;
    end

endmodule
