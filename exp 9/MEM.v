// MEM 阶段：访存（数据 SRAM 接口）与 MEM-WB 流水寄存器。
// 位于五级流水线第四级，接收 EX-MEM 流水寄存器，输出 MEM-WB 流水寄存器。
module mem_stage(
    input  wire        clk,
    input  wire        reset,
    // EX-MEM pipeline bus（来自 EX 阶段的流水寄存器）
    input  wire        ex_mem_valid,
    input  wire [31:0] ex_mem_pc,
    input  wire [31:0] ex_mem_alu_result,
    input  wire [31:0] ex_mem_store_data,
    input  wire        ex_mem_mem_we,
    input  wire        ex_mem_res_from_mem,
    input  wire        ex_mem_gr_we,
    input  wire [ 4:0] ex_mem_dest,
    // data sram interface
    output wire        data_sram_en,
    output wire [ 3:0] data_sram_we,
    output wire [31:0] data_sram_addr,
    output wire [31:0] data_sram_wdata,
    input  wire [31:0] data_sram_rdata,
    // MEM-WB pipeline bus
    output reg         mem_wb_valid,
    output reg  [31:0] mem_wb_pc,
    output reg  [31:0] mem_wb_alu_result,
    output reg  [31:0] mem_wb_mem_data,
    output reg         mem_wb_res_from_mem,
    output reg         mem_wb_gr_we,
    output reg  [ 4:0] mem_wb_dest
);

// 访存请求：load/store 有效时使能；仅 store 时写使能
assign data_sram_en    = ex_mem_valid && (ex_mem_mem_we || ex_mem_res_from_mem);
assign data_sram_we    = {4{ex_mem_valid && ex_mem_mem_we}};
assign data_sram_addr  = ex_mem_alu_result;
assign data_sram_wdata = ex_mem_store_data;

// 时序寄存器更新：将访存结果与写回信息锁存进 MEM-WB 流水寄存器
always @(posedge clk) begin
    if (reset) begin
        mem_wb_valid        <= 1'b0;
        mem_wb_pc           <= 32'b0;
        mem_wb_alu_result   <= 32'b0;
        mem_wb_mem_data     <= 32'b0;
        mem_wb_res_from_mem <= 1'b0;
        mem_wb_gr_we        <= 1'b0;
        mem_wb_dest         <= 5'b0;
    end
    else begin
        mem_wb_valid        <= ex_mem_valid;
        mem_wb_pc           <= ex_mem_pc;
        mem_wb_alu_result   <= ex_mem_alu_result;
        mem_wb_mem_data     <= data_sram_rdata;
        mem_wb_res_from_mem <= ex_mem_res_from_mem;
        mem_wb_gr_we        <= ex_mem_gr_we;
        mem_wb_dest         <= ex_mem_dest;
    end
end

endmodule
