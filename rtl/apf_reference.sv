// Three-wire compensation reference; all current ports use signed Q8 counts.
// cos_* use signed Q16, where +65536 is +1.0 and -65536 is -1.0.
// Supply three correctly phased grid cosines from an external angle estimator.
// WINDOW must be >= 1. The accepted frame rate must be fixed; WINDOW accepted
// frames must span one nominal grid cycle (default: 200 frames at 10 kHz/50 Hz).
//
// Revision 2 (timing): same ports, same 7-clock latency and bit-identical
// results to revision 1. The two constant divisions are now exact
// multiply-by-reciprocal operations, and the averaging history is a
// synchronous-read RAM so it maps to on-chip memory blocks.
module apf_reference #(
    parameter integer WINDOW = 200
) (
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic                 frame_valid,
    input  logic                 invalidate,
    input  logic                 angle_valid,
    input  logic signed [15:0]   load_a,
    input  logic signed [15:0]   load_b,
    input  logic signed [15:0]   load_c,
    input  logic signed [17:0]   cos_a,
    input  logic signed [17:0]   cos_b,
    input  logic signed [17:0]   cos_c,
    output logic                 ready_for_frame,
    output logic                 result_valid,
    output logic                 reference_ready,
    output logic                 input_error,
    output logic signed [17:0]   mean_d,
    output logic signed [17:0]   source_a,
    output logic signed [17:0]   source_b,
    output logic signed [17:0]   source_c,
    output logic signed [17:0]   reference_a,
    output logic signed [17:0]   reference_b,
    output logic signed [17:0]   reference_c
);
    localparam integer INDEX_WIDTH = (WINDOW > 1) ? $clog2(WINDOW) : 1;
    localparam integer COUNT_WIDTH = (WINDOW > 1) ? $clog2(WINDOW + 1) : 1;
    localparam integer SUM_WIDTH = 18 + ((WINDOW > 1) ? $clog2(WINDOW) : 0);

    // d = trunc_zero(2*S / 196608) = sign(S) * floor(floor(|S| / 2^15) / 3).
    // floor(m/3) = (m * 349526) >> 20 is exact for every m < 2^19; here
    // m <= 3*2^31 / 2^15 = 196608 (three Q8 x Q16 products).
    localparam logic [18:0] RECIP_3 = 19'd349526;

    // mean = trunc_zero(T / WINDOW) with floor(m/WINDOW) = (m * R) >> K,
    // R = ceil(2^K / WINDOW). Exact while m * WINDOW < 2^K; |T| <= WINDOW*2^16,
    // so K = 2*clog2(WINDOW) + 17 is always sufficient.
    localparam integer RECIP_SHIFT = 2 * ((WINDOW > 1) ? $clog2(WINDOW) : 0) + 17;
    localparam integer RECIP_BITS = RECIP_SHIFT - ((WINDOW > 1) ? $clog2(WINDOW) : 0) + 1;
    localparam logic [63:0] RECIP_FULL = ((64'd1 << RECIP_SHIFT) + WINDOW - 1) / WINDOW;
    localparam logic [RECIP_BITS-1:0] RECIP_W = RECIP_FULL[RECIP_BITS-1:0];

    typedef enum logic [3:0] {
        IDLE, PRODUCTS, NUMERATOR, DIRECT_CURRENT, WINDOW_SUM,
        WINDOW_MEAN, SOURCE_PRODUCTS, PUBLISH
    } state_t;
    state_t state;

    logic signed [15:0] load_a_q, load_b_q, load_c_q;
    logic signed [17:0] cos_a_q, cos_b_q, cos_c_q;
    logic signed [33:0] product_a, product_b, product_c;
    logic signed [35:0] product_sum;
    logic [17:0] numerator_mag;
    logic numerator_neg;
    logic [36:0] third_product;
    logic signed [17:0] direct_current;
    logic signed [17:0] history [0:WINDOW-1];
    logic signed [17:0] history_read;
    logic history_write;
    logic [INDEX_WIDTH-1:0] write_index;
    logic [COUNT_WIDTH-1:0] sample_count;
    logic signed [SUM_WIDTH-1:0] rolling_total;
    logic signed [SUM_WIDTH-1:0] next_total;
    logic signed [SUM_WIDTH-1:0] old_extended, direct_extended;
    logic [SUM_WIDTH-1:0] total_mag;
    logic total_neg;
    logic [SUM_WIDTH+RECIP_BITS-1:0] mean_product;
    logic [17:0] mean_mag;
    logic signed [17:0] mean_work;
    logic frame_is_full;
    logic signed [35:0] source_product_a, source_product_b, source_product_c;
    logic signed [35:0] source_biased_a, source_biased_b, source_biased_c;
    logic signed [17:0] source_quotient_a, source_quotient_b, source_quotient_c;
    logic coefficient_invalid;
    logic frame_rejected;
    logic flush;

    always_comb begin
        coefficient_invalid =
            (cos_a > 18'sd65536) || (cos_a < -18'sd65536) ||
            (cos_b > 18'sd65536) || (cos_b < -18'sd65536) ||
            (cos_c > 18'sd65536) || (cos_c < -18'sd65536);
        frame_rejected = frame_valid && ((state != IDLE) || coefficient_invalid);
        flush = invalidate || !angle_valid || frame_rejected;
        ready_for_frame = rst_n && (state == IDLE) && angle_valid && !invalidate;

        product_sum = $signed({{2{product_a[33]}}, product_a}) +
                      $signed({{2{product_b[33]}}, product_b}) +
                      $signed({{2{product_c[33]}}, product_c});
        third_product = numerator_mag * RECIP_3;

        // Old history is never used until every slot has been written.
        old_extended = '0;
        if (sample_count == WINDOW)
            old_extended = {{(SUM_WIDTH-18){history_read[17]}}, history_read};
        direct_extended = {{(SUM_WIDTH-18){direct_current[17]}}, direct_current};
        next_total = rolling_total - old_extended + direct_extended;

        mean_product = total_mag * RECIP_W;
        mean_mag = mean_product[RECIP_SHIFT +: 18];

        // Divide by 2^16 truncating toward zero: bias negatives before the shift.
        source_biased_a = source_product_a + (source_product_a[35] ? 36'sd65535 : 36'sd0);
        source_biased_b = source_product_b + (source_product_b[35] ? 36'sd65535 : 36'sd0);
        source_biased_c = source_product_c + (source_product_c[35] ? 36'sd65535 : 36'sd0);
        source_quotient_a = source_biased_a[33:16];
        source_quotient_b = source_biased_b[33:16];
        source_quotient_c = source_biased_c[33:16];

        history_write = rst_n && !flush && (state == WINDOW_SUM);
    end

    // Synchronous-read history RAM (no reset, so it maps to block memory).
    // The slot read at the DIRECT_CURRENT edge is written back one state later.
    always_ff @(posedge clk) begin
        if (history_write)
            history[write_index] <= direct_current;
        history_read <= history[write_index];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            load_a_q <= '0; load_b_q <= '0; load_c_q <= '0;
            cos_a_q <= '0; cos_b_q <= '0; cos_c_q <= '0;
            product_a <= '0; product_b <= '0; product_c <= '0;
            numerator_mag <= '0;
            numerator_neg <= 1'b0;
            direct_current <= '0;
            write_index <= '0;
            sample_count <= '0;
            rolling_total <= '0;
            total_mag <= '0;
            total_neg <= 1'b0;
            mean_work <= '0;
            frame_is_full <= 1'b0;
            source_product_a <= '0; source_product_b <= '0; source_product_c <= '0;
            result_valid <= 1'b0;
            reference_ready <= 1'b0;
            input_error <= 1'b0;
            mean_d <= '0;
            source_a <= '0; source_b <= '0; source_c <= '0;
            reference_a <= '0; reference_b <= '0; reference_c <= '0;
        end else begin
            result_valid <= 1'b0;
            input_error <= 1'b0;

            // An unavailable angle or invalidated measurement discards the
            // complete history and any transaction already in progress.
            if (flush) begin
                state <= IDLE;
                write_index <= '0;
                sample_count <= '0;
                rolling_total <= '0;
                mean_work <= '0;
                frame_is_full <= 1'b0;
                reference_ready <= 1'b0;
                mean_d <= '0;
                source_a <= '0; source_b <= '0; source_c <= '0;
                reference_a <= '0; reference_b <= '0; reference_c <= '0;
                input_error <= frame_rejected && angle_valid && !invalidate;
            end else begin
                case (state)
                    IDLE: begin
                        if (frame_valid) begin
                            // Capture all channels and their angle atomically.
                            load_a_q <= load_a; load_b_q <= load_b; load_c_q <= load_c;
                            cos_a_q <= cos_a; cos_b_q <= cos_b; cos_c_q <= cos_c;
                            state <= PRODUCTS;
                        end
                    end
                    PRODUCTS: begin
                        product_a <= load_a_q * cos_a_q;
                        product_b <= load_b_q * cos_b_q;
                        product_c <= load_c_q * cos_c_q;
                        state <= NUMERATOR;
                    end
                    NUMERATOR: begin
                        // |2S| / 2^16 = |S| / 2^15; keep sign and magnitude.
                        numerator_neg <= product_sum[35];
                        numerator_mag <= product_sum[35] ? 18'((-product_sum) >>> 15)
                                                         : 18'(product_sum >>> 15);
                        state <= DIRECT_CURRENT;
                    end
                    DIRECT_CURRENT: begin
                        // d = trunc_zero(2 * sum(load_p*cos_p) / (3*65536)).
                        direct_current <= numerator_neg ? -$signed({1'b0, third_product[36:20]})
                                                        :  $signed({1'b0, third_product[36:20]});
                        state <= WINDOW_SUM;
                    end
                    WINDOW_SUM: begin
                        rolling_total <= next_total;
                        total_neg <= next_total[SUM_WIDTH-1];
                        total_mag <= next_total[SUM_WIDTH-1] ? -next_total : next_total;
                        if (write_index == WINDOW-1)
                            write_index <= '0;
                        else
                            write_index <= write_index + 1'b1;
                        if (sample_count < WINDOW)
                            sample_count <= sample_count + 1'b1;
                        frame_is_full <= (sample_count >= WINDOW-1);
                        state <= WINDOW_MEAN;
                    end
                    WINDOW_MEAN: begin
                        if (frame_is_full)
                            mean_work <= total_neg ? -$signed(mean_mag) : $signed(mean_mag);
                        else
                            mean_work <= '0;
                        state <= SOURCE_PRODUCTS;
                    end
                    SOURCE_PRODUCTS: begin
                        source_product_a <= mean_work * cos_a_q;
                        source_product_b <= mean_work * cos_b_q;
                        source_product_c <= mean_work * cos_c_q;
                        state <= PUBLISH;
                    end
                    PUBLISH: begin
                        result_valid <= 1'b1;
                        reference_ready <= frame_is_full;
                        mean_d <= mean_work;
                        source_a <= source_quotient_a;
                        source_b <= source_quotient_b;
                        source_c <= source_quotient_c;
                        if (frame_is_full) begin
                            reference_a <= $signed({{2{load_a_q[15]}}, load_a_q}) - source_quotient_a;
                            reference_b <= $signed({{2{load_b_q[15]}}, load_b_q}) - source_quotient_b;
                            reference_c <= $signed({{2{load_c_q[15]}}, load_c_q}) - source_quotient_c;
                        end else begin
                            reference_a <= '0; reference_b <= '0; reference_c <= '0;
                        end
                        state <= IDLE;
                    end
                    default: begin
                        // Recover through the same logical history reset.
                        state <= IDLE;
                        write_index <= '0;
                        sample_count <= '0;
                        rolling_total <= '0;
                        mean_work <= '0;
                        frame_is_full <= 1'b0;
                        reference_ready <= 1'b0;
                        mean_d <= '0;
                        source_a <= '0; source_b <= '0; source_c <= '0;
                        reference_a <= '0; reference_b <= '0; reference_c <= '0;
                    end
                endcase
            end
        end
    end
endmodule
