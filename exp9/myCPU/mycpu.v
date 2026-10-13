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

wire [63:0] id_data;
wire if_to_id_valid;
wire if_to_id_ready;
wire [32:0] if_data;

wire [147:0] ex_data;
wire id_to_ex_valid;
wire id_to_ex_ready;

wire [103:0] mem_data;
wire ex_to_mem_valid;
wire ex_to_mem_ready;

wire [69:0] wb_data;
wire mem_to_wb_valid;
wire mem_to_wb_ready;
wire [38:0] mem_hazard;		//需要额外的长度传递result

wire [38:0] wb_rf_id_data;

if_stage if_u(
    .clk(clk),
    .reset(reset),
    .inst_sram_en(inst_sram_en),
    .inst_sram_we(inst_sram_we),
    .inst_sram_addr(inst_sram_addr),
    .inst_sram_wdata(inst_sram_wdata),
    .inst_sram_rdata(inst_sram_rdata),

    .id_data(id_data),
    .if_to_id_valid(if_to_id_valid),
    .if_to_id_ready(if_to_id_ready),

    .if_data(if_data)
);

id id_u(
    .clk(clk),
    .reset(reset),

    .id_data(id_data),
    .if_to_id_valid(if_to_id_valid),
    .if_to_id_ready(if_to_id_ready),

    .ex_data(ex_data),
    .id_to_ex_valid(id_to_ex_valid),
    .id_to_ex_ready(id_to_ex_ready),

    .mem_data(mem_data),
    .ex_to_mem_valid(ex_to_mem_valid),
    .mem_hazard(mem_hazard),

    .if_data(if_data),
    .wb_rf_id_data(wb_rf_id_data)
);

ex ex_u(
    .clk(clk),
    .reset(reset),

    .ex_data(ex_data),
    .id_to_ex_valid(id_to_ex_valid),
    .id_to_ex_ready(id_to_ex_ready),

    .mem_data(mem_data),
    .ex_to_mem_valid(ex_to_mem_valid),
    .ex_to_mem_ready(ex_to_mem_ready),

    .data_sram_en(data_sram_en),        //访存在EX段发出，地址当拍上线，省掉MEM段空等的一拍
    .data_sram_we(data_sram_we),
    .data_sram_addr(data_sram_addr),
    .data_sram_wdata(data_sram_wdata)
);

mem mem_u(
    .clk(clk),
    .reset(reset),

    .mem_data(mem_data),
    .ex_to_mem_valid(ex_to_mem_valid),
    .ex_to_mem_ready(ex_to_mem_ready),

    .wb_data(wb_data),
    .mem_to_wb_valid(mem_to_wb_valid),
    .mem_to_wb_ready(mem_to_wb_ready),
    .mem_hazard(mem_hazard),

    .data_sram_rdata(data_sram_rdata)   //只收数据：读已在EX段发出，数据本拍已在rdata上
);

wb wb_u(
    .clk(clk),
    .reset(reset),

    .wb_data(wb_data),
    .mem_to_wb_valid(mem_to_wb_valid),
    .mem_to_wb_ready(mem_to_wb_ready),

    .debug_wb_pc(debug_wb_pc),
    .debug_wb_rf_we(debug_wb_rf_we),
    .debug_wb_rf_wnum(debug_wb_rf_wnum),
    .debug_wb_rf_wdata(debug_wb_rf_wdata),
    .wb_rf_id_data(wb_rf_id_data)
);

endmodule

module if_stage(
    input  wire        clk,
    input  wire        reset,

    output wire inst_sram_en,
    output wire [3:0]  inst_sram_we,
    output wire [31:0] inst_sram_addr,
    output wire [31:0] inst_sram_wdata,
    input  wire [31:0] inst_sram_rdata,

    output wire [63:0] id_data,
    output wire if_to_id_valid,
    input if_to_id_ready,

    input wire [32:0] if_data
);

reg  [31:0] pc;
reg         if_to_id_valid_r;
reg  [63:0] if_to_id_data_r;

wire [31:0] seq_pc;
wire [31:0] nextpc;
wire br_taken;
wire [31:0] br_target;

assign br_taken = if_data[32:32];
assign br_target = if_data[31:0];
assign seq_pc       = pc + 3'h4;
assign nextpc       = br_taken ? br_target : seq_pc;

