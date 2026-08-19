// BitMoD FP4-E2M1 decoder with negative-zero remapping.
//
// decoded_o is signed Q4.1: real_weight = decoded_o * 2^-1.
// special_sel_i order follows the released quantizer search order:
//   00:+5, 01:-5, 10:+8, 11:-8.
module bitmod4_decoder (
  input  logic [32'd3:32'd0]        code_i,
  input  logic [32'd1:32'd0]        special_sel_i,
  output logic signed [32'd5:32'd0] decoded_o
);

  always_comb begin
    case (code_i)
      4'h0: decoded_o =  6'sd0;
      4'h1: decoded_o =  6'sd1;
      4'h2: decoded_o =  6'sd2;
      4'h3: decoded_o =  6'sd3;
      4'h4: decoded_o =  6'sd4;
      4'h5: decoded_o =  6'sd6;
      4'h6: decoded_o =  6'sd8;
      4'h7: decoded_o =  6'sd12;
      4'h8: begin
        case (special_sel_i)
          2'b00: decoded_o =  6'sd10;
          2'b01: decoded_o = -6'sd10;
          2'b10: decoded_o =  6'sd16;
          2'b11: decoded_o = -6'sd16;
          default: decoded_o = 6'sd0;
        endcase
      end
      4'h9: decoded_o = -6'sd1;
      4'ha: decoded_o = -6'sd2;
      4'hb: decoded_o = -6'sd3;
      4'hc: decoded_o = -6'sd4;
      4'hd: decoded_o = -6'sd6;
      4'he: decoded_o = -6'sd8;
      4'hf: decoded_o = -6'sd12;
      default: decoded_o = 6'sd0;
    endcase
  end

endmodule
