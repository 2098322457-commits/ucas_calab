module hazard(
    input wire clk,
    input wire reset,

    input wire raddr1,
    input wire raddr2,
    input wire dest,
    input wire gr_we,

    output wire stall
);

reg stall_r;

always @(posedge clk)begin
    if(reset)begin
            stall_r <= 1'b0;
    end
    else begin
        if((raddr1 == dest) || (raddr2 == dest))begin
            stall_r <= (dest != 5'b0) && (gr_we == 1'b1);
        end
        else begin
            stall_r <= 1'b0;
        end
    end
end

assign stall = stall_r;

endmodule