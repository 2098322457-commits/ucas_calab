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
    input  wire [ 1:0] mem_wb_mem_size,
    input  wire        mem_wb_mem_unsigned,
    // Keep the original top-level WB data selection behavior.
    input  wire [31:0] data_sram_rdata,
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

wire [1:0] load_addr_low = mem_wb_alu_result[1:0];  // load 地址低 2 位，定位字节/半字

// 按访存宽度与符号标志对读回数据进行截取与扩展：
// 字节取 data[8*addr_low +: 8]，半字取高/低 16 位；无符号零扩展、有符号符号位扩展；字直通
function [31:0] load_extend;
    input [31:0] data;          
    input [1:0]  mem_size;      
    input        mem_unsigned;  
    reg [ 7:0] byte_r;
    reg [15:0] half_r;
    begin
        if (mem_size == 2'b00) begin
            byte_r      = data[8*load_addr_low +: 8];
            load_extend = mem_unsigned ? {24'b0, byte_r}
                                       : {{24{byte_r[7]}}, byte_r};
        end
        else if (mem_size == 2'b01) begin
            half_r      = load_addr_low[1] ? data[31:16] : data[15:0];
            load_extend = mem_unsigned ? {16'b0, half_r}
                                       : {{16{half_r[15]}}, half_r};
        end
        else begin
            load_extend = data;
        end
    end
endfunction

// 写回数据选择：res_from_mem 时按宽度/符号扩展读回数据，否则取 ALU 结果
assign wb_result = mem_wb_res_from_mem ? load_extend(data_sram_rdata, mem_wb_mem_size, mem_wb_mem_unsigned)
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