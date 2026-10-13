module alu(
  input  wire [18:0] alu_op,
  input  wire [31:0] alu_src1,
  input  wire [31:0] alu_src2,
  output wire [31:0] alu_result
);

wire op_add;   //add operation
wire op_sub;   //sub operation
wire op_slt;   //signed compared and set less than
wire op_sltu;  //unsigned compared and set less than
wire op_and;   //bitwise and
wire op_nor;   //bitwise nor
wire op_or;    //bitwise or
wire op_xor;   //bitwise xor
wire op_sll;   //logic left shift
wire op_srl;   //logic right shift
wire op_sra;   //arithmetic right shift
wire op_lui;   //Load Upper Immediate

wire op_mul;
wire op_mulh;
wire op_mulh_wu;
wire op_div;
wire op_mod;
wire op_div_wu;
wire op_mod_wu;

// control code decomposition
assign op_add  = alu_op[ 0];
assign op_sub  = alu_op[ 1];
assign op_slt  = alu_op[ 2];
assign op_sltu = alu_op[ 3];
assign op_and  = alu_op[ 4];
assign op_nor  = alu_op[ 5];
assign op_or   = alu_op[ 6];
assign op_xor  = alu_op[ 7];
assign op_sll  = alu_op[ 8];
assign op_srl  = alu_op[ 9];
assign op_sra  = alu_op[10];
assign op_lui  = alu_op[11];

assign op_mul = alu_op[12];
assign op_mulh = alu_op[13];
assign op_mulh_wu = alu_op[14];
assign op_div = alu_op[15];
assign op_mod = alu_op[16];
assign op_div_wu = alu_op[17];
assign op_mod_wu = alu_op[18]; 

wire [31:0] add_sub_result;
wire [31:0] slt_result;
wire [31:0] sltu_result;
wire [31:0] and_result;
wire [31:0] nor_result;
wire [31:0] or_result;
wire [31:0] xor_result;
wire [31:0] lui_result;
wire [31:0] sll_result;
wire [63:0] sr64_result;
wire [31:0] sr_result;


wire mul_signed = op_mul | op_mulh;
wire [32:0] mul_a = {mul_signed & alu_src1[31], alu_src1};
wire [32:0] mul_b = {mul_signed & alu_src2[31], alu_src2};
wire signed [63:0] mul_result = $signed(mul_a) * $signed(mul_b);    //￥signed为系统函数，将数解释为有符号数
wire [31:0] mul_sel_result = (op_mulh | op_mulh_wu) ? mul_result[63:32] : mul_result[31:0];

wire div_signed = op_div | op_mod;  //有符号除法和有符号取模
wire [31:0] div_a_x = {32{div_signed & alu_src1[31]}} ^ alu_src1;     //异或。如果有符号且负数，取反之后加一，得到绝对值
wire [31:0] div_b_x = {32{div_signed & alu_src2[31]}} ^ alu_src2;     //无符号则不变
wire [31:0] div_a_abs = div_a_x + {31'b0, (div_signed & alu_src1[31])};   //绝对值
wire [31:0] div_b_abs = div_b_x + {31'b0, (div_signed & alu_src2[31])};   //无符号或者正数则不变
wire [31:0] div_b_nz = (div_b_abs == 32'b0) ? 32'b1 : div_b_abs;  //遇到除数为0修正为1
wire [31:0] div_q_abs = div_a_abs / div_b_nz;   //商的绝对值
wire [31:0] div_r_abs = div_a_abs - div_b_nz * div_q_abs;   //模的绝对值
wire div_q_sign = div_signed & (alu_src1[31] ^ alu_src2[31]);   //商的符号，两个操作数符号不同
wire div_r_sign = div_signed & alu_src1[31];      //模的符号，只看第一个操作数
wire [31:0] div_s_result = ({32{div_q_sign}} ^ div_q_abs) + {31'b0, div_q_sign}; //有符号且为负数时，把绝对值变回符号数
wire [31:0] div_r_result = ({32{div_r_sign}} ^ div_r_abs) + {31'b0, div_r_sign};


// 32-bit adder
wire [31:0] adder_a;
wire [31:0] adder_b;
wire        adder_cin;
wire [31:0] adder_result;
wire        adder_cout;

assign adder_a   = alu_src1;
assign adder_b   = (op_sub | op_slt | op_sltu) ? ~alu_src2 : alu_src2;  //src1 - src2 rj-rk
assign adder_cin = (op_sub | op_slt | op_sltu) ? 1'b1      : 1'b0;
assign {adder_cout, adder_result} = adder_a + adder_b + adder_cin;

// ADD, SUB result
assign add_sub_result = adder_result;

// SLT result
assign slt_result[31:1] = 31'b0;   //rj < rk 1
assign slt_result[0]    = (alu_src1[31] & ~alu_src2[31])
                        | ((alu_src1[31] ~^ alu_src2[31]) & adder_result[31]);

// SLTU result
assign sltu_result[31:1] = 31'b0;
assign sltu_result[0]    = ~adder_cout;

/* answer
 * bug：or运算逻辑错误
 */
// bitwise operation
assign and_result = alu_src1 & alu_src2;
assign or_result  = alu_src1 | alu_src2;
assign nor_result = ~or_result;
assign xor_result = alu_src1 ^ alu_src2;
assign lui_result = alu_src2;

/* answer
 * bug：移位的操作数错误
 */
// SLL result
assign sll_result = alu_src1 << alu_src2[4:0];   //rj << i5

// SRL, SRA result
assign sr64_result = {{32{op_sra & alu_src1[31]}}, alu_src1[31:0]} >> alu_src2[4:0]; //rj >> i5

/* answer
 * bug：位宽错误
 */
assign sr_result   = sr64_result[31:0];

// final result mux
assign alu_result = ({32{op_add|op_sub}} & add_sub_result)
                  | ({32{op_slt       }} & slt_result)
                  | ({32{op_sltu      }} & sltu_result)
                  | ({32{op_and       }} & and_result)
                  | ({32{op_nor       }} & nor_result)
                  | ({32{op_or        }} & or_result)
                  | ({32{op_xor       }} & xor_result)
                  | ({32{op_lui       }} & lui_result)
                  | ({32{op_sll       }} & sll_result)
                  | ({32{op_srl|op_sra}} & sr_result)
                  | ({32{op_mul | op_mulh | op_mulh_wu}} & mul_sel_result)
                  | ({32{op_div | op_div_wu}} & div_s_result)
                  | ({32{op_mod | op_mod_wu}} & div_r_result);

endmodule
