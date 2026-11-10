// 2x1 类 SRAM→AXI 转接桥
// 将 IF 的取指请求与 MEM 的访存请求（类 SRAM req/addr_ok/data_ok 握手）
// 仲裁后复用为一个 AXI 主接口（单拍、字宽、INCR 突发）。
// 类 SRAM 侧：req 保持到 addr_ok，之后等待 data_ok 取回/确认数据。
// AXI 侧：同一时刻只允许一笔未完成事务，响应返回后向对应端口给出单拍 data_ok。
module sram_axi_bridge(
    input  wire        clk,
    input  wire        aresetn,
    //---------------- inst sram (类 SRAM) ----------------
    input  wire        inst_req,
    input  wire        inst_wr,
    input  wire [ 1:0] inst_size,
    input  wire [ 3:0] inst_wstrb,
    input  wire [31:0] inst_addr,
    input  wire [31:0] inst_wdata,
    output wire        inst_addr_ok,
    output wire        inst_data_ok,
    output wire [31:0] inst_rdata,
    //---------------- data sram (类 SRAM) ----------------
    input  wire        data_req,
    input  wire        data_wr,
    input  wire [ 1:0] data_size,
    input  wire [ 3:0] data_wstrb,
    input  wire [31:0] data_addr,
    input  wire [31:0] data_wdata,
    output wire        data_addr_ok,
    output wire        data_data_ok,
    output wire [31:0] data_rdata,
    //---------------- AXI master ----------------
    //ar
    output wire [ 3:0] arid,
    output wire [31:0] araddr,
    output wire        arvalid,
    input  wire        arready,
    //r
    input  wire [ 3:0] rid,
    input  wire [31:0] rdata,
    input  wire [ 1:0] rresp,
    input  wire        rlast,
    input  wire        rvalid,
    output wire        rready,
    //aw
    output wire [ 3:0] awid,
    output wire [31:0] awaddr,
    output wire        awvalid,
    input  wire        awready,
    //w
    output wire [ 3:0] wid,
    output wire [31:0] wdata,
    output wire [ 3:0] wstrb,
    output wire        wlast,
    output wire        wvalid,
    input  wire        wready,
    //b
    input  wire [ 3:0] bid,
    input  wire [ 1:0] bresp,
    input  wire        bvalid,
    output wire        bready
);

// 状态机：IDLE 等待请求，AR/R 读事务，AW/B 写事务，DONE 向 CPU 给出 data_ok
localparam S_IDLE = 3'd0;
localparam S_AR   = 3'd1;
localparam S_R    = 3'd2;
localparam S_AW   = 3'd3;
localparam S_B    = 3'd4;
localparam S_DONE = 3'd5;

reg [2:0]  state;
reg        sel_inst;   // 1：当前事务属于取指端口；0：属于数据端口
reg        rr;         // 轮询仲裁位：1 表示上一次服务的是取指端口
reg [31:0] addr_r;     // 锁存的访问地址
reg        wr_r;       // 锁存的读写标志
reg [31:0] wdata_r;    // 锁存的写数据
reg [ 3:0] wstrb_r;    // 锁存的写选通
reg [31:0] rdata_r;    // 读响应数据
reg        aw_done;    // 写地址通道已完成
reg        w_done;     // 写数据通道已完成

// 轮询仲裁：两个端口同时请求时，优先服务上一次未服务的端口
wire both_req = inst_req & data_req;
wire sel_inst_now = (state == S_IDLE) & inst_req & (both_req ? ~rr : 1'b1);
wire sel_data_now = (state == S_IDLE) & data_req & (both_req ?  rr : 1'b1);

// 地址握手：仅在空闲态接收请求，单拍有效
assign inst_addr_ok = sel_inst_now;
assign data_addr_ok = sel_data_now;

// 数据握手与读数据只在 DONE 状态向对应端口给出
assign inst_data_ok = (state == S_DONE) &  sel_inst;
assign data_data_ok = (state == S_DONE) & ~sel_inst;
assign inst_rdata   = rdata_r;
assign data_rdata   = rdata_r;

// AXI 读地址通道
assign arid    = 4'd0;
assign araddr  = addr_r;
assign arvalid = (state == S_AR);
assign rready  = (state == S_R);
// AXI 写地址/写数据通道
assign awid    = 4'd0;
assign awaddr  = addr_r;
assign awvalid = (state == S_AW) & ~aw_done;
assign wid     = 4'd0;
assign wdata   = wdata_r;
assign wstrb   = wstrb_r;
assign wlast   = 1'b1;
assign wvalid  = (state == S_AW) & ~w_done;
assign bready  = (state == S_B);

// 写通道各自的握手完成标志
wire aw_hs = awvalid & awready;
wire w_hs  = wvalid  & wready;
wire aw_done_now = aw_done | aw_hs;
wire w_done_now  = w_done  | w_hs;

always @(posedge clk) begin
    if (!aresetn) begin
        state    <= S_IDLE;
        sel_inst <= 1'b0;
        rr       <= 1'b0;
        addr_r   <= 32'b0;
        wr_r     <= 1'b0;
        wdata_r  <= 32'b0;
        wstrb_r  <= 4'b0;
        rdata_r  <= 32'b0;
        aw_done  <= 1'b0;
        w_done   <= 1'b0;
    end
    else begin
        case (state)
            S_IDLE: begin
                if (sel_inst_now) begin
                    sel_inst <= 1'b1;
                    rr       <= 1'b1;
                    addr_r   <= inst_addr;
                    wr_r     <= inst_wr;
                    wdata_r  <= inst_wdata;
                    wstrb_r  <= inst_wstrb;
                    aw_done  <= 1'b0;
                    w_done   <= 1'b0;
                    state    <= inst_wr ? S_AW : S_AR;
                end
                else if (sel_data_now) begin
                    sel_inst <= 1'b0;
                    rr       <= 1'b0;
                    addr_r   <= data_addr;
                    wr_r     <= data_wr;
                    wdata_r  <= data_wdata;
                    wstrb_r  <= data_wstrb;
                    aw_done  <= 1'b0;
                    w_done   <= 1'b0;
                    state    <= data_wr ? S_AW : S_AR;
                end
            end

            // 读地址握手，之后等待读数据
            S_AR: begin
                if (arready) state <= S_R;
            end

            // 读数据返回：锁存并进入 DONE 给出 data_ok
            S_R: begin
                if (rvalid) begin
                    rdata_r <= rdata;
                    state   <= S_DONE;
                end
            end

            // 写地址与写数据通道独立握手，两者都完成后等待写响应
            S_AW: begin
                aw_done <= aw_done_now;
                w_done  <= w_done_now;
                if (aw_done_now && w_done_now) state <= S_B;
            end

            // 写响应返回：进入 DONE 向 CPU 确认写完成
            S_B: begin
                if (bvalid) state <= S_DONE;
            end

            // data_ok 单拍有效，随后回到空闲等待下一笔请求
            S_DONE: begin
                state <= S_IDLE;
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
