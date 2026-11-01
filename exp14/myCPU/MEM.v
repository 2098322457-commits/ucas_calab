// MEM 阶段：访存（数据 SRAM 接口）与 MEM-WB 流水寄存器。
// 位于五级流水线第四级，接收 EX-MEM 流水寄存器，输出 MEM-WB 流水寄存器；
// 支持按字节/半字/字访问：依据地址低位生成写选通 store_we，并把写数据复制到对应字节道。
// exp14：data SRAM 改为类 SRAM 握手接口，req 保持到 addr_ok，data_ok 时写回。
module mem_stage(
    input  wire        clk,
    input  wire        reset,
    input  wire        hold,       // IF 级取指未完成，冻结 MEM-WB
    // EX-MEM pipeline bus（来自 EX 阶段的流水寄存器）
    input  wire        ex_mem_valid,
    input  wire [31:0] ex_mem_pc,
    input  wire [31:0] ex_mem_alu_result,
    input  wire [31:0] ex_mem_store_data,
    input  wire        ex_mem_mem_we,
    input  wire        ex_mem_res_from_mem,
    input  wire        ex_mem_gr_we,
    input  wire [ 4:0] ex_mem_dest,
    input  wire [ 1:0] ex_mem_mem_size,
    input  wire        ex_mem_mem_unsigned,
    input  wire        ex_mem_seq,   // EX-MEM 指令序号
    // data sram interface（类 SRAM 握手）
    output reg         data_sram_req,
    output reg         data_sram_wr,
    output reg  [ 1:0] data_sram_size,
    output reg  [ 3:0] data_sram_wstrb,
    output reg  [31:0] data_sram_addr,
    output reg  [31:0] data_sram_wdata,
    input  wire        data_sram_addr_ok,
    input  wire        data_sram_data_ok,
    input  wire [31:0] data_sram_rdata,
    output wire        mem_busy,
    // MEM-WB pipeline bus
    output reg         mem_wb_valid,
    output reg  [31:0] mem_wb_pc,
    output reg  [31:0] mem_wb_alu_result,
    output reg  [31:0] mem_wb_mem_data,
    output reg         mem_wb_res_from_mem,
    output reg         mem_wb_gr_we,
    output reg  [ 4:0] mem_wb_dest,
    output reg  [ 1:0] mem_wb_mem_size,
    output reg         mem_wb_mem_unsigned
);

// 访存握手状态：IDLE 空闲，ISSUE 发出请求，ADDR 等地址握手，DATA 等数据握手
localparam S_IDLE  = 2'd0;
localparam S_ISSUE = 2'd1;
localparam S_ADDR  = 2'd2;
localparam S_DATA  = 2'd3;

reg [1:0]  state;        // 当前握手状态
reg        mem_seq_seen; // 已消费的 EX-MEM 序号
reg [31:0] r_pc;         // 锁存的 PC
reg [31:0] r_alu_result; // 锁存的 ALU 结果（访存地址）
reg [31:0] r_store_data; // 锁存的写数据
reg        r_mem_we;     // 锁存的写使能
reg        r_res_from_mem; // 锁存的 load 标志
reg        r_gr_we;      // 锁存的写回使能
reg [ 4:0] r_dest;       // 锁存的目的寄存器
reg [ 1:0] r_mem_size;   // 锁存的访存宽度
reg        r_mem_unsigned; // 锁存的符号扩展标志

// 访存指令一出现就冻结上游，保证 MEM 只锁存/消费一次；完成后由 seq 防止重复
wire mem_start = (state == S_IDLE) && ex_mem_valid &&
                 (ex_mem_mem_we || ex_mem_res_from_mem) &&
                 (ex_mem_seq != mem_seq_seen) && !hold;

// 请求未完成时冻结上游；完成后再多保持一拍，等 MEM-WB 的 load 数据可前递
wire mem_busy_base = mem_start || (state == S_ADDR) || (state == S_DATA);
reg  mem_busy_r;
always @(posedge clk) begin
    if (reset) mem_busy_r <= 1'b0;
    else       mem_busy_r <= mem_busy_base;
end
assign mem_busy = mem_busy_base || mem_busy_r;

