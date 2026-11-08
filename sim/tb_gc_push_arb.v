// tb_gc_push_arb.v - 2:1 round-robin push arbitration.
`timescale 1ns/1ps
module tb_gc_push_arb;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;
    reg clear = 1'b0;

    reg  [1:0]  req = 2'd0;
    reg  [39:0] id = 40'd0;
    reg         full = 1'b0;
    wire [1:0]  grant;
    wire        we;
    wire [19:0] wdata;

    gc_push_arb #(.LANES(2), .SEL(1)) dut (
        .clk(clk), .rst_n(rst_n), .clear(clear),
        .req(req), .id(id), .full(full),
        .grant(grant), .we(we), .wdata(wdata)
    );

    integer n, errs = 0;

    initial begin
        id[19:0]  = 20'h00100;
        id[39:20] = 20'h00200;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // both request for 4 cycles: grants must alternate lanes
        req = 2'b11;
        for (n = 0; n < 4; n = n + 1) begin
            @(negedge clk);
            if (!we || grant == 2'b00 || grant == 2'b11) begin
                $display("[ARB][FAIL] both-req cycle %0d grant=%b we=%b", n, grant, we);
                errs = errs + 1;
            end
            if (grant[1]) begin
                if (wdata !== 20'h00200) begin
                    $display("[ARB][FAIL] lane1 data=%05x", wdata); errs = errs + 1;
                end
            end else if (grant[0]) begin
                if (wdata !== 20'h00100) begin
                    $display("[ARB][FAIL] lane0 data=%05x", wdata); errs = errs + 1;
                end
            end
        end

        // only lane 0 requests: always granted
        req = 2'b01;
        @(negedge clk);
        if (!we || grant !== 2'b01 || wdata !== 20'h00100) begin
            $display("[ARB][FAIL] single lane0 grant=%b we=%b data=%05x", grant, we, wdata);
            errs = errs + 1;
        end

        // full blocks the push
        req = 2'b11;
        full = 1'b1;
        @(negedge clk);
        if (we || grant != 2'b00) begin
            $display("[ARB][FAIL] full did not block: grant=%b we=%b", grant, we);
            errs = errs + 1;
        end

        if (errs == 0) $display("ARB_RESULT OK");
        else           $display("ARB_RESULT FAIL %0d", errs);
        $finish;
    end

endmodule
