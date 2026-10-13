// 【融合版】本文件为“汲取三方长处”的融合版：前递逻辑中吸收了 chl 的前递保护思想，
// 显式不让多周期乘除的中间值污染 EX->ID 前递；可读性注释亦参考 chl 风格。
// ID 阶段：译码、立即数生成、寄存器堆读取、数据前递、分支解析与冲突检测。
// 位于五级流水线第二级，接收 IF-ID 流水寄存器，输出 ID-EX 流水寄存器；
// 并向 IF 反馈 br_taken/br_target 以及 stall（load-use 冲突 / 乘除多周期）。
module id_stage(
    input  wire        clk,
    input  wire        reset,
    // IF-ID pipeline bus
    input  wire        if_id_valid,
    input  wire [31:0] if_id_pc,
    input  wire [31:0] if_id_inst,
    // Register-file write-back bus（WB 阶段写回，用于前递）
    input  wire        rf_we,
    input  wire [ 4:0] rf_waddr,
    input  wire [31:0] rf_wdata,

    // EX-MEM 阶段的运算结果，作为前递源
    input  wire        ex_mem_valid,
    input  wire        ex_mem_gr_we,
    input  wire [ 4:0] ex_mem_dest,
    input  wire [31:0] ex_mem_alu_result,
    input  wire        ex_mem_res_from_mem,

    // EX 阶段回传的组合 ALU 结果（用于 EX->ID 前递）与除法忙标志
    input  wire [31:0] ex_alu_result,
    input  wire        ex_busy,

    // Branch feedback to IF（分支结果反馈给 IF 阶段）
    output wire        br_taken,
    output wire [31:0] br_target,
    output wire        stall,
    // ID-EX pipeline bus
    output reg         id_ex_valid,
    output reg  [31:0] id_ex_pc,
    output reg  [31:0] id_ex_src1,
    output reg  [31:0] id_ex_src2,
    output reg  [31:0] id_ex_store_data,
    output reg  [18:0] id_ex_alu_op,
    output reg         id_ex_mem_we,
    output reg         id_ex_res_from_mem,
    output reg         id_ex_gr_we,
    output reg  [ 4:0] id_ex_dest
);

// 译码得到的控制信号与操作数
wire [31:0] inst;          // 当前待译码指令
wire [18:0] alu_op;        // ALU one-hot 控制码（19 位，含乘除）
wire        src1_is_pc;    // ALU 源操作数 1 为 PC
wire        src2_is_imm;   // ALU 源操作数 2 为立即数
wire        res_from_mem;  // 写回数据来自访存（load）
wire        dst_is_r1;     // 目的寄存器固定为 r1（bl 指令）
wire        gr_we;         // 通用寄存器写使能
wire        mem_we;        // 存储器写使能
wire        src_reg_is_rd; // 源寄存器 2 使用 rd 而非 rk（beq/bne/st_w）
wire [ 4:0] dest;          // 写回目的寄存器号
wire [31:0] rj_value;      // 寄存器堆读出的 rj
wire [31:0] rkd_value;     // 寄存器堆读出的 rk/rd
wire [31:0] id_src1;       // ALU 源操作数 1
wire [31:0] id_src2;       // ALU 源操作数 2
wire [31:0] imm;           // 生成的立即数
wire [31:0] br_offs;       // 分支偏移
wire [31:0] jirl_offs;     // jirl 跳转偏移
wire        rj_eq_rd;      // rj 与 rk/rd 比较相等（分支条件）

// 指令各字段拆分
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

// 各字段的一位热码译码结果
wire [63:0] op_31_26_d;
wire [15:0] op_25_22_d;
wire [ 3:0] op_21_20_d;
wire [31:0] op_19_15_d;

