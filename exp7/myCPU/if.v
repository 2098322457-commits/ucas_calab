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

wire [31:0] seq_pc;
wire [31:0] nextpc;
wire br_taken;
wire [31:0] br_target;

assign br_taken = id_to_if_data[32:32];
assign br_target = id_to_if_data[31:0];
assign seq_pc       = pc + 3'h4;
assign nextpc       = br_taken ? br_target : seq_pc;

always @(posedge clk) begin
    if (reset) begin
        pc <= 32'h1bfffffc;          //trick: to make nextpc be 0x1c000000 during reset 
        pc_r <= 32'b0;
        if_to_id_valid_r <= 1'b0;
    end
    else begin
        pc <= nextpc;
        pc_r <= pc;
        //br_taken时作废正要送入ID的错误路径指令；pc为复位trick地址时取回的是垃圾，也不注入
        if_to_id_valid_r <= ~br_taken && (pc != 32'h1bfffffc);
    end
end

assign inst_sram_en    = 1'b1;
assign inst_sram_we    = 1'b0;
assign inst_sram_addr  = pc;
assign inst_sram_wdata = 32'b0;

assign if_to_id_valid  = if_to_id_valid_r;
assign if_to_id_data = {
                        pc_r,
                        inst_sram_rdata
                        };
endmodule