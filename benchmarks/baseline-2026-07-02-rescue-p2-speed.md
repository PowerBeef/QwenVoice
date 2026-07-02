
[2026-07-02 · 67078da · rescue-P2 full-matrix speed (-Onone CLI, idle machine) 2026-07-02]

Telemetry summary — /tmp/p2-diag2
(29 runs across 12 cells; warm shows median)
tier: floor_8gb_mac

mode     model                      state len     n    RTF   tok/s  TTFC ms decode ms  peakGPU physFoot  headMin  gpuWS thermal      trims   UIstall QC          
-----------------------------------------------------------------------------------------------------------------------------------------------------------------
clone    pro_clone_speed            cold  short   1   0.75    9.39        -      2878     3617     3853        -   0.66 nominal          0         — warn:dropout
clone    pro_clone_speed            warm  short   2   0.71    8.89        -      2753     3617     3763        -   0.66 nominal          0         — pass        
clone    pro_clone_speed            warm  medium  3   0.77    9.60        -      7447     4267     4212        -   0.78 nominal          0         — pass        
clone    pro_clone_speed            warm  long    3   0.80    9.94        -     23236     4458     4590        -   0.82 nominal          0         — pass        
custom   pro_custom_speed           cold  medium  1   0.98   12.20        -      7457     2505     2456        -   0.46 nominal          0         — pass        
custom   pro_custom_speed           warm  short   3   0.94   11.72        -      2072     2308     2468        -   0.42 nominal          0         — pass        
custom   pro_custom_speed           warm  medium  3   1.05   13.08        -      5828     2310     2487        -   0.42 nominal          0         — pass        
custom   pro_custom_speed           warm  long    3   1.06   13.23        -     21042     2772     2860        -   0.51 nominal          0         — pass        
design   pro_design_speed           cold  medium  1   1.08   13.50        -      7480     3336     3551        -   0.61 nominal          0         — pass        
design   pro_design_speed           warm  short   3   0.99   12.42        -      1890     2877     2976        -   0.53 nominal          0         — pass        
design   pro_design_speed           warm  medium  3   1.09   13.61        -      6269     3703     3761        -   0.68 nominal          0         — pass        
design   pro_design_speed           warm  long    3   1.11   13.87        -     27261     3831     3806        -   0.70 nominal          0         — pass        

GPU MB by stage (peak; median over cell) — mlxMemoryByStage

mode     model                      state len        load   stream     peak     trim
------------------------------------------------------------------------------------
clone    pro_clone_speed            cold  short      3158     3762     4434     4434
clone    pro_clone_speed            warm  short         0        0     4434     4434
clone    pro_clone_speed            warm  medium        0        0     4476     4476
clone    pro_clone_speed            warm  long          0        0     4533     4533
custom   pro_custom_speed           cold  medium     1550     1550     2784     2784
custom   pro_custom_speed           warm  short         0        0     2770     2770
custom   pro_custom_speed           warm  medium        0        0     2784     2784
custom   pro_custom_speed           warm  long          0        0     2829     2829
design   pro_design_speed           cold  medium     2017     2956     3737     3737
design   pro_design_speed           warm  short         0        0     3694     3694
design   pro_design_speed           warm  medium        0        0     3737     3737
design   pro_design_speed           warm  long          0        0     3823     3823

Decode breakdown (ms; median over cell) — timingsMS (named + other ≈ decode ms)

mode     model                      state len     talker sampCB0 codePred code2wav stepEval   other
---------------------------------------------------------------------------------------------------
clone    pro_clone_speed            cold  short      334       1      386       18     2049      90
clone    pro_clone_speed            warm  short      318       1      354       16     1980      83
clone    pro_clone_speed            warm  medium     897       1     1003       33     5220     270
clone    pro_clone_speed            warm  long      2951       3     3120       93    16004    1010
custom   pro_custom_speed           cold  medium    1408       2     1118       70     4303     556
custom   pro_custom_speed           warm  short      358       0      310       23     1317      67
custom   pro_custom_speed           warm  medium    1075       0      923       60     3537     233
custom   pro_custom_speed           warm  long      4083       1     3370      214    12436     903
design   pro_design_speed           cold  medium    1244       1     1244       41     4589     361
design   pro_design_speed           warm  short      296       0      304       16     1194      73
design   pro_design_speed           warm  medium    1027       0     1049       39     3864     297
design   pro_design_speed           warm  long      4650       0     4568      154    16516    1373

