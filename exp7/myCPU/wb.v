module wb(
    input wire clk,
    input wire reset,
    
    input wire [69:0] mem_to_wb_data,
    input wire mem_to_wb_valid,
    output wire mem_to_wb_ready,

    output wire [31:0] debug_wb_pc,
    output wire [ 3:0] debug_wb_rf_we,
    output wire [ 4:0] debug_wb_rf_wnum,
    output wire [31:0] debug_wb_rf_wdata,

    output wire [37:0] wb_rf_id_data
);

reg [69:0] mem_to_wb_data_r;
reg mem_to_wb_ready_r;

always @(posedge clk)begin
    if(reset)begin
        mem_to_wb_data_r <= 70'b0;
    end
    else begin
        if(mem_to_wb_valid && mem_to_wb_ready)begin
            mem_to_wb_data_r <= mem_to_wb_data;
        end
    end
end

always @(posedge clk)begin
    if(reset)begin
        mem_to_wb_ready_r <= 1'b1;
    end
end

reg valid;

always @(posedge clk)begin
    if(reset)begin
        valid <= 1'b0;
    end
    else begin
        if(mem_to_wb_valid && mem_to_wb_ready)begin
            valid <= 1'b1;
        end
        else begin
            valid <= 1'b0;
        end
    end
end

assign mem_to_wb_ready = mem_to_wb_ready_r;

wire [31:0] pc;
wire gr_we;
wire [4:0] dest;
wire rf_we;
wire [4:0] rf_waddr;
wire [31:0] rf_wdata;
wire [31:0] final_result;

assign {
        pc,
        gr_we,
        dest,
        final_result
        } = mem_to_wb_data_r;



assign rf_we    = gr_we && valid;
assign rf_waddr = dest;
assign rf_wdata = final_result;

assign wb_rf_id_data = {
                        rf_we,
                        rf_waddr,
                        rf_wdata
                        };

assign debug_wb_pc       = pc;
assign debug_wb_rf_we    = {4{rf_we}};
assign debug_wb_rf_wnum  = dest;
assign debug_wb_rf_wdata = final_result;


endmodule