// IF 阶段：PC 生成与取指。
// 位于五级流水线第一级，向 ID 阶段输出 IF-ID 流水寄存器；
// 分支跳转(br_taken)时下一拍从 br_target 取指，stall 时冻结当前状态。
module if_stage(
    input  wire        clk,        // 时钟
    input  wire        reset,      // 同步复位，高有效
    input  wire        stall,      // 流水线暂停（load-use 冲突或乘除多周期时由 ID 拉高）
    input  wire        br_taken,   // 分支/跳转已判定发生
    input  wire [31:0] br_target,  // 分支/跳转目标地址
    // inst sram interface
    output wire        inst_sram_en,
    output wire [ 3:0] inst_sram_we,
    output wire [31:0] inst_sram_addr,
    output wire [31:0] inst_sram_wdata,
    input  wire [31:0] inst_sram_rdata,
    // IF-ID pipeline bus
    output reg         if_id_valid,
    output reg  [31:0] if_id_pc,
    output reg  [31:0] if_id_inst
);

reg         valid;        // 复位后已进入正常取指
reg  [31:0] pc;           // 当前取指 PC
reg         if_req_valid; // 取指请求有效标志
reg  [31:0] if_req_pc;    // 当前取指请求对应的 PC

wire [31:0] seq_pc;       // 顺序下一条 PC
wire [31:0] nextpc;       // 下一拍 PC

// 下一拍 PC 选择：分支跳转时走目标地址(+4)，否则顺序执行
assign seq_pc = pc + 32'h4;
assign nextpc = br_taken ? (br_target + 32'h4) : seq_pc;

// 取指 SRAM 接口：stall 时不发起请求；分支时从 br_target 取指
assign inst_sram_en    = ~stall;
assign inst_sram_we    = 4'b0;
assign inst_sram_addr  = br_taken ? br_target : pc;
assign inst_sram_wdata = 32'b0;

// 时序寄存器更新：PC 推进与 IF-ID 流水寄存器写入
always @(posedge clk) begin
    if (reset) begin
        valid        <= 1'b0;
        pc           <= 32'h1bfffffc;
        if_req_valid <= 1'b0;
        if_req_pc    <= 32'b0;
        if_id_valid  <= 1'b0;
        if_id_pc     <= 32'b0;
        if_id_inst   <= 32'b0;
    end
    else if (stall) begin     
    end
    else begin
        valid <= 1'b1;      // 进入正常取指
        pc    <= nextpc;    // 推进 PC

        // IF-ID 流水寄存器：分支发生时本拍指令作废(valid=0)
        if_id_valid <= br_taken ? 1'b0 : if_req_valid;
        if_id_pc    <= if_req_pc;
        if_id_inst  <= inst_sram_rdata;

        // 取指请求：分支时改为从目标地址重新取指
        if_req_valid <= br_taken ? 1'b1 : valid;
        if_req_pc    <= br_taken ? br_target : pc;
    end
end

endmodule