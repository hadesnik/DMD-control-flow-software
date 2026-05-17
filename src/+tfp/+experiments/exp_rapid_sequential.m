function result = exp_rapid_sequential(config, sessionName)
%exp_rapid_sequential Run a rapid sequential-targeting session and return summary results.
%   Same overall shape as exp_ppsf_lateral:
%     1. Load config (mock or real hardware)
%     2. Initialize DMD, DAQ, ScanImage bridge, load calibration
%     3. Pick target cells from a GCaMP FOV (interactive)
%     4. Generate a rapid-sequential trial sequence via tfp.trial.TrialSequence.generateRapidSequential
%     5. Run the sequencer
%     6. Quick-look analysis: per-cell raster across trials
%     7. Save full data + figure
error('not implemented');
end
