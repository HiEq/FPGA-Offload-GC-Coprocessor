// ============================================================
// gc_axi_read.v — AXI HP 读主控模块
//
// 功能: 从DDR读取32位数据 (对象图)
// 连接: PL的AXI HP从机端口 → PS的S_AXI_HP0 → DDR控制器
//
// 协议: AXI4 读事务 (单次, 无突发)
// 数据: 64位数据总线, 取低32位
//
// 时序:
//   start=1 → 状态IDLE→REQ→DATA → done=1, rdata=有效
//   从发起读到数据返回: 取决于DDR延迟, 典型50~200ns
// ============================================================
module gc_axi_read (
    input  wire        ACLK,
    input  wire        ARESETN,

    // 控制接口 (来自标记引擎)
    input  wire        start,        // 单周期启动脉冲
    input  wire [31:0] addr,         // 读地址 (4字节对齐)
    output reg  [31:0] rdata,        // 读回数据
    output reg         done,         // 1=空闲/完成, 0=进行中

    // AXI 读地址通道
    output reg  [31:0] ARADDR,
    output wire [2:0]  ARPROT,
    output reg         ARVALID,
    input  wire        ARREADY,

    // AXI 读数据通道
    input  wire [63:0] RDATA,
    input  wire [1:0]  RRESP,
    input  wire        RVALID,
    output wire        RREADY
);

    // 消除未使用位的警告
    wire _unused_axi = &{1'b0, RDATA[63:32]};

    localparam S_IDLE = 2'd0,   // 等待启动
               S_REQ  = 2'd1,   // 发送读地址
               S_DATA = 2'd2;   // 等待读数据

    reg [1:0] state;

    assign ARPROT = 3'b000;    // 非安全, 非特权
    assign RREADY = 1'b1;      // 始终准备好接收

    always @(posedge ACLK or negedge ARESETN) begin
        if (!ARESETN) begin
            state   <= S_IDLE;
            ARVALID <= 1'b0;
            done    <= 1'b1;
            rdata   <= 32'h0;
            ARADDR  <= 32'h0;
        end else begin
            case (state)
                S_IDLE: begin
                    done <= 1'b1;
                    if (start) begin
                        done    <= 1'b0;
                        ARADDR  <= addr;
                        ARVALID <= 1'b1;
                        state   <= S_REQ;
                    end
                end

                S_REQ: begin
                    if (ARVALID && ARREADY) begin
                        ARVALID <= 1'b0;
                        state   <= S_DATA;
                    end
                end

                S_DATA: begin
                    if (RVALID) begin
                        if (RRESP == 2'b00) begin
                            rdata <= RDATA[31:0];  // 取64位总线的低32位
                        end else begin
                            rdata <= 32'hFFFFFFFF;  // 错误 → 全1 (引擎跳过)
                        end
                        state <= S_IDLE;
                        done  <= 1'b1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
