module ex(
    input wire  clk,
    input wire reset,

    input wire [147:0] id_to_ex_data,
    input wire id_to_ex_valid,
    output wire id_to_ex_ready,


    output wire [103:0] ex_to_mem_data,
    output wire ex_to_mem_valid,
    input wire ex_to_mem_ready
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
reg id_to_ex_ready_r;
reg ex_to_mem_valid_r;

always @(posedge clk)begin
    if(reset)begin
        id_to_ex_data_r <= 147'b0;
    end
    else begin
        if(id_to_ex_valid && id_to_ex_ready)begin
            id_to_ex_data_r <= id_to_ex_data;
        end
    end
end

always @(posedge clk)begin
    if(reset)begin
        id_to_ex_ready_r <= 1'b1;
    end
    else begin
        if((id_to_ex_valid && id_to_ex_ready && ~ex_to_mem_ready) ||        //有输入但是不能输出，接下来阻止一次输�?
            (~id_to_ex_ready && ~ex_to_mem_ready) )begin             //此时禁止输入（有正在工作的指令），且不能输出，继续阻止输�?
            id_to_ex_ready_r <= 1'b0;
        end
        else begin
            id_to_ex_ready_r <= 1'b1;
        end
    end
end

always @(posedge clk)begin
    if(reset)begin
        ex_to_mem_valid_r <= 1'b0;
    end
    else begin
        if(id_to_ex_valid && id_to_ex_ready)begin
            ex_to_mem_valid_r <= 1'b1;
        end
        else if(ex_to_mem_valid && ex_to_mem_ready)begin
            ex_to_mem_valid_r <= 1'b0;
        end
    end
end

assign id_to_ex_ready = id_to_ex_ready_r;
assign ex_to_mem_valid = ex_to_mem_valid_r;

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
} = id_to_ex_data_r;

alu u_alu(
    .alu_op     (alu_op    ),
    .alu_src1   (alu_src1  ),
    .alu_src2   (alu_src2  ),
    .alu_result (alu_result)
    );

assign ex_to_mem_data = {
                        pc,  //32,pc
                        rkd_value, //32
                        res_from_mem,  //1
                        gr_we,     //1
                        mem_we,    //1
                        dest,      //5
                        alu_result //32
                        };

endmodule