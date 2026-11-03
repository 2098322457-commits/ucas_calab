// 【融合版】本文件为“汲取三方长处”的融合版：前递逻辑中吸收了 chl 的前递保护思想，
// 显式不让多周期乘除的中间值污染 EX->ID 前递；可读性注释亦参考 chl 风格。
// ID 阶段：译码、立即数生成、寄存器堆读取、数据前递、分支解析与冲突检测。
// 位于五级流水线第二级，接收 IF-ID 流水寄存器，输出 ID-EX 流水寄存器；
// 并向 IF 反馈 br_taken/br_target 以及 stall（load-use 冲突 / 乘除多周期）。
module id_stage(
    input  wire        clk,
    input  wire        reset,
    input  wire        hold,       // 类 SRAM 访存未完成，冻结 ID-EX
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
    input  wire        mem_wb_valid,   // MEM-WB 有效，异常/ertn 需等更老指令写回
    input  wire        mem_wb_gr_we,   // MEM-WB 写寄存器使能
    input  wire [ 4:0] mem_wb_dest,    // MEM-WB 目的寄存器
    input  wire        mem_wb_res_from_mem, // MEM-WB 是否 load
    input  wire        mem_busy,       // MEM 类 SRAM 握手未完成，异常/ertn 需等待

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
    output reg  [ 4:0] id_ex_dest,
    output reg  [ 1:0] id_ex_mem_size,
    output reg         id_ex_mem_unsigned
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
wire        src_reg_is_rd; // 源寄存器 2 使用 rd 而非 rk（beq/bne/分支/st_w）
wire [ 4:0] dest;          // 写回目的寄存器号
wire [31:0] rj_value;      // 寄存器堆读出的 rj
wire [31:0] rkd_value;     // 寄存器堆读出的 rk/rd
wire [31:0] id_src1;       // ALU 源操作数 1
wire [31:0] id_src2;       // ALU 源操作数 2
wire [31:0] imm;           // 生成的立即数
wire [31:0] br_offs;       // 分支偏移
wire [31:0] jirl_offs;     // jirl 跳转偏移
wire        rj_eq_rd;      // rj 与 rk/rd 比较相等（beq/bne）
wire        rj_lt_rd_s;    // rj < rk/rd 有符号比较（blt/bge）
wire        rj_lt_rd_u;    // rj < rk/rd 无符号比较（bltu/bgeu）

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

// 新增分支与按宽度访存指令识别信号
wire inst_blt;             // 有符号小于跳转
wire inst_bge;             // 有符号大于等于跳转
wire inst_bltu;            // 无符号小于跳转
wire inst_bgeu;            // 无符号大于等于跳转
wire inst_ld_b;            // 取字节（符号扩展）
wire inst_ld_h;            // 取半字（符号扩展）
wire inst_ld_bu;           // 取字节（零扩展）
wire inst_ld_hu;           // 取半字（零扩展）
wire inst_st_b;            // 存字节
wire inst_st_h;            // 存半字

//新增csr控制指令
wire        inst_csr;      // CSR 类指令总标志
wire        inst_csrrd;    // csrrd
wire        inst_csrwr;    // csrwr
wire        inst_csrxchg;  // csrxchg
wire        inst_ertn;     // ertn
wire        inst_syscall;  // syscall

//异常类指令、计数器读指令
wire        inst_break;    // break（同步异常 BRK）
wire        inst_rdcntvl;  // rdcntvl.w：读 64 位自由计数器低 32 位
wire        inst_rdcntvh;  // rdcntvh.w：读 64 位自由计数器高 32 位
wire        inst_rdcntid;  // rdcntid：读核号 CSR.TID
wire        inst_tlbwr;    // tlbwr：本 CPU 未实现 TLB，视为已知指令但不产生效果
wire        inst_known;    // 是否命中本 CPU 已实现的任一指令（否则判为 INE）

//csr所需值
wire [13:0] csr_num;       //csr编号
reg  [31:0] csr_rdata;     //csr当前值（也作为 rdcnt* 的读数据通道）
wire [31:0] csr_wmask;     //写掩码
wire [31:0] csr_wdata;     //写数据
wire [31:0] csr_wvalue;    //最终写入值
wire        csr_we;        //写使能
wire        ertn_taken;       //ertn提交

//同步异常 / 中断请求（统一在 ID 级判定与提交）
wire        adef_valid;       // 取指地址错 ADEF
wire        ale_valid;        // 地址非对齐 ALE
wire        break_valid;      // 断点 BRK
wire        ine_valid;        // 指令不存在 INE
wire        syscall_valid;    // 系统调用 SYS
wire        sync_exc_valid;   // 上述同步异常的统一请求
wire        intr_pending;     // 中断挂起（CRMD.IE & ECFG.LIE & ESTAT.IS）
wire        intr_valid;       // 本拍是否响应中断
wire        exception_valid;  // 本拍是否提交异常（同步异常优先于中断）
wire [5:0]  exception_ecode;  // 写入 ESTAT[21:16] 的异常编码
wire        id_redirect;      // 本拍发生异常/ertn，需把 ID 中指令作废

//ID 级预算的访存地址（供 ALE 检查，与 EX 级公式一致）
wire [31:0] mem_addr;
wire        mem_is_word;      // 字访问 ld.w/st.w
wire        mem_is_half;      // 半字访问 ld.h/ld.hu/st.h
wire        id_is_csr_like;   // 走“0+读值”写回通道的指令（csr* 与 rdcnt*）

//新增csr寄存器
reg [31:0] csr_crmd, csr_prmd, csr_estat, csr_era, csr_eentry;
reg [31:0] csr_save0, csr_save1, csr_save2, csr_save3;
reg [31:0] csr_ecfg, csr_badv, csr_tid, csr_tcfg, csr_tval, csr_ticlr;
reg        timer_stop;     // 非周期定时器计数到 0 后停止的标志
reg [63:0] free_cnt;       // 64 位自由计数器（rdcntvl.w/rdcntvh.w 读取）

// 访存宽度与符号扩展信息（传给 EX/MEM/WB）
wire [ 1:0] mem_size;      // 2'd0 字节 / 2'd1 半字 / 2'd2 字
wire        mem_unsigned;  // load 是否无符号扩展

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
// 按宽度访存指令：op 主码 6'h0a，op_25_22 区分字节/半字/字与读/写
assign inst_ld_b    = op_31_26_d[6'h0a] & op_25_22_d[4'h0];
assign inst_ld_h    = op_31_26_d[6'h0a] & op_25_22_d[4'h1];
assign inst_ld_w    = op_31_26_d[6'h0a] & op_25_22_d[4'h2];
assign inst_st_b    = op_31_26_d[6'h0a] & op_25_22_d[4'h4];
assign inst_st_h    = op_31_26_d[6'h0a] & op_25_22_d[4'h5];
assign inst_st_w    = op_31_26_d[6'h0a] & op_25_22_d[4'h6];
assign inst_ld_bu   = op_31_26_d[6'h0a] & op_25_22_d[4'h8];
assign inst_ld_hu   = op_31_26_d[6'h0a] & op_25_22_d[4'h9];
assign inst_jirl    = op_31_26_d[6'h13];
assign inst_b       = op_31_26_d[6'h14];
assign inst_bl      = op_31_26_d[6'h15];
assign inst_beq     = op_31_26_d[6'h16];
assign inst_bne     = op_31_26_d[6'h17];
// 新增比较分支指令：op 主码 6'h18~6'h1b
assign inst_blt     = op_31_26_d[6'h18];
assign inst_bge     = op_31_26_d[6'h19];
assign inst_bltu    = op_31_26_d[6'h1a];
assign inst_bgeu    = op_31_26_d[6'h1b];
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

//新增csr指令识别
assign csr_num = inst[23:10];
assign inst_csr = (inst[31:24] == 8'h04);
assign inst_csrrd = inst_csr & (inst[9:5] == 5'h00);
assign inst_csrwr = inst_csr & (inst[9:5] == 5'h01);
assign inst_csrxchg = inst_csr & (inst[9:5] != 5'h00) & (inst[9:5] != 5'h01);
assign inst_syscall = (inst[31:15] == 17'h00056);
assign inst_ertn = (inst == 32'h06483800);

//break 0 的机器码为 0x002a0000，即 inst[31:15]==17'h00054（syscall 为 17'h00056）
assign inst_break = (inst[31:15] == 17'h00054);
//计数器/核号读取指令，均在 0x00006000/0x00006400 家族内，靠 rd 所在位段区分：
//  rdcntvl.w rd : 0x00006000 | rd         （rd 在 [4:0]）
//  rdcntvh.w rd : 0x00006400 | rd         （rd 在 [4:0]）
//  rdcntid   rd : 0x00006000 | (rd<<5)    （rd 在 [9:5]）
assign inst_rdcntvl = (inst[31:10] == 22'h000018) & (inst[9:5] == 5'b00000);
assign inst_rdcntvh = (inst[31:10] == 22'h0019) & (inst[9:5] == 5'b00000);
assign inst_rdcntid  = (inst[31:10] == 22'h0018) & (inst[4:0] == 5'b00000)
                      & (inst[9:5] != 5'b00000);
assign inst_tlbwr = (inst[31:15] == 17'h0c90);
//合法指令标志：命中任一已实现指令即合法，都不命中则判为 INE（指令不存在异常）
assign inst_known = inst_add_w   | inst_sub_w   | inst_slt     | inst_sltu    |
                    inst_nor     | inst_and     | inst_or      | inst_xor     |
                    inst_slli_w  | inst_srli_w  | inst_srai_w  |
                    inst_addi_w  | inst_ld_w    | inst_st_w    |
                    inst_slti    | inst_sltui   | inst_andi    | inst_ori     |
                    inst_xori    | inst_sll_w   | inst_srl_w   | inst_sra_w   |
                    inst_lu12i_w | inst_pcaddu12i |
                    inst_mul_w   | inst_mulh_w  | inst_mulh_wu |
                    inst_div_w   | inst_mod_w   | inst_div_wu  | inst_mod_wu  |
                    inst_beq     | inst_bne     | inst_blt     | inst_bge     |
                    inst_bltu    | inst_bgeu    | inst_b       | inst_bl      |
                    inst_jirl    |
                    inst_ld_b    | inst_ld_h    | inst_ld_bu   | inst_ld_hu    |
                    inst_st_b    | inst_st_h    |
                    inst_csr     | inst_syscall | inst_ertn    |
                    inst_break   | inst_rdcntvl | inst_rdcntvh | inst_rdcntid |
                    inst_tlbwr;   

// 生成 ALU 控制码（one-hot）：低位为普通运算，[12:14] 乘法，[15:18] 除法/取模
// 按宽度访存指令均用加法计算访存地址，故归入 alu_op[0]
assign alu_op[ 0] = inst_add_w | inst_addi_w | inst_ld_w | inst_st_w |
                    inst_ld_b | inst_ld_h | inst_ld_bu | inst_ld_hu |
                    inst_st_b | inst_st_h |
                    inst_jirl | inst_bl | inst_pcaddu12i |
                    inst_csrrd | inst_csrwr | inst_csrxchg |  //本质是0+rdata
                    inst_rdcntvl | inst_rdcntvh | inst_rdcntid; // 计数器/核号读回 rd
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
assign need_si12 = inst_addi_w | inst_ld_w | inst_st_w | inst_slti | inst_sltui
                 | inst_ld_b | inst_ld_h | inst_ld_bu | inst_ld_hu
                 | inst_st_b | inst_st_h;
assign need_ui12 = inst_andi | inst_ori | inst_xori;   //无符号 12 位立即数
assign need_si16 = inst_jirl | inst_beq | inst_bne | inst_blt | inst_bge
                 | inst_bltu | inst_bgeu;
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
// 比较分支与 store 类指令的源寄存器 2 使用 rd 字段
assign src_reg_is_rd = inst_beq | inst_bne | inst_blt | inst_bge |
                       inst_bltu | inst_bgeu |
                       inst_st_w | inst_st_b | inst_st_h |
                       inst_csrwr | inst_csrxchg;
assign src1_is_pc    = inst_jirl | inst_bl | inst_pcaddu12i;
assign src2_is_imm   = inst_slli_w | inst_srli_w | inst_srai_w |
                       inst_addi_w | inst_ld_w   | inst_st_w   |
                       inst_ld_b   | inst_ld_h   | inst_ld_bu  | inst_ld_hu |
                       inst_st_b   | inst_st_h   |
                       inst_lu12i_w| inst_jirl   | inst_bl     |
                       inst_slti   | inst_sltui  | inst_andi   |
                       inst_ori    | inst_xori   | inst_pcaddu12i;

assign res_from_mem = inst_ld_w | inst_ld_b | inst_ld_h | inst_ld_bu | inst_ld_hu;
assign dst_is_r1    = inst_bl;
// 分支指令、store 指令与异常指令不写通用寄存器（break 也不写）
assign gr_we        = ~inst_st_w & ~inst_st_b & ~inst_st_h &
                      ~inst_beq  & ~inst_bne  & ~inst_blt  & ~inst_bge &
                      ~inst_bltu & ~inst_bgeu & ~inst_b &
                      ~inst_syscall & ~inst_ertn & ~inst_break;
assign mem_we       = inst_st_w | inst_st_b | inst_st_h;
// 目的寄存器：bl 固定写 r1；rdcntid 的目的寄存器在 [9:5] 位段
assign dest         = inst_rdcntid ? inst[9:5] : (dst_is_r1 ? 5'd1 : rd);

// 访存宽度译码：字节(0)/半字(1)负载写指令分别映射，其余(仅 ld_w/st_w)为字(2)
assign mem_size     = (inst_ld_b | inst_ld_bu | inst_st_b) ? 2'b00 :
                      (inst_ld_h | inst_ld_hu | inst_st_h) ? 2'b01 : 2'b10;
// 仅 ld.bu/ld.hu 无符号扩展，其余 load 按符号扩展
assign mem_unsigned = inst_ld_bu | inst_ld_hu;

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

// 寄存器堆读出的值与分支比较
assign rj_value  = rf_rdata1;
assign rkd_value = rf_rdata2;
assign rj_eq_rd  = (rj_value_fwd == rkd_value_fwd);
assign rj_lt_rd_s = ($signed(rj_value_fwd) < $signed(rkd_value_fwd));  // 有符号比较
assign rj_lt_rd_u = (rj_value_fwd < rkd_value_fwd);                    // 无符号比较

//同步异常 / 中断判定（全部在 ID 级完成，提交于 ID 时序块）
//1) ADEF 取指地址错：IF 取回的 PC 不是 4 字节对齐（位段 [1:0] != 0）
//2) ALE  地址非对齐：字访问要求 addr[1:0]==0，半字访问要求 addr[0]==0，字节访问不检查
//3) BRK  断点指令 break
//4) INE  指令不存在：译码未命中任何本 CPU 已实现的指令
//5) SYS  系统调用 syscall（exp12 已实现，此处纳入统一异常通道）
assign mem_addr    = rj_value_fwd + imm;        // 与 EX 级访存地址公式保持一致
assign mem_is_word = inst_ld_w | inst_st_w;
assign mem_is_half = inst_ld_h | inst_ld_hu | inst_st_h;

assign adef_valid    = if_id_valid && !stall && (if_id_pc[1:0] != 2'b00);
assign ale_valid     = if_id_valid && !stall &&
                       ((mem_is_word && (mem_addr[1:0] != 2'b00)) ||
                        (mem_is_half && (mem_addr[0]   != 1'b0 )));
assign break_valid   = if_id_valid && !stall && inst_break;
assign ine_valid     = if_id_valid && !stall && !inst_known;
assign syscall_valid = if_id_valid && !stall && inst_syscall;
assign sync_exc_valid = adef_valid | ale_valid | break_valid | ine_valid | syscall_valid;

//异常编码（写入 ESTAT[21:16]；ESubCode 统一为 0）
//ADE=0x8  ALE=0x9  SYS=0xb  BRK=0xc  INE=0xd；落到最后的即为中断 INT=0x0
assign exception_ecode = adef_valid    ? 6'h08 :
                         ale_valid     ? 6'h09 :
                         syscall_valid ? 6'h0b :
                         break_valid   ? 6'h0c :
                         ine_valid     ? 6'h0d : 6'h00;

//中断：三级开关 CRMD.IE(全局) & ECFG.LIE[n](局部) & ESTAT.IS[n](状态)；
//      同步异常的优先级高于中断；stall 时说明前一条多周期指令未完成，等其完成再提交
assign intr_pending = csr_crmd[2] & (|(csr_estat[12:0] & csr_ecfg[12:0]));
assign intr_valid   = if_id_valid && !stall && intr_pending && !sync_exc_valid;

wire commit_ready = !ex_mem_valid && !mem_wb_valid && !mem_busy;
assign exception_valid  = (sync_exc_valid | intr_valid) & ~hold & commit_ready;
//注意：进入异常时硬件只置 ESTAT.Ecode，不清除 ESTAT.IS；IS 由软件写 ESTAT/TICLR 清除，
//且在异常处理期间 CRMD.IE 已被清 0，不会因 IS 仍然有效而反复重入中断。

assign ertn_taken = if_id_valid && !stall && !hold && inst_ertn && commit_ready;
//本拍发生异常/ertn：ID 中的这条指令必须作废（送往 EX 的将是气泡）
assign id_redirect = exception_valid | ertn_taken;

// 分支判断：beq/bne 相等比较、blt/bge/bltu/bgeu 大小比较成立，
// 或无条件跳转，且指令有效且未 stall
assign br_taken = if_id_valid && 
                  !stall &&
                  ((inst_beq  && rj_eq_rd) ||
                   (inst_bne  && !rj_eq_rd) ||
                   (inst_blt  && rj_lt_rd_s) ||
                   (inst_bge  && !rj_lt_rd_s) ||
                   (inst_bltu && rj_lt_rd_u) ||
                   (inst_bgeu && !rj_lt_rd_u) ||
                   inst_jirl || inst_bl || inst_b) |
                   id_redirect;   // 异常走 EENTRY、ertn 走 ERA，同样改变取指方向

// 分支目标地址：异常/中断走 EENTRY，ertn 走 ERA，其余为 PC 相对偏移或寄存器相对（jirl）
assign br_target = exception_valid ? csr_eentry :
                   ertn_taken      ? csr_era :
                   ((inst_beq || inst_bne || inst_blt || inst_bge ||
                    inst_bltu || inst_bgeu || inst_bl || inst_b)
                    ? (if_id_pc + br_offs)
                    : (rj_value_fwd + jirl_offs));

// ALU 源操作数选择：csr* 与 rdcnt* 都走“0 + 读值”的通道写回 rd
assign id_is_csr_like = inst_csr | inst_rdcntvl | inst_rdcntvh | inst_rdcntid;
assign id_src1 = id_is_csr_like ? 32'b0    : src1_is_pc  ? if_id_pc : rj_value_fwd;
assign id_src2 = id_is_csr_like ? csr_rdata : src2_is_imm ? imm     : rkd_value_fwd;

// 判断指令是否真正使用 rj / rkd，用于冲突与暂停判断
assign use_rj =  inst_add_w  | inst_sub_w  | inst_slt    | inst_sltu
               | inst_nor    | inst_and    | inst_or     | inst_xor
               | inst_slli_w | inst_srli_w | inst_srai_w
               | inst_addi_w | inst_ld_w   | inst_st_w
               | inst_ld_b   | inst_ld_h   | inst_ld_bu  | inst_ld_hu
               | inst_st_b   | inst_st_h
               | inst_jirl   | inst_beq    | inst_bne
               | inst_blt    | inst_bge    | inst_bltu   | inst_bgeu
               | inst_slti   | inst_sltui  | inst_andi   | inst_ori
               | inst_xori   | inst_sll_w  | inst_srl_w  | inst_sra_w
               | inst_mul_w  | inst_mulh_w | inst_mulh_wu
               | inst_div_w  | inst_mod_w  | inst_div_wu | inst_mod_wu
               | inst_csrxchg;

assign use_rkd =  inst_add_w | inst_sub_w | inst_slt  | inst_sltu
                | inst_nor   | inst_and   | inst_or   | inst_xor
                | inst_st_w  | inst_st_b  | inst_st_h
                | inst_beq   | inst_bne   | inst_blt  | inst_bge  | inst_bltu | inst_bgeu
                | inst_sll_w | inst_srl_w | inst_sra_w
                | inst_mul_w | inst_mulh_w | inst_mulh_wu
                | inst_div_w | inst_mod_w  | inst_div_wu | inst_mod_wu
                | inst_csrwr |inst_csrxchg;

// load-use 冲突：ID 所需寄存器正是 EX/MEM 阶段未写回的 load 目的寄存器
assign load_conflict =
                       (id_ex_valid  && id_ex_gr_we  && id_ex_res_from_mem &&
                        id_ex_dest != 5'd0 &&
                        ((use_rj  && (rj       == id_ex_dest)) ||
                         (use_rkd && (rf_raddr2 == id_ex_dest)))) ||
                       (ex_mem_valid && ex_mem_gr_we && ex_mem_res_from_mem &&
                        ex_mem_dest != 5'd0 &&
                        ((use_rj  && (rj       == ex_mem_dest)) ||
                         (use_rkd && (rf_raddr2 == ex_mem_dest)))) ||
                       (mem_wb_valid && mem_wb_gr_we && mem_wb_res_from_mem &&
                        mem_wb_dest != 5'd0 &&
                        ((use_rj  && (rj       == mem_wb_dest)) ||
                         (use_rkd && (rf_raddr2 == mem_wb_dest))));
//增加wb阶段的阻塞。原先wb的前递是在访存固定一拍的情况下，现在访存时间开销未知故必须要阻塞

// 产生暂停信号（冻结 IF/ID）：EX 除法忙、load-use 冲突，
// 或 EX 中为多周期 div/mod（alu_op[18:15]）时暂停
// 异常/ertn 提交前等待更老的 EX-MEM/MEM-WB 指令完成，保证精确异常；
// 用 stall 冻结 IF-ID，避免等待期间 IF 继续发射而丢掉异常指令。
wire exc_raw = (if_id_pc[1:0] != 2'b00) ||
               (mem_is_word && (mem_addr[1:0] != 2'b00)) ||
               (mem_is_half && (mem_addr[0]   != 1'b0 )) ||
               inst_syscall | inst_break | inst_ertn | !inst_known | intr_pending;
wire exc_wait = if_id_valid && !hold && exc_raw && !commit_ready;

assign stall = ex_busy || exc_wait ||
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

//选择csr读值
//rdcntvl.w/rdcntvh.w/rdcntid 不使用 csr_num 字段，单独优先选择读值
always @(*) begin
    if(inst_rdcntvl)      csr_rdata = free_cnt[31:0];    // 64 位自由计数器低 32 位
    else if(inst_rdcntvh) csr_rdata = free_cnt[63:32];   // 64 位自由计数器高 32 位
    else if(inst_rdcntid) csr_rdata = csr_tid;           // 核号 CSR.TID
    else case (csr_num)
        14'h00 : csr_rdata = csr_crmd;
        14'h01 : csr_rdata = csr_prmd;
        14'h04 : csr_rdata = csr_ecfg;
        14'h05 : csr_rdata = csr_estat;
        14'h06 : csr_rdata = csr_era;
        14'h07 : csr_rdata = csr_badv;
        14'h0c : csr_rdata = csr_eentry;
        14'h30 : csr_rdata = csr_save0;
        14'h31 : csr_rdata = csr_save1;
        14'h32 : csr_rdata = csr_save2;
        14'h33 : csr_rdata = csr_save3;
        14'h40 : csr_rdata = csr_tid;
        14'h41 : csr_rdata = csr_tcfg;
        14'h42 : csr_rdata = csr_tval;
        14'h44 : csr_rdata = csr_ticlr;   // TICLR 只写清除位，读出恒为 0
        default : csr_rdata = 32'b0;
    endcase
end

assign csr_wmask = inst_csrwr ? 32'hffffffff : rj_value_fwd;
assign csr_wdata = rkd_value_fwd;
assign csr_wvalue = (csr_rdata & ~csr_wmask) | (csr_wdata & csr_wmask);
assign csr_we = (inst_csrwr | inst_csrxchg) & if_id_valid & ~stall & ~hold;     
//如果是写指令则关闭rdata通道

always @(posedge clk)begin
    if(reset)begin
        csr_crmd <= 32'h00000008;   //复位后 DA=1，直接地址模式
        csr_prmd <= 32'b0;
        csr_ecfg <= 32'b0;
        csr_estat <= 32'b0;
        csr_era <= 32'b0;
        csr_badv <= 32'b0;
        csr_eentry <= 32'b0;
        csr_save0 <= 32'b0;
        csr_save1 <= 32'b0;
        csr_save2 <= 32'b0;
        csr_save3 <= 32'b0;
        csr_tid <= 32'b0;
        csr_tcfg <= 32'b0;
        csr_tval <= 32'b0;
        csr_ticlr <= 32'b0;
        timer_stop <= 1'b1;         //复位后定时器未使能，处于停止状态
    end
    else begin
        // 核内定时器：En=1 且未停止时逐拍递减，减到 0 置 TI(IS[11]) 
        if(csr_tcfg[0] && !timer_stop & !hold)begin     //若无!hold，指令阻塞时计时器依旧一直-1。在随机种子下可能导致中断落点错误
            if(csr_tval == 32'b0)begin
                csr_estat[11] <= 1'b1;                   // 定时器中断置位（TI 对应 IS[11]）
                csr_tval      <= csr_tcfg[1] ? csr_tcfg[31:2] : 32'b0; // 周期模式重装初值
                timer_stop    <= ~csr_tcfg[1];           // 非周期模式到期后停止计数
            end
            else csr_tval <= csr_tval - 32'b1;
        end
        // 异常/中断提交：优先级高于 ertn 与 CSR 写 
        if(exception_valid)begin
            csr_era          <= if_id_pc;                // 保存返回地址（中断取 ID 中指令的 PC）
            csr_prmd[2:0]    <= csr_crmd[2:0];           // 保存进入前的 PLV/IE
            csr_crmd[2:0]    <= 3'b000;                  // 进入内核态并关闭全局中断
            csr_estat[21:16] <= exception_ecode;         // Ecode 记录异常/中断类型
            csr_estat[30:22] <= 9'h0;                    // ESubCode 本实验统一为 0
            if(adef_valid | ale_valid)                   // 仅这两类异常更新 BADV
                csr_badv <= adef_valid ? if_id_pc : mem_addr;
        end
        else if(ertn_taken) begin
            csr_crmd[2:0] <= csr_prmd[2:0];              // 恢复 PLV/IE
        end
        else if(csr_we)begin
            case(csr_num)
                14'h00 : csr_crmd   <= csr_wvalue;
                14'h01 : csr_prmd   <= csr_wvalue;
                14'h04 : csr_ecfg   <= csr_wvalue & 32'h00001bff;
                        // ECFG 仅 LIE[12:0] 有效，其中 [10] 为保留位，写入后读出恒为 0
                14'h05 : begin
                        // ESTAT：Ecode/ESubCode 与软件中断位 IS[1:0] 可由软件写入；
                        //        IS[12:2] 是硬件中断状态（TI 由 TICLR 清除），软件写入无效
                        csr_estat[21:16] <= csr_wvalue[21:16];
                        csr_estat[30:22] <= csr_wvalue[30:22];
                        csr_estat[1:0]   <= csr_wvalue[1:0];
                        end
                14'h06 : csr_era    <= csr_wvalue;
                14'h07 : csr_badv   <= csr_wvalue;
                14'h0c : csr_eentry <= csr_wvalue;
                14'h30 : csr_save0  <= csr_wvalue;
                14'h31 : csr_save1  <= csr_wvalue;
                14'h32 : csr_save2  <= csr_wvalue;
                14'h33 : csr_save3  <= csr_wvalue;
                14'h40 : csr_tid    <= csr_wvalue;       // TID：核号，由软件写入
                14'h41 : begin                           // TCFG：写配置的同时重装定时器
                         csr_tcfg   <= csr_wvalue;       //   [0]=En 使能, [1]=Periodic, [31:2]=InitVal
                         csr_tval   <= csr_wvalue[31:2];
                         timer_stop <= ~csr_wvalue[0];
                         end
                14'h42 : csr_tval   <= csr_wvalue;       // TVAL：可直接写入当前计数值
                14'h44 : if(csr_wvalue[0]) csr_estat[11] <= 1'b0; // TICLR：写 1 清 TI
                default : ;
            endcase
        end
    end
end

// 64 位自由计数器：每个时钟自增 1，供 rdcntvl.w/rdcntvh.w 读取
always @(posedge clk)begin
    if(reset) free_cnt <= 64'b0;
    else      free_cnt <= free_cnt + 64'b1;
end

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
        id_ex_mem_size     <= 2'b0;
        id_ex_mem_unsigned <= 1'b0;
    end
    else if (hold) begin
        // 类 SRAM 访存未完成：保持 ID-EX 不变，等待后端完成
    end
    else if (stall || id_redirect) begin
        // stall：插入气泡；id_redirect：本拍发生异常/ertn，ID 中的指令作废，同样清空
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
        id_ex_mem_size     <= 2'b0;
        id_ex_mem_unsigned <= 1'b0;
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
        id_ex_mem_size     <= mem_size;
        id_ex_mem_unsigned <= mem_unsigned;
    end
end

endmodule