Chunk timeline summary (streaming cells; median over cell)

mode     model                      state len    nChunks firstChunkMS medianInterChunkMS  talker codePred stepEval audioDecoder
-------------------------------------------------------------------------------------------------------------------------------
clone    pro_clone_speed            cold  short        3         3331               1044     132       99      627            6
clone    pro_clone_speed            warm  short        3          948                944     119       98      678            6
clone    pro_clone_speed            warm  medium       6         1005               1384     166      192      936            6
clone    pro_clone_speed            warm  long        17         1148               1371     179      190      937            5
custom   pro_custom_speed           cold  medium      13         2503                516     104       84      300            5
custom   pro_custom_speed           warm  short        4          737                517     100       84      313            6
custom   pro_custom_speed           warm  medium      11          745                511     103       83      298            5
custom   pro_custom_speed           warm  long        40          817                514     103       84      300            5
design   pro_design_speed           cold  medium       8         2874               1018     175      168      612            5
design   pro_design_speed           warm  short        3          665                652     108       88      436            5
design   pro_design_speed           warm  medium       7          700               1008     171      168      607            5
design   pro_design_speed           warm  long        28          830               1000     172      168      600            5

Mimi decoder breakdown per frame (ms; median over cell)

mode     model                      state len     quant  preC  preT  upsm initC blocks  snake  outC  total
----------------------------------------------------------------------------------------------------------
clone    pro_clone_speed            cold  short       1     0     3     0     0      2      0     0      6
clone    pro_clone_speed            warm  short       1     0     3     0     0      2      0     0      6
clone    pro_clone_speed            warm  medium      1     0     3     0     0      2      0     0      6
clone    pro_clone_speed            warm  long        1     0     3     0     0      2      0     0      5
custom   pro_custom_speed           cold  medium      1     0     2     0     0      2      0     0      5
custom   pro_custom_speed           warm  short       1     0     3     0     0      2      0     0      6
custom   pro_custom_speed           warm  medium      1     0     2     0     0      2      0     0      5
custom   pro_custom_speed           warm  long        1     0     3     0     0      2      0     0      5
design   pro_design_speed           cold  medium      1     0     3     0     0      2      0     0      5
design   pro_design_speed           warm  short       1     0     3     0     0      2      0     0      5
design   pro_design_speed           warm  medium      1     0     3     0     0      2      0     0      5
design   pro_design_speed           warm  long        1     0     3     0     0      2      0     0      5

RTF = audioSeconds / wallSeconds (>1 faster than realtime). tok/s = codec tokens/s. TTFC = submit→first chunk. decode ms = qwen_token_loop_total. peakGPU/physFoot/GPU-stage = MB.
Decode breakdown (ms, median): talker = qwen_talker_forward_total · sampCB0 = qwen_sample_first_codebook_total · codePred = qwen_code_predictor_total (15× loop) · code2wav = qwen_stream_decoder_total (audio decoder) · stepEval = qwen_stream_step_eval_total · other = remainder (codec-embedding assembly + EOS read + audio-chunk eval + unattributed). Named + other ≈ decode ms.
⚠ These are Swift-side wall-clock timers around LAZY MLX ops, not per-stage GPU compute. talker/codePred measure graph-BUILD time; the single per-frame eval() makes stepEval the fused compute of Talker+CodePredictor+sampling. code2wav≈0 because the decoder is asyncEval'd (Phase 2c) and overlaps the token loop — pipelined, not free. To attribute compute per stage, capture the os_signpost intervals (Talker Forward / Code Predictor Loop / Step Eval Flush / Audio Decoder) under Instruments xctrace.
physFoot = phys_footprint peak (the figure Jetsam judges — the OOM-relevant peak; peakRSS + headMin are in the records too). trims = median memory_trim count [worst level]; raw kernel pressure also recorded as memory_pressure marks.
QC = reference-free audio defect verdict (pass / warn / fail:flags — nonfinite/clipping/clicks/dropout/near_silent). It does not judge subtle perceptual quality — that needs the listening pass (see telemetry doc).

> Note: an earlier same-day matrix (HISTORY row 13:27Z) ran concurrently with an iOS
> compile and shows load-contaminated cells (design/long RTF 0.57); THIS idle-machine
> run is the reference. Compare like-for-like: CLI -Onone in-process lane only.
