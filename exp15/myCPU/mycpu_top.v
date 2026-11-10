// 顶层模块：CPU 对外只保留一个 AXI 主接口。
// 内部仍例化 IF/ID/EX/MEM/WB 五个流水级，各流水级之间通过类 SRAM 握手接口
// 访问指令/数据，再由 sram_axi_bridge（2x1）仲裁并转换为 AXI 事务。
module mycpu_top(
    input  wire        aclk,       // AXI 时钟
    input  wire        aresetn,    // AXI 复位，低有效
    //---------------- AXI master ----------------
    //ar
    output wire [ 3:0] arid,
    output wire [31:0] araddr,
    output wire [ 7:0] arlen,
    output wire [ 2:0] arsize,
    output wire [ 1:0] arburst,
    output wire [ 1:0] arlock,
    output wire [ 3:0] arcache,
    output wire [ 2:0] arprot,
    output wire        arvalid,
    input  wire        arready,
    //r
    input  wire [ 3:0] rid,
    input  wire [31:0] rdata,
    input  wire [ 1:0] rresp,
    input  wire        rlast,
    input  wire        rvalid,
    output wire        rready,
    //aw
    output wire [ 3:0] awid,
    output wire [31:0] awaddr,
    output wire [ 7:0] awlen,
    output wire [ 2:0] awsize,
    output wire [ 1:0] awburst,
    output wire [ 1:0] awlock,
    output wire [ 3:0] awcache,
    output wire [ 2:0] awprot,
    output wire        awvalid,
    input  wire        awready,
    //w
    output wire [ 3:0] wid,
    output wire [31:0] wdata,
    output wire [ 3:0] wstrb,
    output wire        wlast,
    output wire        wvalid,
    input  wire        wready,
    //b
    input  wire [ 3:0] bid,
    input  wire [ 1:0] bresp,
    input  wire        bvalid,
    output wire        bready,
    // trace debug interface
    output wire [31:0] debug_wb_pc,
    output wire [ 3:0] debug_wb_rf_we,
    output wire [ 4:0] debug_wb_rf_wnum,
    output wire [31:0] debug_wb_rf_wdata
);

reg reset;  // 内部高有效同步复位（外部 aresetn 为低有效）
always @(posedge aclk) reset <= ~aresetn;

// AXI 单拍、字宽、INCR 突发的固定属性
assign arlen   = 8'd0;
assign arsize  = 3'b010;
assign arburst = 2'b01;
assign arlock  = 2'b00;
assign arcache = 4'b0000;
assign arprot  = 3'b000;
assign awlen   = 8'd0;
assign awsize  = 3'b010;
assign awburst = 2'b01;
assign awlock  = 2'b00;
assign awcache = 4'b0000;
assign awprot  = 3'b000;

//---------------- 内部类 SRAM 接口（转接桥的 CPU 侧） ----------------
// IF 取指
wire        inst_sram_req;
wire        inst_sram_wr;
wire [ 1:0] inst_sram_size;
wire [ 3:0] inst_sram_wstrb;
wire [31:0] inst_sram_addr;
wire [31:0] inst_sram_wdata;
wire        inst_sram_addr_ok;
wire        inst_sram_data_ok;
wire [31:0] inst_sram_rdata;
// MEM 访存
wire        data_sram_req;
wire        data_sram_wr;
wire [ 1:0] data_sram_size;
wire [ 3:0] data_sram_wstrb;
wire [31:0] data_sram_addr;
wire [31:0] data_sram_wdata;
wire        data_sram_addr_ok;
wire        data_sram_data_ok;
wire [31:0] data_sram_rdata;

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
wire if_busy;              // IF 取指握手未完成
wire mem_busy;             // MEM 访存握手未完成
wire ex_mem_seq;           // EX-MEM 指令序号
wire pipe_hold;            // 任一访存未完成时冻结整条流水线

// 任一级类 SRAM 访存未完成时冻结整条流水线，避免重复发射/覆盖流水寄存器
assign pipe_hold = if_busy | mem_busy;

