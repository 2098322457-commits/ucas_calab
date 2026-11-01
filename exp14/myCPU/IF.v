// IF 阶段：PC 生成与取指。
// 位于五级流水线第一级，向 ID 阶段输出 IF-ID 流水寄存器；
// 分支跳转(br_taken)时下一拍从 br_target 取指，stall 时冻结当前状态。
// exp14：inst SRAM 改为类 SRAM 握手接口，req 保持到 addr_ok，data_ok 时取回指令。
module if_stage(
    input  wire        clk,        // 时钟
    input  wire        reset,      // 同步复位，高有效
    input  wire        stall,      // 流水线暂停（load-use 冲突或乘除多周期时由 ID 拉高）
    input  wire        hold,       // MEM 级访存未完成，冻结前端
    input  wire        br_taken,   // 分支/跳转已判定发生
    input  wire [31:0] br_target,  // 分支/跳转目标地址
    // inst sram interface（类 SRAM 握手）
    output reg         inst_sram_req,   // 取指请求
    output wire        inst_sram_wr,    // 取指固定为读
    output wire [ 1:0] inst_sram_size,  // 取指固定按字
    output wire [ 3:0] inst_sram_wstrb, // 取指无写选通
    output reg  [31:0] inst_sram_addr,  // 取指地址
    output wire [31:0] inst_sram_wdata, // 取指无写数据
    input  wire        inst_sram_addr_ok, // 地址握手
    input  wire        inst_sram_data_ok, // 数据握手
    input  wire [31:0] inst_sram_rdata,   // 取回指令
    output wire        if_busy,           // 取指请求未完成
    // IF-ID pipeline bus
    output reg         if_id_valid,
    output reg  [31:0] if_id_pc,
    output reg  [31:0] if_id_inst
);

// 取指握手状态：IDLE 空闲，ISSUE 发出请求，ADDR 等地址握手，DATA 等数据握手，COMMIT 暂存待提交
localparam S_IDLE   = 3'd0;
localparam S_ISSUE  = 3'd1;
localparam S_ADDR   = 3'd2;
localparam S_DATA   = 3'd3;
localparam S_COMMIT = 3'd4;

reg [2:0]  state;       // 当前握手状态
reg [31:0] pc;          // 当前取指 PC
reg [31:0] req_pc;      // 当前请求对应的 PC
reg [31:0] pend_inst;   // stall/hold 期间暂存的取回指令
reg [31:0] pend_pc;     // 暂存指令对应的 PC
reg        pend_valid;  // 是否有暂存指令
reg        first_fetch; // 复位后的第一次取指（0x1bfffffc）只用于对齐，不写入 IF-ID

// 取指固定为字读，无写操作
assign inst_sram_wr    = 1'b0;
assign inst_sram_size  = 2'b10;
assign inst_sram_wstrb = 4'b0;
assign inst_sram_wdata = 32'b0;

// 请求未完成时冻结后端；ISSUE 第一拍不冻结，保证 IF-ID 旧指令先被 ID 取走
assign if_busy = (state == S_ADDR) || (state == S_DATA);

// 时序寄存器更新：握手状态、PC 推进与 IF-ID 流水寄存器写入
always @(posedge clk) begin
    if (reset) begin
        state          <= S_IDLE;
        pc             <= 32'h1bfffffc;
        req_pc         <= 32'b0;
        inst_sram_req  <= 1'b0;
        inst_sram_addr <= 32'b0;
        pend_inst      <= 32'b0;
        pend_pc        <= 32'b0;
        pend_valid     <= 1'b0;
        first_fetch    <= 1'b1;
        if_id_valid    <= 1'b0;
        if_id_pc       <= 32'b0;
        if_id_inst     <= 32'b0;
    end
    else begin
        case (state)
            S_IDLE: begin
                inst_sram_req <= 1'b0;
                if (br_taken) begin
                    // 分支/异常重定向：作废 IF-ID，改从目标地址取指
                    if_id_valid    <= 1'b0;
                    req_pc         <= br_target;
                    inst_sram_addr <= br_target;
                    inst_sram_req  <= 1'b1;
                    state          <= S_ISSUE;
                end
                else if (!stall && !hold) begin
                    // 正常取指：从当前 PC 发起请求；IF-ID 旧指令已被 ID 取走，先置空
                    if_id_valid    <= 1'b0;
                    req_pc         <= pc;
                    inst_sram_addr <= pc;
                    inst_sram_req  <= 1'b1;
                    state          <= S_ISSUE;
                end
            end

            S_ISSUE: begin
                inst_sram_req <= 1'b1;
                if (inst_sram_addr_ok) begin
                    inst_sram_req <= 1'b0;
                    // 地址接收后统一等 data_ok，避免把上一笔请求的 data_ok 当成当前数据
                    state <= S_DATA;
                end
                else begin
                    state <= S_ADDR;
                end
            end

            S_ADDR: begin
                inst_sram_req <= 1'b1;
                if (inst_sram_addr_ok) begin
                    inst_sram_req <= 1'b0;
                    state <= S_DATA;
                end
            end

            S_DATA: begin
                inst_sram_req <= 1'b0;
                if (inst_sram_data_ok) begin
                    if (br_taken) begin
                        if_id_valid <= 1'b0;
                        pc          <= br_target;
                        state       <= S_IDLE;
                    end
                    else if (first_fetch) begin
                        first_fetch <= 1'b0;
                        pc          <= req_pc + 32'h4;
                        state       <= S_IDLE;
                    end
                    else if (stall || hold) begin
                        pend_inst  <= inst_sram_rdata;
                        pend_pc    <= req_pc;
                        pend_valid <= 1'b1;
                        state      <= S_COMMIT;
                    end
                    else begin
                        if_id_valid <= 1'b1;
                        if_id_pc    <= req_pc;
                        if_id_inst  <= inst_sram_rdata;
                        pc          <= req_pc + 32'h4;
                        state       <= S_IDLE;
                    end
                end
            end

            S_COMMIT: begin
                inst_sram_req <= 1'b0;
                if (first_fetch) begin
                    first_fetch <= 1'b0;
                    pend_valid  <= 1'b0;
                    pc          <= pend_pc + 32'h4;
                    state       <= S_IDLE;
                end
                else if (br_taken) begin
                    // 暂存的是错误路径指令，丢弃并重定向
                    if_id_valid <= 1'b0;
                    pend_valid  <= 1'b0;
                    pc          <= br_target;
                    state       <= S_IDLE;
                end
                else if (!stall && !hold) begin
                    // stall/hold 解除，提交暂存指令
                    if_id_valid <= 1'b1;
                    if_id_pc    <= pend_pc;
                    if_id_inst  <= pend_inst;
                    pc          <= pend_pc + 32'h4;
                    pend_valid  <= 1'b0;
                    state       <= S_IDLE;
                end
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
