
[2026-06-16 · 45720dd · streaming-default (speed matrix + custom quality; design quality not installed)]

Telemetry summary — ~/Library/Application Support/QwenVoice/diagnostics
(30 runs across 12 cells; warm shows median)
tier: floor_8gb_mac

mode     model                      state len     n    RTF   tok/s  TTFC ms decode ms  peakGPU physFoot     trims   UIstall QC          
----------------------------------------------------------------------------------------------------------------------------------------
custom   pro_custom_quality         cold  medium  1   0.80   10.03        -      7474     3554     3364         0         — pass        
custom   pro_custom_quality         warm  short   3   0.77    9.64        -      2385     3056     3162         0         — pass        
custom   pro_custom_quality         warm  medium  3   0.83   10.37        -      7226     3505     3594         0         — pass        
custom   pro_custom_quality         warm  long    3   0.84   10.46        -     27827     3533     3624         0         — pass        
custom   pro_custom_speed           cold  medium  1   0.96   12.03        -      6071     2773     2860         0         — pass        
custom   pro_custom_speed           warm  short   3   0.95   11.86        -      1968     2324     2471         0         — pass        
custom   pro_custom_speed           warm  medium  3   1.01   12.58        -      6357     2324     2456         0         — pass        
custom   pro_custom_speed           warm  long    3   1.01   12.63        -     23472     2801     2865         0         — pass        
design   pro_design_speed           cold  medium  1   1.02   12.78        -      6101     2879     3028         0         — pass        
design   pro_design_speed           warm  short   3   0.97   12.18        -      2416     2868     3018         0         — pass        
design   pro_design_speed           warm  medium  3   1.03   12.87        -      6908     3623     3813         0         — pass        
design   pro_design_speed           warm  long    3   1.04   13.04        -     24336     2912     3047         0         — pass        

GPU MB by stage (peak; median over cell) — mlxMemoryByStage

mode     model                      state len        load   stream     peak     trim
------------------------------------------------------------------------------------
custom   pro_custom_quality         cold  medium     2282     2282     3516     3516
custom   pro_custom_quality         warm  short         0        0     3502     3502
custom   pro_custom_quality         warm  medium        0        0     3516     3516
custom   pro_custom_quality         warm  long          0        0     3561     3561
custom   pro_custom_speed           cold  medium     1550     1550     2784     2784
custom   pro_custom_speed           warm  short         0        0     2784     2784
custom   pro_custom_speed           warm  medium        0        0     2784     2784
custom   pro_custom_speed           warm  long          0        0     2829     2829
design   pro_design_speed           cold  medium     2017     3020     3737     3737
design   pro_design_speed           warm  short         0        0     3694     3694
design   pro_design_speed           warm  medium        0        0     3737     3737
design   pro_design_speed           warm  long          0        0     3823     3823

Decode breakdown (ms; median over cell) — timingsMS (named + other ≈ decode ms)

mode     model                      state len     talker sampCB0 codePred code2wav stepEval   other
---------------------------------------------------------------------------------------------------
custom   pro_custom_quality         cold  medium    1153       0      911       57     4876     477
custom   pro_custom_quality         warm  short      363       0      292       21     1644      60
custom   pro_custom_quality         warm  medium    1186       0      916       56     4860     219
custom   pro_custom_quality         warm  long      4726       0     3537      215    18501     906
custom   pro_custom_speed           cold  medium    1130       0      877       57     3508     499
custom   pro_custom_speed           warm  short      362       0      288       21     1230      67
custom   pro_custom_speed           warm  medium    1268       0      966       61     3825     247
custom   pro_custom_speed           warm  long      4823       0     3526      217    13978     916
design   pro_design_speed           cold  medium    1115       0      938       37     3715     296
design   pro_design_speed           warm  short      370       0      365       16     1595      76
design   pro_design_speed           warm  medium    1179       0     1080       38     4346     304
design   pro_design_speed           warm  long      4420       3     3791      122    14880    1120

Chunk timeline summary (streaming cells; median over cell)

mode     model                      state len    nChunks firstChunkMS medianInterChunkMS  talker codePred stepEval audioDecoder
-------------------------------------------------------------------------------------------------------------------------------
custom   pro_custom_quality         cold  medium      11         2646                662     112       84      435            5
custom   pro_custom_quality         warm  short        4          778                652     103       84      439            6
custom   pro_custom_quality         warm  medium      11          776                662     112       84      436            5
custom   pro_custom_quality         warm  long        42          785                666     116       84      438            5
custom   pro_custom_speed           cold  medium      11         2175                542     109       83      320            5
custom   pro_custom_speed           warm  short        4          677                540     100       84      320            5
custom   pro_custom_speed           warm  medium      12          673                542     112       83      322            5
custom   pro_custom_speed           warm  long        43          678                548     115       83      324            5
design   pro_design_speed           cold  medium       7         2618               1068     189      164      633            5
design   pro_design_speed           warm  short        3          746                906     151      117      505            5
design   pro_design_speed           warm  medium       7          778               1066     192      166      640            5
design   pro_design_speed           warm  long        24          818               1060     195      167      644            5

Mimi decoder breakdown per frame (ms; median over cell)

mode     model                      state len     quant  preC  preT  upsm initC blocks  snake  outC  total
----------------------------------------------------------------------------------------------------------
custom   pro_custom_quality         cold  medium      1     0     3     0     0      2      0     0      5
custom   pro_custom_quality         warm  short       1     0     3     0     0      2      0     0      5
custom   pro_custom_quality         warm  medium      1     0     3     0     0      2      0     0      5
custom   pro_custom_quality         warm  long        1     0     3     0     0      2      0     0      5
custom   pro_custom_speed           cold  medium      1     0     3     0     0      2      0     0      5
custom   pro_custom_speed           warm  short       1     0     3     0     0      2      0     0      5
custom   pro_custom_speed           warm  medium      1     0     3     0     0      2      0     0      5
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
