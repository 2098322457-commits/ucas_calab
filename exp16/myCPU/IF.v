// IF 阶段（低延迟版）：PC 生成与取指。
// 与 5 状态版的区别：
//   1. 取消 S_ISSUE —— S_IDLE 当拍组合输出 req，省 1 拍；
//   2. 若 addr_ok 当拍到达，直接进 S_DATA，省 1 拍；
//   3. S_COMMIT 改名 S_HOLD，用 pend 寄存器暂存，语义不变。
//   2. 若 addr_ok 当拍到达，直接进 S_DATA，省 1 拍；
//   3. S_COMMIT 改名 S_HOLD，用 pend 寄存器暂存，语义不变。
module if_stage(
    input  wire        stall,      // 流水线暂停（load-use 冲突或乘除多周期时由 ID 拉高）
    input  wire        hold,       // MEM 级访存未完成，冻结前端
    input  wire        stall,      // 流水线暂停（load-use 冲突或乘除多周期时由 ID 拉高）
    input  wire        hold,       // MEM 级访存未完成，冻结前端
    input  wire        br_taken,   // 分支/跳转已判定发生
    input  wire [31:0] br_target,  // 分支/跳转目标地址
    // inst sram interface（类 SRAM 握手）
    output wire        inst_sram_req,   // 取指请求（组合输出）
    output wire        inst_sram_wr,    // 取指固定为读
    output wire [31:0] inst_sram_addr,  // 取指地址（S_IDLE 用 PC，S_ADDR 用锁存值）
    output wire [ 3:0] inst_sram_wstrb, // 取指无写选通
    output wire [31:0] inst_sram_addr,  // 取指地址（S_IDLE 用 PC，S_ADDR 用锁存值）
    output wire [31:0] inst_sram_wdata, // 取指无写数据
    input  wire        inst_sram_addr_ok, // 地址握手
    input  wire        inst_sram_data_ok, // 数据握手
    // IF-ID pipeline bus
    output reg         if_id_valid,
    output reg  [31:0] if_id_pc,
    output reg  [31:0] if_id_inst
    output reg  [31:0] if_id_pc,
    output reg  [31:0] if_id_inst
);
localparam S_ADDR = 2'd1;   // 等地址握手（addr_ok 未在发请求当拍到达）
localparam S_IDLE = 2'd0;   // 空闲：可当拍发请求
localparam S_HOLD = 2'd3;   // 已取回但送不进 ID，暂存等待
localparam S_DATA = 2'd2;   // 等数据握手
localparam S_HOLD = 2'd3;   // 已取回但送不进 ID，暂存等待
reg [31:0] pc;          // 当前取指 PC
reg [31:0] req_pc;      // 当前请求对应的 PC
reg [31:0] addr_r;      // 请求地址锁存（addr_ok 延迟时保持）
reg [31:0] pend_inst;   // stall/hold 期间暂存的取回指令
reg [31:0] pend_pc;     // 暂存指令对应的 PC
reg        first_fetch; // 复位后第一次取指只用于对齐

assign inst_sram_wr    = 1'b0;
assign inst_sram_size  = 2'b10;
assign inst_sram_wstrb = 4'b0;
assign inst_sram_wdata = 32'b0;

// 空闲态且允许取指时，当拍就发出请求（不再经过 ISSUE 中间态）
wire launch = (state == S_IDLE) && (br_taken || (!stall && !hold));

assign inst_sram_req  = (state == S_IDLE) ? launch : (state == S_ADDR);
assign inst_sram_addr = (state == S_IDLE) ? (br_taken ? br_target : pc) : addr_r;

// 地址尚未接收、或数据尚未返回时算忙；S_HOLD 不算忙，否则会死锁
// 地址尚未接收、或数据尚未返回时算忙；S_HOLD 不算忙，否则会死锁
assign if_busy = (state == S_ADDR) || (state == S_DATA);
        if_id_pc    <= 32'b0;
        if_id_inst  <= 32'b0;
    end
    else begin
        case (state)
            S_IDLE: begin
                    if_id_valid <= 1'b0;                       // 旧指令已被 ID 取走
        pend_pc     <= 32'b0;
                    req_pc      <= br_taken ? br_target : pc;
        if_id_valid <= 1'b0;
        if_id_pc    <= 32'b0;
        if_id_inst  <= 32'b0;
                    state       <= inst_sram_addr_ok ? S_DATA : S_ADDR;
                end
            S_DATA: begin
                if (inst_sram_data_ok) begin
                    if (br_taken) begin
                    if_id_valid <= 1'b0;                       // 旧指令已被 ID 取走
                    req_pc      <= br_taken ? br_target : pc;
                    addr_r      <= br_taken ? br_target : pc;
                    // 地址当拍握手成功则直接进入等数据，省掉一拍
                    state       <= inst_sram_addr_ok ? S_DATA : S_ADDR;
                    else if (first_fetch) begin
                        first_fetch <= 1'b0;
                        pc          <= req_pc + 32'h4;
                        state       <= S_IDLE;
                    end
                    else if (stall || hold) begin
                        pend_inst <= inst_sram_rdata;
                        pend_pc   <= req_pc;
                        state     <= S_HOLD;
                    if (br_taken) begin
                        if_id_valid <= 1'b0;
                        pc          <= br_target;
                        state       <= S_IDLE;
                        if_id_valid <= 1'b1;
                        if_id_pc    <= req_pc;
                        if_id_inst  <= inst_sram_rdata;
                        pc          <= req_pc + 32'h4;
                        state       <= S_IDLE;
                    end
                    else if (stall || hold) begin

                        pend_pc   <= req_pc;
            S_HOLD: begin
                if (first_fetch) begin
                    first_fetch <= 1'b0;
                        if_id_valid <= 1'b1;
                        if_id_pc    <= req_pc;
                        if_id_inst  <= inst_sram_rdata;
                        pc          <= req_pc + 32'h4;
                    state       <= S_IDLE;
                end
                else if (br_taken) begin
                    if_id_valid <= 1'b0;
                    pc          <= br_target;
                    state       <= S_IDLE;
                if (first_fetch) begin
                    first_fetch <= 1'b0;
                    pc          <= pend_pc + 32'h4;
                    state       <= S_IDLE;
                end
                else if (br_taken) begin
                    if_id_valid <= 1'b0;
                    pc          <= br_target;
                    state       <= S_IDLE;
                    if_id_valid <= 1'b1;
                else if (!stall && !hold) begin
                    if_id_valid <= 1'b1;
                    if_id_pc    <= pend_pc;
                    if_id_inst  <= pend_inst;
                    pc          <= pend_pc + 32'h4;
                    state       <= S_IDLE;
                    state       <= S_IDLE;
                end
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
