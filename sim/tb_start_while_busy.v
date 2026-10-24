`timescale 1ns/1ps
// ============================================================
// tb_start_while_busy.v — a second START while the engine is running must be
// ignored, not flush the read engine under the running BFS.
//
// The mark engine only accepts START in S_IDLE.  The read engine used to
// flush on every START, so a duplicate START dropped the current object's
// in-flight reads and the engine waited forever for ref_got == ref_count.
//
// Graph: 64 objects.  Object 0 is the root with 32 references (1..32);
// objects 1..32 have no refs; 33..63 are unreachable.  Expected MARKED = 33.
// The long S_REFS_LOOP gives the AXI-Lite START write time to land inside it.
//
// Negative control: pre-fix RTL times out; fixed RTL reports DONE + 33.
// ============================================================
module tb_start_while_busy;

    localparam integer CLKP = 10;
    localparam integer N    = 64;
    localparam [31:0]  OBJ_BASE = 32'h0;
    localparam [31:0]  REF_BASE = 32'h1000;

    reg clk = 1'b0;
    reg rstn = 1'b0;
    always #(CLKP/2) clk = ~clk;

    // ---------------- AXI-Lite master ----------------
    reg  [11:0] m_awaddr  = 12'h0;
    reg         m_awvalid = 1'b0;
    wire        m_awready;
    reg  [31:0] m_wdata   = 32'h0;
    reg  [3:0]  m_wstrb   = 4'hF;
    reg         m_wvalid  = 1'b0;
    wire        m_wready;
    wire [1:0]  m_bresp;
    wire        m_bvalid;
    reg         m_bready  = 1'b0;
    reg  [11:0] m_araddr  = 12'h0;
    reg         m_arvalid = 1'b0;
    wire        m_arready;
    wire [31:0] m_rdata;
    wire [1:0]  m_rresp;
    wire        m_rvalid;
    reg         m_rready  = 1'b0;

    // ---------------- HP read model ----------------
    wire [31:0] hp_araddr;
    wire [5:0]  hp_arid;
    wire [3:0]  hp_arlen;
    wire [2:0]  hp_arsize;
    wire [1:0]  hp_arburst;
    wire [3:0]  hp_arcache;
    wire [2:0]  hp_arprot;
    wire        hp_arvalid;
    wire        hp_arready;
    wire [63:0] hp_rdata;
    wire [5:0]  hp_rid;
    wire [1:0]  hp_rresp;
    wire        hp_rlast;
    wire        hp_rvalid;
    wire        hp_rready;
    wire [31:0] hp_awaddr;
    wire [5:0]  hp_awid;
    wire [3:0]  hp_awlen;
    wire [2:0]  hp_awsize;
    wire [1:0]  hp_awburst;
    wire [3:0]  hp_awcache;
    wire [2:0]  hp_awprot;
    wire        hp_awvalid;
    wire        hp_awready;
    wire [63:0] hp_wdata;
    wire [5:0]  hp_wid;
    wire [7:0]  hp_wstrb;
    wire        hp_wlast;
    wire        hp_wvalid;
    wire        hp_wready;
    wire [5:0]  hp_bid;
    wire [1:0]  hp_bresp;
    wire        hp_bvalid;
    wire        hp_bready;
    wire        irq;

    wire        _unused = &{1'b0, hp_arlen, hp_arsize, hp_arburst, hp_arcache,
                             hp_arprot, hp_awaddr, hp_awid, hp_awlen, hp_awsize,
                             hp_awburst, hp_awcache, hp_awprot, hp_awvalid,
                             hp_wdata, hp_wid, hp_wstrb, hp_wlast, hp_wvalid,
                             hp_bid, hp_bresp, hp_bvalid, irq};

    gc_top dut (
        .S_AXI_ACLK       (clk),
        .S_AXI_ARESETN    (rstn),
        .S_AXI_AWADDR     (m_awaddr),
        .S_AXI_AWVALID    (m_awvalid),
        .S_AXI_AWREADY    (m_awready),
        .S_AXI_WDATA      (m_wdata),
        .S_AXI_WSTRB      (m_wstrb),
        .S_AXI_WVALID     (m_wvalid),
        .S_AXI_WREADY     (m_wready),
        .S_AXI_BRESP      (m_bresp),
        .S_AXI_BVALID     (m_bvalid),
        .S_AXI_BREADY     (m_bready),
        .S_AXI_ARADDR     (m_araddr),
        .S_AXI_ARVALID    (m_arvalid),
        .S_AXI_ARREADY    (m_arready),
        .S_AXI_RDATA      (m_rdata),
        .S_AXI_RRESP      (m_rresp),
        .S_AXI_RVALID     (m_rvalid),
        .S_AXI_RREADY     (m_rready),
        .S_AXI_HP_ACLK    (clk),
        .S_AXI_HP_ARESETN (rstn),
        .S_AXI_HP_ARADDR  (hp_araddr),
        .S_AXI_HP_ARID    (hp_arid),
        .S_AXI_HP_ARLEN   (hp_arlen),
        .S_AXI_HP_ARSIZE  (hp_arsize),
        .S_AXI_HP_ARBURST (hp_arburst),
        .S_AXI_HP_ARCACHE (hp_arcache),
        .S_AXI_HP_ARPROT  (hp_arprot),
        .S_AXI_HP_ARVALID (hp_arvalid),
        .S_AXI_HP_ARREADY (hp_arready),
        .S_AXI_HP_RDATA   (hp_rdata),
        .S_AXI_HP_RID     (hp_rid),
        .S_AXI_HP_RRESP   (hp_rresp),
        .S_AXI_HP_RLAST   (hp_rlast),
        .S_AXI_HP_RVALID  (hp_rvalid),
        .S_AXI_HP_RREADY  (hp_rready),
        .S_AXI_HP_AWADDR  (hp_awaddr),
        .S_AXI_HP_AWID    (hp_awid),
        .S_AXI_HP_AWLEN   (hp_awlen),
        .S_AXI_HP_AWSIZE  (hp_awsize),
        .S_AXI_HP_AWBURST (hp_awburst),
        .S_AXI_HP_AWCACHE (hp_awcache),
        .S_AXI_HP_AWPROT  (hp_awprot),
        .S_AXI_HP_AWVALID (hp_awvalid),
        .S_AXI_HP_AWREADY (hp_awready),
        .S_AXI_HP_WDATA   (hp_wdata),
        .S_AXI_HP_WID     (hp_wid),
        .S_AXI_HP_WSTRB   (hp_wstrb),
        .S_AXI_HP_WLAST   (hp_wlast),
        .S_AXI_HP_WVALID  (hp_wvalid),
        .S_AXI_HP_WREADY  (hp_wready),
        .S_AXI_HP_BID     (hp_bid),
        .S_AXI_HP_BRESP   (hp_bresp),
        .S_AXI_HP_BVALID  (hp_bvalid),
        .S_AXI_HP_BREADY  (hp_bready),
        .irq_o            (irq)
    );

    // 1 MiB word memory, addressed by (byte address >> 2).
    reg [31:0] mem [0:(1<<18)-1];
    integer i;
    initial begin
        for (i = 0; i < (1<<18); i = i + 1)
            mem[i] = 32'h0;

        for (i = 0; i < N; i = i + 1) begin
            mem[i*4 + 0] = i;
            mem[i*4 + 1] = 0;
            mem[i*4 + 2] = REF_BASE + i * 16;
            mem[i*4 + 3] = 0;
        end
        // Object 0: 32 references to objects 1..32.
        mem[0*4 + 1] = 32;
        for (i = 0; i < 32; i = i + 1)
            mem[(REF_BASE >> 2) + i] = i + 1;
        mem[(REF_BASE >> 2) + 32] = 32'hFFFFFFFF;
    end

    // One outstanding read at a time.  Enough for the engine to make progress;
    // the test only needs a long S_REFS_LOOP window.
    reg        pend_valid = 1'b0;
    reg [5:0]  pend_id    = 6'h0;
    reg [31:0] pend_addr  = 32'h0;
    reg [63:0] pend_data  = 64'h0;

    assign hp_arready = ~pend_valid;
    assign hp_rvalid  = pend_valid;
    assign hp_rid     = pend_id;
    assign hp_rdata   = pend_data;
    assign hp_rresp   = 2'b00;
    assign hp_rlast   = 1'b1;

    always @(posedge clk) begin
        if (!rstn) begin
            pend_valid <= 1'b0;
            pend_id    <= 6'h0;
            pend_addr  <= 32'h0;
            pend_data  <= 64'h0;
        end else if (hp_arvalid && hp_arready) begin
            pend_valid <= 1'b1;
            pend_id    <= hp_arid;
            pend_addr  <= hp_araddr;
            pend_data  <= {mem[(hp_araddr >> 2) + 1], mem[hp_araddr >> 2]};
        end else if (pend_valid && hp_rready) begin
            pend_valid <= 1'b0;
        end
    end

    integer errors = 0;

    task automatic axil_write(input [11:0] a, input [31:0] d);
        begin
            @(negedge clk);
            m_awaddr = a;
            m_awvalid = 1'b1;
            m_wdata = d;
            m_wvalid = 1'b1;
            while (!(m_awvalid && m_awready)) @(posedge clk);
            @(negedge clk);
            m_awvalid = 1'b0;
            while (!(m_wvalid && m_wready)) @(posedge clk);
            @(negedge clk);
            m_wvalid = 1'b0;
            m_bready = 1'b1;
            while (!m_bvalid) @(posedge clk);
            @(negedge clk);
            m_bready = 1'b0;
        end
    endtask

    task automatic axil_read(input [11:0] a, output [31:0] d);
        begin
            @(negedge clk);
            m_araddr = a;
            m_arvalid = 1'b1;
            while (!(m_arvalid && m_arready)) @(posedge clk);
            @(negedge clk);
            m_arvalid = 1'b0;
            m_rready = 1'b1;
            while (!m_rvalid) @(posedge clk);
            d = m_rdata;
            @(negedge clk);
            m_rready = 1'b0;
        end
    endtask

    integer wait_cnt;
    reg [31:0] rd_val;
    reg [31:0] word;

    initial begin
        repeat (5) @(negedge clk);
        rstn = 1'b1;
        repeat (2) @(negedge clk);

        axil_write(12'h004, OBJ_BASE);
        axil_write(12'h008, N);
        axil_write(12'h00C, 32'd1);
        axil_write(12'h040, 32'd0);
        axil_write(12'h000, 32'd4);     // CLEAR_Q
        axil_write(12'h000, 32'd1);     // START

        // Wait until the engine is inside the long reference loop.
        wait_cnt = 0;
        while (dut.u_engine.state != 5'd14 && wait_cnt < 200000) begin
            @(posedge clk);
            wait_cnt = wait_cnt + 1;
        end
        if (wait_cnt >= 200000) begin
            $display("[BUSY-START][FAIL] setup: engine never reached S_REFS_LOOP");
            errors = errors + 1;
        end else begin
            // Duplicate START while busy: the engine must ignore it and the
            // read engine must not flush the current object's reads.
            axil_write(12'h000, 32'd1);

            wait_cnt = 0;
            while (!dut.w_done && wait_cnt < 400000) begin
                @(posedge clk);
                wait_cnt = wait_cnt + 1;
            end
            if (!dut.w_done) begin
                $display("[BUSY-START][FAIL] timeout after duplicate START; state=%0d q=%0d dq=%0d",
                         dut.u_engine.state, dut.u_queue.count, dut.u_engine.dq_cnt);
                errors = errors + 1;
            end else begin
                axil_read(12'h010, rd_val);
                if (rd_val !== 32'd33) begin
                    $display("[BUSY-START][FAIL] MARKED=%0d, expect 33", rd_val);
                    errors = errors + 1;
                end
                axil_read(12'h020, rd_val);
                if (rd_val[3:0] !== 4'h0 || rd_val[4] !== 1'b1) begin
                    $display("[BUSY-START][FAIL] STATUS=0x%08x, expect errors=0 idle=1", rd_val);
                    errors = errors + 1;
                end
                for (i = 0; i < N; i = i + 1) begin
                    word = dut.u_bitmap.mem[i];
                    if (word[i % 32] !== (i <= 32)) begin
                        $display("[BUSY-START][FAIL] bitmap[%0d]=%0d, expect %0d",
                                 i, word[i % 32], (i <= 32));
                        errors = errors + 1;
                    end
                end
            end
        end

        if (errors == 0)
            $display("[BUSY-START] ==================== PASS ====================");
        else
            $display("[BUSY-START][FAIL] %0d check(s) failed", errors);
        $finish;
    end

    initial begin
        #5000000;
        $display("[BUSY-START][FAIL] global timeout");
        $finish;
    end

endmodule
