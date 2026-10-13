module mem(
    input wire clk,
    input wire reset,

    input wire [103:0] ex_to_mem_data,
    input wire ex_to_mem_valid,
    output wire ex_to_mem_ready,

    output wire [69:0] mem_to_wb_data,
    output wire mem_to_wb_valid,
    input wire mem_to_wb_ready,
    output wire [6:0] mem_hazard,

    output wire data_sram_en,
    output wire [3:0] data_sram_we,
    output wire [31:0] data_sram_addr,
    output wire [31:0] data_sram_wdata,
    input  wire [31:0] data_sram_rdata
);

wire [31:0] pc;
wire [31:0] rkd_value;
wire res_from_mem;
wire gr_we;
wire mem_we;
wire [4:0] dest;
wire [31:0] alu_result;

reg [103:0] ex_to_mem_data_r;
reg        mem_to_wb_valid_r;
reg [69:0] mem_to_wb_data_r;
reg        load_pending;        //等待读内存数据
reg [37:0] load_wb_info;

assign{
pc,  //32,pc
rkd_value, //32
res_from_mem,  //1
gr_we,     //1
mem_we,    //1
dest,      //5
alu_result //32
} = ex_to_mem_data;
/*
always @(posedge clk)begin
    if(reset)begin
        ex_to_mem_ready_r <= 1'b1;
    end
    else begin
        if((ex_to_mem_valid && ex_to_mem_ready && ~mem_to_wb_ready) ||        //有输入但是不能输出，接下来阻止一次输�?
            (~ex_to_mem_ready && ~mem_to_wb_ready) )begin             //此时禁止输入（有正在工作的指令），且不能输出，继续阻止输�?
            ex_to_mem_ready_r <= 1'b0;
        end
        else begin
            ex_to_mem_ready_r <= 1'b1;
        end
    end
end
*/
assign ex_to_mem_ready = (~mem_to_wb_valid || mem_to_wb_ready) && ~load_pending;    //阻塞是不识别读指令，自然不能ready
                                                               //&& ~res_from_mem    //若加上这一条，识别到读指令是拒绝上一级发送，这条指令一直停在mem，就会一直阻塞。因此要刷新本条指令，并且在时序中存储相关信息

always @(posedge clk)begin
    if(reset)begin
        mem_to_wb_valid_r <= 1'b0;
        mem_to_wb_data_r <= 70'b0;
        load_pending <= 1'b0;
        load_wb_info <= 38'b0;
    end
    else begin
        if(load_pending)begin       //接受指令前，判断是否在读内存，若是则带上寄存的信息位发送
            mem_to_wb_valid_r <= 1'b1;
            mem_to_wb_data_r <= {load_wb_info, data_sram_rdata};
            load_pending <= 1'b0;
        end
        else if(ex_to_mem_valid && ex_to_mem_ready)begin    //接受到指令，判断要不要读内存阻塞，并寄存当前指令的信息位
            if(res_from_mem)begin
                mem_to_wb_valid_r <= 1'b0;
                load_pending <= 1'b1;
                load_wb_info <= {pc, gr_we, dest};      //因为不能识别res阻塞，所以需要存储当前指令信息
            end
            else begin      //若没有读内存，按照alu直接发送
                mem_to_wb_valid_r <= 1'b1;
                mem_to_wb_data_r <= {
                                    pc, //32
                                    gr_we, //1
                                    dest, //5
                                    alu_result //32
                                    };
            end
        end
        else if(mem_to_wb_valid && mem_to_wb_ready)begin
            mem_to_wb_valid_r <= 1'b0;
        end
    end
end

assign mem_to_wb_valid = mem_to_wb_valid_r;
assign mem_to_wb_data  = mem_to_wb_data_r;
assign mem_hazard = load_pending ? {1'b1, load_wb_info[5:0]} :
                    {mem_to_wb_valid_r, mem_to_wb_data_r[37:32]};

wire [31:0] mem_result;
wire [31:0] final_result;

assign data_sram_en    = ex_to_mem_valid && ex_to_mem_ready;
assign data_sram_we    = {4{ex_to_mem_data[37] && ex_to_mem_valid && ex_to_mem_ready}};
assign data_sram_addr  = ex_to_mem_data[31:0];
assign data_sram_wdata = ex_to_mem_data[71:40];
/*
assign mem_result   = data_sram_rdata;
assign final_result = res_from_mem ? mem_result : alu_result;       //在单周期时一点一个节拍内取到内存值，所以可以直接选择
*/
endmodule
