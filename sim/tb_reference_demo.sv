`timescale 1ns/1ps
// Real arithmetic exists ONLY in this stimulus/testbench, never in rtl/.
module tb_reference_demo;
    logic clk=0;
    always #10 clk=~clk;
    logic rst_n=0,frame_valid=0,invalidate=0,angle_valid=1;
    logic signed [15:0] load_a=0,load_b=0,load_c=0;
    logic signed [17:0] cos_a=65536,cos_b=-32768,cos_c=-32768;
    wire ready_for_frame,result_valid,reference_ready,input_error,cadence_error;
    wire signed [17:0] mean_d,source_a,source_b,source_c;
    wire signed [17:0] reference_a,reference_b,reference_c;
    apf_reference_guard dut(.*);
    real theta,phase,active;
    integer n,p,fd,results_seen=0,ready_seen=0,cadence_faults=0;
    integer load_codes[0:2],cos_codes[0:2];
    string output_csv;
    always @(posedge clk) begin
        #1;
        if(rst_n) begin
            if(input_error) $fatal(1,"Unexpected input error in correctly scheduled demo");
            if(cadence_error) cadence_faults=cadence_faults+1;
            if(result_valid) begin
                results_seen=results_seen+1;
                if(reference_ready) ready_seen=ready_seen+1;
                $fdisplay(fd,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                    $time,$signed(load_a),$signed(load_b),$signed(load_c),reference_ready,
                    $signed(mean_d),$signed(source_a),$signed(source_b),$signed(source_c),
                    $signed(reference_a),$signed(reference_b),$signed(reference_c),
                    cadence_error,input_error);
            end
        end
    end
    initial begin
        if(!$value$plusargs("CSV=%s",output_csv)) output_csv="results/fpga_reference_samples.csv";
        fd=$fopen(output_csv,"w");
        if(!fd) $fatal(1,"Cannot open demo CSV");
        $fdisplay(fd,"time_ns,load_a_q8,load_b_q8,load_c_q8,reference_ready,mean_d_q8,desired_source_a_q8,desired_source_b_q8,desired_source_c_q8,required_filter_a_q8,required_filter_b_q8,required_filter_c_q8,cadence_error,input_error");
        repeat(3) @(negedge clk);
        rst_n=1;
        for(n=0;n<1000;n=n+1) begin
            theta=6.283185307179586*n/200.0;
            active=(n<450)?8.0:12.0;
            for(p=0;p<3;p=p+1) begin
                phase=theta+((p==1)?-2.0943951023931953:((p==2)?2.0943951023931953:0.0));
                load_codes[p]=$rtoi(256.0*(active*$cos(phase)-3.0*$sin(phase)+
                    1.4*$cos(5.0*phase)+0.9*$cos(7.0*phase)));
                cos_codes[p]=$rtoi(65536.0*$cos(phase));
            end
            @(negedge clk);
            load_a=load_codes[0];load_b=load_codes[1];load_c=load_codes[2];
            cos_a=cos_codes[0];cos_b=cos_codes[1];cos_c=cos_codes[2];
            // One intentionally missing frame must invalidate a complete window.
            frame_valid=(n!=650);
            @(negedge clk); frame_valid=0;
            repeat(4998) @(negedge clk);
        end
        // Stop before the next expected frame deadline. Only frame 650 was
        // intentionally missed, so exactly one cadence-error pulse is expected.
        if(results_seen!=999 || ready_seen!=601 || cadence_faults!=1)
            $fatal(1,"Demo accounting: frames=%0d ready=%0d missing=%0d",results_seen,ready_seen,cadence_faults);
        $fclose(fd);
        $display("ALL PASS demo: 999 RTL results at 10 ksample/s, 601 ready results, one missing frame and full recovery");
        $finish;
    end
    initial begin #110000000; $fatal(1,"Demo timeout"); end
endmodule
