package p3llm_pkg;

  typedef enum logic [32'd1:32'd0] {
    OP_LINEAR = 2'b00,
    OP_QK     = 2'b01,
    OP_PV     = 2'b10
  } p3llm_op_mode_e;

  localparam int unsigned PCU_NUM_PES             = 32'd16;
  localparam int unsigned PE_NUM_LANES            = 32'd4;
  localparam int unsigned PCU_PIPELINE_STAGES     = 32'd4;
  localparam int unsigned PCU_EDGE_LATENCY_CYCLES = 32'd3;

  function automatic logic op_mode_is_valid(
    input logic [32'd1:32'd0] mode
  );
    op_mode_is_valid = (mode == OP_LINEAR) ||
                       (mode == OP_QK) ||
                       (mode == OP_PV);
  endfunction

endpackage
