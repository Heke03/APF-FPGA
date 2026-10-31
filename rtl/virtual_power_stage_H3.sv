`timescale 1ns/1ps
// H3: virtual power stage - the grid, the diode-bridge load and the APF inverter
// computed inside the FPGA, so apf_core can run in closed loop on the DE2-115 with
// nothing connected. Bit-exact with matlab/blocks/vps_block_H3.m (fixed point);
// the equations, number formats and constants are specified in matlab/vps_params_H3.m.
//
// One plant step every SUB clocks (10 at 50 MHz = 200 ns), forward Euler:
//   grid voltages LSB 2^-12 V, DC-link state 2^-24 V, currents 2^-24 A,
//   grid angle 40-bit (one turn = 2^40), cosine table + linear interpolation.
// Every product is rounded back as (x + 2^(s-1)) >>> s, like rsh() in the model.
//
// Step schedule (ph = clock within the step):
//   0  latch gates/contactor/load step, advance the angle
//   1  leg voltages; cosine table read for phase a
//   2  phase a cosine; neutral voltage, current drawn from the DC link; read b
//   3  phase b cosine, a voltage; DC-link terms; read c
//   4  phase c cosine, b voltage          5  c voltage
//   6  inductor voltages, diode-bridge DC voltage
//   7  inverter currents, DC link, load DC current
//   8  phase c inverter current, load phase currents
//   9  publish outputs and ADC codes, step_done
module virtual_power_stage_H3 #(
    parameter integer SUB       = 10,
    parameter         COS_FILE  = "cos_table_4096.hex",
    // integer constants, from vps_params_H3(true)
    parameter logic [39:0] DTH   = 40'd10995116,       // angle step: 50 Hz
    parameter logic [39:0] TH120 = 40'd366503875925,   // 120 degrees
    parameter integer KVM   = 409600,                  // 100 V peak
    parameter integer K3    = 21845,                   // 1/3
    parameter integer KRF   = 6554,                    // Rf = 0.1 ohm
    parameter integer KL    = 17896,                   // H / Lf, Lf = 3 mH
    parameter integer KC    = 3355,                    // H / Cdc, 1000 uF
    parameter integer KLEAK = 43,                      // H / (Rleak Cdc), 20 kohm
    parameter integer KD    = 2684,                    // H / Ldc, 20 mH
    parameter integer KT    = 1049,                    // H / tau, 0.2 ms
    parameter integer R1    = 33,                      // load before the step, ohm
    parameter integer R2    = 22,                      // load after the step, ohm
    parameter logic [41:0] VDC0 = 42'd2905813811       // 173.2 V precharge
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [2:0]  gate_hi,          // bit 0: phase a (as apf_core)
    input  logic [2:0]  gate_lo,
    input  logic        contactor,        // inverter connected (apf_core switching)
    input  logic        load_step,        // 0: R1, 1: R2
    output logic        step_done,        // high for one clock after each published step
    output logic signed [23:0] vg [0:2],     // grid phase voltages, 2^-12 V
    output logic signed [31:0] il [0:2],     // load currents, grid -> load, 2^-24 A
    output logic signed [31:0] i_inv [0:2],  // inverter currents, inverter -> grid, 2^-24 A
    output logic signed [41:0] vdc,          // DC link, 2^-24 V
    output logic [11:0] code [0:6],          // ADC codes of this state, apf_core format, no noise
    output logic [31:0] shoot_count          // steps x legs with both switches on (gates while disconnected)
);
    // ---------------- state ----------------
    logic [3:0]  ph;
    logic [39:0] th;
    logic signed [41:0] vdcq;
    logic signed [31:0] ifq [0:2];
    logic signed [31:0] ilq [0:2];
    logic signed [31:0] idq;
    logic [2:0]  g_hi, g_lo;
    logic        g_con, g_step;
    logic signed [23:0] vgq [0:2];

    // ---------------- cosine table (dual-port, synchronous read) ----------------
    // The file holds sign-extended 20-bit words (five hex digits); 18 bits are used.
    logic [19:0] rom [0:4095];
    initial $readmemh(COS_FILE, rom);
    logic [11:0] ra0, ra1, frac_q;
    logic [19:0] rq0, rq1;
    always_ff @(posedge clk) begin
        rq0 <= rom[ra0];
        rq1 <= rom[ra1];
    end

    logic [39:0] angle;
    always_comb begin
        case (ph)
            4'd2:    angle = th - TH120;
            4'd3:    angle = th - (TH120 << 1);
            default: angle = th;
        endcase
        ra0 = angle[39:28];
        ra1 = angle[39:28] + 12'd1;           // wraps at 4096
    end

    // linear interpolation of the word read in the previous clock
    logic signed [17:0] c0, c1;
    logic signed [18:0] cdiff;
    logic signed [31:0] cprod;
    logic signed [18:0] cosv;
    always_comb begin
        c0 = rq0[17:0];
        c1 = rq1[17:0];
        cdiff = 19'(c1) - 19'(c0);
        cprod = 32'(cdiff) * $signed({20'd0, frac_q});
        cosv = 19'(c0) + 19'((cprod + 32'sd2048) >>> 12);
    end
    logic signed [18:0] cos_r;
    logic signed [39:0] vprod;
    logic signed [23:0] vnew;
    always_comb begin
        vprod = 40'(cos_r) * 40'(KVM);
        vnew = 24'((vprod + 40'sd32768) >>> 16);
    end

    // ---------------- inverter legs (start-of-step state) ----------------
    logic signed [29:0] vdc_v;
    logic signed [29:0] vx [0:2];
    always_comb begin
        vdc_v = 30'((vdcq + 42'sd2048) >>> 12);
        for (int p = 0; p < 3; p++) begin
            if (g_hi[p])      vx[p] = vdc_v;
            else if (g_lo[p]) vx[p] = '0;
            else if (ifq[p] > 0) vx[p] = '0;   // dead time: a diode carries the current
            else              vx[p] = vdc_v;
        end
    end

    // registered at ph 1; everything below uses the registered leg voltages
    logic signed [29:0] vx_r [0:2];
    logic signed [31:0] vsum;
    logic signed [48:0] vnprod;
    logic signed [33:0] top;
    always_comb begin
        top = '0;
        for (int p = 0; p < 3; p++)
            if (vx_r[p] > 0) top = top + 34'(ifq[p]);   // current drawn from the DC link
        vsum = 32'(vx_r[0]) + 32'(vx_r[1]) + 32'(vx_r[2]);
        vnprod = 49'(vsum) * 49'(K3);
    end

    // DC-link terms (ph 3), applied at ph 7
    logic signed [33:0] top_r;
    logic signed [46:0] cprod_dc;
    logic signed [48:0] leak;
    logic signed [41:0] kc_r, leak_r;
    always_comb begin
        cprod_dc = 47'(top_r) * 47'(KC);
        leak = 49'(vdcq) * 49'(KLEAK);
    end

    logic signed [31:0] vn_r;
    logic signed [31:0] dv_r [0:1];
    logic signed [31:0] dvd_r;
    logic [1:0] imax_r, imin_r;

    // inductor voltages and the diode bridge (vg complete at ph 6)
    logic signed [45:0] rfprod [0:1];
    logic signed [31:0] dv [0:1];
    logic [1:0] imax, imin;
    logic signed [38:0] rprod;
    logic signed [31:0] dvd;
    always_comb begin
        for (int p = 0; p < 2; p++) begin
            rfprod[p] = 46'(ifq[p]) * 46'(KRF);
            dv[p] = 32'(vx_r[p]) - vn_r - 32'(vgq[p]) - 32'((rfprod[p] + (46'sd1 <<< 27)) >>> 28);
        end
        imax = 2'd0; imin = 2'd0;
        for (int p = 1; p < 3; p++) begin      // first index wins on a tie
            if (vgq[p] > vgq[imax]) imax = 2'(p);
            if (vgq[p] < vgq[imin]) imin = 2'(p);
        end
        rprod = 39'(idq) * 39'(g_step ? R2 : R1);
        dvd = 32'(vgq[imax]) - 32'(vgq[imin]) - 32'((rprod + 39'sd2048) >>> 12);
    end

    // ph 7 updates
    logic signed [47:0] lprod [0:1];
    logic signed [44:0] dprod;
    logic signed [32:0] idq_next;
    always_comb begin
        for (int p = 0; p < 2; p++) lprod[p] = 48'(dv_r[p]) * 48'(KL);
        dprod = 45'(dvd_r) * 45'(KD);
        idq_next = 33'(idq) + 33'((dprod + 45'sd32768) >>> 16);
    end

    // ph 8: load phase currents follow +-idq on the max/min phases
    logic signed [32:0] tdiff [0:2];
    logic signed [44:0] tprod [0:2];
    always_comb begin
        for (int p = 0; p < 3; p++) begin
            if (p == imax_r)      tdiff[p] = 33'(idq) - 33'(ilq[p]);
            else if (p == imin_r) tdiff[p] = 33'sd0 - 33'(idq) - 33'(ilq[p]);
            else                  tdiff[p] = 33'sd0 - 33'(ilq[p]);
            tprod[p] = 45'(tdiff[p]) * 45'(KT);
        end
    end

    // ADC codes of the published state (apf_core scaling)
    function automatic logic [11:0] clamp12(input logic signed [47:0] x);
        if (x < 0) return 12'd0;
        if (x > 4095) return 12'd4095;
        return 12'(x);
    endfunction
    function automatic logic [11:0] code_i(input logic signed [31:0] i);   // 100 counts/A at 2048
        logic signed [47:0] prod;
        prod = 48'(i) * 48'sd100;
        return clamp12(((prod + (48'sd1 <<< 23)) >>> 24) + 48'sd2048);
    endfunction
    function automatic logic [11:0] code_v(input logic signed [23:0] v);   // 16 counts/V at 2048
        return clamp12(((48'(v) + 48'sd128) >>> 8) + 48'sd2048);
    endfunction
    function automatic logic [11:0] code_dc(input logic signed [41:0] v);  // 10 counts/V
        logic signed [47:0] prod;
        prod = 48'(v) * 48'sd10;
        return clamp12((prod + (48'sd1 <<< 23)) >>> 24);
    endfunction

    // ---------------- sequencing ----------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ph <= '0; th <= '0; vdcq <= $signed(VDC0); idq <= '0;
            for (int p = 0; p < 3; p++) begin ifq[p] <= '0; ilq[p] <= '0; vgq[p] <= '0; end
            g_hi <= '0; g_lo <= '0; g_con <= 1'b0; g_step <= 1'b0;
            frac_q <= '0; cos_r <= '0; vn_r <= '0;
            for (int p = 0; p < 3; p++) vx_r[p] <= '0;
            top_r <= '0; kc_r <= '0; leak_r <= '0;
            dv_r[0] <= '0; dv_r[1] <= '0; dvd_r <= '0; imax_r <= '0; imin_r <= '0;
            step_done <= 1'b0; shoot_count <= '0;
            vdc <= $signed(VDC0);
            for (int p = 0; p < 3; p++) begin vg[p] <= '0; il[p] <= '0; i_inv[p] <= '0; end
            for (int ch = 0; ch < 7; ch++) code[ch] <= 12'd2048;
            code[6] <= code_dc($signed(VDC0));
        end else begin
            step_done <= 1'b0;
            ph <= (ph == 4'(SUB - 1)) ? 4'd0 : ph + 4'd1;
            frac_q <= angle[27:16];
            case (ph)
                4'd0: begin
                    g_hi <= gate_hi; g_lo <= gate_lo; g_con <= contactor; g_step <= load_step;
                    th <= th + DTH;
                end
                4'd1: for (int p = 0; p < 3; p++) vx_r[p] <= vx[p];
                4'd2: begin
                    cos_r <= cosv;                         // phase a
                    vn_r <= 32'((vnprod + 49'sd32768) >>> 16);
                    top_r <= top;
                end
                4'd3: begin
                    cos_r <= cosv; vgq[0] <= vnew;
                    kc_r <= 42'((cprod_dc + (47'sd1 <<< 23)) >>> 24);
                    leak_r <= 42'((leak + (49'sd1 <<< 31)) >>> 32);
                end
                4'd4: begin cos_r <= cosv; vgq[1] <= vnew; end
                4'd5: vgq[2] <= vnew;
                4'd6: begin
                    dv_r[0] <= dv[0]; dv_r[1] <= dv[1];
                    dvd_r <= dvd; imax_r <= imax; imin_r <= imin;
                end
                4'd7: begin
                    if (g_con) begin
                        for (int p = 0; p < 2; p++)
                            ifq[p] <= ifq[p] + 32'((lprod[p] + 48'sd32768) >>> 16);
                        vdcq <= vdcq - kc_r - leak_r;
                        shoot_count <= shoot_count + 32'(g_hi[0] & g_lo[0]) + 32'(g_hi[1] & g_lo[1])
                                                   + 32'(g_hi[2] & g_lo[2]);
                    end else begin
                        for (int p = 0; p < 3; p++) ifq[p] <= '0;
                        vdcq <= vdcq - leak_r;
                        shoot_count <= shoot_count + 32'(g_hi[0]) + 32'(g_hi[1]) + 32'(g_hi[2])
                                                   + 32'(g_lo[0]) + 32'(g_lo[1]) + 32'(g_lo[2]);
                    end
                    idq <= (idq_next < 0) ? 32'sd0 : 32'(idq_next);
                end
                4'd8: begin
                    if (g_con) ifq[2] <= -(ifq[0] + ifq[1]);
                    for (int p = 0; p < 3; p++)
                        ilq[p] <= ilq[p] + 32'((tprod[p] + (45'sd1 <<< 19)) >>> 20);
                end
                4'd9: begin
                    for (int p = 0; p < 3; p++) begin
                        vg[p] <= vgq[p]; il[p] <= ilq[p]; i_inv[p] <= ifq[p];
                    end
                    vdc <= vdcq;
                    code[0] <= code_v(vgq[0]);  code[1] <= code_v(vgq[1]);
                    code[2] <= code_i(ilq[0]);  code[3] <= code_i(ilq[1]);
                    code[4] <= code_i(ifq[0]);  code[5] <= code_i(ifq[1]);
                    code[6] <= code_dc(vdcq);
                    step_done <= 1'b1;
                end
                default: ;
            endcase
        end
    end
endmodule
