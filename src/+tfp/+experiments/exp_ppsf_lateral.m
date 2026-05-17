function result = exp_ppsf_lateral(config, sessionName)
%exp_ppsf_lateral Run a lateral PPSF session and return summary results.
%   Steps (per ARCHITECTURE.md "+tfp.+experiments"):
%     1. Load config (mock or real hardware)
%     2. Initialize DMD, DAQ, ScanImage bridge, load calibration
%     3. Pick target cells from a GCaMP FOV (interactive)
%     4. Generate a PPSF trial sequence via tfp.trial.TrialSequence.generatePPSF
%     5. Run the sequencer
%     6. Quick-look analysis: fit a falloff curve
%     7. Save full data + figure
error('not implemented');
end
