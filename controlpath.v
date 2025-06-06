`timescale 1ns / 1ps

/*The control unit has 3 primary responsibilities:
    1. Send control signals to the execution pipeline after receiving the decoded opcode and operands. Also send stall signals if a hazard occurs
    2. Send read to memory in case of a cache miss and stall the pipeline until data is available
    3. Send update signals to the Branch History Table and Branch Target Buffer according to branch execution and prediction success/failure
    
    
    
1. The control signals for instruction execution are:
    1. ALUSrc
    2. ALUOp
    3. PCSrcCont
    4. MemWrite
    5. MemRead
    6. MemToReg
    6. RegWrite
    7. IsStall
    
    ALUSrc tells the ALU to read from either rs2 register or immediate depending on whether the instruction is R type or not.
    
    ALUOp sends an opcode to the ALU based on which the ALU decides which operation is to be performed, ADD,AND,SUB etc.
    
    PCSrcCont is the signal sent if the instruction is recognized to be a branch. The pipeline is informed that if the branch is unconditional, or if the 
    condition evaluates to true, then the PC should be loaded with the branch target and not PC+4.
    
    MemWrite is the control signal for store instruction, so that ALU output is sent to data memory during MEM stage.
    
    MemRead is for load instructions, to read from data memory during MEM stage.
    
    MemToReg is the signal which indicates whether the ALU output is to be written to the register file, or the loaded word from load instruction.
    Without this signal, instead of the loaded data, the address calculated by the ALU for memory read would get written to the register file, as both
    ALU output and memory contents are forwarded to the WB pipeline stage and chosen from according to the instruction type.
    
    RegWrite signal indicates that the instruction should be allowed to write to the register file during the WB stage, as S and B instructions do not write.
    
    IsStall is the signal that tells the pipeline to stall in case of a data or control hazard, or in case of a cache miss. Although data forwarding units are
    present, there can still be a need for stalls in case of a load-use hazard. 
    As the branch decoding and execution in this core occurs during ID stage, conditional branches may also need stalls until data forwarding units
    are able to provide the operands.
    
    
    
2. The control unit receives the cache miss signal from cache during the IF stage, and immediately tell the pipeline to stall, simultaneously sending a read
   request to the instruction memory.
   When the cache receives the requested data, it sends a cache_updated signal to the control unit. In response to this, the control unit commands the datapath
   to send another read request to the cache, and ends the pipeline stall after the instruction has been successfully fetched.
   

3. If a branch instruction is executed for the first, wthe control unit sends the updation signals to the BHT and BTB to register the branch.
   Updation signals are also sent when a branch prediction gets tested and known to be correct/incorrect.
   

*/



module controlpath(inout wire start,
                   input wire clk,
                   input wire cache_hit,
                   input wire cache_update_occured,
                   input wire [6:0] opcode,
                   input wire [2:0] funct3,
                   input wire [6:0] funct7,
                   input wire [4:0] if_id_rdloc,
                   input wire load_stall,
                   input wire [1:0] br_stall,
                   input wire [1:0] br_stall_prev,
                   input wire branch_flag,
                   input wire prediction_false_flag,
                   input wire IF_ID_branch_pred,
                   input wire ID_PCSrc,
                   output reg imem_read,
                   output reg icache_read_again,
                   output reg [4:0] ALUOp,
                   output reg ALUSrc,
                   output reg PCSrcCont,
                   output reg MemWrite,
                   output reg MemRead,
                   output reg MemToReg,
                   output reg RegWrite,
                   output reg IsStall,
                   output reg btb_update,
                   output reg bht_update,
                   output reg bht_update_dir
                   );
                   
localparam [6:0] OP_REG = 7'b0110011,OP_LW = 7'b0000011,OP_SW = 7'b0100011,OP_B = 7'b1100011,OP_JAL = 7'b1101111;

reg send_imem_read_counter;
reg [1:0] icache_read_again_counter;
reg icache_read_again_parity;

/* Below logic is to send a read request pulse that lasts one cycle, to the instruction memory when cache miss occurs.
   send_imem_read_counter is a 1 bit counter, reset whenever cache miss occurs. After the read request has been sent, the counter gets set and
   the read signal is pulled down.
*/
always @(posedge clk)
    if (send_imem_read_counter == 1'b0)
        begin
            send_imem_read_counter <= 1'b1;
            imem_read <= 1'b0;
        end        

always @(*)
    if (!cache_hit)
        begin
            imem_read = 1'b1;
            send_imem_read_counter = 1'b0;
        end

/* When the cache gets updated after a miss, the processor is still stalling. If the stall is ended immediately, the PC will have changed when the read request 
   is sent, as PC updation and cache read requests are in parallel. This way, the first instruction of every block gets lost.
   To prevent this, it is neccesary that the read request is sent by datapath to cache before the stall has ended, and the below logic does this with
   send_read_again and send_read_again_counter.
*/

always @(*)
    if (start)
        icache_read_again_counter = 2'b00;

always @(posedge clk)
    if (icache_read_again_counter < 2'b10 && icache_read_again_parity)
            icache_read_again_counter <= icache_read_again_counter + 1;

always @(*)
    begin
        if (cache_update_occured)
            begin
                icache_read_again_counter = 2'b00;
                icache_read_again = 1'b1;
                icache_read_again_parity = 1'b1;
            end
        if (icache_read_again_counter == 2'b10)
            begin
                IsStall = 1'b0;
                icache_read_again_parity = 1'b0;
                icache_read_again = 1'b0;
                icache_read_again_counter = 2'b00;
            end
    end

/* Control signals initialized to 0 at startup, and are updated with each instruction decode.
   Stall logic is also included here, with stalls needed by load-use hazards and when conditional branches wait for their operands.
   
   Also, when a branch instruction is executed or a prediction is false and pipeline needs to roll back, one extra instruction gets fetched while the PC
   gets updated. The branch_flag and prediction_false_flag signals are sent by datapath when this happens, so that the control signals can be deasserted
   and the instruction does not execute.
*/

always @(*)
    begin
        if (start)
            begin
                IsStall = 1'b0;
                RegWrite = 1'b0;
                MemWrite = 1'b0;
                MemRead = 1'b0;
                MemToReg = 1'b0;
                ALUSrc = 1'b0;
                PCSrcCont = 1'b0;
                ALUOp = 5'b11111;
            end
        if (!load_stall && !br_stall[0] && !br_stall_prev[1] && cache_hit)
            begin
                IsStall = 1'b0;
                if (branch_flag || prediction_false_flag)
                    begin
                        RegWrite = 1'b0;
                        MemWrite = 1'b0;
                        MemRead = 1'b0;
                        MemToReg = 1'b0;
                        ALUSrc = 1'b0;
                        PCSrcCont = 1'b0;
                        ALUOp = 5'b11111;
                    end
                else
                    begin
                        case (opcode)
                            OP_REG: begin
                                        ALUSrc = 1'b0;
                                        PCSrcCont = 1'b0;
                                        MemWrite = 1'b0;
                                        MemRead = 1'b0;
                                        MemToReg = 1'b0;
                                        RegWrite = 1'b1;
                                        case (funct7)
                                            7'b0000000: case (funct3)
                                                            3'b000: ALUOp = 5'b00000;
                                                            3'b110: ALUOp = 5'b00011;
                                                            3'b111: ALUOp = 5'b00010;
                                                        endcase
                                            7'b0100000: case (funct3)
                                                            3'b000: ALUOp = 3'b00001;
                                                        endcase
                                        endcase
                                    end
                             OP_LW: begin
                                        ALUSrc = 1'b1;
                                        PCSrcCont = 1'b0;
                                        MemWrite = 1'b0;
                                        MemRead = 1'b1;
                                        MemToReg = 1'b1;
                                        RegWrite = 1'b1;
                                        case (funct3)
                                            3'b010: ALUOp = 5'b00000;
                                        endcase
                                    end
                             OP_SW: begin
                                        ALUSrc = 1'b1;
                                        PCSrcCont = 1'b0;
                                        MemWrite = 1'b1;
                                        MemRead = 1'b0;
                                        MemToReg = 1'b0;
                                        RegWrite = 1'b0;
                                        case(funct3)
                                            3'b010: ALUOp = 5'b00000;
                                        endcase
                                    end
                             OP_B: begin
                                        ALUSrc = 1'b0;
                                        PCSrcCont = 1'b1;
                                        MemWrite = 1'b0;
                                        MemRead = 1'b0;
                                        MemToReg = 1'b0;
                                        RegWrite = 1'b0;
                                        case (funct3)
                                            3'b000: ALUOp = 5'b00100;
                                        endcase
                                    end
                            OP_JAL: begin
                                        ALUSrc = 1'b0;
                                        PCSrcCont = 1'b1;
                                        MemWrite = 1'b0;
                                        MemRead = 1'b0;
                                        MemToReg = 1'b0;
                                        RegWrite = (if_id_rdloc == 5'b00000) ? 1'b0 : 1'b1;
                                        ALUOp = 5'b00000;
                                    end
                           default: begin
                                        RegWrite = 1'b0;
                                        MemWrite = 1'b0;
                                        MemRead = 1'b0;
                                        MemToReg = 1'b0;
                                        ALUSrc = 1'b0;
                                        PCSrcCont = 1'b0;
                                        ALUOp = 5'b11111;
                                    end
                        endcase
                    end 
            end
        if (load_stall || br_stall || br_stall_prev[1] || (!cache_hit && (icache_read_again_counter != 2'b10)))
            begin
                RegWrite = 1'b0;
                MemWrite = 1'b0;
                MemRead = 1'b0;
                MemToReg = 1'b0;
                ALUSrc = 1'b0;
                PCSrcCont = 1'b0;
                ALUOp = 5'b11111;
                IsStall = 1'b1;
            end        
    end

/* Providing update signals to BHT and BTB according to branch execution and branch status.
   IF_ID_branch_pred tells if a prediction has occured due to this instruction, and ID_PCSrc tests the prediction.
   Updation signals are sent according to the combinations of these two.
   
   (IF_ID_branch_pred && ID_PCSrc) -> A prediction had been made and has been verified
   (IF_ID_branch_pred && !ID_PCSrc) -> A prediction had been made and was incorrect
   (!IF_ID_branch_pred && ID_PCSrc) -> A new branch instruction has been encountered
   (!IF_ID_branch_pred && !ID_PCSrc) -> No branches or predictions
*/
always @(posedge clk)
    begin
        if (IsStall)
            begin
                bht_update <= 1'b0;
                btb_update <= 1'b0;
            end
        if (!IsStall)
            begin
                if (IF_ID_branch_pred && ID_PCSrc)
                    begin
                        bht_update <= 1'b1;
                        btb_update <= 1'b1;
                        bht_update_dir <= 1'b1;
                    end
                if (IF_ID_branch_pred && !ID_PCSrc)
                    begin
                        bht_update <= 1'b1;
                        btb_update <= 1'b0;
                        bht_update_dir <= 1'b0;
                    end
                if (!IF_ID_branch_pred && ID_PCSrc)
                    begin
                        bht_update <= 1'b1;
                        btb_update <= 1'b1;
                        bht_update_dir <= 1'b1;
                    end
                if (!IF_ID_branch_pred && !ID_PCSrc)
                    begin
                        bht_update <= 1'b0;
                        btb_update <= 1'b0;
                        bht_update_dir <= 1'b0;
                    end 
            end   
               
    end
                   
endmodule
