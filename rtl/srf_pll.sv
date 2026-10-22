// Three-phase synchronous-reference-frame PLL (grid angle estimator).
//
// One voltage frame per sample_valid strobe (nominally 10 kHz). For every frame
// the block projects the phase voltages onto the angle it predicted for that
// sample, normalizes the q-axis error by the voltage magnitude (so the loop
// gain does not depend on grid amplitude or sensor scaling), runs a PI loop,
// advances the 32-bit phase accumulator, and looks up the cosines for the
// NEXT sample. cos_a/b/c therefore always describe the sample that has not
// arrived yet, so a block that captures them on the same strobe as this PLL
// (for example apf_reference) gets the angle of that sample.
//
// Bit-accurate model: model/pll_model.py. About 85 clocks per frame.
//
// Formats: voltages are signed ADC counts (offset removed); cos/sin are Q16
// (+65536 = +1.0); phase_error is sin(angle error) in Q16; theta is a full
// turn per 2^32; freq_word is phase advance per sample (f = word*FS/2^32).
module srf_pll #(
    parameter integer SAMPLE_HZ     = 10000,
    parameter integer F_NOM_HZ      = 50,
    parameter integer F_MIN_HZ      = 45,
    parameter integer F_MAX_HZ      = 55,
    parameter integer KP            = 185,     // phase-word per Q16 error count (20 Hz, zeta 0.707)
    parameter integer KI            = 422,     // per sample, 8 fraction bits
    parameter integer MIN_AMPLITUDE = 400,     // phase amplitude (counts) needed to run the loop
    parameter integer LOCK_ERR      = 2287,    // sin(2 deg) in Q16
    parameter integer UNLOCK_ERR    = 16962,   // sin(15 deg) in Q16
    parameter integer LOCK_SAMPLES  = 400,     // good samples in a row to declare lock
    parameter integer UNLOCK_SAMPLES = 50,     // bad samples in a row to drop lock
    parameter         COS_FILE      = "cos_table_4096.hex"
) (
    input  logic                clk,
    input  logic                rst_n,
    input  logic                sample_valid,
    input  logic                sample_ok,      // measurement healthy for this frame
    input  logic signed [15:0]  v_a,
    input  logic signed [15:0]  v_b,
    input  logic signed [15:0]  v_c,
    output logic                ready,          // idle and waiting for a frame
    output logic                result_valid,   // one-clock pulse when a frame is done
    output logic                overrun,        // one-clock pulse: frame arrived while busy (ignored)
    output logic                angle_valid,    // locked
    output logic                low_amplitude,
    output logic signed [17:0]  phase_error,
    output logic [25:0]         amplitude,      // |V| = 1.5 * phase amplitude * 256
    output logic [31:0]         freq_word,
    output logic [31:0]         theta,
    output logic signed [17:0]  cos_a,
    output logic signed [17:0]  cos_b,
    output logic signed [17:0]  cos_c,
    output logic signed [17:0]  sin_a,
    output logic signed [17:0]  sin_b,
    output logic signed [17:0]  sin_c
);
    localparam logic [63:0] TURN = 64'd1 << 32;
    localparam logic [31:0] NOM_WORD = 32'((TURN * F_NOM_HZ) / SAMPLE_HZ);
    localparam logic [31:0] FREQ_MIN = 32'((TURN * F_MIN_HZ) / SAMPLE_HZ);
    localparam logic [31:0] FREQ_MAX = 32'((TURN * F_MAX_HZ + SAMPLE_HZ - 1) / SAMPLE_HZ);
    localparam integer KI_FRAC = 8;
    localparam logic signed [33:0] INTEG_MAX = 34'(64'(FREQ_MAX - NOM_WORD) << KI_FRAC);
    localparam logic [25:0] MAG_MIN = 26'(MIN_AMPLITUDE * 384);

    // Table offsets on a 2^32 turn; 32-bit arithmetic wraps like the model's modulo.
    localparam logic [31:0] OFF_120 = 32'd1431655765;
    localparam logic [31:0] OFF_90  = 32'd1073741824;
    localparam logic [31:0] ADDR_ROUND = 32'd1 << 19;

    typedef enum logic [3:0] {
        INIT, IDLE, PRODUCTS, PROJECT, SQUARES, ROOT, DIVIDE, SIGN, LOOP, TRIG, PUBLISH
    } state_t;
    state_t state;

    // Cosine ROM, synchronous read so it maps to block memory. The file holds
    // sign-extended 20-bit words (five hex digits); only 18 bits are used.
    (* romstyle = "M10K" *) logic [19:0] rom [0:4095];
    initial $readmemh(COS_FILE, rom);
    logic [11:0] rom_addr;
    logic [19:0] rom_word;
    logic signed [17:0] rom_q;
    always_ff @(posedge clk) rom_word <= rom[rom_addr];
    assign rom_q = rom_word[17:0];

    logic signed [15:0] va_q, vb_q, vc_q;
    logic ok_q;
    logic signed [17:0] trig [0:5];             // cos a,b,c then sin a,b,c for the current theta
    logic signed [33:0] prod [0:5];
    logic signed [35:0] d_sum, q_sum;
    logic signed [26:0] vd_s, vq_s;
    logic [51:0] radicand;
    logic [28:0] root_rem;
    logic [25:0] root;
    logic [28:0] root_trial;
    logic [28:0] root_shifted;
    logic [41:0] dividend;
    logic [26:0] div_rem, div_shifted;
    logic [17:0] quotient;
    logic [5:0]  step;
    logic signed [17:0] err;
    logic low_amp;
    logic signed [33:0] integ, integ_sum, integ_next;
    logic signed [34:0] freq_sum;
    logic [31:0] freq_next;
    logic [8:0] lock_count;
    logic [5:0] unlock_count;
    logic good, bad;
    logic [2:0] trig_idx;
    logic [31:0] trig_phase;
    logic have_result;

    always_comb begin
        d_sum = 36'(prod[0]) + 36'(prod[1]) + 36'(prod[2]);
        q_sum = -(36'(prod[3]) + 36'(prod[4]) + 36'(prod[5]));

        root_shifted = {root_rem[26:0], radicand[51:50]};
        root_trial = {1'b0, root, 2'b01};
        div_shifted = {div_rem[25:0], dividend[41]};

        integ_sum = integ + 34'(KI) * 34'(err);
        if (integ_sum > INTEG_MAX)       integ_next = INTEG_MAX;
        else if (integ_sum < -INTEG_MAX) integ_next = -INTEG_MAX;
        else                             integ_next = integ_sum;
        freq_sum = 35'($signed({3'b000, NOM_WORD})) + 35'(KP) * 35'(err) + 35'(integ_next >>> KI_FRAC);
        if (freq_sum < 35'($signed({3'b000, FREQ_MIN})))      freq_next = FREQ_MIN;
        else if (freq_sum > 35'($signed({3'b000, FREQ_MAX}))) freq_next = FREQ_MAX;
        else                                                  freq_next = freq_sum[31:0];

        good = !low_amp && (err <= LOCK_ERR) && (err >= -LOCK_ERR);
        bad  = low_amp || (err > UNLOCK_ERR) || (err < -UNLOCK_ERR);

        case (trig_idx)
            3'd0:    trig_phase = theta;
            3'd1:    trig_phase = theta - OFF_120;
            3'd2:    trig_phase = theta + OFF_120;
            3'd3:    trig_phase = theta - OFF_90;
            3'd4:    trig_phase = theta - OFF_120 - OFF_90;
            default: trig_phase = theta + OFF_120 - OFF_90;
        endcase
        rom_addr = 12'((trig_phase + ADDR_ROUND) >> 20);

        ready = rst_n && (state == IDLE);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= INIT;
            va_q <= '0; vb_q <= '0; vc_q <= '0; ok_q <= 1'b0;
            for (int i = 0; i < 6; i++) begin trig[i] <= '0; prod[i] <= '0; end
            vd_s <= '0; vq_s <= '0;
            radicand <= '0; root_rem <= '0; root <= '0;
            dividend <= '0; div_rem <= '0; quotient <= '0;
            step <= '0;
            err <= '0; low_amp <= 1'b1;
            integ <= '0;
            lock_count <= '0; unlock_count <= '0;
            trig_idx <= '0;
            have_result <= 1'b0;
            result_valid <= 1'b0; overrun <= 1'b0;
            angle_valid <= 1'b0; low_amplitude <= 1'b1;
            phase_error <= '0; amplitude <= '0;
            freq_word <= NOM_WORD; theta <= '0;
            cos_a <= '0; cos_b <= '0; cos_c <= '0;
            sin_a <= '0; sin_b <= '0; sin_c <= '0;
        end else begin
            result_valid <= 1'b0;
            overrun <= sample_valid && (state != IDLE);

            case (state)
                INIT: begin
                    // Fill the table outputs for theta = 0 before the first frame.
                    have_result <= 1'b0;
                    trig_idx <= '0;
                    step <= '0;
                    state <= TRIG;
                end
                IDLE: begin
                    if (sample_valid) begin
                        va_q <= v_a; vb_q <= v_b; vc_q <= v_c;
                        ok_q <= sample_ok;
                        state <= PRODUCTS;
                    end
                end
                PRODUCTS: begin
                    prod[0] <= va_q * trig[0];
                    prod[1] <= vb_q * trig[1];
                    prod[2] <= vc_q * trig[2];
                    prod[3] <= va_q * trig[3];
                    prod[4] <= vb_q * trig[4];
                    prod[5] <= vc_q * trig[5];
                    state <= PROJECT;
                end
                PROJECT: begin
                    vd_s <= 27'(d_sum >>> 8);
                    vq_s <= 27'(q_sum >>> 8);
                    state <= SQUARES;
                end
                SQUARES: begin
                    radicand <= 52'(vd_s * vd_s) + 52'(vq_s * vq_s);
                    root_rem <= '0;
                    root <= '0;
                    step <= 6'd0;
                    state <= ROOT;
                end
                ROOT: begin
                    // floor(sqrt(radicand)), two radicand bits per clock.
                    if (root_shifted >= root_trial) begin
                        root_rem <= root_shifted - root_trial;
                        root <= {root[24:0], 1'b1};
                    end else begin
                        root_rem <= root_shifted;
                        root <= {root[24:0], 1'b0};
                    end
                    radicand <= {radicand[49:0], 2'b00};
                    if (step == 6'd25) begin
                        step <= 6'd0;
                        state <= DIVIDE;
                    end else
                        step <= step + 1'b1;
                    // Prepare the divider: |vq| * 2^16.
                    dividend <= 42'(vq_s[26] ? -vq_s : vq_s) << 16;
                    div_rem <= '0;
                    quotient <= '0;
                end
                DIVIDE: begin
                    // floor(|vq| * 2^16 / |V|), one bit per clock.
                    // root now holds |V|; the quotient never exceeds 65536.
                    if (root == 26'd0 || !ok_q || root < MAG_MIN) begin
                        low_amp <= 1'b1;
                        err <= '0;
                        state <= LOOP;
                    end else begin
                        if (div_shifted >= {1'b0, root}) begin
                            div_rem <= div_shifted - {1'b0, root};
                            quotient <= {quotient[16:0], 1'b1};
                        end else begin
                            div_rem <= div_shifted;
                            quotient <= {quotient[16:0], 1'b0};
                        end
                        dividend <= {dividend[40:0], 1'b0};
                        if (step == 6'd41) begin
                            step <= 6'd0;
                            state <= SIGN;
                        end else
                            step <= step + 1'b1;
                    end
                end
                SIGN: begin
                    low_amp <= 1'b0;
                    err <= vq_s[26] ? -$signed({1'b0, quotient[16:0]}) : $signed({1'b0, quotient[16:0]});
                    state <= LOOP;
                end
                LOOP: begin
                    integ <= integ_next;
                    freq_word <= freq_next;
                    theta <= theta + freq_next;
                    if (!ok_q) begin
                        angle_valid <= 1'b0;
                        lock_count <= '0;
                        unlock_count <= '0;
                    end else if (!angle_valid) begin
                        if (good) begin
                            if (lock_count >= 9'(LOCK_SAMPLES - 1)) begin
                                angle_valid <= 1'b1;
                                unlock_count <= '0;
                            end
                            lock_count <= lock_count + 1'b1;
                        end else
                            lock_count <= '0;
                    end else begin
                        if (bad) begin
                            if (unlock_count >= 6'(UNLOCK_SAMPLES - 1)) begin
                                angle_valid <= 1'b0;
                                lock_count <= '0;
                            end
                            unlock_count <= unlock_count + 1'b1;
                        end else
                            unlock_count <= '0;
                    end
                    have_result <= 1'b1;
                    trig_idx <= '0;
                    state <= TRIG;
                end
                TRIG: begin
                    // Six table reads for the new theta; data arrives one clock after its address.
                    if (trig_idx != 3'd0)
                        trig[trig_idx - 1'b1] <= rom_q;
                    if (trig_idx == 3'd6)
                        state <= PUBLISH;
                    else
                        trig_idx <= trig_idx + 1'b1;
                end
                PUBLISH: begin
                    cos_a <= trig[0]; cos_b <= trig[1]; cos_c <= trig[2];
                    sin_a <= trig[3]; sin_b <= trig[4]; sin_c <= trig[5];
                    if (have_result) begin
                        result_valid <= 1'b1;
                        phase_error <= err;
                        amplitude <= root;
                        low_amplitude <= low_amp;
                    end
                    state <= IDLE;
                end
                default: state <= INIT;
            endcase
        end
    end
endmodule
