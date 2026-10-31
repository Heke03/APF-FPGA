function c = load_capture_H3(dir)
% H3: loads a waveform recording of the board (rtl/capture_H3.sv), as written by
% quartus/read_capture_H3.tcl (from the board) or by sim/tb_de2_115_H3.sv (from
% the simulation): INF.txt and IG/IL/II/VD/VG.txt, one hex word per line.
%
%   c = load_capture_H3(folder)
%
%   c.t                 time from the trigger, s (one sample per 100 us)
%   c.ig, c.il, c.ii    grid, load and inverter current of phase a, A
%   c.vdc, c.vg         DC link and grid voltage of phase a, V
%                       (NaN where nothing was recorded since the last KEY1 / reset)
%   c.is                grid current in the THD meter's format (2^-10 A, whole numbers)
%   c.event             what triggered it, e.g. "SW1 up (load 22 ohm)"
%   c.ready             true: the recording had stopped (LEDG8 on) when it was read
%   c.window_start      indices of the samples where the board's THD meter starts a window
inf = hex2dec(readlines(fullfile(dir, 'INF.txt'), 'EmptyLineRule', 'skip'));
assert(numel(inf) == 8 && inf(1) == hex2dec('A9F00003'), 'load_capture_H3: %s is not a recording of the H3 board', dir);
st = inf(2);
c.ready = bitget(st, 1) == 1;
D = 2^bitand(bitshift(st, -8), 255);
wr = inf(3); trig = inf(4); fresh = inf(5); k_trig = inf(7); sw = inf(8);
order = mod(wr + (0:D - 1).', D) + 1;                     % oldest first
ok = (1:D).' > D - fresh;                                % recorded since the last KEY1 / reset
kt = mod(trig - wr, D) + 1;                              % the trigger sample
if ~bitget(st, 2), kt = D; end                           % not triggered yet: t = 0 is the newest sample
c.t = ((1:D).' - kt) / 1e4;
s16 = @(u) double(u) - 65536 * (u >= 32768);
rd = @(name) hex2dec(readlines(fullfile(dir, [name '.txt']), 'EmptyLineRule', 'skip'));
ch = struct('ig', s16(rd('IG')) / 2^10, 'il', s16(rd('IL')) / 2^10, 'ii', s16(rd('II')) / 2^10, ...
            'vdc', rd('VD') / 2^6, 'vg', s16(rd('VG')) / 2^7);
for f = fieldnames(ch).'
    x = ch.(f{1})(order); x(~ok) = NaN; c.(f{1}) = x;
end
c.is = round(c.ig * 2^10);
% the board's THD meter windows: the trigger sample is at position k_trig of its window
c.window_start = find(mod(k_trig + ((1:D).' - kt), 1000) == 0 & ok);
before = bitand(bitshift(sw, -4), 7); after = bitand(sw, 7);
names = ["SW0 up (filter on)", "SW0 down (filter off)"; "SW1 up (load 22 ohm)", "SW1 down (load 33 ohm)"; ...
         "SW2 up (ADC noise on)", "SW2 down (ADC noise off)"];
c.event = "no switch flipped yet";
for b = 1:3
    if bitget(before, b) ~= bitget(after, b), c.event = names(b, 2 - bitget(after, b)); end
end
c.triggered = bitget(st, 2) == 1;
c.samples_before = sum(ok(1:kt - 1));
end
