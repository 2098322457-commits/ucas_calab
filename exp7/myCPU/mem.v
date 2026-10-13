module mem(
    input wire clk,
    input wire reset,

    input wire [103:0] ex_to_mem_data,
    input wire ex_to_mem_valid,
    output wire ex_to_mem_ready,

    output wire [69:0] mem_to_wb_data,
    output wire mem_to_wb_valid,
    input wire mem_to_wb_ready,

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
reg        ex_to_mem_ready_r;
reg        mem_to_wb_valid_r;

assign{
pc,  //32,pc
rkd_value, //32
res_from_mem,  //1
gr_we,     //1
mem_we,    //1
dest,      //5
alu_result //32
} = ex_to_mem_data_r;

always @(posedge clk)begin
    if(reset)begin
        ex_to_mem_data_r <= 104'b0;
    end
    else begin
        if(ex_to_mem_valid && ex_to_mem_ready)begin
            ex_to_mem_data_r <= ex_to_mem_data;
        end
    end
end

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

always @(posedge clk)begin
    if(reset)begin
        mem_to_wb_valid_r <= 1'b0;
    end
    else begin
        if(ex_to_mem_valid && ex_to_mem_ready)begin
            mem_to_wb_valid_r <= 1'b1;
        end
        else if(mem_to_wb_valid && mem_to_wb_ready)begin
            mem_to_wb_valid_r <= 1'b0;
        end
    end
end

assign ex_to_mem_ready = ex_to_mem_ready_r;
assign mem_to_wb_valid = mem_to_wb_valid_r;

wire [31:0] mem_result;
wire [31:0] final_result;

assign data_sram_en    = ex_to_mem_valid && ex_to_mem_ready;
assign data_sram_we    = {4{ex_to_mem_data[37] && ex_to_mem_valid && ex_to_mem_ready}};
assign data_sram_addr  = ex_to_mem_data[31:0];
assign data_sram_wdata = ex_to_mem_data[71:40];

assign mem_result   = data_sram_rdata;
assign final_result = res_from_mem ? mem_result : alu_result;

assign mem_to_wb_data = {
                        pc, //32
                        gr_we, //1
                        dest, //5
                        final_result //32
                        };

endmodule
