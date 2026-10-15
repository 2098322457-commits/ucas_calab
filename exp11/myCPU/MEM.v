// MEM 阶段：访存（数据 SRAM 接口）与 MEM-WB 流水寄存器。
// 位于五级流水线第四级，接收 EX-MEM 流水寄存器，输出 MEM-WB 流水寄存器；
// 支持按字节/半字/字访问：依据地址低位生成写选通 store_we，并把写数据复制到对应字节道。
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
    input  wire [ 1:0] ex_mem_mem_size,
    input  wire        ex_mem_mem_unsigned,
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
    output reg  [ 4:0] mem_wb_dest,
    output reg  [ 1:0] mem_wb_mem_size,
    output reg         mem_wb_mem_unsigned
);

wire [1:0] mem_size = ex_mem_mem_size;   // 本次访存宽度
wire [1:0] addr_low = ex_mem_alu_result[1:0];  // 地址低 2 位，决定落在哪个字节道

// 按宽度与地址低位生成字节写选通：字节写只选 1 道；半字写选低半或高半 2 道；字写全 4 道
wire [3:0] store_we = (mem_size == 2'b00) ? (4'b0001 << addr_low) :
                      (mem_size == 2'b01) ? (addr_low[1] ? 4'b1100 : 4'b0011) :
                                            4'b1111;

// 写数据按宽度复制到各字节道：字节写复制低 8 位、半字写复制低 16 位，字写原样
wire [31:0] store_data = (mem_size == 2'b00) ? {4{ex_mem_store_data[ 7: 0]}} :
                         (mem_size == 2'b01) ? {2{ex_mem_store_data[15: 0]}} :
                                               ex_mem_store_data;

// 访存请求：load/store 有效时使能；写选通再与 store 写使能相与
assign data_sram_en    = ex_mem_valid && (ex_mem_mem_we || ex_mem_res_from_mem);
assign data_sram_we    = {4{ex_mem_valid && ex_mem_mem_we}} & store_we;
assign data_sram_addr  = ex_mem_alu_result;
assign data_sram_wdata = store_data;

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
        mem_wb_mem_size     <= 2'b10;
        mem_wb_mem_unsigned <= 1'b0;
    end
    else begin
        mem_wb_valid        <= ex_mem_valid;
        mem_wb_pc           <= ex_mem_pc;
        mem_wb_alu_result   <= ex_mem_alu_result;
        mem_wb_mem_data     <= data_sram_rdata;
        mem_wb_res_from_mem <= ex_mem_res_from_mem;
        mem_wb_gr_we        <= ex_mem_gr_we;
        mem_wb_dest         <= ex_mem_dest;
        mem_wb_mem_size     <= ex_mem_mem_size;
        mem_wb_mem_unsigned <= ex_mem_mem_unsigned;
    end
end

endmodule