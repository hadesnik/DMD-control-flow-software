classdef test_calibration_report < matlab.unittest.TestCase
    %test_calibration_report The dated folder a calibration session leaves.
    %
    %   The report is the deliverable of a bringup session: months later it
    %   is the only account of what the rig measured on a given day and
    %   whether anyone judged it good. These tests cover the properties that
    %   make it usable then rather than just written now.
    %
    %   Methods:
    %     writesADatedFolderPerSession
    %     recordsAStepAsSoonAsItCompletes
    %     retakeReplacesTheEntryAndCountsAttempts
    %     reportIsSelfContained
    %     everyVerdictShowsItsColourAndItsNumbers
    %     aSecondSessionOnTheSameDayGetsItsOwnFolder
    %     operatorNotesSurviveARewrite

    properties
        tmpDir
    end

    methods (TestMethodSetup)
        function makeTmp(testCase)
            testCase.tmpDir = tempname();
            mkdir(testCase.tmpDir);
        end
    end

    methods (TestMethodTeardown)
        function removeTmp(testCase)
            if isfolder(testCase.tmpDir), rmdir(testCase.tmpDir, 's'); end
        end
    end

    methods (Test)

        function writesADatedFolderPerSession(testCase)
            r = tfp.gui.CalibrationReport(testCase.tmpDir, 'bringup', ...
                struct('gitHash', 'abc1234'));
            [~, name] = fileparts(r.dir);
            testCase.verifyMatches(name, '^\d{4}-\d{2}-\d{2}_bringup');
            testCase.verifyTrue(isfolder(fullfile(r.dir, 'steps')));
            testCase.verifyTrue(isfolder(fullfile(r.dir, 'figures')));
        end

        function recordsAStepAsSoonAsItCompletes(testCase)
            % Written per step, not at the end: the record has to survive a
            % crashed MATLAB or an operator who walks away mid-procedure.
            r = testCase.makeReport();
            [step, result, verdict] = testCase.sampleStep('pass');
            r.recordStep(step, result, verdict);

            testCase.verifyTrue(isfile(r.htmlPath()));
            testCase.verifyTrue(isfile(fullfile(r.dir, 'report.json')));
            testCase.verifyTrue(isfile(fullfile(r.dir, 'steps', [step.id '.json'])));
            testCase.verifyTrue(isfile(fullfile(r.dir, 'steps', [step.id '.mat'])));

            loaded = load(fullfile(r.dir, 'steps', [step.id '.mat']));
            testCase.verifyEqual(loaded.result.fit.r2, result.fit.r2);

            html = fileread(r.htmlPath());
            testCase.verifySubstring(html, step.title);
            testCase.verifySubstring(html, verdict.headline);
        end

        function retakeReplacesTheEntryAndCountsAttempts(testCase)
            % A retaken step must not appear twice — but how many attempts it
            % took is itself worth knowing when reading a calibration back.
            r = testCase.makeReport();
            [step, result, bad] = testCase.sampleStep('adjust');
            r.recordStep(step, result, bad, struct('attempt', 1));
            [~, ~, good] = testCase.sampleStep('pass');
            r.recordStep(step, result, good, struct('attempt', 2));

            testCase.verifyEqual(numel(r.entries), 1);
            testCase.verifyEqual(r.entries.attempt, 2);
            testCase.verifyEqual(r.entries.verdict, 'pass');

            html = fileread(r.htmlPath());
            testCase.verifySubstring(html, 'Attempt 2');
            testCase.verifyEqual(count(html, ['id="' step.id '"']), 1);
        end

        function reportIsSelfContained(testCase)
            % Read on a rig PC that often has no network, and published as an
            % artifact where external stylesheets and images are blocked
            % outright. An external reference is a broken page in both places.
            r = testCase.makeReport();
            [step, result, verdict] = testCase.sampleStep('warn');
            r.recordStep(step, result, verdict);
            html = fileread(r.htmlPath());

            testCase.verifyEmpty(regexp(html, 'src\s*=\s*"https?://', 'once'), ...
                'the report must not load remote images');
            testCase.verifyEmpty(regexp(html, '<link[^>]*stylesheet', 'once'), ...
                'the report must not load an external stylesheet');
            testCase.verifyEmpty(regexp(html, '<script', 'once'), ...
                'the report needs no script, and a CSP would block it anyway');
            testCase.verifySubstring(html, '<style>');
        end

        function everyVerdictShowsItsColourAndItsNumbers(testCase)
            r = testCase.makeReport();
            for verdictName = {'pass', 'warn', 'adjust', 'fail'}
                [step, result, verdict] = testCase.sampleStep(verdictName{1});
                step.id = ['step_' verdictName{1}];
                r.recordStep(step, result, verdict);
            end
            html = fileread(r.htmlPath());
            for verdictName = {'pass', 'warn', 'adjust', 'fail'}
                testCase.verifySubstring(html, ...
                    sprintf('pill %s', verdictName{1}));
            end
            % And the measured value itself, not only the judgement.
            testCase.verifySubstring(html, '0.995');
        end

        function aSecondSessionOnTheSameDayGetsItsOwnFolder(testCase)
            % Two calibrations in one day is normal — a morning attempt and
            % an afternoon one after a bench change. The afternoon must not
            % overwrite the morning.
            a = tfp.gui.CalibrationReport(testCase.tmpDir, 'bringup');
            b = tfp.gui.CalibrationReport(testCase.tmpDir, 'bringup');
            testCase.verifyNotEqual(a.dir, b.dir);
            testCase.verifyTrue(isfolder(a.dir) && isfolder(b.dir));
        end

        function operatorNotesSurviveARewrite(testCase)
            r = testCase.makeReport();
            [step, result, verdict] = testCase.sampleStep('warn');
            r.recordStep(step, result, verdict);
            r.note(step.id, 'film looked bleached in the top left corner');
            html = fileread(r.htmlPath());
            testCase.verifySubstring(html, 'bleached in the top left');
        end
    end

    % =======================================================================
    methods (Access = private)

        function r = makeReport(testCase)
            r = tfp.gui.CalibrationReport(testCase.tmpDir, 'bringup', ...
                struct('gitHash', 'abc1234', 'hardwareKind', 'mock'));
        end

        function [step, result, verdict] = sampleStep(~, verdictName)
            steps = tfp.gui.bringupSteps();
            step = steps(strcmp({steps.id}, 'field_tilt'));
            result = struct('fit', struct('aUmPerUm', 0.0284, 'bUmPerUm', 1e-4, ...
                'cUm', 0, 'r2', 0.995), ...
                'focusAtWindowEdge', false(1, 9), ...
                'sanity', struct('gradientInBand', true, 'walkInBand', true));
            verdict = tfp.gui.stepVerdict(step, result);
            verdict.verdict  = verdictName;
            verdict.headline = sprintf('Synthetic %s verdict for the report test.', ...
                verdictName);
        end
    end
end
