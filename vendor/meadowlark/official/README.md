# vendor/meadowlark/official — Blink SDK (NOT YET VENDORED)

This directory receives the Blink SDK header + manual copied from the SLM
PC's Meadowlark install, exactly as `vendor/alp/official/` holds the ALP
header. Until it is populated and [docs/blink-api-audit.md](../../../docs/blink-api-audit.md)
is completed, `tfp.hardware.BlinkSLM` stays stubbed
(`tfp:hardware:BlinkSLM:sdkNotVendored`) and `slm_server` runs dry.

Copy here (strip any `.git/` from copied folders):
- `Blink_C_wrapper.h` (or this SDK version's equivalent C header)
- the SDK manual PDF
- a `VERSION.txt` noting the SDK version + install path on the SLM PC

Never invent Blink function names — the header in this directory is the only
authority (CLAUDE.md rule).
