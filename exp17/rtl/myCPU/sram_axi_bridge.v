// 2x1 类 SRAM→AXI 转接桥（低延迟版）
//
// 与状态机版相比的延迟优化：
//   1. 接收请求的当拍就组合输出 arvalid —— 不再等一级仲裁状态；
//   2. 若 arready 当拍拉高，直接进入等数据状态（省 1 拍）；
//   3. 取消 S_DONE —— data_ok 在 rvalid / bvalid 当拍组合给出（省 1 拍）。
//
// 仍是单 outstanding：一次只允许一笔事务，取指与访存冲突时取指优先。
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
    output wire [ 3:0] arid,
    output wire [31:0] araddr,
    output wire        arvalid,
    input  wire        arready,
    input  wire [ 3:0] rid,
    input  wire [31:0] rdata,
    input  wire [ 1:0] rresp,
    input  wire        rlast,
    input  wire        rvalid,
    output wire        rready,
    output wire [ 3:0] awid,
    output wire [31:0] awaddr,
    output wire        awvalid,
    input  wire        awready,
    output wire [ 3:0] wid,
    output wire [31:0] wdata,
    output wire [ 3:0] wstrb,
    output wire        wlast,
    output wire        wvalid,
    input  wire        wready,
    input  wire [ 3:0] bid,
    input  wire [ 1:0] bresp,
    input  wire        bvalid,
    output wire        bready
);

localparam S_IDLE = 3'd0;
localparam S_ADDR = 3'd1;   // 地址握手未在当拍完成
localparam S_DATA = 3'd2;   // 等读数据
localparam S_AW   = 3'd3;   // 等 AW/W 握手
localparam S_B    = 3'd4;   // 等写响应

reg [2:0]  st;
reg        is_inst;     // 当前事务归属：1 取指，0 访存
reg        is_wr;       // 当前事务是写
reg [31:0] addr_r;
reg [31:0] wdata_r;
reg [3:0]  wstrb_r;
reg        aw_done;
reg        w_done;

//---------------- 请求接收（组合） ----------------
wire acc_i = (st == S_IDLE) && inst_req;
wire acc_d = (st == S_IDLE) && data_req && !inst_req;   // 冲突时取指优先

assign inst_addr_ok = acc_i;
assign data_addr_ok = acc_d;

wire acc_now  = acc_i | acc_d;
wire wr_now   = acc_i ? inst_wr : data_wr;
wire rd_now   = !wr_now;
wire acc_wr   = acc_now && wr_now;

//---------------- 读地址通道（接收当拍就发） ----------------
assign arvalid = (acc_now && rd_now) || (st == S_ADDR);
assign arid    = (st == S_IDLE) ? (acc_i ? 4'd0 : 4'd1) : (is_inst ? 4'd0 : 4'd1);
assign araddr  = (st == S_IDLE) ? (acc_i ? inst_addr : data_addr) : addr_r;

wire ar_hs = arvalid && arready;

//---------------- 读数据通道（组合 data_ok） ----------------
assign rready       = (st == S_DATA);
assign inst_rdata   = rdata;
assign data_rdata   = rdata;
assign inst_data_ok = (st == S_DATA) && rvalid &&  is_inst;
assign data_data_ok = ((st == S_DATA) && rvalid && !is_inst) ||
                      ((st == S_B)    && bvalid);

//---------------- 写通道 ----------------
assign awid    = 4'd1;
assign awaddr  = acc_wr ? (acc_i ? inst_addr : data_addr) : addr_r;
assign awvalid = acc_wr || ((st == S_AW) && !aw_done);
assign wid     = 4'd1;
assign wdata   = acc_wr ? (acc_i ? inst_wdata : data_wdata) : wdata_r;
assign wstrb   = acc_wr ? (acc_i ? inst_wstrb : data_wstrb) : wstrb_r;
assign wlast   = 1'b1;
assign wvalid  = acc_wr || ((st == S_AW) && !w_done);
assign bready  = (st == S_B);

wire aw_hs = awvalid && awready;
wire w_hs  = wvalid  && wready;

always @(posedge clk) begin
    if (!aresetn) begin
        st      <= S_IDLE;
        is_inst <= 1'b1;
        is_wr   <= 1'b0;
        addr_r  <= 32'b0;
        wdata_r <= 32'b0;
        wstrb_r <= 4'b0;
        aw_done <= 1'b0;
        w_done  <= 1'b0;
    end
    else begin
        case (st)
            S_IDLE: begin
                if (acc_now) begin
                    is_inst <= acc_i;
                    is_wr   <= wr_now;
                    addr_r  <= acc_i ? inst_addr  : data_addr;
                    wdata_r <= acc_i ? inst_wdata : data_wdata;
                    wstrb_r <= acc_i ? inst_wstrb : data_wstrb;
                    aw_done <= acc_wr && aw_hs;
                    w_done  <= acc_wr && w_hs;
                    if (wr_now) begin
                        if(aw_hs && w_hs) begin //写也考虑当拍地址握手的情况
                            st <= S_B;
                        end
                        else begin
                            st <= S_AW;
                        end
                    end
                    else if (ar_hs)begin
                        st <= S_DATA;  // 地址当拍已握手
                    end
                    else begin
                        st <= S_ADDR;
                    end
                end
            end

            S_ADDR: if (ar_hs) st <= S_DATA;

            S_DATA: if (rvalid) st <= S_IDLE;

            S_AW: begin
                aw_done <= aw_done | aw_hs;
                w_done  <= w_done  | w_hs;
                if ((aw_done || aw_hs) && (w_done || w_hs)) st <= S_B;
            end

            S_B: if (bvalid) st <= S_IDLE;

            default: st <= S_IDLE;
        endcase
    end
end

endmodule
