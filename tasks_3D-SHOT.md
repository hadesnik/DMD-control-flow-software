# tasks_3D-SHOT.md — parallel build of the 3D-SHOT SLM power-curve feature

Branch: `3dshot-slm`. Plan of record: `~/.claude/plans/ok-i-actually-want-indexed-turing.md`
(read it for rationale). This file is the **interface contract** so independent
agents produce mutually-consistent code without seeing each other's work.

## Hard rules for every agent

- **Stay inside this repo.** Never create/edit/delete files outside
  `/Users/hillel/Dropbox/Vibe Code/DMD-control-flow-software/`.
- **Only touch the files your task assigns.** Do not edit another task's files,
  `runtests.m`, `CLAUDE.md`, or existing source. (Exception: Task 7 edits the two
  config YAMLs; Task 6 may add the experiment only.)
- **Do NOT run MATLAB** (`matlab -batch ...`) and do NOT run `git`. The
  orchestrator runs the full suite centrally to avoid MATLAB contention. You may
  read files freely.
- Match existing conventions exactly (see below). MATLAB target **R2023a**.
- Tests use `matlab.unittest.TestCase`; the project `runtests.m` auto-discovers
  any `tests/test_*.m` via `TestSuite.fromFolder` — no registration needed.

## Global conventions (from the existing codebase)

- Package code lives under `src/+tfp/...`. Call sibling package functions by full
  path, e.g. `tfp.patterns.threeDShot.lateralGratingPhase(...)`.
