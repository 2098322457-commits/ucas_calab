// ALU：根据 19 位 one-hot 控制码 alu_op，对两个 32 位操作数 alu_src1/alu_src2
// 执行加/减/比较/逻辑/移位/lui/乘法 运算，输出 alu_result。
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
wire op_mul_w;     //mul.w：取乘积低 32 位
wire op_mulh_w;    //mulh.w：取有符号乘积高 32 位
wire op_mulh_wu;   //mulh.wu：取无符号乘积高 32 位

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
assign op_mul_w    = alu_op[12];
assign op_mulh_w   = alu_op[13];
assign op_mulh_wu  = alu_op[14];

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
wire [31:0] mul_result;    //乘法结果低位
wire [31:0] mulh_result;   //有符号乘法结果高位
wire [31:0] mulhu_result;  //无符号乘法结果高位


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

// 乘法：分别用有符号/无符号 32x32 组合乘法，得到 64 位乘积
wire signed [63:0] mul_s;
wire        [63:0] mul_u;
assign mul_s = $signed(alu_src1) * $signed(alu_src2);
assign mul_u = alu_src1 * alu_src2;

// 取乘积的不同部分：低位(mul.w)、有符号高位(mulh.w)、无符号高位(mulh.wu)
assign mul_result   = mul_s[31:0];
assign mulh_result  = mul_s[63:32];
assign mulhu_result = mul_u[63:32];

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
                  | ({32{op_mul_w    }} & mul_result)
                  | ({32{op_mulh_w   }} & mulh_result)
                  | ({32{op_mulh_wu  }} & mulhu_result);

endmodule
