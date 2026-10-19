// gc_top.v — FOGCCC GC协处理器顶层模块
// 平台: Xilinx Zynq-7000 XC7Z100
//
// 端口说明:
//   S_AXI_*    : AXI-Lite从机, 连接PS的M_AXI_GP0 (寄存器控制)
//   S_AXI_HP_* : AXI HP从机, 连接PS的S_AXI_HP0  (读DDR对象图)
//
// 时钟: 单一时钟域. S_AXI_HP_ACLK 与 S_AXI_ACLK 都接 FCLK_CLK0 (100MHz).
//
// 内部结构:
//   gc_regs        AXI-Lite寄存器接口
//   gc_mark_engine BFS标记状态机 (核心)
//   gc_bitmap      标记位图 (简单双口BRAM, 读/写地址独立)
//   gc_queue       BFS队列 (双口BRAM)
//   gc_axi_read    AXI HP读命令队列主控 (多笔未完成读)
//   root_mem[]     根集存储 (分布式RAM)
module gc_top (
    input  wire        S_AXI_ACLK,
    input  wire        S_AXI_ARESETN,
    input  wire [11:0] S_AXI_AWADDR,
    input  wire        S_AXI_AWVALID,
    output wire        S_AXI_AWREADY,
    input  wire [31:0] S_AXI_WDATA,
    input  wire [3:0]  S_AXI_WSTRB,
    input  wire        S_AXI_WVALID,
    output wire        S_AXI_WREADY,
    output wire [1:0]  S_AXI_BRESP,
    output wire        S_AXI_BVALID,
    input  wire        S_AXI_BREADY,
    input  wire [11:0] S_AXI_ARADDR,
    input  wire        S_AXI_ARVALID,
    output wire        S_AXI_ARREADY,
    output wire [31:0] S_AXI_RDATA,
    output wire [1:0]  S_AXI_RRESP,
    output wire        S_AXI_RVALID,
    input  wire        S_AXI_RREADY,

    // HP 主机实为 AXI3（PS7 的 S_AXI_HP 就是 AXI3）：ID_WIDTH=6，两条读流
    // （ARID=0 引用 / ARID=1 对象头），ARSIZE=3 / ARLEN=0 / ARBURST=INCR。
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI_HP_ACLK, ASSOCIATED_BUSIF S_AXI_HP, ASSOCIATED_RESET S_AXI_HP_ARESETN" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 S_AXI_HP_ACLK CLK" *)
    input  wire        S_AXI_HP_ACLK,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 S_AXI_HP_ARESETN RST" *)
    input  wire        S_AXI_HP_ARESETN,

    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI_HP, PROTOCOL AXI3, ADDR_WIDTH 32, DATA_WIDTH 64, ID_WIDTH 6, HAS_BURST 1, NUM_READ_OUTSTANDING 8, NUM_WRITE_OUTSTANDING 1, READ_WRITE_MODE READ_WRITE, SUPPORTS_NARROW_BURST 0" *)
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP ARADDR" *)
    output wire [31:0] S_AXI_HP_ARADDR,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP ARID" *)
    output wire [5:0]  S_AXI_HP_ARID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP ARLEN" *)
    output wire [3:0]  S_AXI_HP_ARLEN,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP ARSIZE" *)
    output wire [2:0]  S_AXI_HP_ARSIZE,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP ARBURST" *)
    output wire [1:0]  S_AXI_HP_ARBURST,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP ARCACHE" *)
    output wire [3:0]  S_AXI_HP_ARCACHE,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP ARPROT" *)
    output wire [2:0]  S_AXI_HP_ARPROT,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP ARVALID" *)
    output wire        S_AXI_HP_ARVALID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP ARREADY" *)
    input  wire        S_AXI_HP_ARREADY,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP RDATA" *)
    input  wire [63:0] S_AXI_HP_RDATA,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP RID" *)
    input  wire [5:0]  S_AXI_HP_RID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP RRESP" *)
    input  wire [1:0]  S_AXI_HP_RRESP,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP RLAST" *)
    input  wire        S_AXI_HP_RLAST,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP RVALID" *)
    input  wire        S_AXI_HP_RVALID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP RREADY" *)
    output wire        S_AXI_HP_RREADY,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP AWADDR" *)
    output wire [31:0] S_AXI_HP_AWADDR,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP AWID" *)
    output wire [5:0]  S_AXI_HP_AWID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP AWLEN" *)
    output wire [3:0]  S_AXI_HP_AWLEN,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP AWSIZE" *)
    output wire [2:0]  S_AXI_HP_AWSIZE,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP AWBURST" *)
    output wire [1:0]  S_AXI_HP_AWBURST,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP AWCACHE" *)
    output wire [3:0]  S_AXI_HP_AWCACHE,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP AWPROT" *)
    output wire [2:0]  S_AXI_HP_AWPROT,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP AWVALID" *)
    output wire        S_AXI_HP_AWVALID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP AWREADY" *)
    input  wire        S_AXI_HP_AWREADY,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP WDATA" *)
    output wire [63:0] S_AXI_HP_WDATA,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP WID" *)
    output wire [5:0]  S_AXI_HP_WID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP WSTRB" *)
    output wire [7:0]  S_AXI_HP_WSTRB,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP WLAST" *)
    output wire        S_AXI_HP_WLAST,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP WVALID" *)
    output wire        S_AXI_HP_WVALID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP WREADY" *)
    input  wire        S_AXI_HP_WREADY,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP BID" *)
    input  wire [5:0]  S_AXI_HP_BID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP BRESP" *)
    input  wire [1:0]  S_AXI_HP_BRESP,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP BVALID" *)
    input  wire        S_AXI_HP_BVALID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_HP BREADY" *)
    output wire        S_AXI_HP_BREADY,

    output wire        irq_o
);

    wire [31:0] w_obj_base, w_obj_count, w_root_count;
    wire        w_start, w_clear_q, w_abort;
    wire        w_done;
    wire [31:0] w_marked_count, w_cycles;

    // 只读 DDR; 接口为完整 AXI4, 写信号绑常量
    assign S_AXI_HP_AWADDR  = 32'h0;
    assign S_AXI_HP_AWID    = 6'h0;
    assign S_AXI_HP_AWLEN   = 4'h0;
    assign S_AXI_HP_AWSIZE  = 3'b011;
    assign S_AXI_HP_AWBURST = 2'b01;
    assign S_AXI_HP_AWCACHE = 4'b0011;
    assign S_AXI_HP_AWPROT  = 3'b000;
    assign S_AXI_HP_AWVALID = 1'b0;

    assign S_AXI_HP_WDATA   = 64'h0;
    assign S_AXI_HP_WID     = 6'h0;
    assign S_AXI_HP_WSTRB   = 8'h0;
    assign S_AXI_HP_WLAST   = 1'b1;
    assign S_AXI_HP_WVALID  = 1'b0;

    assign S_AXI_HP_BREADY  = 1'b1;

    (* ram_style = "distributed" *)
    reg  [31:0] root_mem [0:255];
    wire [7:0]  root_wr_addr;
    wire [31:0] root_wr_data;
    wire        root_we;
    wire [7:0]  root_rd_addr;
    reg  [31:0] root_rd_data;

    always @(posedge S_AXI_ACLK) begin
        if (root_we)
            root_mem[root_wr_addr] <= root_wr_data;
    end

    always @(posedge S_AXI_ACLK) begin
        root_rd_data <= root_mem[root_rd_addr];
    end

    // An unwritten root entry must read 0, never stale/X: software may set
    // root_count larger than the number of entries it actually programmed.
    integer root_i;
    initial begin
        for (root_i = 0; root_i < 256; root_i = root_i + 1) root_mem[root_i] = 32'h0;
    end

    wire        w_q_push, w_q_pop;
    wire [11:0] w_q_push_data, w_q_push_addr;
    wire        w_q_pop_ack;
    wire [11:0] w_q_pop_id;
    wire [11:0] w_q_head, w_q_tail;
    wire        w_q_empty;
    wire        w_q_full;
    wire [12:0] w_q_count;
    wire        w_err_ovf, w_err_ref, w_err_hdr;

    wire [11:0] w_bm_raddr_eng, w_bm_waddr;
    wire [11:0] w_bm_raddr_eff;
    wire [11:0] w_regs_bm_addr;
    wire [31:0] w_bm_wdata;
    wire [31:0] w_bm_rdata;
    reg  [31:0] w_bm_probe_r = 32'h0;
    wire        w_bm_we;
    wire        w_engine_idle;

    wire [31:0] w_rd_cmd_addr;
    wire        w_rd_cmd_valid, w_rd_cmd_ready;
    wire [31:0] w_rd_data;
    wire        w_rd_data_valid, w_rd_data_ready;
    wire        w_rd_err;

    wire _unused = &{1'b0,
                     S_AXI_WSTRB,                          // AXI-Lite字节选通(不用)
                     S_AXI_HP_AWREADY, S_AXI_HP_WREADY,    // 写通道桩(从不写)
                      S_AXI_HP_BRESP, S_AXI_HP_BVALID};     // write response (never used)

    gc_regs u_regs (
        .ACLK              (S_AXI_ACLK),
        .ARESETN           (S_AXI_ARESETN),
        .AWADDR            (S_AXI_AWADDR),
        .AWVALID           (S_AXI_AWVALID),
        .AWREADY           (S_AXI_AWREADY),
        .WDATA             (S_AXI_WDATA),
        .WSTRB             (S_AXI_WSTRB),
        .WVALID            (S_AXI_WVALID),
        .WREADY            (S_AXI_WREADY),
        .BRESP             (S_AXI_BRESP),
        .BVALID            (S_AXI_BVALID),
        .BREADY            (S_AXI_BREADY),
        .ARADDR            (S_AXI_ARADDR),
        .ARVALID           (S_AXI_ARVALID),
        .ARREADY           (S_AXI_ARREADY),
        .RDATA             (S_AXI_RDATA),
        .RRESP             (S_AXI_RRESP),
        .RVALID            (S_AXI_RVALID),
        .RREADY            (S_AXI_RREADY),
        .reg_obj_base      (w_obj_base),
        .reg_obj_count     (w_obj_count),
        .reg_root_count    (w_root_count),
        .reg_start         (w_start),
        .reg_abort         (w_abort),
        .reg_clear_q       (w_clear_q),
        .reg_done          (w_done),
        .reg_marked_count  (w_marked_count),
        .reg_cycles        (w_cycles),
        .q_head            (w_q_head),
        .q_tail            (w_q_tail),
        .err_ovf           (w_err_ovf),
        .err_rd            (w_rd_err),
        .err_ref           (w_err_ref),
        .err_hdr           (w_err_hdr),
        .root_wr_addr      (root_wr_addr),
        .root_wr_data      (root_wr_data),
        .root_we           (root_we),
        .reg_bm_addr       (w_regs_bm_addr),
        .reg_bm_data       (w_bm_probe_r)
    );

    wire [31:0] w_hdr_cmd_addr;
    wire        w_hdr_cmd_valid;
    wire        w_hdr_cmd_ready;
    wire [31:0] w_hdr_data;
    wire        w_hdr_data_valid;
    wire        w_hdr_data_ready;

    gc_mark_engine u_engine (
        .clk            (S_AXI_ACLK),
        .rst_n          (S_AXI_ARESETN),
        .obj_base       (w_obj_base),
        .obj_count      (w_obj_count),
        .root_count     (w_root_count),
        .start          (w_start),
        .abort          (w_abort),
        .root_rd_addr   (root_rd_addr),
        .root_rd_data   (root_rd_data),
        .q_push         (w_q_push),
        .q_push_data    (w_q_push_data),
        .q_push_addr    (w_q_push_addr),
        .q_pop          (w_q_pop),
        .q_pop_ack      (w_q_pop_ack),
        .q_pop_id       (w_q_pop_id),
        .q_tail         (w_q_tail),
        .q_empty        (w_q_empty),
        .q_full         (w_q_full),
        .bm_raddr       (w_bm_raddr_eng),
        .bm_rdata       (w_bm_rdata),
        .bm_waddr       (w_bm_waddr),
        .bm_wdata       (w_bm_wdata),
        .bm_we          (w_bm_we),
        .rd_cmd_addr    (w_rd_cmd_addr),
        .rd_cmd_valid   (w_rd_cmd_valid),
        .rd_cmd_ready   (w_rd_cmd_ready),
        .rd_data        (w_rd_data),
        .rd_data_valid  (w_rd_data_valid),
        .rd_data_ready  (w_rd_data_ready),
        .hdr_cmd_addr   (w_hdr_cmd_addr),
        .hdr_cmd_valid  (w_hdr_cmd_valid),
        .hdr_cmd_ready  (w_hdr_cmd_ready),
        .hdr_data       (w_hdr_data),
        .hdr_data_valid (w_hdr_data_valid),
        .hdr_data_ready (w_hdr_data_ready),
        .done           (w_done),
        .marked_count   (w_marked_count),
        .cycles         (w_cycles),
        .err_ovf        (w_err_ovf),
        .err_ref        (w_err_ref),
        .err_hdr        (w_err_hdr),
        .engine_idle    (w_engine_idle)
    );

    gc_bitmap u_bitmap (
        .clk   (S_AXI_ACLK),
        .waddr (w_bm_waddr),
        .din   (w_bm_wdata),
        .we    (w_bm_we),
        .raddr (w_bm_raddr_eff),
        .dout  (w_bm_rdata)
    );

    assign w_bm_raddr_eff = w_engine_idle ? w_regs_bm_addr : w_bm_raddr_eng;

    always @(posedge S_AXI_ACLK) w_bm_probe_r <= w_bm_rdata;

    gc_queue u_queue (
        .clk    (S_AXI_ACLK),
        .rst_n  (S_AXI_ARESETN),
        .clear  (w_clear_q),
        .waddr  (w_q_push_addr),
        .wdata  (w_q_push_data),
        .we     (w_q_push),
        .en     (w_q_pop),
        .rdata  (w_q_pop_id),
        .rvalid (w_q_pop_ack),
        .head   (w_q_head),
        .tail   (w_q_tail),
        .empty  (w_q_empty),
        .full   (w_q_full),
        .count  (w_q_count)
    );

    gc_axi_read u_axi_rd (
        .ACLK        (S_AXI_HP_ACLK),
        .ARESETN     (S_AXI_HP_ARESETN),

        .cmd0_valid  (w_rd_cmd_valid),
        .cmd0_addr   (w_rd_cmd_addr),
        .cmd0_ready  (w_rd_cmd_ready),
        .data0_out   (w_rd_data),
        .data0_valid (w_rd_data_valid),
        .data0_ready (w_rd_data_ready),

        .cmd1_valid  (w_hdr_cmd_valid),
        .cmd1_addr   (w_hdr_cmd_addr),
        .cmd1_ready  (w_hdr_cmd_ready),
        .data1_out   (w_hdr_data),
        .data1_valid (w_hdr_data_valid),
        .data1_ready (w_hdr_data_ready),

        .run_start   (w_start),
        .err         (w_rd_err),

        .ARADDR      (S_AXI_HP_ARADDR),
        .ARID        (S_AXI_HP_ARID),
        .ARLEN       (S_AXI_HP_ARLEN),
        .ARSIZE      (S_AXI_HP_ARSIZE),
        .ARBURST     (S_AXI_HP_ARBURST),
        .ARCACHE     (S_AXI_HP_ARCACHE),
        .ARPROT      (S_AXI_HP_ARPROT),
        .ARVALID     (S_AXI_HP_ARVALID),
        .ARREADY     (S_AXI_HP_ARREADY),
        .RDATA       (S_AXI_HP_RDATA),
        .RID         (S_AXI_HP_RID),
        .RRESP       (S_AXI_HP_RRESP),
        .RLAST       (S_AXI_HP_RLAST),
        .RVALID      (S_AXI_HP_RVALID),
        .RREADY      (S_AXI_HP_RREADY)
    );

    assign irq_o = w_done;

endmodule
