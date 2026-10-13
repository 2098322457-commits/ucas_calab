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
reg ex_to_mem_valid_r;
reg [103:0] ex_to_mem_data_r;

/*
always @(posedge clk)begin
    if(reset)begin
        ex_to_mem_valid_r <= 1'b0;
        ex_to_mem_data_r <= 104'b0;
    end
    else begin
        if(id_to_ex_valid && id_to_ex_ready)begin       //这里只要有接受就一定刷新当前流水级，未考虑下一级阻塞
            ex_to_mem_valid_r <= 1'b1;
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
        else if(ex_to_mem_valid && ex_to_mem_ready)begin
            ex_to_mem_valid_r <= 1'b0;
        end
    end
end
*/

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
assign ex_to_mem_data  = ex_to_mem_data_r;

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
} = id_to_ex_data;

alu u_alu(
    .alu_op     (alu_op    ),
    .alu_src1   (alu_src1  ),
    .alu_src2   (alu_src2  ),
    .alu_result (alu_result)
    );

endmodule