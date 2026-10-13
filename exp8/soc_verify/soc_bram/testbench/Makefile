.PHONY: clean
IVERILOG_DIR = project/loongson.sim/sim_1/behav/iverilog
iverilog : $(IVERILOG_DIR)/gettrace
	cd $(IVERILOG_DIR) && vvp ./gettrace

$(IVERILOG_DIR)/gettrace:
	mkdir -p $(IVERILOG_DIR) && iverilog -g2005-sv -Wall -I../../../myCPU/ -o $(IVERILOG_DIR)/gettrace ../../../pipeline.v ../../../myCPU/tools.v ../../../myCPU/regfile.v ../../../myCPU/alu.v ../rtl/*.v ../rtl/*/*.v sync_ram.v mycpu_tb.v

clean : 
	rm -rf ./project 
