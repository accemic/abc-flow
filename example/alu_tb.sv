module alu_tb();

    reg [7:0] A, B;
    reg [2:0] op;
    wire [7:0] result;

    // Instantiate the ALU
    alu_top uut (
        .A(A),
        .B(B),
        .op(op),
        .result(result)
    );

    // Stimulus process
    initial begin
        // Test ADD operation
        A = 8'h1A;
        B = 8'h0F;
        op = 3'b000;
        #10;

        // Test SUB operation
        A = 8'h23;
        B = 8'h12;
        op = 3'b001;
        #10;

        // Test AND operation
        A = 8'hF0;
        B = 8'hA3;
        op = 3'b010;
        #10;

        // Test OR operation
        A = 8'h56;
        B = 8'h3C;
        op = 3'b011;
        #10;

        // Test XOR operation
        A = 8'h9A;
        B = 8'hC7;
        op = 3'b100;
        #10;

        // Test NAND operation
        A = 8'hE3;
        B = 8'hB1;
        op = 3'b101;
        #10;

        // Test NOR operation
        A = 8'h7F;
        B = 8'h1E;
        op = 3'b110;
        #10;

        // Test XNOR operation
        A = 8'h52;
        B = 8'hA8;
        op = 3'b111;
        #10;

        // Finish the simulation
        $finish;
    end

    // Monitor process
    always @(posedge op) begin
        $display("A: %h, B: %h, op: %b, result: %h", A, B, op, result);
    end

endmodule
