# ALP API cross-reference audit

**Date:** 2026-05-16
**Status:** Pre-official-Vialux-installer baseline. Use this audit as the authoritative API surface for `+tfp/+hardware/DLP650LNIR_DMD.m` development until the official Vialux SDK installer arrives, after which this audit must be diffed against the official headers.

## Verified against official Vialux ALP-4.3 header (2026-05-18)

**Official header:** `vendor/alp/official/alp.h` — Version 28, © 2004-2024 ViALUX GmbH
**Reference header:** `vendor/alp/reference/parot-alptool/alp.h` — Version 14, © 2004-2015 ViALUX GmbH

### Result: all 9 audited functions verified — identical signatures

`AlpDevAlloc`, `AlpDevInquire`, `AlpDevHalt`, `AlpDevFree`, `AlpSeqAlloc`, `AlpSeqPut`,
`AlpSeqFree`, `AlpProjStart`, `AlpProjStartCont` are byte-identical across both headers.
`ALP_ID` typedef is `unsigned long` in both. `AlpSeqControl`, `AlpProjControl`, and
`AlpSeqTiming` (not formally audited but in scope) also appear with identical signatures.

### Critical new constant for DLP650LNIR_DMD.m

```c
#define ALP_DMDTYPE_WXGA_S450  12L   // 1280x800, DLP650LNIR for DLPC410
```

This constant is in the official header only (parot topped out at type 7). Use it when calling
`AlpDevControl(DeviceId, ALP_DEV_DMDTYPE, ALP_DMDTYPE_WXGA_S450)` during device init.

### Removed from official — do not use

| Symbol | Parot value | Action |
|---|---|---|
| `ALP_PROJ_SYNC` / `ALP_SYNCHRONOUS` / `ALP_ASYNCHRONOUS` | `2303–2305L` | Removed. Use `AlpProjWait` to block until completion. |
| `ALP_TRIGGER_TIME_OUT` / `ALP_TIME_OUT_ENABLE` / `ALP_TIME_OUT_DISABLE` | `2014L`, `0L`, `1L` | Removed. Official compat alias `ALP_VD_TIME_OUT` is a dangling reference — avoid both. |

### New in official (additive)

- `AlpSeqPutEx` — line-level partial sequence put; not needed for our primary load path.
- `ALP_CONFIG_MISMATCH 1021L`, `ALP_ERROR_UNKNOWN 1999L` — new error codes.
- `ALP_DMD_RESUME 0L` — explicit wake-up complement to `ALP_DMD_POWER_FLOAT`.
- `ALP_PROJ_ABORT_ASYNC 2345L` — immediate abort asynchronous to frame.
- `ALP_USB_DISCONNECT_BEHAVIOUR 2078L` — USB resilience control.
- `ALP_SEQ_CONFIG 2153L` — must precede `AlpSeqAlloc` when enabling bitplane-LUT-row mode.

### Phase 3 implementation notes for DLP650LNIR_DMD.m

- **`ALP_PROJ_ABORT_ASYNC (2345L)`** — wire into `DLP650LNIR_DMD.cleanup()` / the abort path
  called by `Sequencer.abort()`. This is the correct mid-sequence halt: it stops the DMD
  immediately without waiting for end-of-frame, matching the "Pockels-cell-closed-on-abort"
  safety principle — the DAQ closes the beam in parallel, and the DMD should not linger on the
  current pattern.

- **`ALP_CONFIG_MISMATCH (1021L)` and `ALP_ERROR_UNKNOWN (1999L)`** — add named-case handling
  in the error-translation helper (the function that maps ALP return codes to `tfp:hardware`
  error identifiers). Without explicit cases these will silently fall through to a generic error,
  making diagnosis on the scope PC harder.

- **`ALP_USB_DISCONNECT_BEHAVIOUR (2078L)`** — set explicitly in `initialize()`, do not accept
  the power-on default. Recommended: `ALP_USB_RESET` (stop sequence and DLP on disconnect) so
  a cable pull is treated as a fault rather than a silent continue. Matches fail-loudly principle.

- **`AlpSeqPutEx` and `ALP_SEQ_CONFIG`** — NOT needed for Phase 3 minimum viable path (binary
  1-bit patterns, full-frame puts via `AlpSeqPut`). Flag as Phase 4+ if grayscale, bitplane-LUT,
  or partial-update workflows emerge.

### Verification task: CLOSED

The "diff against official alp.h" checklist item below is resolved. No action required before
writing `DLP650LNIR_DMD.m` beyond the notes above.

---

## References audited

