// EX 阶段：执行（组合 ALU 运算 / 多周期除法）与 EX-MEM 流水寄存器。
// 位于五级流水线第三级，接收 ID-EX 流水寄存器，输出 EX-MEM 流水寄存器；
// 除法为多周期操作，用状态机驱动 div 模块，完成前用 ex_busy 通知 ID 冻结流水线。
module ex_stage(
    input  wire        clk,        // 时钟
    input  wire        reset,      // 同步复位，高有效
    // ID-EX pipeline bus（来自 ID 阶段的流水寄存器）
    input  wire        id_ex_valid,
    input  wire [31:0] id_ex_pc,
    input  wire [31:0] id_ex_src1,
    input  wire [31:0] id_ex_src2,
    input  wire [31:0] id_ex_store_data,
    input  wire [18:0] id_ex_alu_op,
    input  wire        id_ex_mem_we,
    input  wire        id_ex_res_from_mem,
    input  wire        id_ex_gr_we,
    input  wire [ 4:0] id_ex_dest,
    input  wire [ 1:0] id_ex_mem_size,      // 访存宽度（透传，供 MEM 按宽度写/读）
    input  wire        id_ex_mem_unsigned,  // load 无符号扩展标志（透传）
    // multi-cycle div busy flag to ID
    output wire        ex_busy,       // 除法进行中，通知 ID 暂停取指并插气泡
    output wire [31:0] ex_alu_result, // 组合 ALU 结果（回传给 ID 做前递）
    // EX-MEM pipeline bus
    output reg         ex_mem_valid,
    output reg  [31:0] ex_mem_pc,
    output reg  [31:0] ex_mem_alu_result,
    output reg  [31:0] ex_mem_store_data,
    output reg         ex_mem_mem_we,
    output reg         ex_mem_res_from_mem,
    output reg         ex_mem_gr_we,
    output reg  [ 4:0] ex_mem_dest,
    output reg  [ 1:0] ex_mem_mem_size,
    output reg         ex_mem_mem_unsigned
);

// 组合 ALU：对 ID-EX 寄存器的操作数执行运算（乘法等单周期运算在此完成）
alu u_alu(
    .alu_op     (id_ex_alu_op),
    .alu_src1   (id_ex_src1),
    .alu_src2   (id_ex_src2),
    .alu_result (ex_alu_result)
);

// ---------- multi-cycle div ----------
// 除法控制状态机：S_IDLE 空闲，S_DIV 等待多周期除法完成
localparam S_IDLE = 2'd0;
localparam S_DIV  = 2'd1;

reg [1:0] state;

// id_ex_alu_op[18:12] 一位热码：乘除指令译码
wire [6:0] kind_r = id_ex_alu_op[18:12];
wire k_div_w    = kind_r[3];   //div.w
wire k_mod_w    = kind_r[4];   //mod.w
wire k_div_wu   = kind_r[5];   //div.wu
wire k_mod_wu   = kind_r[6];   //mod.wu

wire k_is_div = k_div_w | k_mod_w | k_div_wu | k_mod_wu;  // 是否为除法/取模指令

wire div_start = (state == S_IDLE) && id_ex_valid && k_is_div;  // 启动一次除法

// 多周期期间保存的控制信息（id_ex 会被暂停清空）
reg [31:0] r_pc;
reg [ 4:0] r_dest;
reg        r_gr_we;
reg        r_sel_rem;   // 取除法余数

wire [31:0] div_s;         // 商
wire [31:0] div_r;         // 余数
wire        div_complete;  // 除法完成标志

// 多周期除法器例化：div.w/mod.w 为有符号，div.wu/mod.wu 为无符号
div u_div(
    .div_clk    (clk),
    .resetn     (~reset),
    .div        (div_start),
    .div_signed (k_div_w | k_mod_w),
    .x          (id_ex_src1),
    .y          (id_ex_src2),
    .s          (div_s),
    .r          (div_r),
    .complete   (div_complete)
);

// 除法进行中拉高 ex_busy，ID 据此冻结取指并向 EX 插气泡
assign ex_busy = (state != S_IDLE);

// 时序逻辑：S_IDLE 处理普通指令或启动除法；S_DIV 等待除法完成并写回结果
always @(posedge clk) begin
    if (reset) begin
        state               <= S_IDLE;
        ex_mem_valid        <= 1'b0;
        ex_mem_pc           <= 32'b0;
        ex_mem_alu_result   <= 32'b0;
        ex_mem_store_data   <= 32'b0;
        ex_mem_mem_we       <= 1'b0;
        ex_mem_res_from_mem <= 1'b0;
        ex_mem_gr_we        <= 1'b0;
        ex_mem_dest         <= 5'b0;
        ex_mem_mem_size     <= 2'b10;
        ex_mem_mem_unsigned <= 1'b0;
        r_pc                <= 32'b0;
        r_dest              <= 5'b0;
        r_gr_we             <= 1'b0;
        r_sel_rem           <= 1'b0;
    end
    else begin
        case (state)
            S_IDLE: begin
                if (div_start) begin
                    // 遇到除法指令：锁存写回信息，转入 S_DIV，先向 EX-MEM 插一个空泡
                    state        <= S_DIV;
                    r_pc         <= id_ex_pc;
                    r_dest       <= id_ex_dest;
                    r_gr_we      <= id_ex_gr_we;
                    r_sel_rem    <= k_mod_w | k_mod_wu;   // 取模则写回余数
                    ex_mem_valid <= 1'b0;
                end
                else begin
                    // 普通指令：组合 ALU 结果直接锁存进 EX-MEM（含访存宽度/符号信息）
                    ex_mem_valid        <= id_ex_valid;
                    ex_mem_pc           <= id_ex_pc;
                    ex_mem_alu_result   <= ex_alu_result;
                    ex_mem_store_data   <= id_ex_store_data;
                    ex_mem_mem_we       <= id_ex_mem_we;
                    ex_mem_res_from_mem <= id_ex_res_from_mem;
                    ex_mem_gr_we        <= id_ex_gr_we;
                    ex_mem_dest         <= id_ex_dest;
                    ex_mem_mem_size     <= id_ex_mem_size;
                    ex_mem_mem_unsigned <= id_ex_mem_unsigned;
                end
            end
            S_DIV: begin
                if (div_complete) begin
                    // 除法完成：按 div/mod 选择商或余数写入 EX-MEM，回到空闲
                    ex_mem_valid        <= 1'b1;
                    ex_mem_pc           <= r_pc;
                    ex_mem_alu_result   <= r_sel_rem ? div_r : div_s;
                    ex_mem_store_data   <= 32'b0;
                    ex_mem_mem_we       <= 1'b0;
                    ex_mem_res_from_mem <= 1'b0;
                    ex_mem_gr_we        <= r_gr_we;
                    ex_mem_dest         <= r_dest;
                    ex_mem_mem_size     <= 2'b10;   // 除法视为按字写回
                    ex_mem_mem_unsigned <= 1'b0;
                    state               <= S_IDLE;
                end
                else begin
                    ex_mem_valid        <= 1'b0;   // 未完成，继续插气泡
                end
            end
            default: state <= S_IDLE;
        endcase
    end
end

endmodule