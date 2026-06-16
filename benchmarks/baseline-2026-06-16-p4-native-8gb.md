
[2026-06-16 · 0e7d6dd · P4 native 8GB full matrix]

Telemetry summary — /Users/patricedery/Library/Application Support/QwenVoice/diagnostics
(76 runs across 36 cells; warm shows median)
tier: floor_8gb_mac

mode     model                      state len     n    RTF   tok/s  TTFC ms decode ms  peakGPU physFoot     trims   UIstall QC          
----------------------------------------------------------------------------------------------------------------------------------------
clone    pro_clone_quality          cold  short   1   0.41    5.06        -      2902     7130     7390         0         — pass        
clone    pro_clone_quality          warm  short   2   0.32    4.02        -      5502     6739     6940         0         — pass        
clone    pro_clone_quality          warm  medium  4   0.49    6.07        -     10606     7609     7401         0         — pass        
clone    pro_clone_quality          warm  long    3   0.52    6.55        -     29690     8516     8473         0         — pass        
clone    pro_clone_speed            cold  short   1   0.46    5.73        -      3687     6791     6101         0         — pass        
clone    pro_clone_speed            warm  short   2   0.43    5.36        -      4476     6132     6326         0         — pass        
clone    pro_clone_speed            warm  medium  4   0.56    6.98        -      9496     6179     6344         0         — pass        
clone    pro_clone_speed            warm  long    3   0.64    7.99        -     27219     7847     7790         0         — warn:dropout
custom   pro_custom_quality         cold  medium  1   0.78    9.71        -      7363     4591     4753         0         — pass        
custom   pro_custom_quality         warm  short   3   0.78    9.80        -      2450     4844     5148         0         — pass        
custom   pro_custom_quality         warm  medium  4   0.81   10.15        -      7083     5276     5064         0         — pass        
custom   pro_custom_quality         warm  long    3   0.71    8.91        -     30068     8114     7228         0         — pass        
custom   pro_custom_speed           cold  medium  1   0.83   10.38        -      5371     4188     3370         0         — pass        
custom   pro_custom_speed           warm  short   3   0.91   11.35        -      1815     2109     2336         0         — pass        
custom   pro_custom_speed           warm  medium  4   0.98   12.25        -      5417     4491     4223         0         — pass        
custom   pro_custom_speed           warm  long    3   0.89   11.08        -     23081     6117     5695         0         — fail:dropout
design   pro_design_quality         cold  medium  1   0.85   10.61        -      7582     5940     5214         0         — pass        
design   pro_design_quality         warm  short   3   0.79    9.84        -      2551     4673     4102         0         — pass        
design   pro_design_quality         warm  medium  4   0.81   10.13        -      7422     5479     5336         0         — pass        
design   pro_design_quality         warm  long    3   0.70    8.76        -     30333     7613     7679         0         — warn:dropout
design   pro_design_speed           cold  medium  1   1.01   12.59        -      6029     5138     5323         0         — pass        
design   pro_design_speed           warm  short   3   0.88   11.05        -      2102     4846     4249         0         — pass        
design   pro_design_speed           warm  medium  4   1.00   12.52        -      5838     5439     5320         0         — pass        
design   pro_design_speed           warm  long    3   0.91   11.39        -     25472     8105     7834         0         — warn:dropout

Delivery cells (--delivery; medium text, instruct-bearing) — notes.delivery

