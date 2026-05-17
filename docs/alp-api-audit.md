# ALP API cross-reference audit

**Date:** 2026-05-16
**Status:** Pre-official-Vialux-installer baseline. Use this audit as the authoritative API surface for `+tfp/+hardware/DLP650LNIR_DMD.m` development until the official Vialux SDK installer arrives, after which this audit must be diffed against the official headers.

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

- [ ] Diff [vendor/alp/reference/parot-alptool/alp.h](../vendor/alp/reference/parot-alptool/alp.h) against the official `alp.h` shipped with the Vialux installer. The vendored copy is from an earlier ALP-4.3 release ("© 2004-2015", header version 14) — newer installers may have added functions or changed signatures. Pay particular attention to:
  - The 9 functions audited above (most critical — sequence playback path).
  - `AlpSeqControl`, `AlpProjControl`, `AlpSeqTiming` (used in our likely code path but not in this audit).
  - The `ALP_ID` typedef (unlikely to change, but confirm).
  - Any new `AlpProjControlEx` / `AlpSeqControlEx` struct types (FLUT, dynamic synch, mask, shear — these vary by version).
