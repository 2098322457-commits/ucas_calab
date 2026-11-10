// 除法器：多周期串行除法模块，支持有符号/无符号的 div/mod。
// 采用 32 拍移位迭代：64 位 shift 高 32 位存放余数、低 32 位存放商；
// div 拉高后进入 S_RUN，complete 拉高表示结果有效（s 为商、r 为余数）。
// 端口：div_signed 选择有符号除；x 被除数、y 除数；s 商、r 余数；complete 完成标志。
module div(
    input  wire        div_clk,
    input  wire        resetn,
    input  wire        div,         
    input  wire        div_signed,  
    input  wire [31:0] x,          
    input  wire [31:0] y,            
    output reg  [31:0] s,            
    output reg  [31:0] r,           
    output reg         complete      
);

localparam S_IDLE = 2'd0;
localparam S_RUN  = 2'd1;

// 状态机与运算寄存器：
//   state   : 状态机状态（S_IDLE 空闲 / S_RUN 迭代中）
//   x_r     : 锁存的被除数原值（除零时用于返回余数）
//   divisor : 除数绝对值
//   x_sign_r / y_sign_r : 被除数 / 除数的符号位
//   zero_r  : 除数为零标志
//   shift   : 64 位移位寄存器（高 32 位余数、低 32 位商）
//   cnt     : 迭代计数（0~31 共 32 拍）
reg [1:0]  state;
reg [31:0] x_r;        
reg [31:0] divisor;    
reg        x_sign_r;
reg        y_sign_r;
reg        zero_r;    
reg [63:0] shift;      
reg [5:0]  cnt;

// 符号与绝对值处理：signed 时取符号位，按“取反加一”求绝对值参与无符号运算
wire        x_s = div_signed & x[31];
wire        y_s = div_signed & y[31];
wire [31:0] x_abs = ({32{x_s}} ^ x) + {31'b0, x_s};
wire [31:0] y_abs = ({32{y_s}} ^ y) + {31'b0, y_s};

// 一次移位迭代：shift 左移一位试除，用高 32 位与除数比较决定是否减；
// 商的当前位（够减为 1，否则为 0）补到最低位
wire [63:0] sh        = {shift[62:0], 1'b0};
wire        ge        = (sh[63:32] >= divisor);
wire [31:0] rem_sub   = sh[63:32] - divisor;
wire [63:0] shift_nxt = ge ? {rem_sub, sh[31:1], 1'b1}
                           : {sh[63:32], sh[31:1], 1'b0};

// 时序逻辑：同步复位清零；S_IDLE 检测启动，S_RUN 逐步迭代 32 拍后写回商与余数
always @(posedge div_clk) begin
    if (!resetn) begin
        state    <= S_IDLE;
        complete <= 1'b0;
        s        <= 32'b0;
        r        <= 32'b0;
        x_r      <= 32'b0;
        divisor  <= 32'b0;
        x_sign_r <= 1'b0;
        y_sign_r <= 1'b0;
        zero_r   <= 1'b0;
        shift    <= 64'b0;
        cnt      <= 6'b0;
    end
    else begin
        case (state)
            S_IDLE: begin
                complete <= 1'b0;
                if (div) begin
                    // 锁存操作数：绝对值参与迭代，同时记录符号与除零标志
                    x_r      <= x;
                    divisor  <= y_abs;
                    x_sign_r <= x_s;
                    y_sign_r <= y_s;
                    zero_r   <= (y_abs == 32'b0);
                    shift    <= {32'b0, x_abs};
                    cnt      <= 6'b0;
                    state    <= S_RUN;
                end
            end
            S_RUN: begin
                if (cnt == 6'd31) begin      // 迭代 32 拍完成
                    if (zero_r) begin        // 除零：商全 1，余数取被除数
                        s <= 32'hffffffff;
                        r <= x_r;
                    end
                    else begin
                        // 商的符号由两操作数符号异或决定，为负则“取反加一”还原
                        s <= (x_sign_r ^ y_sign_r)
                             ? (~shift_nxt[31:0]  + 32'b1) : shift_nxt[31:0];
                        // 余数符号同被除数，为负则“取反加一”还原
                        r <= x_sign_r
                             ? (~shift_nxt[63:32] + 32'b1) : shift_nxt[63:32];
                    end
                    complete <= 1'b1;        // 拉高完成信号，供 EX 取用结果
                    state    <= S_IDLE;
                end
                else begin
                    shift <= shift_nxt;      // 继续移位迭代
                    cnt   <= cnt + 6'b1;
                end
            end
            default: state <= S_IDLE;
        endcase
    end
end

endmodule