mode     model                      state delivery          n    RTF   tok/s decode ms physFoot QC           prosN  prosEff  dF0Std  dRateCV  dPauseR  dRough
-------------------------------------------------------------------------------------------------------------------------------------------------------------
custom   pro_custom_quality         warm  calm.normal       1   0.78    9.80      7712     5535 pass             1    +8.27   -6.40   -0.040   +0.000  +0.023
custom   pro_custom_quality         warm  happy.strong      1   0.48    5.97     11244     5342 pass             1   +10.38   +6.90   -0.010   -0.033  +0.014
custom   pro_custom_quality         warm  whisper.normal    1   0.72    8.98      8306     4886 pass             1    +8.81   -0.60   -0.070   +0.010  +0.046
custom   pro_custom_speed           warm  calm.normal       1   0.99   12.42      5522     4863 pass             1    +7.12   -5.30   -0.010   +0.014  -0.033
custom   pro_custom_speed           warm  happy.strong      1   0.63    7.89      8377     4885 pass             1   +10.12   +2.50   +0.050   -0.018  +0.016
custom   pro_custom_speed           warm  whisper.normal    1   1.00   12.44      6192     4632 warn:clicks      1    +8.14  -20.10   +0.090   +0.006  +0.034
design   pro_design_quality         warm  calm.normal       1   0.84   10.51      7652     5795 pass             1    +6.55  -10.20   -0.050   +0.028  +0.024
design   pro_design_quality         warm  happy.strong      1   0.83   10.40      6053     6109 pass             1   +10.35  +27.00   -0.010   +0.029  +0.009
design   pro_design_quality         warm  whisper.normal    1   0.85   10.63      7419     5390 pass             1    +5.69   -9.00   -0.050   +0.044  -0.009
design   pro_design_speed           warm  calm.normal       1   1.00   12.48      5419     5855 pass             1    +7.51   +9.10   +0.030   -0.020  +0.019
design   pro_design_speed           warm  happy.strong      1   0.99   12.36      5360     5408 pass             1    +9.06  +29.20   +0.020   -0.028  -0.007
design   pro_design_speed           warm  whisper.normal    1   1.04   13.01      9390     5658 warn:dropout     1    +6.86  +17.40   +0.510   +0.238  -0.037

GPU MB by stage (peak; median over cell) — mlxMemoryByStage

mode     model                      state len        load   stream     peak     trim
------------------------------------------------------------------------------------
clone    pro_clone_quality          cold  short      4577     5063     7598     7598
clone    pro_clone_quality          warm  short         0        0     7736     7736
clone    pro_clone_quality          warm  medium        0        0     7879     7879
clone    pro_clone_quality          warm  long          0        0     9215     9215
clone    pro_clone_speed            cold  short      3629     3768     6788     6788
clone    pro_clone_speed            warm  short         0        0     6833     6833
clone    pro_clone_speed            warm  medium        0        0     7169     7169
clone    pro_clone_speed            warm  long          0        0     8195     8195
custom   pro_custom_quality         cold  medium     2751     2751     6052     6052
custom   pro_custom_quality         warm  short         0        0     5016     5016
custom   pro_custom_quality         warm  medium        0        0     5996     5996
custom   pro_custom_quality         warm  long          0        0     8111     8111
custom   pro_custom_speed           cold  medium     1550     1550     4371     4371
custom   pro_custom_speed           warm  short         0        0     3704     3704
custom   pro_custom_speed           warm  medium        0        0     4850     4850
custom   pro_custom_speed           warm  long          0        0     7306     7306
design   pro_design_quality         cold  medium     3687     4159     6337     6337
design   pro_design_quality         warm  short         0        0     5411     5411
design   pro_design_quality         warm  medium        0        0     6537     6537
design   pro_design_quality         warm  long          0        0     8624     8624
design   pro_design_speed           cold  medium     2486     3425     5498     5498
design   pro_design_speed           warm  short         0        0     4688     4688
design   pro_design_speed           warm  medium        0        0     5747     5747
design   pro_design_speed           warm  long          0        0     8102     8102

Decode breakdown (ms; median over cell) — timingsMS (named + other ≈ decode ms)

