module mycpu_top(
    input  wire        clk,
    input  wire        resetn,
    // inst sram interface
    output wire inst_sram_en,
    output wire [3:0]  inst_sram_we,
    output wire [31:0] inst_sram_addr,
    output wire [31:0] inst_sram_wdata,
    input  wire [31:0] inst_sram_rdata,
    // data sram interface
    output wire data_sram_en,
    output wire [3:0]  data_sram_we,
    output wire [31:0] data_sram_addr,
    output wire [31:0] data_sram_wdata,
    input  wire [31:0] data_sram_rdata,
    // trace debug interface
    output wire [31:0] debug_wb_pc,
    output wire [ 3:0] debug_wb_rf_we,
    output wire [ 4:0] debug_wb_rf_wnum,
    output wire [31:0] debug_wb_rf_wdata
);
reg reset;
always @(posedge clk)begin
    reset <= ~resetn;
end

wire [63:0] if_to_id_data;
wire if_to_id_valid;
wire if_to_id_ready;
wire [32:0] id_to_if_data;

wire [147:0] id_to_ex_data;
wire id_to_ex_valid;
wire id_to_ex_ready;

wire [103:0] ex_to_mem_data;
wire ex_to_mem_valid;
wire ex_to_mem_ready;

wire [69:0] mem_to_wb_data;
wire mem_to_wb_valid;
wire mem_to_wb_ready;
wire [6:0] mem_hazard;

wire [37:0] wb_rf_id_data;

if_stage if_u(
    .clk(clk),
    .reset(reset),
    .inst_sram_en(inst_sram_en),
    .inst_sram_we(inst_sram_we),
    .inst_sram_addr(inst_sram_addr),
    .inst_sram_wdata(inst_sram_wdata),
    .inst_sram_rdata(inst_sram_rdata),

    .if_to_id_data(if_to_id_data),
    .if_to_id_valid(if_to_id_valid),
    .if_to_id_ready(if_to_id_ready),

    .id_to_if_data(id_to_if_data)
);

id id_u(
    .clk(clk),
    .reset(reset),

    .if_to_id_data(if_to_id_data),
    .if_to_id_valid(if_to_id_valid),
    .if_to_id_ready(if_to_id_ready),

    .id_to_ex_data(id_to_ex_data),
    .id_to_ex_valid(id_to_ex_valid),
    .id_to_ex_ready(id_to_ex_ready),

    .ex_to_mem_data(ex_to_mem_data),
    .ex_to_mem_valid(ex_to_mem_valid),
    .mem_hazard(mem_hazard),

    .id_to_if_data(id_to_if_data),
    .wb_rf_id_data(wb_rf_id_data)
);

ex ex_u(
    .clk(clk),
    .reset(reset),

    .id_to_ex_data(id_to_ex_data),
    .id_to_ex_valid(id_to_ex_valid),
    .id_to_ex_ready(id_to_ex_ready),

    .ex_to_mem_data(ex_to_mem_data),
    .ex_to_mem_valid(ex_to_mem_valid),
    .ex_to_mem_ready(ex_to_mem_ready)
);

mem mem_u(
    .clk(clk),
    .reset(reset),

    .ex_to_mem_data(ex_to_mem_data),
    .ex_to_mem_valid(ex_to_mem_valid),
    .ex_to_mem_ready(ex_to_mem_ready),

    .mem_to_wb_data(mem_to_wb_data),
    .mem_to_wb_valid(mem_to_wb_valid),
    .mem_to_wb_ready(mem_to_wb_ready),
    .mem_hazard(mem_hazard),

    .data_sram_en(data_sram_en),
    .data_sram_we(data_sram_we),
    .data_sram_addr(data_sram_addr),
    .data_sram_wdata(data_sram_wdata),
    .data_sram_rdata(data_sram_rdata)
);

wb wb_u(
    .clk(clk),
    .reset(reset),

    .mem_to_wb_data(mem_to_wb_data),
    .mem_to_wb_valid(mem_to_wb_valid),
    .mem_to_wb_ready(mem_to_wb_ready),

    .debug_wb_pc(debug_wb_pc),
    .debug_wb_rf_we(debug_wb_rf_we),
    .debug_wb_rf_wnum(debug_wb_rf_wnum),
    .debug_wb_rf_wdata(debug_wb_rf_wdata),
    .wb_rf_id_data(wb_rf_id_data)
);

endmodule
