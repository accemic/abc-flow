module alu_smoke;
    logic [7:0] a;
    logic [7:0] b;
    logic [7:0] y;

    alu_core dut(
        .a(a),
        .b(b),
        .y(y)
    );
endmodule