// 各具体指令的一位热码识别信号
wire inst_add_w;
wire inst_sub_w;
wire inst_slt;
wire inst_sltu;
wire inst_nor;
wire inst_and;
wire inst_or;
wire inst_xor;
wire inst_slli_w;
wire inst_srli_w;
wire inst_srai_w;
wire inst_addi_w;
wire inst_ld_w;
wire inst_st_w;
wire inst_jirl;
wire inst_b;
wire inst_bl;
wire inst_beq;
wire inst_bne;
wire inst_lu12i_w;
wire inst_slti;
wire inst_sltui;
wire inst_andi;
wire inst_ori;
wire inst_xori;
wire inst_sll_w;
wire inst_srl_w;
wire inst_sra_w;
wire inst_pcaddu12i;
wire inst_mul_w;
wire inst_mulh_w;
wire inst_mulh_wu;
wire inst_div_w;
wire inst_mod_w;
wire inst_div_wu;
wire inst_mod_wu;

// 立即数格式选择信号
wire need_ui5;
wire need_si12;
wire need_ui12;
wire need_si16;
wire need_si20;
wire need_si26;
wire src2_is_4;

// 寄存器堆读写端口
wire [ 4:0] rf_raddr1;
wire [31:0] rf_rdata1;
wire [ 4:0] rf_raddr2;
wire [31:0] rf_rdata2;

// 数据前递与冲突检测信号
wire use_rj;           // 指令使用 rj 作为源操作数
wire use_rkd;          // 指令使用 rk/rd 作为源操作数

wire load_conflict;    // load-use 数据冲突

wire [31:0] rj_value_fwd;
wire [31:0] rkd_value_fwd;

assign inst = if_id_inst;

assign op_31_26 = inst[31:26];
assign op_25_22 = inst[25:22];
assign op_21_20 = inst[21:20];
assign op_19_15 = inst[19:15];

assign rd  = inst[ 4: 0];
assign rj  = inst[ 9: 5];
assign rk  = inst[14:10];
assign i12 = inst[21:10];
assign i20 = inst[24: 5];
assign i16 = inst[25:10];
assign i26 = {inst[9:0], inst[25:10]};

decoder_6_64 u_dec0(.in(op_31_26), .out(op_31_26_d));
decoder_4_16 u_dec1(.in(op_25_22), .out(op_25_22_d));
decoder_2_4  u_dec2(.in(op_21_20), .out(op_21_20_d));
decoder_5_32 u_dec3(.in(op_19_15), .out(op_19_15_d));

