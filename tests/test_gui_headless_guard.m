classdef test_gui_headless_guard < matlab.unittest.TestCase
    %test_gui_headless_guard Structural guard on the GUI/logic split.
    %
    %   A uifigure cannot be constructed under matlab -nodisplay, so any
    %   decision that drifts into tfp.gui.CalibrationApp becomes permanently
    %   untestable. Reviews do not reliably catch that over six months of
    %   edits; this test does, mechanically, on every run.
    %
    %   Three invariants:
    %     1. CalibrationApp.m is the ONLY file under +gui/ allowed to touch
    %        graphics.
    %     2. Nothing under +gui/ may call a hardware-specific API — that rule
    %        is CLAUDE.md's, and it applies to the view as much as anywhere.
    %     3. LaserPowerController is the only caller of outputSingleAnalog in
    %        src/, so the interlock cannot be bypassed by a new call site.
    %
    %   Methods:
    %     onlyTheAppTouchesGraphics
    %     guiNeverTouchesHardwareApis
    %     onlyTheControllerDrivesTheModulator
    %     noMlappInTheRepo

    properties (Constant)
        GraphicsPat = 'uifigure|uiaxes|uicontrol|uitab|uigridlayout|uiconfirm|uialert|figure\(';
        HardwarePat = 'videoinput|imaqhwinfo|daqmx|ALP_|calllib|loadlibrary|mssend|msrecv';
    end

    methods (Access = private)
        function root = repoRoot(~)
            root = fileparts(fileparts(mfilename('fullpath')));
        end

        function files = guiFiles(testCase)
            d = dir(fullfile(testCase.repoRoot(), 'src', '+tfp', '+gui', '*.m'));
            files = fullfile({d.folder}, {d.name});
        end
    end

    methods (Test)

        function onlyTheAppTouchesGraphics(testCase)
            files = testCase.guiFiles();
            testCase.verifyNotEmpty(files, 'expected files under src/+tfp/+gui/');
            for k = 1:numel(files)
                [~, name] = fileparts(files{k});
                if strcmp(name, 'CalibrationApp')
                    continue
                end
                txt = fileread(files{k});
                txt = testCase.stripComments(txt);
                hit = regexp(txt, testCase.GraphicsPat, 'match', 'once');
                testCase.verifyEmpty(hit, sprintf( ...
                    ['%s.m contains graphics call ''%s''. Only CalibrationApp.m ' ...
                     'may touch graphics — everything else must stay runnable ' ...
                     'under matlab -nodisplay.'], name, hit));
            end
        end

        function guiNeverTouchesHardwareApis(testCase)
            files = testCase.guiFiles();
            for k = 1:numel(files)
                [~, name] = fileparts(files{k});
                txt = testCase.stripComments(fileread(files{k}));
                hit = regexp(txt, testCase.HardwarePat, 'match', 'once');
                testCase.verifyEmpty(hit, sprintf( ...
                    ['%s.m contains hardware-specific API ''%s''. CLAUDE.md: ' ...
                     'no code outside +hardware/ ever touches a hardware ' ...
                     'API — add it to the abstraction layer instead.'], name, hit));
            end
        end

        function onlyTheControllerDrivesTheModulator(testCase)
            % If a NEW call site starts driving AO directly, the pulse-energy
            % interlock and the confirmation dialog are both bypassed. Matches
            % method CALLS specifically, so code that merely inspects a DAQ log
            % for 'outputSingleAnalog' events is not flagged.
            %
            % The allow-list is deliberately explicit rather than a directory
            % rule, and each entry is there for a stated reason:
            %   LaserPowerController — the one sanctioned path.
            %   powerMeterSweep      — the FS-50 two-phase sweep for build A,
            %                          which predates the controller. Build B
            %                          uses powerMeterSweepSingle, which does
            %                          go through it.
            %   exp_ensemble_*       — build-A experiment scripts that drive
            %                          the FS-50 on ao3. Routing them through
            %                          the controller is worth doing, but it is
            %                          a separate change on a different rig;
            %                          listing them here keeps the guard honest
            %                          instead of quietly blessing everything.
            root = fullfile(testCase.repoRoot(), 'src');
            hits = testCase.grepTree(root, '\.outputSingleAnalog\s*\(');
            allowed = {'LaserPowerController.m', 'powerMeterSweep.m', ...
                       'exp_ensemble_activation.m', 'exp_ensemble_fill_factor_power.m'};
            for k = 1:numel(hits)
                [~, name, ext] = fileparts(hits{k});
                testCase.verifyTrue(ismember([name ext], allowed), sprintf( ...
                    ['%s calls outputSingleAnalog directly, bypassing ' ...
                     'tfp.hardware.LaserPowerController and therefore the ' ...
                     'pulse-energy interlock and the confirmation dialog.'], ...
                    [name ext]));
            end
            % And the sanctioned path must still be in the list of callers, so
            % this test cannot pass by the pattern silently matching nothing.
            names = cellfun(@(p) subsref(struct('n', {strsplit(p, filesep)}), ...
                substruct('.', 'n')), hits, 'UniformOutput', false);
            names = cellfun(@(c) c{end}, names, 'UniformOutput', false);
            testCase.verifyTrue(ismember('LaserPowerController.m', names), ...
                'the guard pattern matched nothing — it has stopped guarding');
        end

        function noMlappInTheRepo(testCase)
            % A .mlapp is a binary MAT container: undiffable, unreviewable,
            % unmergeable, and the guards above cannot read it.
            hits = dir(fullfile(testCase.repoRoot(), '**', '*.mlapp'));
            testCase.verifyEmpty(hits, ...
                'App Designer .mlapp files cannot be diffed or grepped; use a programmatic classdef.');
        end
    end

    methods (Access = private)

        function txt = stripComments(~, txt)
            % Crude but adequate: drop whole-line comments so a docstring may
            % legitimately mention uifigure while code may not.
            lines = strsplit(txt, newline);
            keep  = ~startsWith(strtrim(lines), '%');
            txt   = strjoin(lines(keep), newline);
        end

        function files = grepTree(testCase, root, pattern)
            files = {};
            d = dir(fullfile(root, '**', '*.m'));
            for k = 1:numel(d)
                p = fullfile(d(k).folder, d(k).name);
                txt = testCase.stripComments(fileread(p));
                if ~isempty(regexp(txt, pattern, 'once'))
                    files{end+1} = p; %#ok<AGROW>
                end
            end
        end
    end
end
