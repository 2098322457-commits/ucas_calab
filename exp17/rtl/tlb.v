`timescale 1ns / 1ps

module tlb
#(
    parameter TLBNUM = 16
)
(
    input  wire                      clk,

    // search port 0 (for fetch)
    input  wire [              18:0] s0_vppn,
    input  wire                      s0_va_bit12,
    input  wire [               9:0] s0_asid,
    output wire                      s0_found,
    output wire [$clog2(TLBNUM)-1:0] s0_index,
    output wire [              19:0] s0_ppn,
    output wire [               5:0] s0_ps,
    output wire [               1:0] s0_plv,
    output wire [               1:0] s0_mat,
    output wire                      s0_d,
    output wire                      s0_v,

    // search port 1 (for load/store)
    input  wire [              18:0] s1_vppn,
    input  wire                      s1_va_bit12,
    input  wire [               9:0] s1_asid,
    output wire                      s1_found,
    output wire [$clog2(TLBNUM)-1:0] s1_index,
    output wire [              19:0] s1_ppn,
    output wire [               5:0] s1_ps,
    output wire [               1:0] s1_plv,
    output wire [               1:0] s1_mat,
    output wire                      s1_d,
    output wire                      s1_v,

    // invtlb opcode
    input  wire                      invtlb_valid,
    input  wire [               4:0] invtlb_op,

    // write port
    input  wire                      we,
    input  wire [$clog2(TLBNUM)-1:0] w_index,
    input  wire                      w_e,
    input  wire [              18:0] w_vppn,
    input  wire [               5:0] w_ps,
    input  wire [               9:0] w_asid,
    input  wire                      w_g,
    input  wire [              19:0] w_ppn0,
    input  wire [               1:0] w_plv0,
    input  wire [               1:0] w_mat0,
    input  wire                      w_d0,
    input  wire                      w_v0,
    input  wire [              19:0] w_ppn1,
    input  wire [               1:0] w_plv1,
    input  wire [               1:0] w_mat1,
    input  wire                      w_d1,
    input  wire                      w_v1,

    // read port
    input  wire [$clog2(TLBNUM)-1:0] r_index,
    output wire                      r_e,
    output wire [              18:0] r_vppn,
    output wire [               5:0] r_ps,
    output wire [               9:0] r_asid,
    output wire                      r_g,
    output wire [              19:0] r_ppn0,
    output wire [               1:0] r_plv0,
    output wire [               1:0] r_mat0,
    output wire                      r_d0,
    output wire                      r_v0,
    output wire [              19:0] r_ppn1,
    output wire [               1:0] r_plv1,
    output wire [               1:0] r_mat1,
    output wire                      r_d1,
    output wire                      r_v1
);

reg [TLBNUM - 1:0] tlb_e;
reg [TLBNUM - 1:0] tlb_ps4MB;

reg [18:0]  tlb_vppn    [TLBNUM-1 : 0];
reg [9:0]   tlb_asid    [TLBNUM-1 : 0];
reg         tlb_g       [TLBNUM-1 : 0];
reg [19:0]  tlb_ppn0    [TLBNUM-1 : 0];
reg [1:0]   tlb_plv0    [TLBNUM-1 : 0];
reg [1:0]   tlb_mat0    [TLBNUM-1 : 0];
reg         tlb_d0      [TLBNUM-1 : 0];
reg         tlb_v0      [TLBNUM-1 : 0];
reg [19:0]  tlb_ppn1    [TLBNUM-1 : 0];
reg [1:0]   tlb_plv1    [TLBNUM-1 : 0];
reg [1:0]   tlb_mat1    [TLBNUM-1 : 0];
reg         tlb_d1      [TLBNUM-1 : 0];
reg         tlb_v1      [TLBNUM-1 : 0];

wire [TLBNUM-1:0] match0;
wire [TLBNUM-1:0] match1;
wire [TLBNUM-1:0] inv_match;

genvar i;
generate
    for(i = 0; i<TLBNUM; i = i+1)begin : gen_match
    //命中项
    assign match0[i] = (s0_vppn[18:10] == tlb_vppn[i][18:10])       //同一虚页范围
                       && (tlb_ps4MB[i] || (s0_vppn[9:0] == tlb_vppn[i][9:0]))  //大页则继续，小页则比较低9位
                       && ((s0_asid == tlb_asid[i]) || tlb_g[i]);   //进程号同，或者是全局页
    assign match1[i] = (s1_vppn[18:10] == tlb_vppn[i][18:10])
                       && (tlb_ps4MB[i] || (s1_vppn[9:0] == tlb_vppn[i][9:0]))
                       && ((s1_asid == tlb_asid[i]) || tlb_g[i]);

    wire cond1 = ~tlb_g[i];     //非全局
    wire cond2 = tlb_g[i];      //全局
    wire cond3 = (s1_asid == tlb_asid[i]);      //同进程
    wire cond4 = (s1_vppn[18:10] == tlb_vppn[i][18:10])     //同虚页
                 && (tlb_ps4MB[i] || (s1_vppn[9:0] == tlb_vppn[i][9:0]));
    //清空项
    assign inv_match[i] = (invtlb_op == 5'd0) ? (cond1 || cond2) :      //全部清除
                          (invtlb_op == 5'd1) ? (cond1 || cond2) :      //全部清除
                          (invtlb_op == 5'd4) ? (cond1 && cond3) :      //清除本进程
                          (invtlb_op == 5'd5) ? (cond1 && cond3 && cond4) :     //清除本进程某虚页
                          (invtlb_op == 5'd6) ? ((cond2 || cond3) && cond4) :   //清除能够翻译到的所有项
                          1'b0;
    end 
endgenerate 

integer j;
always @(posedge clk) begin
    if(we)begin
        tlb_e       [w_index] <= w_e;
        tlb_ps4MB   [w_index] <= (w_ps == 6'h15);
        tlb_vppn    [w_index] <= w_vppn;
        tlb_asid    [w_index] <= w_asid;
        tlb_g       [w_index] <= w_g;
        tlb_ppn0    [w_index] <= w_ppn0;
        tlb_plv0    [w_index] <= w_plv0;
        tlb_mat0    [w_index] <= w_mat0;
        tlb_d0      [w_index] <= w_d0;
        tlb_v0      [w_index] <= w_v0;
        tlb_ppn1    [w_index] <= w_ppn1;
        tlb_plv1    [w_index] <= w_plv1;
        tlb_mat1    [w_index] <= w_mat1;
        tlb_d1      [w_index] <= w_d1;
        tlb_v1      [w_index] <= w_v1;
    end
    else if(invtlb_valid)begin
        for(j = 0; j < TLBNUM; j = j + 1)begin
            if(inv_match[j])begin
                tlb_e[j] <= 1'b0;
            end
        end
    end
end

reg [$clog2(TLBNUM) - 1:0] s0_index_t;
reg [19:0] s0_ppn_t;
reg [5:0] s0_ps_t;
reg [1:0] s0_plv_t;
reg [1:0] s0_mat_t;
reg s0_d_t;
reg s0_v_t;

reg [$clog2(TLBNUM) - 1:0] s1_index_t;
reg [19:0] s1_ppn_t;
reg [5:0] s1_ps_t;
reg [1:0] s1_plv_t;
reg [1:0] s1_mat_t;
reg s1_d_t;
reg s1_v_t;

integer k;
always @(*) begin
    s0_index_t = {($clog2(TLBNUM)){1'b0}};
    s0_ppn_t = 20'd0;
    s0_ps_t = 6'd0;
    s0_plv_t = 2'd0;
    s0_mat_t = 2'd0;
    s0_d_t = 1'd0;
    s0_v_t = 1'd0;
    for(k = TLBNUM - 1; k >= 0; k = k - 1)begin
        if(match0[k])begin
            s0_index_t = k;
            s0_ppn_t = tlb_ps4MB[k] ? {tlb_ppn0[k][19:9], s0_vppn[8:0]}
                                    : (s0_va_bit12 ? tlb_ppn1[k] : tlb_ppn0[k]);
            s0_ps_t = tlb_ps4MB[k] ? 6'h15 : 6'h0c;
            s0_plv_t = s0_va_bit12 ? tlb_plv1[k] : tlb_plv0[k];
            s0_mat_t = s0_va_bit12 ? tlb_mat1[k] : tlb_mat0[k];
            s0_d_t = s0_va_bit12 ? tlb_d1[k] : tlb_d0[k];
            s0_v_t = s0_va_bit12 ? tlb_v1[k] : tlb_v0[k];
        end
    end
end

always @(*) begin
    s1_index_t = {($clog2(TLBNUM)){1'b0}};
    s1_ppn_t = 20'd0;
    s1_ps_t = 6'd0;
    s1_plv_t = 2'd0;
    s1_mat_t = 2'd0;
    s1_d_t = 1'd0;
    s1_v_t = 1'd0;
    for(k = TLBNUM - 1; k >= 0; k = k - 1)begin
        if(match1[k])begin
            s1_index_t = k;
            s1_ppn_t = tlb_ps4MB[k] ? {tlb_ppn0[k][19:9], s1_vppn[8:0]}
                                    : (s1_va_bit12 ? tlb_ppn1[k] : tlb_ppn0[k]);
            s1_ps_t = tlb_ps4MB[k] ? 6'h15 : 6'h0c;
            s1_plv_t = s1_va_bit12 ? tlb_plv1[k] : tlb_plv0[k];
            s1_mat_t = s1_va_bit12 ? tlb_mat1[k] : tlb_mat0[k];
            s1_d_t = s1_va_bit12 ? tlb_d1[k] : tlb_d0[k];
            s1_v_t = s1_va_bit12 ? tlb_v1[k] : tlb_v0[k];
        end
    end
end

assign s0_found = | match0;
assign s0_index = s0_index_t;
assign s0_ppn = s0_ppn_t;
assign s0_ps = s0_ps_t;
assign s0_plv = s0_plv_t;
assign s0_mat = s0_mat_t;
assign s0_d = s0_d_t;
assign s0_v = s0_v_t;

assign s1_found = | match1;
assign s1_index = s1_index_t;
assign s1_ppn = s1_ppn_t;
assign s1_ps = s1_ps_t;
assign s1_plv = s1_plv_t;
assign s1_mat = s1_mat_t;
assign s1_d = s1_d_t;
assign s1_v = s1_v_t;

assign r_e = tlb_e[r_index];
assign r_vppn = tlb_vppn[r_index];
assign r_ps = tlb_ps4MB[r_index] ? 6'h15 : 6'h0c;
assign r_asid = tlb_asid[r_index];
assign r_g = tlb_g [r_index];

assign r_ppn0 = tlb_ppn0[r_index];
assign r_plv0 = tlb_plv0[r_index];
assign r_mat0 = tlb_mat0[r_index];
assign r_d0 = tlb_d0[r_index];
assign r_v0 = tlb_v0[r_index];

assign r_ppn1 = tlb_ppn1[r_index];
assign r_plv1 = tlb_plv1[r_index];
assign r_mat1 = tlb_mat1[r_index];
assign r_d1 = tlb_d1[r_index];
assign r_v1 = tlb_v1[r_index];

endmodule
