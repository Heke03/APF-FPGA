`timescale 1ns/1ps
module tb_apf_reference;
    logic clk=0;
    always #10 clk=~clk;
    logic rst_n=0, frame_valid=0, invalidate=0, angle_valid=1;
    logic signed [15:0] load_a=0, load_b=0, load_c=0;
    logic signed [17:0] cos_a=65536, cos_b=-32768, cos_c=-32768;
    wire ready_for_frame, result_valid, reference_ready, input_error;
    wire signed [17:0] mean_d, source_a,source_b,source_c;
    wire signed [17:0] reference_a,reference_b,reference_c;
    apf_reference dut(.*);
    integer fd,status,row=0,completed=0,ready_results=0,latency;
    integer event_code,ia,ib,ic,ca,cb,cc,expected_ready,md,sa,sb,sc,fa,fb,fc;
    integer observed_sum,source_residue_max=0;
    string vector_file;

    task automatic check_flush;
        if (reference_ready!==0 || result_valid!==0 || mean_d!==0 ||
            source_a!==0 || source_b!==0 || source_c!==0 ||
            reference_a!==0 || reference_b!==0 || reference_c!==0)
            $fatal(1,"Stale reference after flush, row %0d",row);
    endtask

    task automatic start_frame(input integer a,b,c,x,y,z);
        @(negedge clk);
        if(!ready_for_frame) $fatal(1,"Driver attempted frame while busy");
        load_a=a; load_b=b; load_c=c; cos_a=x; cos_b=y; cos_c=z;
        frame_valid=1;
        @(posedge clk); #1;
        @(negedge clk);
        frame_valid=0;
        // These changes must not contaminate the captured transaction.
        load_a=-32768; load_b=32767; load_c=-12345;
        cos_a=-65536; cos_b=65536; cos_c=0;
    endtask

    task automatic wait_result;
        latency=0;
        while(!result_valid && latency<16) begin
            @(posedge clk); #1; latency=latency+1;
        end
        if(!result_valid || latency!=7)
            $fatal(1,"Latency mismatch at row %0d: %0d clocks",row,latency);
        if(input_error) $fatal(1,"Unexpected input_error at row %0d",row);
        if(!ready_for_frame) $fatal(1,"Core did not return to idle");
    endtask

    task automatic assert_no_late_result;
        repeat(10) begin
            @(posedge clk); #1;
            if(result_valid || reference_ready) $fatal(1,"Canceled work escaped");
        end
    endtask

    initial begin
        if(!$value$plusargs("VECTORS=%s",vector_file))
            vector_file="sim/reference_vectors.txt";
        repeat(3) @(negedge clk);
        rst_n=1;
        fd=$fopen(vector_file,"r");
        if(!fd) $fatal(1,"Cannot open %s",vector_file);
        while(!$feof(fd)) begin
            status=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d\n",
                event_code,ia,ib,ic,ca,cb,cc,expected_ready,md,sa,sb,sc,fa,fb,fc);
            if(status!=15) $fatal(1,"Malformed golden-vector row %0d",row);
            if(event_code==0) begin
                start_frame(ia,ib,ic,ca,cb,cc);
                wait_result();
                if(reference_ready!==expected_ready[0] || $signed(mean_d)!=md ||
                   $signed(source_a)!=sa || $signed(source_b)!=sb || $signed(source_c)!=sc ||
                   $signed(reference_a)!=fa || $signed(reference_b)!=fb || $signed(reference_c)!=fc)
                    $fatal(1,"Integer scoreboard mismatch row %0d: ready=%0d mean=%0d source=%0d,%0d,%0d ref=%0d,%0d,%0d",row,
                        reference_ready,$signed(mean_d),$signed(source_a),$signed(source_b),$signed(source_c),
                        $signed(reference_a),$signed(reference_b),$signed(reference_c));
                completed=completed+1;
                if(reference_ready) begin
                    ready_results=ready_results+1;
                    if(($signed(source_a)+$signed(reference_a))!=ia ||
                       ($signed(source_b)+$signed(reference_b))!=ib ||
                       ($signed(source_c)+$signed(reference_c))!=ic)
                        $fatal(1,"Compensation-current sign or phase mismatch");
                    // Physical-angle scenarios finish before arithmetic-only stress.
                    if(row<2891) begin
                        observed_sum=$signed(source_a)+$signed(source_b)+$signed(source_c);
                        if(observed_sum<0) observed_sum=-observed_sum;
                        if(observed_sum>source_residue_max) source_residue_max=observed_sum;
                        if(observed_sum>4) $fatal(1,"Unexpected balanced-source quantization residue");
                    end
                end
                @(posedge clk); #1;
                if(result_valid) $fatal(1,"Result-valid pulse longer than one clock");
            end else if(event_code==1) begin
                @(negedge clk); invalidate=1;
                @(posedge clk); #1; check_flush();
                if(input_error) $fatal(1,"Explicit invalidation is not an input error");
                @(negedge clk); invalidate=0;
            end else if(event_code==2) begin
                @(negedge clk);
                load_a=ia; load_b=ib; load_c=ic; cos_a=ca; cos_b=cb; cos_c=cc;
                frame_valid=1;
                @(posedge clk); #1; check_flush();
                if(!input_error) $fatal(1,"Bad coefficient was not rejected");
                @(negedge clk); frame_valid=0;
                @(posedge clk); #1;
                if(input_error) $fatal(1,"Input-error pulse longer than one clock");
            end else $fatal(1,"Unknown event code");
            row=row+1;
        end
        $fclose(fd);
        if(row!=3582 || completed!=3574 || ready_results!=2326)
            $fatal(1,"Not all independent vectors were executed");
        $display("PASS: 3582 independent events; 3574 completed frames; 2326 ready references");
        $display("PASS: signed extrema, negative active power, harmonic extraction, load step and exact 200-frame warmup");
        $display("PASS: atomic input capture, seven-clock latency, single-cycle results and phase/sign identity");
        $display("PASS: physical-angle source-current sum residue <= %0d Q8 codes",source_residue_max);

        // Interrupt every in-flight pipeline position. No partially computed
        // result or old RAM entry may make the history ready again.
        for(integer position=0;position<7;position=position+1) begin
            @(negedge clk); invalidate=1;
            @(negedge clk); invalidate=0;
            start_frame(2560,-1280,-1280,65536,-32768,-32768);
            if(position>0) begin
                repeat(position) begin @(posedge clk); #1; end
                @(negedge clk);
            end
            invalidate=1;
            @(posedge clk); #1; check_flush();
            @(negedge clk); invalidate=0;
            assert_no_late_result();
        end
        $display("PASS: cancellation at every in-flight pipeline position");

        start_frame(2560,-1280,-1280,65536,-32768,-32768);
        frame_valid=1; // second strobe while PRODUCTS is busy
        @(posedge clk); #1; check_flush();
        if(!input_error) $fatal(1,"Busy-frame collision was not rejected");
        @(negedge clk); frame_valid=0;
        assert_no_late_result();
        $display("PASS: busy-frame rejection flushes unfinished work");

        start_frame(2560,-1280,-1280,65536,-32768,-32768);
        angle_valid=0;
        @(posedge clk); #1; check_flush();
        if(ready_for_frame || input_error) $fatal(1,"Lost angle handling failed");
        @(negedge clk); angle_valid=1;
        assert_no_late_result();
        $display("PASS: loss of grid-angle validity cancels work and inhibits references");

        start_frame(2560,-1280,-1280,65536,-32768,-32768);
        rst_n=0; #1; check_flush();
        if(ready_for_frame) $fatal(1,"Ready asserted during reset");
        @(negedge clk); rst_n=1;
        assert_no_late_result();
        for(integer n=1;n<=200;n=n+1) begin
            start_frame(2560,-1280,-1280,65536,-32768,-32768);
            wait_result();
            if(reference_ready!==(n==200)) $fatal(1,"Reset recovery count mismatch %0d",n);
        end
        if($signed(mean_d)!=2560 || $signed(source_a)!=2560 || reference_a!=0)
            $fatal(1,"Known active-current result failed after reset recovery");
        $display("PASS: asynchronous reset and exactly 200 fresh frames before recovery");
        $display("ALL PASS: FPGA compensation-reference arithmetic and protocol");
        $finish;
    end
    initial begin #10000000; $fatal(1,"Reference test timeout"); end
endmodule
