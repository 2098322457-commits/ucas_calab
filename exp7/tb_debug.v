`timescale 1ns/1ps
module tb_debug;
reg clk, resetn;
wire        inst_sram_en;
wire [3:0]  inst_sram_we;
wire [31:0] inst_sram_addr;
wire [31:0] inst_sram_wdata;
reg  [31:0] inst_sram_rdata;
wire        data_sram_en;
wire [3:0]  data_sram_we;
wire [31:0] data_sram_addr;
wire [31:0] data_sram_wdata;
reg  [31:0] data_sram_rdata;
wire [31:0] debug_wb_pc;
wire [3:0]  debug_wb_rf_we;
wire [4:0]  debug_wb_rf_wnum;
wire [31:0] debug_wb_rf_wdata;

initial begin
    clk = 0; resetn = 0;
    #53; resetn = 1;
    #20000;
    $display("TIMEOUT");
    $finish;
end
always #5 clk = ~clk;

mycpu_top dut(
    .clk(clk), .resetn(resetn),
    .inst_sram_en(inst_sram_en), .inst_sram_we(inst_sram_we),
    .inst_sram_addr(inst_sram_addr), .inst_sram_wdata(inst_sram_wdata),
    .inst_sram_rdata(inst_sram_rdata),
    .data_sram_en(data_sram_en), .data_sram_we(data_sram_we),
    .data_sram_addr(data_sram_addr), .data_sram_wdata(data_sram_wdata),
    .data_sram_rdata(data_sram_rdata),
    .debug_wb_pc(debug_wb_pc), .debug_wb_rf_we(debug_wb_rf_we),
    .debug_wb_rf_wnum(debug_wb_rf_wnum), .debug_wb_rf_wdata(debug_wb_rf_wdata)
);

// instruction ram: sync read, word addressed by addr[19:2]
reg [31:0] iram [0:262143];
initial $readmemb("func/obj/inst_ram.mif", iram);
always @(posedge clk) begin
    if (inst_sram_en)
        inst_sram_rdata <= iram[inst_sram_addr[19:2]];
end

// data ram: sync read, byte writes
reg [31:0] dram [0:65535];
initial $readmemb("func/obj/data_ram.mif", dram);
integer i;
always @(posedge clk) begin
    if (data_sram_en) begin
        for (i = 0; i < 4; i = i + 1) begin
            if (data_sram_we[i])
                dram[data_sram_addr[17:2]][i*8+:8] <= data_sram_wdata[i*8+:8];
        end
        data_sram_rdata <= dram[data_sram_addr[17:2]];
    end
end

// pipeline handshake monitor
always @(posedge clk) begin
    #1;
    if (resetn)
        $display("[%t] pc=%h inst_r=%h | IF>id v=%b r=%b | ID>EX v=%b r=%b | EX>MEM v=%b r=%b | MEM>WB v=%b r=%b | wb_pc=%h we=%b wnum=%d wdata=%h",
            $time,
            dut.if_u.pc, dut.if_u.pc_r,
            dut.if_u.if_to_id_valid, dut.id_u.if_to_id_ready,
            dut.id_u.id_to_ex_valid, dut.ex_u.id_to_ex_ready,
            dut.ex_u.ex_to_mem_valid, dut.mem_u.ex_to_mem_ready,
            dut.mem_u.mem_to_wb_valid, dut.wb_u.mem_to_wb_ready,
            debug_wb_pc, debug_wb_rf_we, debug_wb_rf_wnum, debug_wb_rf_wdata);
end
endmodule