always @(posedge clk) begin
    if (reset) begin
        pc <= 32'h1bfffffc;          //trick: to make nextpc be 0x1c000000 during reset 
        if_to_id_valid_r <= 1'b0;
        if_to_id_data_r <= 64'b0;
    end
    else if (if_to_id_ready || br_taken) begin      //考虑阻塞，只有非阻塞和跳转的时候发生传递
        pc <= nextpc;
        //br_taken时作废本拍取回的错误路径指令；pc为复位trick地址时取回的是垃圾，也不注入
        if_to_id_valid_r <= ~br_taken && (pc != 32'h1bfffffc);
        if_to_id_data_r <= {
                    pc,         //访存的地址是上一节拍送的pc_next，与当前节拍的pc一致
                    inst_sram_rdata
                    };
    end
end

assign id_data = if_to_id_data_r;

assign inst_sram_en    = if_to_id_ready || br_taken;        //考虑阻塞的情况，只有在id可接受新指令，或者发生跳转时
                                                            //（有可能id在阻塞中，但阻塞对应的指令是跳转的，直接跳转但是不发送），取新指令
assign inst_sram_we    = 1'b0;
assign inst_sram_addr  = nextpc;        //直接由组合逻辑得到pc，不需要额外等待时序。并且提前送pc不用等访存节拍
assign inst_sram_wdata = 32'b0;

assign if_to_id_valid  = if_to_id_valid_r;
endmodule

module id(
    input wire clk,
    input wire reset,

    input wire [63:0] id_data,
    input wire if_to_id_valid,
    output wire if_to_id_ready,

    output wire [147:0] ex_data,
    output wire id_to_ex_valid,
    input wire id_to_ex_ready,

    input wire [103:0] mem_data,
    input wire ex_to_mem_valid,
    input wire [38:0] mem_hazard,	//需要额外的长度传递result

    output wire [32:0] if_data,
    input wire [38:0] wb_rf_id_data
);

wire [11:0] alu_op;
wire        load_op;
wire        src1_is_pc;
wire        src2_is_imm;
wire        res_from_mem;
wire        dst_is_r1;
wire        gr_we;
wire        mem_we;
wire        src_reg_is_rd;
wire [4: 0] dest;
wire [31:0] rj_value;
wire [31:0] rkd_value;
wire [31:0] imm;
wire [31:0] br_offs;
wire [31:0] jirl_offs;

wire [ 5:0] op_31_26;
wire [ 3:0] op_25_22;
wire [ 1:0] op_21_20;
wire [ 4:0] op_19_15;
wire [ 4:0] rd;
wire [ 4:0] rj;
wire [ 4:0] rk;
wire [11:0] i12;
wire [19:0] i20;
wire [15:0] i16;
wire [25:0] i26;

wire [63:0] op_31_26_d;
wire [15:0] op_25_22_d;
wire [ 3:0] op_21_20_d;
wire [31:0] op_19_15_d;

wire        inst_add_w;
wire        inst_sub_w;
wire        inst_slt;
wire        inst_sltu;
wire        inst_nor;
wire        inst_and;
wire        inst_or;
wire        inst_xor;
wire        inst_slli_w;
wire        inst_srli_w;
wire        inst_srai_w;
wire        inst_addi_w;
wire        inst_ld_w;
wire        inst_st_w;
wire        inst_jirl;
wire        inst_b;
wire        inst_bl;
wire        inst_beq;
wire        inst_bne;
wire        inst_lu12i_w;

wire        need_ui5;
wire        need_si12;
wire        need_si16;
wire        need_si20;
wire        need_si26;
wire        src2_is_4;

wire [ 4:0] rf_raddr1;
wire [ 4:0] rf_raddr2;
wire [31:0] rf_rdata1;
wire [31:0] rf_rdata2;
wire        rf_we;
wire [ 4:0] rf_waddr;
wire [31:0] rf_wdata;
wire        rj_eq_rd;
wire        br_taken;
wire [31:0] br_target;
wire [31:0] alu_src1;
wire [31:0] alu_src2;

wire [31:0] inst;
wire [31:0] pc;
reg [31:0] inst_r;
reg         id_to_ex_valid_r;
reg [147:0] id_to_ex_data_r;

always @(posedge clk)begin
    if(reset)begin
        id_to_ex_valid_r <= 1'b0;
        id_to_ex_data_r <= 148'b0;
    end
    else begin
        if(if_to_id_valid && if_to_id_ready && ~stall)begin
            id_to_ex_valid_r <= 1'b1;
            id_to_ex_data_r <= {
                                pc,            //32,pc
                                rkd_value,     //32
                                res_from_mem,  //1，结果来自内存/计算
                                gr_we,         //1，读写寄存器使能
                                mem_we,        //1，写使能
                                dest,          //5，写入寄存器编号
                                alu_op,        //12
                                alu_src1,      //32
                                alu_src2       //32
                                };
        end
        else if(id_to_ex_valid && id_to_ex_ready)begin
            id_to_ex_valid_r <= 1'b0;
        end
    end
end

assign ex_data = id_to_ex_data_r;

assign id_to_ex_valid = id_to_ex_valid_r;
assign if_to_id_ready = ~stall && (~id_to_ex_valid || id_to_ex_ready);    
                                  //当前无指令或者立即可发出

assign inst = id_data[31:0];
assign pc   = id_data[63:32];

assign op_31_26  = inst[31:26];
assign op_25_22  = inst[25:22];
assign op_21_20  = inst[21:20];
assign op_19_15  = inst[19:15];

assign rd   = inst[ 4: 0];
assign rj   = inst[ 9: 5];
assign rk   = inst[14:10];

assign i12  = inst[21:10];
assign i20  = inst[24: 5];
assign i16  = inst[25:10];
assign i26  = {inst[ 9: 0], inst[25:10]};

decoder_6_64 u_dec0(.in(op_31_26 ), .out(op_31_26_d ));
decoder_4_16 u_dec1(.in(op_25_22 ), .out(op_25_22_d ));
decoder_2_4  u_dec2(.in(op_21_20 ), .out(op_21_20_d ));
decoder_5_32 u_dec3(.in(op_19_15 ), .out(op_19_15_d ));

assign inst_add_w  = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h00];
assign inst_sub_w  = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h02];
assign inst_slt    = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h04];
assign inst_sltu   = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h05];
assign inst_nor    = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h08];
assign inst_and    = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h09];
assign inst_or     = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h0a];
assign inst_xor    = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h0b];
assign inst_slli_w = op_31_26_d[6'h00] & op_25_22_d[4'h1] & op_21_20_d[2'h0] & op_19_15_d[5'h01];
assign inst_srli_w = op_31_26_d[6'h00] & op_25_22_d[4'h1] & op_21_20_d[2'h0] & op_19_15_d[5'h09];
assign inst_srai_w = op_31_26_d[6'h00] & op_25_22_d[4'h1] & op_21_20_d[2'h0] & op_19_15_d[5'h11];
assign inst_addi_w = op_31_26_d[6'h00] & op_25_22_d[4'ha];
assign inst_ld_w   = op_31_26_d[6'h0a] & op_25_22_d[4'h2];
assign inst_st_w   = op_31_26_d[6'h0a] & op_25_22_d[4'h6];
assign inst_jirl   = op_31_26_d[6'h13];
assign inst_b      = op_31_26_d[6'h14];
assign inst_bl     = op_31_26_d[6'h15];
assign inst_beq    = op_31_26_d[6'h16];
assign inst_bne    = op_31_26_d[6'h17];
assign inst_lu12i_w= op_31_26_d[6'h05] & ~inst[25];

assign alu_op[ 0] = inst_add_w | inst_addi_w | inst_ld_w | inst_st_w
                    | inst_jirl | inst_bl;
assign alu_op[ 1] = inst_sub_w;
assign alu_op[ 2] = inst_slt;
assign alu_op[ 3] = inst_sltu;
assign alu_op[ 4] = inst_and;
assign alu_op[ 5] = inst_nor;
assign alu_op[ 6] = inst_or;
assign alu_op[ 7] = inst_xor;
assign alu_op[ 8] = inst_slli_w;
assign alu_op[ 9] = inst_srli_w;
assign alu_op[10] = inst_srai_w;
assign alu_op[11] = inst_lu12i_w;

assign need_ui5   =  inst_slli_w | inst_srli_w | inst_srai_w;
assign need_si12  =  inst_addi_w | inst_ld_w | inst_st_w;
assign need_si16  =  inst_jirl | inst_beq | inst_bne;
assign need_si20  =  inst_lu12i_w;
assign need_si26  =  inst_b | inst_bl;
assign src2_is_4  =  inst_jirl | inst_bl;

assign imm = src2_is_4 ? 32'h4                      :
             need_si20 ? {i20[19:0], 12'b0}         :
/*need_ui5 || need_si12*/{{20{i12[11]}}, i12[11:0]} ;

assign br_offs = need_si26 ? {{ 4{i26[25]}}, i26[25:0], 2'b0} :
                             {{14{i16[15]}}, i16[15:0], 2'b0} ;

assign jirl_offs = {{14{i16[15]}}, i16[15:0], 2'b0};

assign src_reg_is_rd = inst_beq | inst_bne | inst_st_w;

assign src1_is_pc    = inst_jirl | inst_bl;

assign src2_is_imm   = inst_slli_w |
                       inst_srli_w |
                       inst_srai_w |
                       inst_addi_w |
                       inst_ld_w   |
                       inst_st_w   |
                       inst_lu12i_w|
                       inst_jirl   |
                       inst_bl     ;

assign res_from_mem  = inst_ld_w;
assign dst_is_r1     = inst_bl;

assign gr_we         = ~inst_st_w & ~inst_beq & ~inst_bne & ~inst_b;
assign mem_we        = inst_st_w;
assign dest          = dst_is_r1 ? 5'd1 : rd;

assign rf_raddr1 = rj;
assign rf_raddr2 = src_reg_is_rd ? rd :rk;

assign {
        rf_we,
        rf_waddr,
        rf_wdata
        } = wb_rf_id_data[37:0];

regfile u_regfile(
    .clk    (clk      ),
    .raddr1 (rf_raddr1),
    .rdata1 (rf_rdata1),
    .raddr2 (rf_raddr2),
    .rdata2 (rf_rdata2),
    .we     (rf_we    ),
    .waddr  (rf_waddr ),
    .wdata  (rf_wdata )
    );

assign rj_value  =  ex_rf1 ? alu_result :
                    mem_rf1 ? mem_rf_data :
                    wb_rf1 ? wb_rf_data :
                    rf_rdata1;
assign rkd_value =  ex_rf2 ? alu_result :
                    mem_rf2 ? mem_rf_data :
                    wb_rf2 ? wb_rf_data :
                    rf_rdata2;

assign rj_eq_rd = (rj_value == rkd_value);
assign br_taken = (   inst_beq  &&  rj_eq_rd
                   || inst_bne  && !rj_eq_rd
                   || inst_jirl
                   || inst_bl
                   || inst_b
                  ) && if_to_id_valid 
                  && ~stall; 
assign br_target = (inst_beq || inst_bne || inst_bl || inst_b) ? (pc + br_offs) :
                                                   /*inst_jirl*/ (rj_value + jirl_offs);

assign alu_src1 = src1_is_pc  ? pc[31:0] : rj_value;
assign alu_src2 = src2_is_imm ? imm : rkd_value;

assign if_data = {
                        br_taken,
                        br_target
                        };


wire stall;
wire [4:0] mem_dest;
wire mem_gr_we;
wire wb_gr_we;
wire [4:0] wb_dest;
wire mem_to_wb_valid;

wire [31:0] mem_rf_data;
wire [31:0] wb_rf_data;
wire ex_rf1;
wire ex_rf2;
wire mem_rf1;
wire mem_rf2;
wire wb_rf1;
wire wb_rf2;
wire [31:0] alu_result;

//aluresult来自距离为1的指令，刚刚使用alu计算出，存在寄存器里
//memdata和访存时的hazard都来自距离为2的指令。若是访存，hazard里面存ex阶段请求的访存结果，
                                        //若不是则存发给下一阶段的alu数据，此时前递选择ex时发给mem的数据包，也就是aluresult
//wbrfiddata相当于wbdata，两者是wire连接，也就是距离为3的数据包，已经预先选择了访存结果/计算结果
assign mem_rf_data = (ex_to_mem_valid && mem_data[39]) ? mem_hazard[31:0] : mem_data[31:0];   //MEM段是load时数据本拍已在rdata上，否则取alu结果
assign mem_dest = mem_data[36:32];
assign mem_gr_we = mem_data[38];

assign {mem_to_wb_valid, wb_gr_we, wb_dest,wb_rf_data} = wb_rf_id_data;
   
alu u_ex_alu (
    .alu_op (ex_data[75:64]), 
    .alu_src1 (ex_data[63:32]), 
    .alu_src2 (ex_data[31:0]), 
    .alu_result (alu_result)
    );
assign stall = (id_to_ex_valid && ex_data[82] && (ex_data[80:76] != 5'b0) &&
                ((rf_raddr1 == ex_data[80:76]) || (rf_raddr2 == ex_data[80:76]))) &&     //ex阶段需要阻塞
                ex_data[83];    //只有EX段load-use要停1拍：数据下一拍就能从MEM段组合前递
assign ex_rf1 = id_to_ex_valid && ex_data[82] &&(ex_data[80:76] != 5'b0) &&
                (rf_raddr1 == ex_data[80:76]) && ~ex_data[83];
assign ex_rf2 = id_to_ex_valid && ex_data[82] &&(ex_data[80:76] != 5'b0) &&
                (rf_raddr2 == ex_data[80:76]) && ~ex_data[83];
assign mem_rf1 = (ex_to_mem_valid && mem_gr_we && (mem_dest != 5'b0) &&
                (rf_raddr1 == mem_dest));       //load的数据在MEM段就绪，距离2不再需要阻塞
assign mem_rf2 = (ex_to_mem_valid && mem_gr_we && (mem_dest != 5'b0) &&
                (rf_raddr2 == mem_dest));
assign wb_rf1 =  (mem_to_wb_valid && wb_gr_we && (wb_dest != 5'b0) &&
                (rf_raddr1 == wb_dest));
assign wb_rf2 =  (mem_to_wb_valid && wb_gr_we && (wb_dest != 5'b0) &&
                (rf_raddr2 == wb_dest));

endmodule

module ex(
    input wire  clk,
    input wire reset,

    input wire [147:0] ex_data,
    input wire id_to_ex_valid,
    output wire id_to_ex_ready,


    output wire [103:0] mem_data,
    output wire ex_to_mem_valid,
    input wire ex_to_mem_ready,

    output wire data_sram_en,
    output wire [3:0] data_sram_we,
    output wire [31:0] data_sram_addr,
    output wire [31:0] data_sram_wdata
);

wire [31:0] pc;
wire [31:0] rkd_value;
wire res_from_mem;
wire gr_we;
wire mem_we;
wire [4:0] dest;
wire [11:0] alu_op;
wire [31:0] alu_src1;
wire [31:0] alu_src2;
wire [31:0] alu_result;

reg [147:0] id_to_ex_data_r;
reg ex_to_mem_valid_r;
reg [103:0] ex_to_mem_data_r;

always @(posedge clk)begin
    if(reset)begin
        ex_to_mem_valid_r <= 1'b0;
        ex_to_mem_data_r <= 104'b0;
    end
    else if(id_to_ex_ready)begin        //raedy时组合逻辑实时更新的，会判断mem级的ready，拉高时一定可以刷新
        ex_to_mem_valid_r <= id_to_ex_valid;
        if(id_to_ex_valid)begin
            ex_to_mem_data_r <= {
                                pc,  //32,pc
                                rkd_value, //32
                                res_from_mem,  //1
                                gr_we,     //1
                                mem_we,    //1
                                dest,      //5
                                alu_result //32
                                };
        end
    end
end

assign id_to_ex_ready = ~ex_to_mem_valid_r || ex_to_mem_ready;      //当前为空或下一级可接受（ex无阻塞）。或者说当前已有指令（valid高）且无法下发才不能接受新指令
assign ex_to_mem_valid = ex_to_mem_valid_r;
assign mem_data  = ex_to_mem_data_r;

assign {
pc,  //32,pc
rkd_value,
res_from_mem,  //1
gr_we,     //1
mem_we,    //1
dest,      //5
alu_op,    //12
alu_src1,  //32
alu_src2   //32
} = ex_data;

alu u_alu(
    .alu_op     (alu_op    ),
    .alu_src1   (alu_src1  ),
    .alu_src2   (alu_src2  ),
    .alu_result (alu_result)
    );

//访存在EX段直接发出：地址就是本拍ALU结果，RAM在下一个时钟沿把数据取回，MEM段直接用
assign data_sram_en    = id_to_ex_valid && (res_from_mem || mem_we);
assign data_sram_we    = {4{id_to_ex_valid && mem_we}};
assign data_sram_addr  = alu_result;
assign data_sram_wdata = rkd_value;

endmodule

module mem(
    input wire clk,
    input wire reset,

    input wire [103:0] mem_data,
    input wire ex_to_mem_valid,
    output wire ex_to_mem_ready,

    output wire [69:0] wb_data,
    output wire mem_to_wb_valid,
    input wire mem_to_wb_ready,
    output wire [38:0] mem_hazard,

    input  wire [31:0] data_sram_rdata
);

wire [31:0] pc;
wire [31:0] rkd_value;
wire res_from_mem;
wire gr_we;
wire mem_we;
wire [4:0] dest;
wire [31:0] alu_result;
wire [31:0] mem_result;

reg        mem_to_wb_valid_r;
reg [69:0] mem_to_wb_data_r;

assign{
pc,  //32,pc
rkd_value, //32
res_from_mem,  //1
gr_we,     //1
mem_we,    //1
dest,      //5
alu_result //32
} = mem_data;

assign ex_to_mem_ready = (~mem_to_wb_valid || mem_to_wb_ready);    //读已在EX段发出，MEM段不再需要空等一拍

always @(posedge clk)begin
    if(reset)begin
        mem_to_wb_valid_r <= 1'b0;
        mem_to_wb_data_r <= 70'b0;
    end
    else begin
        if(ex_to_mem_valid && ex_to_mem_ready)begin    //load的数据本拍已在rdata上，随信息位一起寄存
            mem_to_wb_valid_r <= 1'b1;
            mem_to_wb_data_r <= {
                                pc, //32
                                gr_we, //1
                                dest, //5
                                mem_result //32，load取rdata，其余取alu结果
                                };
        end
        else if(mem_to_wb_valid && mem_to_wb_ready)begin
            mem_to_wb_valid_r <= 1'b0;
        end
    end
end

assign mem_to_wb_valid = mem_to_wb_valid_r;
assign wb_data  = mem_to_wb_data_r;
assign mem_hazard = (ex_to_mem_valid && res_from_mem) ? {1'b1, gr_we, dest, data_sram_rdata} :   //MEM段是load：数据当拍可得，直接前递
                    {mem_to_wb_valid_r, mem_to_wb_data_r[37:0]};   //指令有效，寄存器，地址

assign mem_result = res_from_mem ? data_sram_rdata : alu_result;

endmodule

module wb(
    input wire clk,
    input wire reset,
    
    input wire [69:0] wb_data,
    input wire mem_to_wb_valid,
    output wire mem_to_wb_ready,

    output wire [31:0] debug_wb_pc,
    output wire [ 3:0] debug_wb_rf_we,
    output wire [ 4:0] debug_wb_rf_wnum,
    output wire [31:0] debug_wb_rf_wdata,

    output wire [38:0] wb_rf_id_data
);

reg mem_to_wb_ready_r;

always @(posedge clk)begin
    if(reset)begin
        mem_to_wb_ready_r <= 1'b1;
    end
end

assign mem_to_wb_ready = mem_to_wb_ready_r;

wire [31:0] pc;
wire gr_we;
wire [4:0] dest;
wire rf_we;
wire [4:0] rf_waddr;
wire [31:0] rf_wdata;
wire [31:0] final_result;

assign {
        pc,
        gr_we,
        dest,
        final_result
        } = wb_data;



assign rf_we    = gr_we && mem_to_wb_valid;
assign rf_waddr = dest;
assign rf_wdata = final_result;

assign wb_rf_id_data = {
                        mem_to_wb_valid,
                        rf_we,
                        rf_waddr,
                        rf_wdata
                        };

assign debug_wb_pc       = pc;
assign debug_wb_rf_we    = {4{rf_we}};
assign debug_wb_rf_wnum  = dest;
assign debug_wb_rf_wdata = final_result;

endmodule

