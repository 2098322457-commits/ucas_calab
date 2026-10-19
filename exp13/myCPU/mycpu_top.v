// 顶层模块：例化 IF/ID/EX/MEM/WB 五个流水级，并连接各级流水寄存器总线、
// inst/data SRAM 接口以及 trace 调试接口。
module mycpu_top(
    input  wire        clk,
    input  wire        resetn,
    // inst sram interface
    output wire        inst_sram_en,
    output wire [ 3:0] inst_sram_we,
    output wire [31:0] inst_sram_addr,
    output wire [31:0] inst_sram_wdata,
    input  wire [31:0] inst_sram_rdata,
    // data sram interface
    output wire        data_sram_en,
    output wire [ 3:0] data_sram_we,
    output wire [31:0] data_sram_addr,
    output wire [31:0] data_sram_wdata,
    input  wire [31:0] data_sram_rdata,
    // trace debug interface
    output wire [31:0] debug_wb_pc,
    output wire [ 3:0] debug_wb_rf_we,
    output wire [ 4:0] debug_wb_rf_wnum,
    output wire [31:0] debug_wb_rf_wdata
);

reg reset;  // 内部高有效同步复位（外部 resetn 为低有效）
always @(posedge clk) reset <= ~resetn;

// IF-ID pipeline bus
wire        if_id_valid;
wire [31:0] if_id_pc;
wire [31:0] if_id_inst;

// Branch feedback from ID to IF
wire        br_taken;
wire [31:0] br_target;

// ID-EX pipeline bus
wire        id_ex_valid;
wire [31:0] id_ex_pc;
wire [31:0] id_ex_src1;
wire [31:0] id_ex_src2;
wire [31:0] id_ex_store_data;
wire [18:0] id_ex_alu_op;
wire        id_ex_mem_we;
wire        id_ex_res_from_mem;
wire        id_ex_gr_we;
wire [ 4:0] id_ex_dest;
wire [ 1:0] id_ex_mem_size;      // 访存宽度：2'd0 字节 / 2'd1 半字 / 2'd2 字
wire        id_ex_mem_unsigned;  // load 是否按无符号扩展

// EX-MEM pipeline bus
wire        ex_mem_valid;
wire [31:0] ex_mem_pc;
wire [31:0] ex_mem_alu_result;
wire [31:0] ex_mem_store_data;
wire        ex_mem_mem_we;
wire        ex_mem_res_from_mem;
wire        ex_mem_gr_we;
wire [ 4:0] ex_mem_dest;
wire [ 1:0] ex_mem_mem_size;
wire        ex_mem_mem_unsigned;

// MEM-WB pipeline bus
wire        mem_wb_valid;
wire [31:0] mem_wb_pc;
wire [31:0] mem_wb_alu_result;
wire [31:0] mem_wb_mem_data;
wire        mem_wb_res_from_mem;
wire        mem_wb_gr_we;
wire [ 4:0] mem_wb_dest;
wire [ 1:0] mem_wb_mem_size;
wire        mem_wb_mem_unsigned;

// Register-file write-back bus
wire        rf_we;
wire [ 4:0] rf_waddr;
wire [31:0] rf_wdata;

wire stall;                // ID 反馈给 IF 的流水线暂停信号
wire ex_busy;              // EX 除法进行中，ID 据此暂停取指
wire [31:0] ex_alu_result; // EX 组合 ALU 结果，回传给 ID 做前递

// IF 级
if_stage u_if_stage(
    .clk             (clk),
    .reset           (reset),
    .stall           (stall),
    .br_taken        (br_taken),
    .br_target       (br_target),
    .inst_sram_en    (inst_sram_en),
    .inst_sram_we    (inst_sram_we),
    .inst_sram_addr  (inst_sram_addr),
    .inst_sram_wdata (inst_sram_wdata),
    .inst_sram_rdata (inst_sram_rdata),
    .if_id_valid     (if_id_valid),
    .if_id_pc        (if_id_pc),
    .if_id_inst      (if_id_inst)
);

// ID 级
id_stage u_id_stage(
    .clk                (clk),
    .reset              (reset),
    .if_id_valid        (if_id_valid),
    .if_id_pc           (if_id_pc),
    .if_id_inst         (if_id_inst),
    .rf_we              (rf_we),
    .rf_waddr           (rf_waddr),
    .rf_wdata           (rf_wdata),
    .br_taken           (br_taken),
    .br_target          (br_target),
    .stall              (stall),
    .id_ex_valid        (id_ex_valid),
    .id_ex_pc           (id_ex_pc),
    .id_ex_src1         (id_ex_src1),
    .id_ex_src2         (id_ex_src2),
    .id_ex_store_data   (id_ex_store_data),
    .id_ex_alu_op       (id_ex_alu_op),
    .id_ex_mem_we       (id_ex_mem_we),
    .id_ex_res_from_mem (id_ex_res_from_mem),
    .id_ex_gr_we        (id_ex_gr_we),
    .id_ex_dest         (id_ex_dest),
    .id_ex_mem_size     (id_ex_mem_size),
    .id_ex_mem_unsigned (id_ex_mem_unsigned),
    .ex_mem_valid    (ex_mem_valid),
    .ex_mem_gr_we    (ex_mem_gr_we),
    .ex_mem_dest     (ex_mem_dest),
    .ex_mem_alu_result (ex_mem_alu_result),
    .ex_mem_res_from_mem (ex_mem_res_from_mem),
    .ex_alu_result   (ex_alu_result),
    .ex_busy         (ex_busy)
);