1. [vendor/alp/reference/ALP4lib/src/ALP4.py](../vendor/alp/reference/ALP4lib/src/ALP4.py) — Python wrapper over the ALP-4.x high-speed API (`ctypes` calling `alp4395.dll` / `alpV42.dll` / etc.). Cleanest single-file API summary.
2. [vendor/alp/reference/parot-alptool/](../vendor/alp/reference/parot-alptool/) — MATLAB wrapper with ALP 4.3 support. **Also vendors the canonical Vialux C header** at [parot-alptool/alp.h](../vendor/alp/reference/parot-alptool/alp.h) (copied from an earlier ALP-4.3 installer — header banner reads "© 2004-2015 ViALUX GmbH" and "Version: 14"). That `alp.h` is the strongest signature source in the repo today.
3. [vendor/alp/reference/nakul-alp41/](../vendor/alp/reference/nakul-alp41/) — MATLAB wrapper for the **ALP Basic** API. Different API surface (different DLL `alp41basic.dll`, `Alpb*` prefix, no sequence/projection model). Not usable for sequence-based stimulation, only for device alloc/free/inquire mechanics.

## Function cross-reference table

| C function | Seen in `ALP4.py` (high-speed) | Seen in `parot-alptool` (high-speed) | Seen in `nakul-alp41` (BASIC) | Canonical C signature (from `parot-alptool/alp.h`) |
|---|---|---|---|---|
| `AlpDevAlloc` | yes — [ALP4.py:504](../vendor/alp/reference/ALP4lib/src/ALP4.py#L504) | yes — [alp.h:370](../vendor/alp/reference/parot-alptool/alp.h#L370); proto [alpV43x64proto.m:11-12](../vendor/alp/reference/parot-alptool/alpV43x64proto.m#L11-L12); wrapper [@alpapi/devalloc.m:35](../vendor/alp/reference/parot-alptool/@alpapi/devalloc.m#L35) | **not found** (only `AlpbDevAlloc` at [api_allocate.m:19](../vendor/alp/reference/nakul-alp41/api_allocate.m#L19)) | `long AlpDevAlloc(long DeviceNum, long InitFlag, ALP_ID* DeviceIdPtr)` |
| `AlpDevInquire` | yes — [ALP4.py:508-510](../vendor/alp/reference/ALP4lib/src/ALP4.py#L508-L510), [882](../vendor/alp/reference/ALP4lib/src/ALP4.py#L882) | yes — [alp.h:378](../vendor/alp/reference/parot-alptool/alp.h#L378); proto [alpV43x64proto.m:21-22](../vendor/alp/reference/parot-alptool/alpV43x64proto.m#L21-L22); wrapper [@alpapi/devinquire.m:36](../vendor/alp/reference/parot-alptool/@alpapi/devinquire.m#L36) | **not found** (only `AlpbDevInquire` at [api_inquire.m:39](../vendor/alp/reference/nakul-alp41/api_inquire.m#L39)) | `long AlpDevInquire(ALP_ID DeviceId, long InquireType, long *UserVarPtr)` |
| `AlpDevHalt` | yes — [ALP4.py:1216](../vendor/alp/reference/ALP4lib/src/ALP4.py#L1216) | yes — [alp.h:371](../vendor/alp/reference/parot-alptool/alp.h#L371); proto [alpV43x64proto.m:13-14](../vendor/alp/reference/parot-alptool/alpV43x64proto.m#L13-L14); wrapper [@alpapi/devhalt.m:30](../vendor/alp/reference/parot-alptool/@alpapi/devhalt.m#L30) | **not found** | `long AlpDevHalt(ALP_ID DeviceId)` |
| `AlpDevFree` | yes — [ALP4.py:1226](../vendor/alp/reference/ALP4lib/src/ALP4.py#L1226) | yes — [alp.h:372](../vendor/alp/reference/parot-alptool/alp.h#L372); proto [alpV43x64proto.m:15-16](../vendor/alp/reference/parot-alptool/alpV43x64proto.m#L15-L16); wrapper [@alpapi/devfree.m:30](../vendor/alp/reference/parot-alptool/@alpapi/devfree.m#L30) | **not found** (only `AlpbDevFree` at [api_free.m:16](../vendor/alp/reference/nakul-alp41/api_free.m#L16)) | `long AlpDevFree(ALP_ID DeviceId)` |
| `AlpSeqAlloc` | yes — [ALP4.py:579](../vendor/alp/reference/ALP4lib/src/ALP4.py#L579) | yes — [alp.h:384](../vendor/alp/reference/parot-alptool/alp.h#L384); proto [alpV43x64proto.m:23-24](../vendor/alp/reference/parot-alptool/alpV43x64proto.m#L23-L24); wrapper [@alpapi/seqalloc.m:36](../vendor/alp/reference/parot-alptool/@alpapi/seqalloc.m#L36) | **not found** (basic API has no sequence concept) | `long AlpSeqAlloc(ALP_ID DeviceId, long BitPlanes, long PicNum, ALP_ID *SequenceIdPtr)` |
| `AlpSeqPut` | yes — [ALP4.py:739](../vendor/alp/reference/ALP4lib/src/ALP4.py#L739) | yes — [alp.h:398-399](../vendor/alp/reference/parot-alptool/alp.h#L398-L399); proto [alpV43x64proto.m:33-34](../vendor/alp/reference/parot-alptool/alpV43x64proto.m#L33-L34); wrapper [@alpapi/seqput.m:33](../vendor/alp/reference/parot-alptool/@alpapi/seqput.m#L33) | **not found** (basic API uses `AlpbDevLoadRows` at [api_load.m:34](../vendor/alp/reference/nakul-alp41/api_load.m#L34) instead) | `long AlpSeqPut(ALP_ID DeviceId, ALP_ID SequenceId, long PicOffset, long PicLoad, void *UserArrayPtr)` |
| `AlpSeqFree` | yes — [ALP4.py:1158](../vendor/alp/reference/ALP4lib/src/ALP4.py#L1158) | yes — [alp.h:385](../vendor/alp/reference/parot-alptool/alp.h#L385); proto [alpV43x64proto.m:25-26](../vendor/alp/reference/parot-alptool/alpV43x64proto.m#L25-L26); wrapper [@alpapi/seqfree.m:30](../vendor/alp/reference/parot-alptool/@alpapi/seqfree.m#L30) | **not found** | `long AlpSeqFree(ALP_ID DeviceId, ALP_ID SequenceId)` |
| `AlpProjStart` | yes — [ALP4.py:1195](../vendor/alp/reference/ALP4lib/src/ALP4.py#L1195) | yes — [alp.h:403](../vendor/alp/reference/parot-alptool/alp.h#L403); proto [alpV43x64proto.m:35-36](../vendor/alp/reference/parot-alptool/alpV43x64proto.m#L35-L36); wrapper [@alpapi/projstart.m:30](../vendor/alp/reference/parot-alptool/@alpapi/projstart.m#L30) | **not found** | `long AlpProjStart(ALP_ID DeviceId, ALP_ID SequenceId)` |
| `AlpProjStartCont` | yes — [ALP4.py:1190](../vendor/alp/reference/ALP4lib/src/ALP4.py#L1190) | yes — [alp.h:404](../vendor/alp/reference/parot-alptool/alp.h#L404); proto [alpV43x64proto.m:37-38](../vendor/alp/reference/parot-alptool/alpV43x64proto.m#L37-L38); wrapper [@alpapi/projstartcont.m:30](../vendor/alp/reference/parot-alptool/@alpapi/projstartcont.m#L30) | **not found** | `long AlpProjStartCont(ALP_ID DeviceId, ALP_ID SequenceId)` |

## ALP_ID typedef

`ALP_ID` is defined as `typedef unsigned long` at [parot-alptool/alp.h:41](../vendor/alp/reference/parot-alptool/alp.h#L41). All four parot-alptool prototype variants (`alpV1x32`, `alpV42x32`, `alpV42x64`, `alpV43x64`) declare `ulong`/`ulongPtr` for `ALP_ID` parameters, consistent with the header.

**Note on ALP4.py:** the Python wrapper uses `ct.c_long` (signed) for `SequenceId` — e.g. [ALP4.py:573](../vendor/alp/reference/ALP4lib/src/ALP4.py#L573) — when passing it to `AlpSeqAlloc`, `AlpSeqPut`, `AlpSeqFree`, `AlpProjStart`, and `AlpProjStartCont`. The header parameter type is `ALP_ID` (unsigned long). Same byte size on Windows x64 so it works in practice, but the strictly correct MATLAB binding type for sequence IDs is `uint32`/`ulong` (matching parot-alptool), not signed `long`.

## Findings

1. **Signature drift:** none material among the 9 audited functions across the high-speed references, beyond the `c_long` vs `ALP_ID` (unsigned long) discrepancy in ALP4.py noted above.
2. **Version specificity:** none. All 9 functions appear with identical signatures across the four parot-alptool prototype variants (V1/V42x32/V42x64/V43x64) — stable across ALP high-speed versions.
3. **Name variants:** nakul-alp41 uses `Alpb*` (note the lowercase `b`) — this is **not a spelling variant** of the high-speed API but a separate API ("ALP Basic"), with no sequence/projection concept. For fast pattern switching this reference is not usable.

## Verification needed when official installer arrives

- [x] Diff [vendor/alp/reference/parot-alptool/alp.h](../vendor/alp/reference/parot-alptool/alp.h) against the official `alp.h` shipped with the Vialux installer. **Done 2026-05-18** — see "Verified against official Vialux ALP-4.3 header" section above. All 9 functions and `ALP_ID` typedef verified identical; `AlpSeqControl`, `AlpProjControl`, `AlpSeqTiming` also identical. See Phase 3 implementation notes for actionable deltas.
