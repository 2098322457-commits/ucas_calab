// WB 阶段：写回数据选择与寄存器堆写回。
// 位于五级流水线最后一级，选择写回数据并向 trace 调试接口输出；
// 对按字节/半字 load 结果，依据访存宽度与符号标志做相应的截取与扩展。
module wb_stage(
    // MEM-WB pipeline bus
    input  wire        mem_wb_valid,
    input  wire [31:0] mem_wb_pc,
    input  wire [31:0] mem_wb_alu_result,
    input  wire [31:0] mem_wb_mem_data,
    input  wire        mem_wb_res_from_mem,
    input  wire        mem_wb_gr_we,
    input  wire [ 4:0] mem_wb_dest,

    // Register-file write-back bus（写回寄存器堆）
    output wire        rf_we,
    output wire [ 4:0] rf_waddr,
    output wire [31:0] rf_wdata,
    // trace debug interface
    output wire [31:0] debug_wb_pc,
    output wire [ 3:0] debug_wb_rf_we,
    output wire [ 4:0] debug_wb_rf_wnum,
    output wire [31:0] debug_wb_rf_wdata
);

wire [31:0] wb_result;   // 最终写回数据

// 写回数据选择：res_from_mem 时按宽度/符号扩展读回数据，否则取 ALU 结果
// exp14：load 数据已在 MEM 阶段按请求地址完成字节/半字扩展，wb无需再做扩展
assign wb_result = mem_wb_res_from_mem ? mem_wb_mem_data
                                       : mem_wb_alu_result;

// 寄存器堆写回：流水寄存器有效且需写通用寄存器时才写
assign rf_we    = mem_wb_valid && mem_wb_gr_we;
assign rf_waddr = mem_wb_dest;
assign rf_wdata = wb_result;

// trace 调试接口输出
assign debug_wb_pc       = mem_wb_pc;
assign debug_wb_rf_we    = {4{rf_we}};
assign debug_wb_rf_wnum  = mem_wb_dest;
assign debug_wb_rf_wdata = wb_result;

endmodule