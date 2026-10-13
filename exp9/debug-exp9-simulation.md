# exp9 仿真调试记录

状态：[CLOSED]
会话：exp9-simulation

## 初始假设

1. 仿真工程或文件列表配置错误，导致模块未编译或顶层模块不正确。
2. `mycpu.v` 存在语法、端口或位宽错误，仿真在编译阶段失败。
3. CPU 的复位、状态机或时序控制存在错误，仿真可以启动但执行异常。
4. BRAM/指令存储器的读写时序或地址映射与 CPU 不匹配。
5. testbench、测试程序或期望结果与设计接口不一致。

## 复现方式

```
cd soc_verify\soc_bram\testbench
iverilog -Wall -I ../../../myCPU/ -o project\loongson.sim\sim_1\behav\iverilog\gettrace ^
  ../../../myCPU/alu.v ../../../myCPU/mycpu.v ../../../myCPU/regfile.v ../../../myCPU/tools.v ^
  ../rtl/soc_lite_top.v ../rtl/BRIDGE/bridge_1x2.v ../rtl/CONFREG/confreg.v sync_ram.v mycpu_tb.v
cd project\loongson.sim\sim_1\behav\iverilog && vvp ./gettrace
```

## 证据

### 1) 首次失败的轨迹比对点（修复前）

```
[   2517 ns] Error!!!
    reference: PC = 0x1c027f84, wb_rf_wnum = 0x0d, wb_rf_wdata = 0x00001000
    mycpu    : PC = 0x1c027f84, wb_rf_wnum = 0x0d, wb_rf_wdata = 0x00001002
```

对应程序（`func/obj/test.s`，n1_lu12i_w_test）：

```
1c027f74: 0280000d  addi.w $r13,$r0,0     <== 生产者：应写 r13 = 0
1c027f78: 14000004  lu12i.w $r4,0
1c027f7c: 1400000c  lu12i.w $r12,0
1c027f80: 00103484  add.w  $r4,$r4,$r13
1c027f84: 001039ad  add.w  $r13,$r13,$r14  <== 消费者：读 r13，应为 0，实读到 0x2
```

消费者与生产者相隔 4 条指令，读到的 r13 是旧值 0x2，得到 `0x2 + 0x1000 = 0x1002`。

### 2) 运行期插桩（修复前，`mycpu_tb.v` 临时打印失配窗口）

```
[DBG] t=2476 ns
  IF->ID : id_pc=1c027f84 inst=001039ad stall=0 if_rdy=1
  ID oper: raddr1=13 rdata1=00000002 raddr2=14 rdata2=00001000
           | mem_rf1=0 mem_rf2=0 wb_rf1=0 wb_rf2=0 | rj_v=00000002 rkd_v=00001000 | rf13=00000002
  WB     : pc=1c027f74 rf_we=1 waddr=13 wdata=00000000 valid=1
```

即：生产者已在 wb 单元（`rf_we=1, waddr=13, wdata=0`），消费者同时在 ID 段读 r13，
但三条前递路径全部未命中（`mem_rf1/2=0`、`wb_rf1/2=0`），`rj_v` 取到寄存器堆旧值 0x2。

### 3) 时序分析（根因）

- `id` 的 WB 段前递源是 `mem_hazard`，它在 mem 单元的 `mem_to_wb_data_r` 被写入的**那一拍**有效（生产者处于「MEM→WB 寄存器」）。
- 真正写寄存器堆的是 `wb` 单元，它在 `wb_data` 上**又寄存了一拍**并用 `valid` 打拍，因此 `rf_we` 比 `mem_hazard` 的 valid 窗口**晚一拍**，寄存器堆的写生效再晚一拍。
- 结果：在「`mem_hazard` 的 valid 已撤销」而「寄存器堆写入尚未生效」之间存在**一拍空档**。
  - 相隔 3 条指令（消费者在 ID 时生产者在 MEM→WB 寄存器）→ `mem_hazard` 命中，正常。
  - 相隔 4 条指令（消费者在 ID 时生产者已在 wb 单元的寄存器）→ 空档，命中失败，读到旧值。
- 对照 exp8：exp8 的 `wb` 单元同样多寄存一拍，但 exp8 的 `id` 在 WB 段冲突时**阻塞一拍**（`rf_we && rf_waddr`）来补偿；exp9 改为「前递」后没有覆盖 wb 单元这一拍，于是留下空档。

## 结论

错误位置：`exp9/exp9/myCPU/mycpu.v` 的 `id` 模块 —— **缺少对 WB 段（wb 单元真正写回那一拍）的前递**，只覆盖了 EX/MEM 段和 MEM→WB 寄存器段。

最小修复（`id` 模块内新增一条前递路径，源为 wb 单元输出 `wb_rf_id_data`，优先级最低）：

```verilog
assign wb_id_rf_we   = wb_rf_id_data[37];
assign wb_id_rf_dest = wb_rf_id_data[36:32];
assign wb_id_rf_data = wb_rf_id_data[31:0];

assign wb_id_rf1 = (wb_id_rf_we && (wb_id_rf_dest != 5'b0) && (rf_raddr1 == wb_id_rf_dest));
assign wb_id_rf2 = (wb_id_rf_we && (wb_id_rf_dest != 5'b0) && (rf_raddr2 == wb_id_rf_dest));

assign rj_value  = mem_rf1 ? mem_rf_data : wb_rf1 ? wb_rf_data : wb_id_rf1 ? wb_id_rf_data : rf_rdata1;
assign rkd_value = mem_rf2 ? mem_rf_data : wb_rf2 ? wb_rf_data : wb_id_rf2 ? wb_id_rf_data : rf_rdata2;
```

修复后同一窗口的运行期证据：

```
[DBG] t=2476 ns
  IF->ID : id_pc=1c027f84 inst=001039ad stall=0 if_rdy=1
  ID oper: raddr1=13 rdata1=00000002 ... wb_rf1=0 wb_rf2=0 | rj_v=00000000 rkd_v=00001000
  WB     : pc=1c027f74 rf_we=1 waddr=13 wdata=00000000 valid=1
```

`rdata1` 仍是旧的 0x2（证明寄存器堆写入未生效），但 `rj_v` 已由 wb 段前递得到正确的 0x0，
下一拍 `1c027f84` 在 EX 段结果 `res=00001000`，与 golden trace 一致。

### 验证结果

`vvp ./gettrace` 全程跑完，20 个功能测试点全部通过：

```
----[ 878085 ns] Number 8'd20 Functional Test Point PASS!!!
Test end!
----PASS!!!
```

## 附注

- `mycpu_tb.v` 第 1 行原为 `` `/*--- ``（行首多一个反引号），iverilog 编译报 syntax error，已改为 `/*`。
- 该试验台的 `$dumpvars` 会生成约 8 GB 的 `dump.vcd`（`testbench/` 目录下），调试期间曾临时关闭；现已恢复原样。
