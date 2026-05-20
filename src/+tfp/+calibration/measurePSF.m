function calib = measurePSF(dmd, camera, sampleSlab, options)
%measurePSF Measure the temporal-focusing point-spread function on a thin slab.
%   Projects a single small DMD spot onto a thin fluorescent film and
%   captures images on the substage widefield camera. Fits a 2D Gaussian to
%   the intensity profile to extract lateral PSF widths (sigma_x, sigma_y).
%   Optionally steps the objective through a series of z positions to
%   characterise the axial PSF as well.
%
%   Temporal-focusing geometry note:
%     Lateral confinement is set by the DMD pixel size and the optical
%     magnification from DMD to sample. Axial confinement arises from
%     spectral dispersion at the grating: only at the nominal focal plane
%     does the full bandwidth recombine to produce a short pulse and
%     efficient 2-photon excitation. The axial PSF width (sigma_z) is
%     therefore the primary figure of merit for temporal focusing.
%
%   Required hardware:
%     dmd        - tfp.hardware.DMD-derived object (real or mock), initialised.
%                  Projects the calibration spot pattern.
%     camera     - tfp.hardware.SubstageCamera-derived object, initialised.
%                  Captures fluorescence images of the slab.
%                  NOTE: ScanImage cannot image DMD spots — it uses a PMT
%                  point detector, not a widefield camera. Use a substage
%                  camera only.
%     sampleSlab - struct describing the fluorescent sample:
%                    .zStage     tfp.hardware.ZStage-derived object for axial
%                                stepping (required when options.measureAxial
%                                is true; ignored otherwise).
%                    .thicknessUm  nominal slab thickness in µm (informational).
%                    .fluorophore  char, e.g. 'fluorescein', 'FITC' (informational).
%
%   Algorithm:
%     1. Project a single small spot (radius = options.spotRadiusPx DMD pixels)
%        at the DMD centre onto the fluorescent slab.
%     2. Capture one image per z position on the substage camera. At the
%        nominal focal plane (z = 0) this is the only image (lateral PSF only).
%     3. For each image, fit a 2D Gaussian:
%          I(x,y) = A * exp(-((x-x0)^2/(2*sx^2) + (y-y0)^2/(2*sy^2))) + B
%        Extract sigma_x, sigma_y in camera pixels; convert to µm via
%        options.umPerPixel.
%     4. If options.measureAxial is true, repeat steps 1-3 at each z position
%        in options.zPositionsUm (requires sampleSlab.zStage). Fit a Gaussian
%        to the integrated fluorescence vs. z to obtain sigma_z.
%     5. Store all results in the output calib struct.
%
%   calib = measurePSF(dmd, camera, sampleSlab)
%   calib = measurePSF(dmd, camera, sampleSlab, options)
%
%   options fields (all optional):
%     .spotRadiusPx   — test-spot radius on DMD in pixels (default 3)
%     .exposureS      — camera exposure / settle time per capture (s) (default 0.05)
%     .umPerPixel     — camera pixel size at sample plane (µm/px) (default 1.56)
%     .measureAxial   — if true, step z and measure axial PSF (default false)
%     .zPositionsUm   — z positions relative to nominal focus (µm)
%                       (default linspace(-30, 30, 13), used when measureAxial true)
%     .nAverages      — frames averaged per z position (default 3)
%     .showFigure     — display diagnostic figure on completion (default true)
%     .saveImages     — store raw frames in calib.images (default false)
%     .notes          — char appended to calib.notes
%
%   Output calib struct:
%     .sigmaXUm       — lateral PSF 1/e half-width in x at focus (µm)
%     .sigmaYUm       — lateral PSF 1/e half-width in y at focus (µm)
%     .fwhmXUm        — FWHM in x (µm) = 2*sqrt(2*log(2))*sigmaXUm
%     .fwhmYUm        — FWHM in y (µm)
%     .sigmaZUm       — axial PSF 1/e half-width (µm); [] if not measured
%     .fwhmZUm        — axial FWHM (µm); [] if not measured
%     .zPositionsUm   — z positions sampled (µm); [] if not measured
%     .integratedF    — integrated fluorescence at each z (a.u.); [] if not measured
%     .spotCenterDMD  — [col, row] DMD pixel of the test spot
%     .gaussFitFocus  — fit-parameter vector [A, x0, y0, sx, sy, B] at focus
%     .umPerPixel     — camera pixel size used (µm/px)
%     .timestamp      — datetime of measurement
%     .notes          — string
%     .images         — cell array of raw frames; {} if options.saveImages false
%
%   See also tfp.calibration.alignDMDtoCamera, tfp.calibration.powerMeterSweep.

error('tfp:calibration:measurePSF:notImplemented', ...
    ['measurePSF is not yet implemented. ' ...
     'Implement when substage camera and z-stage hardware are available.']);
end