// IF 级
if_stage u_if_stage(
    .clk             (aclk),
    .reset           (reset),
    .stall           (stall),
    .hold            (mem_busy),
    .br_taken        (br_taken),
    .br_target       (br_target),
    .inst_sram_req   (inst_sram_req),
    .inst_sram_wr    (inst_sram_wr),
    .inst_sram_size  (inst_sram_size),
    .inst_sram_wstrb (inst_sram_wstrb),
    .inst_sram_addr  (inst_sram_addr),
    .inst_sram_wdata (inst_sram_wdata),
    .inst_sram_addr_ok (inst_sram_addr_ok),
    .inst_sram_data_ok (inst_sram_data_ok),
    .inst_sram_rdata (inst_sram_rdata),
    .if_busy         (if_busy),
    .if_id_valid     (if_id_valid),
    .if_id_pc        (if_id_pc),
    .if_id_inst      (if_id_inst)
);

// ID 级
id_stage u_id_stage(
    .clk                (aclk),
    .reset              (reset),
    .hold               (pipe_hold),
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
    .mem_wb_valid    (mem_wb_valid),
    .mem_wb_gr_we    (mem_wb_gr_we),
    .mem_wb_dest     (mem_wb_dest),
    .mem_wb_res_from_mem (mem_wb_res_from_mem),
    .mem_busy        (mem_busy),
    .ex_alu_result   (ex_alu_result),
    .ex_busy         (ex_busy)
);

// EX 级
ex_stage u_ex_stage(
    .clk                 (aclk),
    .reset               (reset),
    .hold                (pipe_hold),
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
    .ex_mem_seq          (ex_mem_seq),
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
    .clk                  (aclk),
    .reset                (reset),
    .hold                 (if_busy),
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
    .ex_mem_seq           (ex_mem_seq),
    .data_sram_req        (data_sram_req),
    .data_sram_wr         (data_sram_wr),
    .data_sram_size       (data_sram_size),
    .data_sram_wstrb      (data_sram_wstrb),
    .data_sram_addr       (data_sram_addr),
    .data_sram_wdata      (data_sram_wdata),
    .data_sram_addr_ok    (data_sram_addr_ok),
    .data_sram_data_ok    (data_sram_data_ok),
    .data_sram_rdata      (data_sram_rdata),
    .mem_busy             (mem_busy),
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
    .data_sram_rdata     (mem_wb_mem_data), // exp14：用 MEM 阶段锁存的 load 数据做扩展
    .rf_we               (rf_we),
    .rf_waddr            (rf_waddr),
    .rf_wdata            (rf_wdata),
    .debug_wb_pc         (debug_wb_pc),
    .debug_wb_rf_we      (debug_wb_rf_we),
    .debug_wb_rf_wnum    (debug_wb_rf_wnum),
    .debug_wb_rf_wdata   (debug_wb_rf_wdata)
);

// 2x1 类 SRAM→AXI 转接桥：仲裁取指/访存请求，复用为单一 AXI 主接口
sram_axi_bridge u_sram_axi_bridge(
    .clk          (aclk),
    .aresetn      (aresetn),
    // inst sram
    .inst_req     (inst_sram_req),
    .inst_wr      (inst_sram_wr),
    .inst_size    (inst_sram_size),
    .inst_wstrb   (inst_sram_wstrb),
    .inst_addr    (inst_sram_addr),
    .inst_wdata   (inst_sram_wdata),
    .inst_addr_ok (inst_sram_addr_ok),
    .inst_data_ok (inst_sram_data_ok),
    .inst_rdata   (inst_sram_rdata),
    // data sram
    .data_req     (data_sram_req),
    .data_wr      (data_sram_wr),
    .data_size    (data_sram_size),
    .data_wstrb   (data_sram_wstrb),
    .data_addr    (data_sram_addr),
    .data_wdata   (data_sram_wdata),
    .data_addr_ok (data_sram_addr_ok),
    .data_data_ok (data_sram_data_ok),
    .data_rdata   (data_sram_rdata),
    // AXI master
    .arid         (arid),
    .araddr       (araddr),
    .arvalid      (arvalid),
    .arready      (arready),
    .rid          (rid),
    .rdata        (rdata),
    .rresp        (rresp),
    .rlast        (rlast),
    .rvalid       (rvalid),
    .rready       (rready),
    .awid         (awid),
    .awaddr       (awaddr),
    .awvalid      (awvalid),
    .awready      (awready),
    .wid          (wid),
    .wdata        (wdata),
    .wstrb        (wstrb),
    .wlast        (wlast),
    .wvalid       (wvalid),
    .wready       (wready),
    .bid          (bid),
    .bresp        (bresp),
    .bvalid       (bvalid),
    .bready       (bready)
);

endmodule