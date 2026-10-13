module if_stage(
    input  wire        clk,
    input  wire        reset,

    output wire inst_sram_en,
    output wire [3:0]  inst_sram_we,
    output wire [31:0] inst_sram_addr,
    output wire [31:0] inst_sram_wdata,
    input  wire [31:0] inst_sram_rdata,

    output wire [63:0] if_to_id_data,
    output wire if_to_id_valid,
    input if_to_id_ready,

    input wire [32:0] id_to_if_data
);

reg  [31:0] pc;
reg  [31:0] pc_r;
reg         if_to_id_valid_r;
reg  [63:0] if_to_id_data_r;

wire [31:0] seq_pc;
wire [31:0] nextpc;
wire br_taken;
reg br_taken_r;     //ram每个节拍取出的指令是上一节拍，所以每次分支时会取两次错误指令，需阻塞两个节拍
wire [31:0] br_target;

assign br_taken = id_to_if_data[32:32];
assign br_target = id_to_if_data[31:0];
assign seq_pc       = pc + 3'h4;
assign nextpc       = br_taken ? br_target : seq_pc;

always @(posedge clk) begin
    if (reset) begin
        pc <= 32'h1bfffffc;          //trick: to make nextpc be 0x1c000000 during reset 
        pc_r <= 32'h1bfffffc;       //寄存一拍pc的值
        if_to_id_valid_r <= 1'b0;
        if_to_id_data_r <= 64'b0;
        br_taken_r <= 1'b0;
    end
    else if (if_to_id_ready || br_taken) begin      //考虑阻塞，只有非阻塞和跳转的时候发生传递
        pc <= nextpc;
        pc_r <= pc;
        br_taken_r <= br_taken;
        //br_taken时作废正要送入ID的错误路径指令；pc为复位trick地址时取回的是垃圾，也不注入
        if_to_id_valid_r <= ~br_taken && ~br_taken_r && (pc_r != 32'h1bfffffc);
        if_to_id_data_r <= {
                    pc_r,       //每次ram取出的指令是上一节拍的，于是发包要发上一节拍的pc
                    inst_sram_rdata
                    };
    end
end

assign if_to_id_data = if_to_id_data_r;

assign inst_sram_en    = if_to_id_ready || br_taken;        //考虑阻塞的情况，只有在id可接受新指令，或者发生跳转时
                                                            //（有可能id在阻塞中，但阻塞对应的指令是跳转的，直接跳转但是不发送），取新指令
assign inst_sram_we    = 1'b0;
assign inst_sram_addr  = pc;
assign inst_sram_wdata = 32'b0;

assign if_to_id_valid  = if_to_id_valid_r;
endmodule