- Classes: abstract base + `Mock*` + real subclass. Constructor takes a config
  struct; `initialize(obj,config)` uses a **local** `configField(config,name,default)`
  helper (copy the 5-line helper into each file's `% --- Local helper ---` section).
- Private props use **trailing-underscore** (`mask_`, `state_`, `log_`).
- Every hardware/mock class keeps `log_ = struct('timestamp',{},'eventType',{},'payload',{})`,
  a private `logEvent(obj,type,payload)` that appends `datetime('now')`, and a
  public `getLog()` returning it.
- Error identifiers: `tfp:hardware:<Class>:<reason>`, `tfp:patterns:threeDShot:<fn>:<reason>`,
  `tfp:io:<fn>:<reason>`, `tfp:experiments:<caller>:<reason>`.
- Units: micrometres (µm) and radians internally; wavelength nm→µm at the boundary.
- Docstring on every public function/class (1-paragraph summary at top).
- **DIMS CONVENTION (load-bearing across tasks):** config uses `dims = [nCols, nRows]`.
  CGH params: `Nx = dims(1) = nCols`, `Ny = dims(2) = nRows`. A phase mask is
  `[Ny x Nx] = [nRows x nCols]`. The SLM device's `nCols = dims(1)`, `nRows = dims(2)`,
  so `loadPhaseMask` (which checks `[nRows nCols]`) matches a CGH mask exactly.
  Anything that builds a device + params from the same config MUST derive both
  from the same `dims`.

## Already written (Task 1 must NOT recreate these) — `src/+tfp/+patterns/+threeDShot/`

- `defaultParams(slmConfig)` → `params` struct with fields:
  `Nx, Ny, pitch_um, lambda_um, f_ft_um, mag, n, diskRadius_um, gsIters,
  gsWeighted, gsSeed, dx_focal_um` (`dx_focal_um = lambda_um*f_ft_um/(Nx*pitch_um)`).
- `lateralGratingPhase(dx_um, dy_um, params)` → `phiLat` (Ny×Nx rad):
  `2*pi*(fx*x_slm + fy*y_slm)`, `fx = dx_um/(lambda_um*f_ft_um)`. Centred grid
  `x=(j-(Nx+1)/2)*pitch_um`, `y=(i-(Ny+1)/2)*pitch_um`, `meshgrid(1:Nx,1:Ny)`.
- `axialLensPhase(dz_um, params)` → `phiAx` (Ny×Nx rad):
  `(pi*n*dz*mag^2)/(lambda_um*f_ft_um^2)*r2`, `r2=x^2+y^2`; `dz==0 → zeros`.
- `steeringPhase(target_xyz_um, params)` → `lateralGratingPhase + axialLensPhase`
  for one target (1×2 or 1×3, z optional).

## FFT / reconstruction convention (load-bearing — keep identical everywhere)

- SLM field `E = exp(1i*phi)` (phase-only, `|E|=1`).
- Forward (SLM→focal): `F = fftshift(fft2(ifftshift(E))) / sqrt(Nx*Ny)` (unitary).
- Focal-plane pixel size `params.dx_focal_um`; centre at `((Nx+1)/2,(Ny+1)/2)`.
- Target focal pixel for a target `(x,y)`: `mcol = round((Nx+1)/2 + x/dx_focal_um)`,
  `nrow = round((Ny+1)/2 + y/dx_focal_um)` (clamp to `[1,Nx]`/`[1,Ny]`),
  `li = sub2ind([Ny Nx], nrow, mcol)`.

---

## ROUND 1 — parallel authoring (7 disjoint tasks). No cross-edits.

### Task 1 — CGH math core + test
Files (all under `src/+tfp/+patterns/+threeDShot/`, plus one test):
- `quantizePhase.m`: `mask = quantizePhase(phi, params, lut)`. `phiWrap=mod(phi,2*pi)`.
  `lut` empty/`[]` → `mask = uint8(min(round(phiWrap/(2*pi)*255),255))`. Non-empty
  `lut` (256-vector of achieved phase per drive 0..255): map each desired phase to
  the nearest drive via `interp1(sort(mod(lut,2*pi)), drives_sorted, phiWrap,
  'nearest','extrap')`, return uint8. Pure.
- `loadPhaseLUT.m`: `lut = loadPhaseLUT(lutFile)`. Empty/`''`/missing → `[]`.
  `.mat` → first numeric field as a column vector; other ext → `readmatrix` →
  column vector. Error `tfp:patterns:threeDShot:loadPhaseLUT:fileNotFound` if a
  non-empty path doesn't exist. Read-only.
- `gerchbergSaxton.m`: `[phi, info] = gerchbergSaxton(targets_xyz_um, params, opts)`.
  Weighted GS (GSW) over the target points. ALGORITHM (implement exactly):
  ```
  N = size(targets_xyz_um,1); Nx=params.Nx; Ny=params.Ny;
  eta = ones(N,1); if opts has .efficiency & nonempty, eta = double(opts.efficiency(:));
  d = sqrt(1./eta); d = d / max(d);                 % desired per-cell amplitude
  % focal pixel indices li (see FFT convention above)
  % init phase:
  if opts.phaseInit nonempty -> phi = opts.phaseInit
  else accF = sum_k exp(1i*steeringPhase(targets(k,:),params)); phi = angle(accF);
  weighted = params.gsWeighted (default true); w = ones(N,1);
  for it=1:max(1,round(params.gsIters))
      E = exp(1i*phi);
      F = fftshift(fft2(ifftshift(E)))/sqrt(Nx*Ny);
      V = F(li); a = abs(V);
      if weighted, ad = a./d; w = w .* (mean(ad)./max(ad,eps)); end
      Ftar = complex(zeros(Ny,Nx)); Ftar(li) = w.*d.*exp(1i*angle(V));
      Enew = fftshift(ifft2(ifftshift(Ftar)))*sqrt(Nx*Ny);
      phi = angle(Enew);
      uniformity(it) = 1 - std(a)/mean(a); rms(it) = std(a./d);
  end
  % final metrics
  E=exp(1i*phi); F=fftshift(fft2(ifftshift(E)))/sqrt(Nx*Ny); V=F(li);
  cellIntensity = abs(V).^2; delivered = eta.*cellIntensity;
  perCellDeliveredFraction = mean(delivered)/(Nx*Ny);   % relative; %VERIFY absolute
  etaEffective = sum(delivered)/sum(abs(F(:)).^2);
  info = struct('weights',w,'cellIntensity',cellIntensity,'delivered',delivered, ...
     'perCellDeliveredFraction',perCellDeliveredFraction,'etaEffective',etaEffective, ...
     'uniformity',uniformity(:),'rms',rms(:),'nIters',it,'targetLinIdx',li);
  ```
  Deterministic (no RNG used by the superposition init). Pure.
- `composeHologram.m`: `[mask, phi, info] = composeHologram(targets_xyz_um, params, opts)`.
  `opts` optional with `.efficiency`, `.phaseInit`, `.lut`. Calls
  `[phi,info]=gerchbergSaxton(targets,params,opts)` then
  `mask=quantizePhase(phi,params, optsLutOrEmpty)`. `targets_xyz_um` is N×3 (N≥1).
- `reconstructFocalField.m`: `info = reconstructFocalField(mask, params, targets_xyz_um)`
  (3rd arg optional). `phi=double(mask)/255*2*pi; E=exp(1i*phi);
  F=fftshift(fft2(ifftshift(E)))/sqrt(Nx*Ny); I=abs(F).^2`. Returns
  `.intensity=I, .totalEnergy=sum(I(:))`. If targets given: `.cellIntensity=I(li)`
  (Nx1) and `.centroid_um = [(mcol-cx)*dx_focal_um, (nrow-cy)*dx_focal_um]` (Nx2).
  Else global-peak centroid (1×2) + `.cellIntensity` = peak value. Pure.
- `tests/test_threeDShot_cgh.m`: assert (use small dims for speed, e.g.
  `params = defaultParams(struct('dims',[256 256],'gsIters',12))`):
  (a) `composeHologram` returns uint8 `[Ny Nx]`, values 0..255; one 1024²
  call returns `[1024 1024]`. (b) single target `[dx 0 0]`: reconstruct (pass
  targets) → `centroid_um(1)` ≈ dx within `±dx_focal_um`; sweep a few dx, slope≈1.
  **If the centroid sign is inverted, FLIP the sign in your OWN test expectation
  is NOT allowed — instead note it; do not edit lateralGratingPhase.** (The
  orchestrator will reconcile sign centrally.) Just assert `abs(centroid)` ≈
  `abs(dx)` and monotonic to de-risk sign. (c) pure-dx grating leaves
  `abs(centroid_um(2))` small. (d) multi-target (e.g. 4 targets): reconstruct →
  each target pixel intensity well above background; with `opts.efficiency` a
  synthetic non-uniform η, `delivered` (= η.*cellIntensity) has lower
  coefficient-of-variation than `cellIntensity` (correction equalizes). (e) GS
  `info.uniformity(end) >= info.uniformity(1)`. (f) determinism: two calls equal.
  (g) `quantizePhase`: phi=0 → 0; identity LUT path. (h) `defaultParams` fallbacks.

### Task 2 — CGH calibration parsers + target validator + tests
- `src/+tfp/+patterns/+threeDShot/loadSLMScanCalibration.m`:
  `calib = loadSLMScanCalibration(file)`. Empty/`''`/missing → identity:
  `struct('affine',eye(3),'type','identity','zDefault',0,'source','identity')`.
  Non-empty → require `.mat` with `scanToSlm_affine` (3×3); optional `zDefault`.
  → `struct('affine',...,'type','affine','zDefault',...,'source',file)`.
  Errors `:fileNotFound`, `:badSchema`. **%VERIFY** comment: real file schema TBD
  (user supplies later).
- `mapScanToSLM.m`: `slm_xyz = mapScanToSLM(siCentroids_Nx2, calib)`. Homogeneous
  apply `calib.affine` to `[x y 1]'`; output N×3 `[x y z]`, `z = calib.zDefault`.
  Pure.
- `loadEfficiencyMap.m`: `effMap = loadEfficiencyMap(file)`. Empty → uniform:
  `struct('type','uniform','source','uniform')`. Non-empty `.mat` with
  `eff`(matrix),`x_um`(vec),`y_um`(vec) → `struct('type','grid','eff',...,
  'x_um',...,'y_um',...,'source',file)`. Errors `:fileNotFound`,`:badSchema`. **%VERIFY**.
- `efficiencyAtTargets.m`: `eta = efficiencyAtTargets(targets_xyz, effMap)` → Nx1.
  `uniform` → ones. `grid` → `interp2(x_um,y_um,eff,xq,yq,'linear',NaN)`;
  out-of-range/≤0 → `min(eff(:))`. Pure.
- `src/+tfp/+util/validateSLMTargets.m`:
  `targets = validateSLMTargets(targets, slmParams, callerId)`. Input N×2 or N×3
  (SLM sample µm). Coerce to N×3 (z=0 if 2D). Read via local configField:
  `maxCells` (default 20), `addressableRadiusUm` (default inf), `minSpacingUm`
  (default 0). Drop targets with `hypot(x,y) > addressableRadiusUm`; greedy-reject
  the later of any pair closer than `minSpacingUm`; cap to first `maxCells`.
  Errors `tfp:experiments:<callerId>:badTargets` (bad shape) and
  `:noTargetsInField` (none survive radius). Return accepted N×3. Pure.
- `tests/test_threeDShot_calibration.m`: identity calib + `mapScanToSLM` round-trips
  a known 3×3 affine (build a translate+scale affine, check mapping); uniform
  effMap → ones; synthetic grid effMap → `efficiencyAtTargets` interpolates
  expected values; `loadSLMScanCalibration('')`/`loadEfficiencyMap('')` give
  identity/uniform.
- `tests/test_validateSLMTargets.m`: cap at maxCells; drop beyond
  addressableRadiusUm; reject pairs below minSpacingUm; valid central set returns
  unchanged (same N×3); bad shape → `:badTargets`.

### Task 3 — SLM display-device layer + tests
- `src/+tfp/+hardware/SLM.m` (abstract, `classdef SLM < handle`): abstract props
  `nRows,nCols,pitch_um,isInitialized`; abstract methods
  `initialize(obj,config), loadPhaseMask(obj,mask), present(obj), blank(obj),
  slmPower(obj,onTF), getStatus(obj), cleanup(obj)`. Concrete (non-abstract)
  `displayPhase(obj,mask)` = `loadPhaseMask`+`present`. Doc: state machine
  `idle→loaded→presenting`; display device only, no holography.
- `src/+tfp/+hardware/MockSLM.m < tfp.hardware.SLM` (model on MockPLM.m):
  props `nRows=[],nCols=[],pitch_um=[],isInitialized=false`; private
  `mask_,state_('idle'),powerOn_(false),log_,debugFigure_`. `initialize` reads
  `dims`([nCols nRows], default [1024 1024]) → `nCols=dims(1)`,`nRows=dims(2)`
  (use explicit `nRows`/`nCols` fields if present); `pitch_um`(17),
  `debugFigure`(false) via configField, logs. `loadPhaseMask` validates uint8 (`:badMask`) and size
  `[nRows nCols]` (`:badMaskShape`), stores, state→`loaded`, logs. `present`
  state→`presenting`, logs (if debugFigure, log a `renderToDebugFigure` event —
  do NOT draw). `blank` sets `mask_=zeros(nRows,nCols,'uint8')`, state→`presenting`,
  logs. `slmPower(onTF)` sets `powerOn_=logical(onTF)`, logs. `getStatus` →
  `struct('state',state_,'isMaskLoaded',~isempty(mask_),'powerOn',powerOn_)`.
  `getActivePattern` returns `mask_`. `cleanup` resets, logs. `getLog`. Error ids
  `tfp:hardware:MockSLM:*` incl `:notInitialized`.
- `tests/test_MockSLM.m` (model on test_MockPLM.m): init sets props/isInitialized;
  loadPhaseMask validation (`:badMask` non-uint8, `:badMaskShape` wrong size);
  state transitions idle→loaded→presenting; displayPhase = load+present (log
  order); blank → all-zero mask + presenting; slmPower toggles getStatus.powerOn;
  getActivePattern returns mask; getLog ordering (initialize first); cleanup
  clears.
- `src/+tfp/+hardware/Meadowlark1024_SLM.m < tfp.hardware.SLM` (model on
  DLP650LNIR_DMD.m): constructor `Meadowlark1024_SLM(config)` calls `initialize`.
  `initialize` does `loadlibrary('Blink_SDK_C.dll','Blink_SDK_C_matlab.h')` then
  `calllib` `Create_SDK`/`Set_true_frames`/`Write_cal_buffer`/`Load_linear_LUT`/
  `SLM_power(true)`. Map: `loadPhaseMask` stores; `present`/`blank` →
  `Write_overdrive_image` (mask vs zeros); `slmPower`→`SLM_power`. Private
  `checkBlink(ret,fn)` throws `tfp:hardware:Meadowlark1024_SLM:blinkError` using
  `Get_last_error_message`. `cleanup` best-effort `SLM_power(false)`→`Delete_SDK`→
  `unloadlibrary`, never throws. **Every Blink signature wrapped in a `%VERIFY`
  ASSUME/TEST/CHANGE comment block** (mirror DLP650LNIR_DMD.m). On a Mac (no DLL),
  `initialize` must throw a CLEAN `tfp:hardware:Meadowlark1024_SLM:libLoadFailed`
  (wrap the loadlibrary in try/catch and rethrow with that id) — NOT a raw
  loadlibrary crash. config fields via configField: `dims`(default [1024 1024]),
  `pitch_um`(17), `dllPath`(''), `headerPath`(''), `lutFile`('').
- `tests/test_Meadowlark1024_SLM_stub.m`: on this Mac, constructing/initializing
  throws `tfp:hardware:Meadowlark1024_SLM:libLoadFailed` (use verifyError with the
  id; if the DLL somehow loads, skip via assumeFail is fine).

### Task 4 — controller + shared dispatcher + tests
- `src/+tfp/+io/slmDispatch.m`: `reply = slmDispatch(slm, ctx, op, payload)`.
  `ctx = struct('params',params,'calib',calib,'effMap',effMap)`. `slm` is an SLM
  device (Mock or real). Ops:
  - `'projectTargets'`: `payload` = N×2 SI centroids (or N×3 already-SLM if
    `ctx.calib.type=='identity'` they pass through after map). Steps:
    `slm_xyz = tfp.patterns.threeDShot.mapScanToSLM(payload, ctx.calib);`
    `slm_xyz = tfp.util.validateSLMTargets(slm_xyz, ctx.params, 'slmDispatch');`
    `eta = tfp.patterns.threeDShot.efficiencyAtTargets(slm_xyz, ctx.effMap);`
    `[mask,~,info] = tfp.patterns.threeDShot.composeHologram(slm_xyz, ctx.params, struct('efficiency',eta));`
    `slm.loadPhaseMask(mask); slm.present();`
    `reply = struct('op','projectTargets','ok',true,'nAccepted',size(slm_xyz,1),
       'perCellDeliveredFraction',info.perCellDeliveredFraction,'etaEffective',info.etaEffective);`
    NOTE: `ctx.params` must ALSO carry the validation fields (`maxCells`,
    `addressableRadiusUm`, `minSpacingUm`) so validateSLMTargets sees them — the
    orchestrator builds `ctx.params` by merging `defaultParams(slmConfig)` with
    those three fields copied from slmConfig. So validateSLMTargets reads them off
    `ctx.params`. (Document this in the dispatch docstring.)
  - `'blank'`: `slm.blank()`; reply ok.
  - `'slmPower'`: `slm.slmPower(payload)`; reply ok.
  - `'ping'`: reply `ok=true,'status',slm.getStatus()`.
  - `'shutdown'`: `slm.cleanup()`; reply ok, plus `'shutdown',true`.
  - unknown op → reply `ok=false,'error','unknown op'`. Wrap the body in try/catch
    → on error reply `struct('op',op,'ok',false,'error',ME.message)`.
- `src/+tfp/+hardware/RemoteSLM.m < handle` (NOT an SLM subclass; model the mode
  switch on ScanImageBridge.m). Constructor `RemoteSLM(config)`; `initialize`
  reads `connectionMode`('loopback'|'msocket'|'mock'→loopback), `slmPcIp`,
  `slmPort`(3046), `msocketPath`, `connectTimeoutS`(30), and the SLM/CGH config
  (it builds `ctx` for loopback). Public props `nRows=1024,nCols=1024,
  pitch_um=17,isInitialized`. Methods:
  - `initialize(obj,config)`: loopback → build `localSlm_ = MockSLM` (initialize
    it) and `ctx_ = struct('params',mergedParams,'calib',
    loadSLMScanCalibration(slmScanCalib_file),'effMap',loadEfficiencyMap(efficiencyMap_file))`
    where `mergedParams = defaultParams(config)` plus copied `maxCells/
    addressableRadiusUm/minSpacingUm`. msocket → `msconnect(ip,port)`, expect
    `hello` handshake (read `struct` with `.op=='hello'`); store `sock_`.
  - `res = projectTargets(obj, siCentroids)`: loopback →
    `reply = tfp.io.slmDispatch(obj.localSlm_, obj.ctx_, 'projectTargets', siCentroids)`;
    msocket → `mssend(sock_, struct('op','projectTargets','payload',siCentroids))`,
    `reply = msrecv(sock_, timeout)`. Return
    `res = struct('nAccepted',reply.nAccepted,'perCellDeliveredFraction',
    reply.perCellDeliveredFraction,'etaEffective',reply.etaEffective)`; error
    `tfp:hardware:RemoteSLM:projectFailed` if `~reply.ok`.
  - `blank`, `slmPower(onTF)`, `getStatus`: same loopback/msocket dispatch on
    ops `'blank'/'slmPower'/'ping'`.
  - `cleanup`: msocket → `msclose(sock_)` (best-effort); loopback → `localSlm_.cleanup()`.
  - `shutdownServer`: msocket → send `'shutdown'`. logs via getLog.
  - Add a test hook `getLocalSlm()` returning `localSlm_` (loopback) so tests can
    inspect the MockSLM's `getActivePattern`.
- `tests/test_slm_dispatch.m`: build `ctx` with `defaultParams(struct('dims',
  [256 256],'gsIters',8))` merged with maxCells=20/addressableRadiusUm=1e6/
  minSpacingUm=0, identity calib, uniform effMap, and a `MockSLM` (1024² —
  but use dims 256 in params; NOTE MockSLM must be initialized with nRows/nCols
  matching params dims, i.e. 256, so loadPhaseMask shape matches). Each op →
  `ok=true`, projectTargets returns numeric `nAccepted/perCellDeliveredFraction`,
  MockSLM ends `presenting` with a mask; unknown op → `ok=false`.
- `tests/test_RemoteSLM_loopback.m`: `RemoteSLM` in loopback (use small dims via
  config), `projectTargets(siCentroids)` returns res with finite
  `perCellDeliveredFraction`; `getLocalSlm().getActivePattern()` is uint8 of the
  configured size; `blank`/`slmPower(true)`/`getStatus` work; `'mock'` aliases
  loopback. **Keep dims small (e.g. config.dims=[128 128], gsIters=6) for speed.**

### Task 5 — SLM-PC server scripts (no MATLAB-run; scripts only)
- `scripts/slm_pc_setup/slm_pc_config.m` (model on
  `scripts/imaging_pc_setup/imaging_pc_config.m` — READ it first):
  `cfg = slm_pc_config()` returns struct with `.msocketPath`, `.slmPort`(3046),
  `.backend`('mock'|'meadowlark'), `.slmScanCalib_file`(''), `.efficiencyMap_file`(''),
  and `.slmConfig` (dims [1024 1024], pitch_um 17, lambda_nm 1030, f_ft_um, mag,
  n 1.33, lutFile '', gsIters 20, gsWeighted true, gsSeed 0, maxCells 20,
  addressableRadiusUm, minSpacingUm 15). Adds msocketPath to path if present;
  supports an optional gitignored `slm_pc_config_local.m` override (mirror imaging
  pattern). Mark rig values `%VERIFY`.
- `scripts/slm_pc_setup/slm_pc_server.m`: function/script that runs on the SLM PC.
  Build `params = tfp.patterns.threeDShot.defaultParams(cfg.slmConfig)` merged with
  maxCells/addressableRadiusUm/minSpacingUm copied from slmConfig;
  `calib=loadSLMScanCalibration(cfg.slmScanCalib_file)`,
  `effMap=loadEfficiencyMap(cfg.efficiencyMap_file)`,
  `ctx=struct('params',params,'calib',calib,'effMap',effMap)`. Build `slm` =
  `MockSLM` or `Meadowlark1024_SLM` per `cfg.backend`, initialize with slmConfig.
  Loop: `srvsock=mslisten(cfg.slmPort)`; `sock=msaccept(srvsock,timeout)`;
  `msclose(srvsock)`; send `mssend(sock, struct('op','hello','ok',true,'dims',[1024 1024]))`;
  inner loop `cmd=msrecv(sock, pollTimeout)`; dispatch via
  `reply=tfp.io.slmDispatch(slm, ctx, cmd.op, cmd.payload)`; `mssend(sock,reply)`;
  break inner on `shutdown`. Use the explicit-handle msocket API (no msdisconnect).
  `%VERIFY` the flat-struct round-trip note (fall back to op-header + bare array).
  This file is reference-only on the Mac; it won't be unit-tested.

### Task 6 — experiment + integration test
- `src/+tfp/+experiments/exp_power_curve_3dshot.m` (model on `exp_power_curve.m`
  and `exp_ppsf_lateral.m` — READ both):
  `result = exp_power_curve_3dshot(configOrPath, sessionName)`. Flow:
  1. `loadOrUseConfig` (local helper, copy from exp_power_curve); make `sessionDir`;
     `tfp.io.sessionLog(sessionDir,'session-start',struct('experiment',
     'exp_power_curve_3dshot','sessionName',char(sessionName)))`.
  2. `makeHardware`: mock → `MockDMD`+`MockDAQ` (initialize both with config.dmd/
     config.daq); real → `DLP650LNIR_DMD`+`NI6323_DAQ`. Configure DAQ AI/AO/DO from
     config.daq (mirror exp_power_curve lines 17-20). Build SLM:
     `slm = tfp.hardware.RemoteSLM(config.slm)` with `config.slm.connectionMode`
     = 'loopback' for mock, 'msocket' for real; `slm.initialize(config.slm)`.
     onCleanup teardown closure blanks+powers-off+cleans SLM and DMD/DAQ.
  3. Targets: mock → `siCentroids = config.mockTargets` (N×2). real →
     `siCentroids = tfp.io.receiveROIsFromScanImage(roiOpts)`.
  4. `slm.slmPower(true); res = slm.projectTargets(siCentroids); N = res.nAccepted;
     f = res.perCellDeliveredFraction;`
     `tfp.io.sessionLog(sessionDir,'slm-targets-projected',struct('n',N,'fraction',f))`.
  5. `perCell = config.powerCurve.perCellPowersMw; nReps = config.powerCurve.nReps;`
     `totalPowers = perCell(:).' ./ max(f,eps);` safety-clip each to
     `config.laser.modulation_voltage_max` (default 5) — warn+drop any above; if all
     dropped, error `tfp:experiments:exp_power_curve_3dshot:noFeasiblePowers`.
     `dummyTarget=[round(config.dmd.nCols/2) round(config.dmd.nRows/2)];`
     `sequence = tfp.trial.TrialSequence.generatePowerCurve(dummyTarget, totalPowers, nReps);`
     For each trial set `tr.metadata.perCellMw` (the per-cell value matching its
     total) and `tr.targetSpec.patternRef = tfp.patterns.singleSpot(dmd,dummyTarget,15);`
     (Map each trial's total back to perCell by index — replicate the
     rep-outer/power-inner order generatePowerCurve uses.) Optionally
     `tr.metadata.slmTargets` note. Honour `config.bringupMode` (short trials) like
     exp_power_curve.
  6. `sequencer = tfp.trial.Sequencer(dmd,daq,sequence,sessionDir);` run in
     try/catch logging `experiment-run-error` (verbatim from exp_power_curve).
  7. Build `result`: `sessionDir, nTrialsCompleted, nTrialsFailed,
     perCellPowersMw, nCells=N, perCellDeliveredFraction=f,
     summary = summarizeByPowerPerCell(sequence.trials, perCell)`. Local
     `summarizeByPowerPerCell`: for each cell c (column of `tr.data.aiData`) and
     each perCell level, average peak ΔF/F (reuse the `tracePeakResponse` pattern
     from exp_power_curve via `tfp.analysis.onlineDFF`) over reps → matrix
     `response(nCells, nPower)`. Return a struct with `.perCellMw` (1×nPower),
     `.response` (nCells×nPower), `.nCells`. Be defensive: if a trial lacks aiData
     skip; if fewer channels than cells, size to available.
  8. `sessionLog('session-end',...)`. Mirror exp_power_curve's helper structure
     (loadOrUseConfig/makeHardware/teardownHardware as local functions).
- `tests/test_exp_power_curve_3dshot_mock.m` (model on
  `test_exp_axial_ppsf_mock.m`): inline mock config with **small SLM dims**
  (`config.slm.dims=[128 128]`, `gsIters=6`, `connectionMode='loopback'`,
  `addressableRadiusUm=1e6`, `minSpacingUm=0`, `maxCells=20`, `slmScanCalib_file=''`,
  `efficiencyMap_file=''`, pitch_um 17, f_ft_um 16800, mag 1, n 1.33, lambda_nm
  1030), `config.powerCurve.perCellPowersMw=[1 2]`, `nReps=2`,
  `config.mockTargets = [0 0; 5 0; -5 0]` (3 cells in SLM µm; small),
  `config.dmd.*` (mock), `config.daq.*` with `analogInChannels=[0 1 2]`,
  `config.laser.modulation_voltage_max=5`, `config.paths.dataDir=tempname`,
  `config.fakeCells` 3 cells. Arm safety in TestMethodSetup
  (`tfp.util.safetyChecks('arm')`). Assert: `nTrialsCompleted = 2*2 = 4`;
  4 `_meta.mat` files all `status='complete'`; `result.summary.response` is
  `[nCells x 2]`; exactly one `projectTargets` happened before the sweep (inspect
  via session log having one `slm-targets-projected`); teardown blanked the SLM
  (no assert needed if hard; at least no error). Use `rmdirSafe` local helper.

### Task 7 — config additions (edits the two YAMLs)
- Append to `configs/mock.yaml` a flat `slm:` block and a `powerCurve:` block.
  `slm:` keys: `connectionMode: loopback`, `dims: [1024, 1024]`, `pitch_um: 17`,
  `lutFile: ""`, `slmPcIp: "127.0.0.1"`, `slmPort: 3046`, `msocketPath: ""`,
  `overdrive: false`, `lambda_nm: 1030`, `f_ft_um: 16800`, `mag: 1.0`,
  `NA_eff: 0.6`, `n: 1.33`, `diskRadius_um: 5`, `gsIters: 20`, `gsWeighted: true`,
  `gsSeed: 0`, `maxCells: 20`, `addressableRadiusUm: 150`, `minSpacingUm: 15`,
  `slmScanCalib_file: ""`, `efficiencyMap_file: ""`.
  `powerCurve:` keys: `perCellPowersMw: [1, 2, 4]`, `nReps: 2`.
  Also add `mockTargets` for SLM use is NOT needed in YAML (tests pass it inline);
  but DO ensure `daq.analogInChannels` stays as-is.
  NOTE the loadConfig parser supports one-level nesting + inline arrays `[a, b]`
  and quoted strings; keep keys flat under `slm:`/`powerCurve:`. Match the file's
  existing 2-space indent and comment style.
- Append the same `slm:` and `powerCurve:` blocks to `configs/real.yaml` but with
  `connectionMode: msocket`, real-ish placeholders, and `%VERIFY`-style `#` comments
  on `slmPcIp`, `lutFile`, `msocketPath`, `f_ft_um`, `mag`, `NA_eff`,
  `slmScanCalib_file`, `efficiencyMap_file` (READ real.yaml first to match style).

---

## ROUND 2 — central verification + fix (orchestrator only)
Run `matlab -batch "runtests"` from repo root. Triage failures; dispatch targeted
fix agents or fix inline. Re-run until: **baseline-passing count + all new tests
pass, 0 new failures.** Then `git add -A && git commit`.

## Progress log
- [done] Branch `3dshot-slm`; `defaultParams/lateralGratingPhase/axialLensPhase/steeringPhase` written.
- [done] Baseline canary: **182 total / 182 passed / 0 failed**.
- [done] Round 1 tasks 1-7 authored by 7 parallel agents (all files present).
- [done] Verify run1: 300 total / 293 passed / 7 failed (3 root causes):
  (a) experiment `tracePeakResponse` used `onlineDFF` on a 1-pixel column (collapses to 2-D) → rewritten inline;
  (b) `quantizePhase` LUT path: drive 0 and 255 both wrap to phase 0 → `interp1` non-unique → dedupe sample points;
  (c) `test_validateSLMTargets/testMinSpacingGreedyReject` expectation wrong (greedy-against-accepted keeps the 10 µm point) → test fixed;
  plus the experiment mock test's laser ceiling (5) clipped arbitrary-unit totalPowers → raised to 1e9 in the mock test.
- [done] Verify run2 after fixes: **300 total / 300 passed / 0 failed / 0 filtered**. No regressions vs the 182 baseline; 118 new tests green.
- [done] Committed on `3dshot-slm`.
- [pending] Polish pass + final full-suite run.