// 指令识别：用各字段的一位热码相与得到具体指令
assign inst_add_w   = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h00];
assign inst_sub_w   = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h02];
assign inst_slt     = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h04];
assign inst_sltu    = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h05];
assign inst_nor     = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h08];
assign inst_and     = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h09];
assign inst_or      = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h0a];
assign inst_xor     = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h0b];
assign inst_slli_w  = op_31_26_d[6'h00] & op_25_22_d[4'h1] & op_21_20_d[2'h0] & op_19_15_d[5'h01];
assign inst_srli_w  = op_31_26_d[6'h00] & op_25_22_d[4'h1] & op_21_20_d[2'h0] & op_19_15_d[5'h09];
assign inst_srai_w  = op_31_26_d[6'h00] & op_25_22_d[4'h1] & op_21_20_d[2'h0] & op_19_15_d[5'h11];
assign inst_addi_w  = op_31_26_d[6'h00] & op_25_22_d[4'ha];
assign inst_ld_w    = op_31_26_d[6'h0a] & op_25_22_d[4'h2];
assign inst_st_w    = op_31_26_d[6'h0a] & op_25_22_d[4'h6];
assign inst_jirl    = op_31_26_d[6'h13];
assign inst_b       = op_31_26_d[6'h14];
assign inst_bl      = op_31_26_d[6'h15];
assign inst_beq     = op_31_26_d[6'h16];
assign inst_bne     = op_31_26_d[6'h17];
assign inst_lu12i_w = op_31_26_d[6'h05] & ~inst[25];

// 新增的立即数运算、字移位与 pcaddu12i 指令识别
assign inst_slti    = op_31_26_d[6'h00] & op_25_22_d[4'h8];
assign inst_sltui   = op_31_26_d[6'h00] & op_25_22_d[4'h9];
assign inst_andi    = op_31_26_d[6'h00] & op_25_22_d[4'hd];
assign inst_ori     = op_31_26_d[6'h00] & op_25_22_d[4'he];
assign inst_xori    = op_31_26_d[6'h00] & op_25_22_d[4'hf];
assign inst_sll_w   = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h0e];
assign inst_srl_w   = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h0f];
assign inst_sra_w   = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h10];
assign inst_pcaddu12i = op_31_26_d[6'h07] & ~inst[25];

// 乘除指令识别：乘法在 ALU 内组合完成，除法交给 EX 的多周期模块
assign inst_mul_w   = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h18];
assign inst_mulh_w  = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h19];
assign inst_mulh_wu = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h1a];
assign inst_div_w   = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h2] & op_19_15_d[5'h00];
assign inst_mod_w   = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h2] & op_19_15_d[5'h01];
assign inst_div_wu  = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h2] & op_19_15_d[5'h02];
assign inst_mod_wu  = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h2] & op_19_15_d[5'h03];

// 生成 ALU 控制码（one-hot）：低位为普通运算，[12:14] 乘法，[15:18] 除法/取模
assign alu_op[ 0] = inst_add_w | inst_addi_w | inst_ld_w | inst_st_w |
                    inst_jirl | inst_bl | inst_pcaddu12i;
assign alu_op[ 1] = inst_sub_w;
assign alu_op[ 2] = inst_slt | inst_slti;
assign alu_op[ 3] = inst_sltu | inst_sltui;
assign alu_op[ 4] = inst_and | inst_andi;
assign alu_op[ 5] = inst_nor;
assign alu_op[ 6] = inst_or | inst_ori;
assign alu_op[ 7] = inst_xor | inst_xori;
assign alu_op[ 8] = inst_slli_w | inst_sll_w;
assign alu_op[ 9] = inst_srli_w | inst_srl_w;
assign alu_op[10] = inst_srai_w | inst_sra_w;
assign alu_op[11] = inst_lu12i_w;
assign alu_op[12] = inst_mul_w;      //乘积低位
assign alu_op[13] = inst_mulh_w;     //有符号乘积高位
assign alu_op[14] = inst_mulh_wu;    //无符号乘积高位
assign alu_op[15] = inst_div_w;      //[18:15] 为 div/mod，冲突判定与屏蔽前递用
assign alu_op[16] = inst_mod_w;
assign alu_op[17] = inst_div_wu;
assign alu_op[18] = inst_mod_wu;

// 立即数类型选择：不同指令使用不同立即数格式
assign need_ui5  = inst_slli_w | inst_srli_w | inst_srai_w;
assign need_si12 = inst_addi_w | inst_ld_w | inst_st_w | inst_slti | inst_sltui;
assign need_ui12 = inst_andi | inst_ori | inst_xori;   //无符号 12 位立即数
assign need_si16 = inst_jirl | inst_beq | inst_bne;
assign need_si20 = inst_lu12i_w | inst_pcaddu12i;
assign need_si26 = inst_b | inst_bl;
assign src2_is_4 = inst_jirl | inst_bl;

// 立即数生成：按 ui5/si12/ui12/si20 等格式扩展或拼接
assign imm = src2_is_4 ? 32'h4 :
             need_si20 ? {i20[19:0], 12'b0} :
             need_ui12 ? {20'b0, i12[11:0]} :
             /* need_ui5 || need_si12 */ {{20{i12[11]}}, i12[11:0]};

// 分支/jirl 偏移生成（最低位补 0）
assign br_offs = need_si26 ? {{4{i26[25]}}, i26[25:0], 2'b0} :
                              {{14{i16[15]}}, i16[15:0], 2'b0};
assign jirl_offs = {{14{i16[15]}}, i16[15:0], 2'b0};

// 源操作数选择/写回等控制信息
assign src_reg_is_rd = inst_beq | inst_bne | inst_st_w;
assign src1_is_pc    = inst_jirl | inst_bl | inst_pcaddu12i;
assign src2_is_imm   = inst_slli_w | inst_srli_w | inst_srai_w |
                       inst_addi_w | inst_ld_w   | inst_st_w   |
                       inst_lu12i_w| inst_jirl   | inst_bl     |
                       inst_slti   | inst_sltui  | inst_andi   |
                       inst_ori    | inst_xori   | inst_pcaddu12i;

assign res_from_mem = inst_ld_w;
assign dst_is_r1    = inst_bl;
assign gr_we        = ~inst_st_w & ~inst_beq & ~inst_bne & ~inst_b;
assign mem_we       = inst_st_w;
assign dest         = dst_is_r1 ? 5'd1 : rd;

assign rf_raddr1 = rj;
assign rf_raddr2 = src_reg_is_rd ? rd : rk;

// 寄存器堆例化（读端口 1=rj，读端口 2=rk 或 rd）
regfile u_regfile(
    .clk    (clk),
    .raddr1 (rf_raddr1),
    .rdata1 (rf_rdata1),
    .raddr2 (rf_raddr2),
    .rdata2 (rf_rdata2),
    .we     (rf_we),
    .waddr  (rf_waddr),
    .wdata  (rf_wdata)
);









// 寄存器堆读出的值与分支相等比较
assign rj_value  = rf_rdata1;
assign rkd_value = rf_rdata2;
assign rj_eq_rd  = (rj_value_fwd == rkd_value_fwd);

// 分支判断：beq/bne 条件成立或无条件跳转，且指令有效且未 stall
assign br_taken = if_id_valid && 
                  !stall &&
                  ((inst_beq && rj_eq_rd) ||
                   (inst_bne && !rj_eq_rd) ||
                   inst_jirl || inst_bl || inst_b);

// 分支目标地址：PC 相对偏移或寄存器相对（jirl）
assign br_target = (inst_beq || inst_bne || inst_bl || inst_b)
                 ? (if_id_pc + br_offs)
                 : (rj_value_fwd + jirl_offs);

// ALU 源操作数选择
assign id_src1 = src1_is_pc  ? if_id_pc : rj_value_fwd;
assign id_src2 = src2_is_imm ? imm      : rkd_value_fwd;

// 判断指令是否真正使用 rj / rkd，用于冲突与暂停判断
assign use_rj =  inst_add_w  | inst_sub_w  | inst_slt    | inst_sltu
               | inst_nor    | inst_and    | inst_or     | inst_xor
               | inst_slli_w | inst_srli_w | inst_srai_w
               | inst_addi_w | inst_ld_w   | inst_st_w
               | inst_jirl   | inst_beq    | inst_bne
               | inst_slti   | inst_sltui  | inst_andi   | inst_ori
               | inst_xori   | inst_sll_w  | inst_srl_w  | inst_sra_w
               | inst_mul_w  | inst_mulh_w | inst_mulh_wu
               | inst_div_w  | inst_mod_w  | inst_div_wu | inst_mod_wu;

assign use_rkd =  inst_add_w | inst_sub_w | inst_slt  | inst_sltu
                | inst_nor   | inst_and   | inst_or   | inst_xor
                | inst_st_w  | inst_beq   | inst_bne
                | inst_sll_w | inst_srl_w | inst_sra_w
                | inst_mul_w | inst_mulh_w | inst_mulh_wu
                | inst_div_w | inst_mod_w  | inst_div_wu | inst_mod_wu;

// load-use 冲突：ID 所需寄存器正是 EX/MEM 阶段未写回的 load 目的寄存器
assign load_conflict =
                       (id_ex_valid  && id_ex_gr_we  && id_ex_res_from_mem &&
                        id_ex_dest != 5'd0 &&
                        ((use_rj  && (rj       == id_ex_dest)) ||
                         (use_rkd && (rf_raddr2 == id_ex_dest)))) ||
                       (ex_mem_valid && ex_mem_gr_we && ex_mem_res_from_mem &&
                        ex_mem_dest != 5'd0 &&
                        ((use_rj  && (rj       == ex_mem_dest)) ||
                         (use_rkd && (rf_raddr2 == ex_mem_dest))));

// 产生暂停信号（冻结 IF/ID）：EX 除法忙、load-use 冲突，
// 或 EX 中为多周期 div/mod（alu_op[18:15]）时暂停
assign stall = ex_busy ||
               (if_id_valid && (load_conflict ||
                                (id_ex_valid && (|id_ex_alu_op[18:15]))));

// EX 中是否为多周期除法/取模指令（用于屏蔽其前递）
wire id_ex_is_multicycle = (|id_ex_alu_op[18:15]);

// 数据前递：优先级 EX 组合结果 > EX/MEM > WB，均未命中时用寄存器堆读数；
// 多周期乘除的中间值不参与前递（!id_ex_is_multicycle）
assign rj_value_fwd = (id_ex_valid && id_ex_gr_we && !id_ex_res_from_mem && !id_ex_is_multicycle && id_ex_dest != 5'd0 && rj == id_ex_dest) ? ex_alu_result :
                      (ex_mem_valid && ex_mem_gr_we && !ex_mem_res_from_mem &&
                       ex_mem_dest != 5'd0 && rj == ex_mem_dest) ? ex_mem_alu_result : 
                      ((rf_we && rf_waddr != 5'd0 && rj == rf_waddr) ? rf_wdata : rj_value);

assign rkd_value_fwd = (id_ex_valid && id_ex_gr_we && !id_ex_res_from_mem && !id_ex_is_multicycle && id_ex_dest != 5'd0 && rf_raddr2 == id_ex_dest) ? ex_alu_result :
                       (ex_mem_valid && ex_mem_gr_we && !ex_mem_res_from_mem &&
                        ex_mem_dest != 5'd0 && rf_raddr2 == ex_mem_dest ) ? ex_mem_alu_result :
                       ((rf_we && rf_waddr != 5'd0 && rf_raddr2 == rf_waddr) ? rf_wdata :rkd_value);

// 时序寄存器更新：写入 ID-EX 流水寄存器；stall 时清空以插入气泡
always @(posedge clk) begin
    if (reset) begin
        id_ex_valid        <= 1'b0;
        id_ex_pc           <= 32'b0;
        id_ex_src1         <= 32'b0;
        id_ex_src2         <= 32'b0;
        id_ex_store_data   <= 32'b0;
        id_ex_alu_op       <= 19'b0;
        id_ex_mem_we       <= 1'b0;
        id_ex_res_from_mem <= 1'b0;
        id_ex_gr_we        <= 1'b0;
        id_ex_dest         <= 5'b0;
    end
    else if (stall) begin
        id_ex_valid        <= 1'b0;
        id_ex_pc           <= 32'b0;
        id_ex_src1         <= 32'b0;
        id_ex_src2         <= 32'b0;
        id_ex_store_data   <= 32'b0;
        id_ex_alu_op       <= 19'b0;
        id_ex_mem_we       <= 1'b0;
        id_ex_res_from_mem <= 1'b0;
        id_ex_gr_we        <= 1'b0;
        id_ex_dest         <= 5'b0;
    end
    else begin
        id_ex_valid        <= if_id_valid;
        id_ex_pc           <= if_id_pc;
        id_ex_src1         <= id_src1;
        id_ex_src2         <= id_src2;
        id_ex_store_data   <= rkd_value_fwd;
        id_ex_alu_op       <= alu_op;
        id_ex_mem_we       <= mem_we;
        id_ex_res_from_mem <= res_from_mem;
        id_ex_gr_we        <= gr_we;
        id_ex_dest         <= dest;
    end
end

endmodule