// EX 级
ex_stage u_ex_stage(
    .clk                 (clk),
    .reset               (reset),
    .id_ex_valid         (id_ex_valid),
    .id_ex_pc            (id_ex_pc),
    .id_ex_src1          (id_ex_src1),
    .id_ex_src2          (id_ex_src2),
    .id_ex_store_data    (id_ex_store_data),
    .id_ex_alu_op        (id_ex_alu_op),
    .id_ex_mem_we        (id_ex_mem_we),
    .id_ex_res_from_mem  (id_ex_res_from_mem),
    .id_ex_gr_we         (id_ex_gr_we),
    .id_ex_dest          (id_ex_dest),
    .id_ex_mem_size      (id_ex_mem_size),
    .id_ex_mem_unsigned  (id_ex_mem_unsigned),
    .ex_busy             (ex_busy),
    .ex_alu_result       (ex_alu_result),
    .ex_mem_valid        (ex_mem_valid),
    .ex_mem_pc           (ex_mem_pc),
    .ex_mem_alu_result   (ex_mem_alu_result),
    .ex_mem_store_data   (ex_mem_store_data),
    .ex_mem_mem_we       (ex_mem_mem_we),
    .ex_mem_res_from_mem (ex_mem_res_from_mem),
    .ex_mem_gr_we        (ex_mem_gr_we),
    .ex_mem_dest         (ex_mem_dest),
    .ex_mem_mem_size     (ex_mem_mem_size),
    .ex_mem_mem_unsigned (ex_mem_mem_unsigned)
);

// MEM 级
mem_stage u_mem_stage(
    .clk                  (clk),
    .reset                (reset),
    .ex_mem_valid         (ex_mem_valid),
    .ex_mem_pc            (ex_mem_pc),
    .ex_mem_alu_result    (ex_mem_alu_result),
    .ex_mem_store_data    (ex_mem_store_data),
    .ex_mem_mem_we        (ex_mem_mem_we),
    .ex_mem_res_from_mem  (ex_mem_res_from_mem),
    .ex_mem_gr_we         (ex_mem_gr_we),
    .ex_mem_dest          (ex_mem_dest),
    .ex_mem_mem_size      (ex_mem_mem_size),
    .ex_mem_mem_unsigned  (ex_mem_mem_unsigned),
    .data_sram_en         (data_sram_en),
    .data_sram_we         (data_sram_we),
    .data_sram_addr       (data_sram_addr),
    .data_sram_wdata      (data_sram_wdata),
    .data_sram_rdata      (data_sram_rdata),
    .mem_wb_valid         (mem_wb_valid),
    .mem_wb_pc            (mem_wb_pc),
    .mem_wb_alu_result    (mem_wb_alu_result),
    .mem_wb_mem_data      (mem_wb_mem_data),
    .mem_wb_res_from_mem  (mem_wb_res_from_mem),
    .mem_wb_gr_we        (mem_wb_gr_we),
    .mem_wb_dest         (mem_wb_dest),
    .mem_wb_mem_size     (mem_wb_mem_size),
    .mem_wb_mem_unsigned (mem_wb_mem_unsigned)
);

// WB 级（无时钟，纯组合写回逻辑）
wb_stage u_wb_stage(
    .mem_wb_valid        (mem_wb_valid),
    .mem_wb_pc           (mem_wb_pc),
    .mem_wb_alu_result   (mem_wb_alu_result),
    .mem_wb_mem_data     (mem_wb_mem_data),
    .mem_wb_res_from_mem (mem_wb_res_from_mem),
    .mem_wb_gr_we        (mem_wb_gr_we),
    .mem_wb_dest         (mem_wb_dest),
    .mem_wb_mem_size     (mem_wb_mem_size),
    .mem_wb_mem_unsigned (mem_wb_mem_unsigned),
    .data_sram_rdata     (data_sram_rdata),
    .rf_we               (rf_we),
    .rf_waddr            (rf_waddr),
    .rf_wdata            (rf_wdata),
    .debug_wb_pc         (debug_wb_pc),
    .debug_wb_rf_we      (debug_wb_rf_we),
    .debug_wb_rf_wnum    (debug_wb_rf_wnum),
    .debug_wb_rf_wdata   (debug_wb_rf_wdata)
);

endmodule