mode     model                      state len     talker sampCB0 codePred code2wav stepEval   other
---------------------------------------------------------------------------------------------------
clone    pro_clone_quality          cold  short      155       0      353        0     2377      17
clone    pro_clone_quality          warm  short      194       1      425        0     4864      18
clone    pro_clone_quality          warm  medium     504       1     1091        0     8981      60
clone    pro_clone_quality          warm  long      1490       1     3329        0    24953     145
clone    pro_clone_speed            cold  short      198       0      448        0     3023      18
clone    pro_clone_speed            warm  short      217       1      476        0     3762      20
clone    pro_clone_speed            warm  medium     552       1     1178        0     7749      60
clone    pro_clone_speed            warm  long      1577       0     3470        0    22004     179
custom   pro_custom_quality         cold  medium     478       0     1010        0     5840      35
custom   pro_custom_quality         warm  short      161       0      339        0     1933      14
custom   pro_custom_quality         warm  medium     488       1      970        0     5160      28
custom   pro_custom_quality         warm  long      1739       1     3555        0    24530      39
custom   pro_custom_speed           cold  medium     398       0      875        0     4048      50
custom   pro_custom_speed           warm  short      134       0      302        0     1366      13
custom   pro_custom_speed           warm  medium     427       1      914        0     3864      56
custom   pro_custom_speed           warm  long      1677       1     3651        0    17628     133
design   pro_design_quality         cold  medium     558       0     1131        0     5880      13
design   pro_design_quality         warm  short      169       0      320        0     2008       5
design   pro_design_quality         warm  medium     499       0      998        0     5760      18
design   pro_design_quality         warm  long      1847       1     3735        0    24722      28
design   pro_design_speed           cold  medium     533       0     1084        0     4395      17
design   pro_design_speed           warm  short      163       0      330        0     1566       9
design   pro_design_speed           warm  medium     552       0      991        0     4084      17
design   pro_design_speed           warm  long      2245       1     4550        0    18605       3

Chunk timeline summary (streaming cells; median over cell)

mode     model                      state len    nChunks firstChunkMS medianInterChunkMS  talker codePred stepEval audioDecoder
-------------------------------------------------------------------------------------------------------------------------------
clone    pro_clone_quality          warm  medium       7         1918               1574     202      193     1112            5
clone    pro_clone_speed            warm  medium       7         1735               1463     197      190      997            6
custom   pro_custom_quality         warm  medium      11         1186                653     112       85      433            5
custom   pro_custom_speed           warm  medium      11         3061                551     118       86      323            5
design   pro_design_quality         warm  medium       7         1181               1290     196      169      856            5
design   pro_design_speed           warm  medium       6          930               1067     193      169      634            5

Mimi decoder breakdown per frame (ms; median over cell)

mode     model                      state len     quant  preC  preT  upsm initC blocks  snake  outC  total
----------------------------------------------------------------------------------------------------------
clone    pro_clone_quality          warm  medium      1     0     3     0     0      2      0     0      5
clone    pro_clone_speed            warm  medium      1     0     3     0     0      2      0     0      6
custom   pro_custom_quality         warm  medium      1     0     3     0     0      2      0     0      5
custom   pro_custom_speed           warm  medium      1     0     3     0     0      2      0     0      5
design   pro_design_quality         warm  medium      1     0     3     0     0      2      0     0      5
design   pro_design_speed           warm  medium      1     0     3     0     0      2      0     0      5

RTF = audioSeconds / wallSeconds (>1 faster than realtime). tok/s = codec tokens/s. TTFC = submit→first chunk. decode ms = qwen_token_loop_total. peakGPU/physFoot/GPU-stage = MB.
Decode breakdown (ms, median): talker = qwen_talker_forward_total · sampCB0 = qwen_sample_first_codebook_total · codePred = qwen_code_predictor_total (15× loop) · code2wav = qwen_stream_decoder_total (audio decoder) · stepEval = qwen_stream_step_eval_total · other = remainder (codec-embedding assembly + EOS read + audio-chunk eval + unattributed). Named + other ≈ decode ms.
⚠ These are Swift-side wall-clock timers around LAZY MLX ops, not per-stage GPU compute. talker/codePred measure graph-BUILD time; the single per-frame eval() makes stepEval the fused compute of Talker+CodePredictor+sampling. code2wav≈0 because the decoder is asyncEval'd (Phase 2c) and overlaps the token loop — pipelined, not free. To attribute compute per stage, capture the os_signpost intervals (Talker Forward / Code Predictor Loop / Step Eval Flush / Audio Decoder) under Instruments xctrace.
physFoot = phys_footprint peak (the figure Jetsam judges — the OOM-relevant peak; peakRSS + headMin are in the records too). trims = median memory_trim count [worst level]; raw kernel pressure also recorded as memory_pressure marks.
QC = reference-free audio defect verdict (pass / warn / fail:flags — nonfinite/clipping/clicks/dropout/near_silent). It does not judge subtle perceptual quality — that needs the listening pass (see telemetry doc).
Delivery prosody: prosEff = signed prosody-effect score vs paired neutral (+F0 dynamics +rate variability -pauses +roughness). Requires `vocello bench --delivery`.