// 在 MEM 阶段按本次请求的地址低 2 位做字节/半字扩展，避免 WB 阶段地址与数据配对错误
function [31:0] load_extend;
    input [31:0] data;
    input [1:0]  size;
    input        is_unsigned;
    input [1:0]  addr_low;
    reg [7:0]  byte_r;
    reg [15:0] half_r;
    begin
        if (size == 2'b00) begin
            byte_r      = data[8*addr_low +: 8];
            load_extend = is_unsigned ? {24'b0, byte_r}
                                   : {{24{byte_r[7]}}, byte_r};
        end
        else if (size == 2'b01) begin
            half_r      = addr_low[1] ? data[31:16] : data[15:0];
            load_extend = is_unsigned ? {16'b0, half_r}
                                   : {{16{half_r[15]}}, half_r};
        end
        else begin
            load_extend = data;
        end
    end
endfunction

wire [1:0] mem_size = ex_mem_mem_size;   // 本次访存宽度
wire [1:0] addr_low = ex_mem_alu_result[1:0];  // 地址低 2 位，决定落在哪个字节道

// 按宽度与地址低位生成字节写选通：字节写只选 1 道；半字写选低半或高半 2 道；字写全 4 道
wire [3:0] store_we = (mem_size == 2'b00) ? (4'b0001 << addr_low) :
                      (mem_size == 2'b01) ? (addr_low[1] ? 4'b1100 : 4'b0011) :
                                            4'b1111;

// 写数据按宽度复制到各字节道：字节写复制低 8 位、半字写复制低 16 位，字写原样
wire [31:0] store_data = (mem_size == 2'b00) ? {4{ex_mem_store_data[ 7: 0]}} :
                         (mem_size == 2'b01) ? {2{ex_mem_store_data[15: 0]}} :
                                               ex_mem_store_data;

// 时序寄存器更新：握手状态、MEM-WB 流水寄存器
always @(posedge clk) begin
    if (reset) begin
        state               <= S_IDLE;
        mem_seq_seen        <= 1'b0;
        data_sram_req       <= 1'b0;
        data_sram_wr        <= 1'b0;
        data_sram_size      <= 2'b0;
        data_sram_wstrb     <= 4'b0;
        data_sram_addr      <= 32'b0;
        data_sram_wdata     <= 32'b0;
        r_pc                <= 32'b0;
        r_alu_result        <= 32'b0;
        r_store_data        <= 32'b0;
        r_mem_we            <= 1'b0;
        r_res_from_mem      <= 1'b0;
        r_gr_we             <= 1'b0;
        r_dest              <= 5'b0;
        r_mem_size          <= 2'b10;
        r_mem_unsigned      <= 1'b0;
        mem_wb_valid        <= 1'b0;
        mem_wb_pc           <= 32'b0;
        mem_wb_alu_result   <= 32'b0;
        mem_wb_mem_data     <= 32'b0;
        mem_wb_res_from_mem <= 1'b0;
        mem_wb_gr_we        <= 1'b0;
        mem_wb_dest         <= 5'b0;
        mem_wb_mem_size     <= 2'b10;
        mem_wb_mem_unsigned <= 1'b0;
    end
    else if (hold && state == S_IDLE) begin
        // IF 正在取指：MEM 空闲时向 MEM-WB 写空泡，避免同一写回在 WB 重复有效
        data_sram_req       <= 1'b0;
        mem_wb_valid        <= 1'b0;
        mem_wb_pc           <= 32'b0;
        mem_wb_alu_result   <= 32'b0;
        mem_wb_mem_data     <= 32'b0;
        mem_wb_res_from_mem <= 1'b0;
        mem_wb_gr_we        <= 1'b0;
        mem_wb_dest         <= 5'b0;
        mem_wb_mem_size     <= 2'b10;
        mem_wb_mem_unsigned <= 1'b0;
        if (!ex_mem_valid)
            mem_seq_seen <= ex_mem_seq;
    end
    else begin
        case (state)
            S_IDLE: begin
                data_sram_req <= 1'b0;
                if (!ex_mem_valid) begin
                    // 空泡：直接写入 MEM-WB，并记录序号，避免下一拍有效指令误判为已消费
                    mem_seq_seen        <= ex_mem_seq;
                    mem_wb_valid        <= 1'b0;
                    mem_wb_pc           <= 32'b0;
                    mem_wb_alu_result   <= 32'b0;
                    mem_wb_mem_data     <= 32'b0;
                    mem_wb_res_from_mem <= 1'b0;
                    mem_wb_gr_we        <= 1'b0;
                    mem_wb_dest         <= 5'b0;
                    mem_wb_mem_size     <= 2'b10;
                    mem_wb_mem_unsigned <= 1'b0;
                end
                else if (ex_mem_seq == mem_seq_seen) begin
                    // 该 EX-MEM 指令已经消费过（EX 被 hold 住），只输出空泡
                    mem_wb_valid        <= 1'b0;
                    mem_wb_pc           <= 32'b0;
                    mem_wb_alu_result   <= 32'b0;
                    mem_wb_mem_data     <= 32'b0;
                    mem_wb_res_from_mem <= 1'b0;
                    mem_wb_gr_we        <= 1'b0;
                    mem_wb_dest         <= 5'b0;
                    mem_wb_mem_size     <= 2'b10;
                    mem_wb_mem_unsigned <= 1'b0;
                end
                else if (ex_mem_mem_we || ex_mem_res_from_mem) begin
                    // 访存指令：锁存请求信息并发起类 SRAM 请求
                    r_pc           <= ex_mem_pc;
                    r_alu_result   <= ex_mem_alu_result;
                    r_store_data   <= store_data;
                    r_mem_we       <= ex_mem_mem_we;
                    r_res_from_mem <= ex_mem_res_from_mem;
                    r_gr_we        <= ex_mem_gr_we;
                    r_dest         <= ex_mem_dest;
                    r_mem_size     <= ex_mem_mem_size;
                    r_mem_unsigned <= ex_mem_mem_unsigned;
                    data_sram_req       <= 1'b1;
                    data_sram_wr        <= ex_mem_mem_we;
                    data_sram_size      <= ex_mem_mem_size;
                    data_sram_wstrb     <= store_we;
                    data_sram_addr      <= ex_mem_alu_result;
                    data_sram_wdata     <= store_data;
                    mem_seq_seen        <= ex_mem_seq;
                    state               <= S_ISSUE;
                end
                else begin
                    // 非访存指令：直接写入 MEM-WB
                    mem_wb_valid        <= 1'b1;
                    mem_wb_pc           <= ex_mem_pc;
                    mem_wb_alu_result   <= ex_mem_alu_result;
                    mem_wb_mem_data     <= load_extend(data_sram_rdata, r_mem_size, r_mem_unsigned, r_alu_result[1:0]);
                    mem_wb_res_from_mem <= ex_mem_res_from_mem;
                    mem_wb_gr_we        <= ex_mem_gr_we;
                    mem_wb_dest         <= ex_mem_dest;
                    mem_wb_mem_size     <= ex_mem_mem_size;
                    mem_wb_mem_unsigned <= ex_mem_mem_unsigned;
                    mem_seq_seen        <= ex_mem_seq;
                end
            end

            S_ISSUE: begin
                data_sram_req <= 1'b1;
                if (data_sram_addr_ok) begin
                    data_sram_req <= 1'b0;
                    // 地址接收后统一等 data_ok，避免把上一笔请求的 data_ok 当成当前数据
                    state <= S_DATA;
                end
                else begin
                    state <= S_ADDR;
                end
            end

            S_ADDR: begin
                data_sram_req <= 1'b1;
                if (data_sram_addr_ok) begin
                    data_sram_req <= 1'b0;
                    state <= S_DATA;
                end
            end

            S_DATA: begin
                data_sram_req <= 1'b0;
                if (data_sram_data_ok) begin
                    mem_wb_valid        <= 1'b1;
                    mem_wb_pc           <= r_pc;
                    mem_wb_alu_result   <= r_alu_result;
                    mem_wb_mem_data     <= load_extend(data_sram_rdata, r_mem_size, r_mem_unsigned, r_alu_result[1:0]);
                    mem_wb_res_from_mem <= r_res_from_mem;
                    mem_wb_gr_we        <= r_gr_we;
                    mem_wb_dest         <= r_dest;
                    mem_wb_mem_size     <= r_mem_size;
                    mem_wb_mem_unsigned <= r_mem_unsigned;
                    state               <= S_IDLE;
                end
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
