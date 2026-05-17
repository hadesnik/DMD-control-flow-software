function result = exp_power_curve(config, sessionName)
%exp_power_curve Run a power-curve session at one target and return summary results.
%   Same overall shape as exp_ppsf_lateral:
%     1. Load config (mock or real hardware)
%     2. Initialize DMD, DAQ, ScanImage bridge, load calibration
%     3. Pick the target cell from a GCaMP FOV (interactive)
%     4. Generate a power-curve trial sequence via tfp.trial.TrialSequence.generatePowerCurve
%     5. Run the sequencer
%     6. Quick-look analysis: fit a dose-response curve at the target
%     7. Save full data + figure
error('not implemented');
end
