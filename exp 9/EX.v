// EX 阶段：执行（组合 ALU 运算）与 EX-MEM 流水寄存器。
// 位于五级流水线第三级，接收 ID-EX 流水寄存器，输出 EX-MEM 流水寄存器。
module ex_stage(
    input  wire        clk,
    input  wire        reset,
    // ID-EX pipeline bus（来自 ID 阶段的流水寄存器）
    input  wire        id_ex_valid,
    input  wire [31:0] id_ex_pc,
    input  wire [31:0] id_ex_src1,
    input  wire [31:0] id_ex_src2,
    input  wire [31:0] id_ex_store_data,
    input  wire [11:0] id_ex_alu_op,
    input  wire        id_ex_mem_we,
    input  wire        id_ex_res_from_mem,
    input  wire        id_ex_gr_we,
    input  wire [ 4:0] id_ex_dest,
    // EX-MEM pipeline bus
    output reg         ex_mem_valid,
    output reg  [31:0] ex_mem_pc,
    output reg  [31:0] ex_mem_alu_result,
    output reg  [31:0] ex_mem_store_data,
    output reg         ex_mem_mem_we,
    output reg         ex_mem_res_from_mem,
    output reg         ex_mem_gr_we,
    output reg  [ 4:0] ex_mem_dest
);

wire [31:0] ex_alu_result;  // 组合 ALU 运算结果

// 组合 ALU：对 ID-EX 寄存器的操作数执行运算
alu u_alu(
    .alu_op     (id_ex_alu_op),
    .alu_src1   (id_ex_src1),
    .alu_src2   (id_ex_src2),
    .alu_result (ex_alu_result)
);

// 时序寄存器更新：将运算结果与控制信号锁存进 EX-MEM 流水寄存器
always @(posedge clk) begin
    if (reset) begin
        ex_mem_valid        <= 1'b0;
        ex_mem_pc           <= 32'b0;
        ex_mem_alu_result   <= 32'b0;
        ex_mem_store_data   <= 32'b0;
        ex_mem_mem_we       <= 1'b0;
        ex_mem_res_from_mem <= 1'b0;
        ex_mem_gr_we        <= 1'b0;
        ex_mem_dest         <= 5'b0;
    end
    else begin
        ex_mem_valid        <= id_ex_valid;
        ex_mem_pc           <= id_ex_pc;
        ex_mem_alu_result   <= ex_alu_result;
        ex_mem_store_data   <= id_ex_store_data;
        ex_mem_mem_we       <= id_ex_mem_we;
        ex_mem_res_from_mem <= id_ex_res_from_mem;
        ex_mem_gr_we        <= id_ex_gr_we;
        ex_mem_dest         <= id_ex_dest;
    end
end

endmodule
