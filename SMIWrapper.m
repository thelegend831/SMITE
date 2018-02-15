function fhndl = SMIWrapper(settings,scrInfo,textSetup)


% params
iView       = [];
debugLevel  = false;

if isnumeric(scrInfo) % bgColor only
    thecolor = scrInfo;
    clear scrInfo;
    scrInfo.rect    = Screen('Rect',0); scrInfo.rect(1:2) = [];
    scrInfo.center  = scrInfo.rect/2;
    scrInfo.bgclr   = thecolor;
end


% setup function handles
fhndl.init              = @init;
fhndl.calibrate         = @calibrate;
fhndl.startRecording    = @startRecording;  % NB: stops any previous recording and throws away all recorded data. So only call at start of experiment
fhndl.pauseRecording    = @pauseRecording;
fhndl.continueRecording = @continueRecording;
fhndl.stopRecording     = @stopRecording;
% NB: consider using: % calllib('iViewXAPI','iV_SendImageMessage','msg_string') 
% directly whenever you want to store a message in the data file to ensure
% minimum overhead.
fhndl.sendMessage       = @sendMessage;
fhndl.isConnected       = @isConnected;
fhndl.saveData          = @saveData;
fhndl.cleanUp           = @cleanUp;
fhndl.processError      = @processError;
        
    function out = init(input1)
        debugLevel = input1;
        
        % setup colors
        settings.cal.fixBackColor = color2RGBA(settings.cal.fixBackColor);
        settings.cal.fixFrontColor= color2RGBA(settings.cal.fixFrontColor);
        
        % Load in plugin, create structure with function wrappers
        iView = iViewXAPI();
        
        % Create logger file
        if debugLevel&&0    % forced switch off as 2 always crashes on the second invocation of setlog...
            logLvl = 1+2+8+16;  % 4 shows many internal function calls as well. as long as the server is on, it is trying to track. so every x ms you have a record of the output of the function that calculates gaze position...
        else
            logLvl = 1;
        end
        ret = iView.setLogger(logLvl, settings.logFileName);
        if ret ~= 1
            error('Logger at "%s" could not be opened (error %d: %s)',settings.logFileName,ret,SMIErrCode2String(ret));
        end
        
        % Connect to server
        iView.disconnect();  % disconnect first, found this necessary as API otherwise apparently does not recognize it when eye tracker server crashed or closed by hand while connected. Well, calling 'iV_IsConnected' twice seems to work...
        ret = iView.start(settings.etApp);  % returns 1 when starting app, 4 if its already running
        qStarting = ret==1;
        
        % connect
        ret = connect(iView,settings.connectInfo);
        if qStarting && ret~=1
            % in case eye tracker server is starting, give it some time
            % before trying to connect, don't hammer it unnecessarily
            iView.setConnectionTimeout(1);   % "timeout for how long iV_Connect tries to connect to iView eye tracking server." server startup is slow, give it a lot of time to try to connect.
            count = 1;
            while count < 30 && ret~=1
                ret = connect(iView,settings.connectInfo);
                count = count+1;
            end
        end
        
        switch ret
            case 1
                % connected, we're good. nothing to do here
            case 104
                error('SMI: Could not establish connection. Check if Eye Tracker is running (error 104: %s)',SMIErrCode2String(ret));
            case 105
                error('SMI: Could not establish connection. Check the communication ports (error 105: %s)',SMIErrCode2String(ret));
            case 123
                error('SMI: Could not establish connection. Another process is blocking the communication ports (error 123: %s)',SMIErrCode2String(ret));
            case 201
                error('SMI: Could not establish connection. Check if Eye Tracker is installed and running (error 200: %s)',SMIErrCode2String(ret));
            otherwise
                error('SMI: Could not establish connection (error %d: %s)',ret,SMIErrCode2String(ret));
        end
        
        % Set debug mode with iView.setupDebugMode(1) not supported on
        % REDm it seems
        
        % setup device geometry
        ret = iView.selectREDGeometry(settings.geomProfile);
        assert(ret==1,'SMI: Error selecting geometry profile (error %d: %s)',ret,SMIErrCode2String(ret));
        % get info about the setup
        [~,out.geom] = iView.getCurrentREDGeometry();
        % get info about the system
        [~,out.systemInfo] = iView.getSystemInfo();
        % check operating at requested tracking frequency (the command
        % to set frequency is only supported on the NG systems...)
        assert(out.systemInfo.samplerate == settings.freq,'Tracker not running at requested sampling rate (%d Hz), but at %d Hz',settings.freq,out.systemInfo.samplerate);
        % setup track mode
        ret = iView.setTrackingParameter(['ET_PARAM_' settings.trackEye], ['ET_PARAM_' settings.trackMode], 1);
        assert(ret==1,'SMI: Error selecting tracking mode (error %d: %s)',ret,SMIErrCode2String(ret));
        % switch off averaging filter so we get separate data for each eye
        ret = iView.configureFilter('Average', 'Set', 0);
        assert(ret==1,'SMI: Error configuring averaging filter (error %d: %s)',ret,SMIErrCode2String(ret));
    end

    function out = calibrate(wpnt,qClearBuffer)
        % this function does all setup, draws the interface, etc
        
        % by default don't clear recording buffer. You DO NOT want to do
        % that when recalibrating, e.g. in the middle of the trial, or at
        % second attempt
        if nargin<2
            qClearBuffer = false;
        end
        
        %%% 1: set up calibration
        CalibrationData = getSMIStructEnum('CalibrationStruct');
        CalibrationData.method = settings.cal.nPoint;
        % Setup calibration look. Necessary in all cases so that validate
        % image looks similar to calibration stimuli
        CalibrationData.foregroundBrightness = settings.cal.fixBackColor(1);
        CalibrationData.backgroundBrightness = settings.cal.bgColor(1);
        CalibrationData.targetSize           = max(10,round(settings.cal.fixBackSize/2));   % 10 is the minimum size. Ignored for validation image...
        CalibrationData.visualization        = 0;   % we draw fixation points ourselves
        ret = iView.setupCalibration(CalibrationData);
        processError(ret,'SMI: Error setting up calibration');
        
        % change calibration points if wanted
        if ~isempty(settings.cal.pointPos)
            error('Not implemented')
            % TODO
            % be careful! "If this function is used with a RED or RED-m
            % device, the change is applied to the currently selected
            % profile." So we better first make a temp profile or so that
            % we then use...
            % iV_ChangeCalibrationPoint ( int number, int positionX, int positionY )
        end
        % get where the calibration points are
        pCalibrationPoint = getSMIStructEnum('CalibrationPointStruct');
        out.calibrationPoints = struct('X',zeros(1,settings.cal.nPoint),'Y',zeros(1,settings.cal.nPoint));
        for p=1:settings.cal.nPoint
            iView.getCalibrationPoint(p, pCalibrationPoint);
            out.calibrationPoints.X(p) = pCalibrationPoint.positionX;
            out.calibrationPoints.Y(p) = pCalibrationPoint.positionY;
        end
        
        %%% 2: enter the screens, from setup to validation results
        kCal = 0;
        
        % The below is a big loop that will run possibly multiple
        % calibration until exiting because skipped or a calibration is
        % selected by user.
        % there are three start modes:
        % 0. skip head positioning, go straight to calibration
        % 1. start with simple head positioning interface
        % 2. start with advanced head positioning interface
        startScreen = settings.setup.startScreen;
        while true
            kCal = kCal+1;
            if startScreen>0
                %%% 2a: show head positioning screen
                status = showHeadPositioning(wpnt,iView,scrInfo,settings,textSetup,startScreen,debugLevel);
                switch status
                    case 1
                        % all good, continue
                    case 2
                        % skip setup
                        break;
                    case -3
                        % full stop
                        error('run ended from SMI calibration routine')
                    otherwise
                        error('status %d not implemented',status);
                end
            end
            
            %%% 2b: calibrate and validate
            [out.attempt{kCal}.calStatus,temp] = DoCalAndVal(wpnt,iView,settings.cal,@startRecording,qClearBuffer,@stopRecording,@sendMessage);
            warning('off','catstruct:DuplicatesFound')  % field already exists but is empty, will be overwritten with the output from the function here
            out.attempt{kCal} = catstruct(out.attempt{kCal},temp);
            % qClearbuffer should now become false even if it was true, as
            % buffer has been cleared in calibration lines above
            qClearBuffer = false;
            % check returned action state
            switch out.attempt{kCal}.calStatus
                case 1
                    % all good, continue
                case 2
                    % skip setup
                    break;
                case -1
                    % restart calibration
                    startScreen = 0;
                    continue;
                case -2
                    % go to setup
                    startScreen = max(1,startScreen);
                    continue;
                case -3
                    % full stop
                    error('run ended from SMI calibration routine')
                otherwise
                    error('status %d not implemented',out.attempt{kCal}.calStatus);
            end
            
            % check calibration status to be sure we're calibrated
            [~,out.attempt{kCal}.calStatusSMI] = iView.getCalibrationStatus();
            if ~strcmp(out.attempt{kCal}.calStatusSMI,'calibrationValid')
                % retry calibration
                startScreen = max(1,startScreen);
                continue;
            end
            
            % store calibration so user can select which one they want
            iView.saveCalibration(num2str(kCal));
            
            %%% 2c: show calibration results
            % get info about accuracy of calibration
            [~,out.attempt{kCal}.validateAccuracy] = iView.getAccuracy([], 0);
            % get validation image
            [~,out.attempt{kCal}.validateImage] = iView.getAccuracyImage();
            % show validation result and ask to continue
            [out.attempt{kCal}.valResultAccept,out.attempt{kCal}.calSelection] = showValidationResult(wpnt,out.attempt,kCal,scrInfo,textSetup,iView);
            switch out.attempt{kCal}.valResultAccept
                case 1
                    % all good, we're done
                    break;
                case 2
                    % skip setup
                    break;
                case -1
                    % restart calibration
                    startScreen = 0;
                    continue;
                case -2
                    % go to setup
                    startScreen = max(1,startScreen);
                    continue;
                case -3
                    % full stop
                    error('run ended from SMI calibration routine')
                otherwise
                    error('status %d not implemented',out.attempt{kCal}.valResultAccept);
            end
        end
    end

    function out = startRecording(qClearBuffer)
        % by default do not clear recording buffer. For SMI, by the time
        % user calls startRecording, we already have data recorded during
        % calibration and validation in the buffer
        if nargin<1
            qClearBuffer = false;
        end
        iView.stopRecording();      % make sure we're not already recording when we startRecording(), or we get an error
        if qClearBuffer
            iView.clearRecordingBuffer();
        end
        ret = iView.startRecording();
        out = true;
        processError(ret,'SMI: Error starting recording');
        WaitSecs(.1); % give it some time to get started. not needed according to doc, but never hurts
    end

    function out = pauseRecording()
        ret = iView.pauseRecording();
        out = true;
        processError(ret,'SMI: Error pausing recording');
    end

    function out = continueRecording(message)
        ret = iView.continueRecording(message);
        out = true;
        processError(ret,'SMI: Error continuing recording');
    end

    function out = stopRecording()
        ret = iView.stopRecording();
        out = true;
        processError(ret,'SMI: Error stopping recording');
    end

    function out = isConnected()
        % call it twice as i have found that after manually closing the
        % server (and waiting for 10 s), the first call still returns that
        % we are connected. I don't want to risk the connection breaking
        % and only finding out much later
        iView.isConnected();
        out = iView.isConnected();
    end

    function out = sendMessage(str)
        % using
        % calllib('iViewXAPI','iV_SendImageMessage','msg_string')
        % here to save overhead
        % consider using that directly in your code for best timing
        % ret = iView.sendImageMessage(str);
        ret = calllib('iViewXAPI','iV_SendImageMessage',str);
        out = true;
        processError(ret,'SMI: Error sending message to data file');
    end

    function out = saveData(filename, description, user, overwrite)
        out = true;
        ret = iView.saveData([filename '.idf'], description, user, overwrite);
        processError(ret,'SMI: Error saving data');
    end

    function out = cleanUp()
        iView.disconnect();
        % also, read log, return contents as output and delete
        fid = fopen(settings.logFileName, 'r');
        out = fread(fid, inf, '*char').';
        fclose(fid);
        % somehow, matlab maintains a handle to the log file, even after
        % fclose all and unloading the SMI library. Somehow a dangling
        % handle from smi, would be my guess (note that calling iV_Quit did
        % not fix it).
        % delete(smiSetup.logFileName);
    end

    function processError(returnCode,errorString)
        % for SMI, anything that is not 1 is an error
        if returnCode~=1
            error('%s (error %d: %s)',errorString,returnCode,SMIErrCode2String(returnCode));
        end
    end

end




% helpers
function ret_con = connect(iView,connectInfo)
if isempty(connectInfo)
    ret_con = iView.connectLocal();
else
    ret_con = iView.connect(connectInfo{:});
end
end

function status = showHeadPositioning(wpnt,iView,scrInfo,settings,textSetup,startScreen,debugLevel)
% status output:
%  1: continue (setup seems good) (space)
%  2: skip calibration and continue with task (shift+s)
% -2: Exit completely (control+escape)
% (NB: no -1 for this function)

% init
status = 5+5*(startScreen==2);  % 5 if simple screen requested, 10 if advanced screen

while true
    if status==5
        % simple setup screen. has two circles for positioning, a button to
        % start calibration and a button to go to advanced view
        status = showHeadPositioningSimple(wpnt,iView,scrInfo,settings,textSetup,debugLevel);
    elseif status==10
        % advanced interface, has head box and eye image
        status = showHeadPositioningAdvanced(wpnt,iView,scrInfo,settings,textSetup,debugLevel);
    else
        break;
    end
end
end

function status = showHeadPositioningSimple(wpnt,iView,scrInfo,settings,textSetup,debugLevel)
% if user it at reference viewing distance and at center of head box
% vertically and horizontally, two circles will overlap
% TODO don't hardcode viewing distance
refViewDist = 65;

% setup text
Screen('TextFont',  wpnt, textSetup.font);
Screen('TextSize',  wpnt, textSetup.size);
Screen('TextStyle', wpnt, textSetup.style);

% setup ovals
ovalVSz = .15;
refSz   = ovalVSz*scrInfo.rect(2);
refClr  = [0 0 255];
headClr = [255 255 0];
% setup head position visualization
distGain= 1.5;

% setup buttons
buttonSz    = [300 45];
buttonOff   = 80;
yposBase    = round(scrInfo.rect(2)*.95);
% place buttons for back to simple interface, or calibrate
baseRect                = OffsetRect([0 0 buttonSz],scrInfo.center(1),yposBase-buttonSz(2)); % left is now at screen center, bottom at right height
advancedButRect         = OffsetRect(baseRect,-buttonOff/2-buttonSz(1),0);
advancedButTextCache    = getButtonTextCache(wpnt,'advanced (<i>a<i>)'       ,advancedButRect,textSetup);
continueButRect         = OffsetRect(baseRect, buttonOff/2            ,0);
continueButTextCache    = getButtonTextCache(wpnt,'continue (<i>spacebar<i>)',continueButRect,textSetup);
Screen('FillRect', wpnt, scrInfo.bgclr); % clear what we've just drawn

% setup fixation points in the corners of the screen
fixPos = [.1 .1; .1 .9; .9 .9; .9 .1] .* repmat(scrInfo.rect(1:2),4,1);

% setup cursors
cursors.rect    = {advancedButRect.' continueButRect.'};
cursors.cursor  = [2 2 2 2 2];  % Hand
cursors.other   = 0;            % Arrow
if debugLevel<2  % for cleanup
    cursors.reset = -1; % hide cursor (else will reset to cursor.other by default, so we're good with that default
end
cursor          = cursorUpdater(cursors);

% get tracking status and visualize
pTrackingStatusS= getSMIStructEnum('TrackingStatusStruct');
pSampleS        = getSMIStructEnum('SampleStruct');

while true
    % get tracking status info
    [~,pTrackingStatus]=iView.getTrackingStatus(pTrackingStatusS);  % for position in headbox
    [~,pSample]=iView.getSample(pSampleS);                          % for distance
    
    % get average eye distance. use distance from one eye if only one eye
    % available
    distL   = pSample.leftEye .eyePositionZ/10;
    distR   = pSample.rightEye.eyePositionZ/10;
    dists   = [distL distR];
    avgDist = mean(dists(~isnan(dists)));
    
    % scale up size of oval. define size/rect at standard distance, have a
    % gain for how much to scale as distance changes
    if pTrackingStatus.leftEye.validity || pTrackingStatus.rightEye.validity
        pos  = [pTrackingStatus.total.relativePositionX -pTrackingStatus.total.relativePositionY];  %-Y as +1 is upper and -1 is lower edge. needs to be reflected for screen drawing
        % determine size of oval, based on distance from reference distance
        fac  = avgDist/refViewDist;
        headSz = refSz - refSz*(fac-1)*distGain;
        % move 
        headPos = pos.*scrInfo.rect./2+scrInfo.center;
    else
        headPos = [];
    end
    
    % draw distance info
    DrawFormattedText(wpnt,sprintf('Position yourself such that the two circles overlap.\nDistance: %.0f cm',avgDist),'center',fixPos(1,2)-.03*scrInfo.rect(2),255,[],[],[],1.5);
    % draw ovals
    drawCircle(wpnt,refClr,scrInfo.center,refSz,5);
    if ~isempty(headPos)
        drawCircle(wpnt,headClr,headPos,headSz,5);
    end
    % draw buttons
    Screen('FillRect',wpnt,[11 122 244],advancedButRect);
    DrawMonospacedText(advancedButTextCache);
    Screen('FillRect',wpnt,[ 0 120   0],continueButRect);
    DrawMonospacedText(continueButTextCache);
    % draw fixation points
    drawfixpoint(wpnt,fixPos,[settings.cal.fixBackSize settings.cal.fixFrontSize],{settings.cal.fixBackColor settings.cal.fixFrontColor});
    
    % drawing done, show
    Screen('Flip',wpnt);

    

    % check for keypresses or button clicks
    [mx,my,buttons] = GetMouse;
    [~,~,keyCode] = KbCheck;
    % update cursor look if needed
    cursor.update(mx,my);
    if any(buttons)
        % don't care which button for now. determine if clicked on either
        % of the buttons
        qIn = inRect([mx my],[advancedButRect.' continueButRect.']);
        if any(qIn)
            if qIn(1)
                status = 10;
                break;
            elseif qIn(2)
                status = 1;
                break;
            end
        end
    elseif any(keyCode)
        keys = KbName(keyCode);
        if any(strcmpi(keys,'a'))
            status = 10;
            break;
        elseif any(strcmpi(keys,'space'))
            status = 1;
            break;
        elseif any(strcmpi(keys,'escape')) && any(strcmpi(keys,'shift'))
            status = -3;
            break;
        elseif any(strcmpi(keys,'s')) && any(strcmpi(keys,'shift'))
            % skip calibration
            iView.abortCalibration();
            status = 2;
            break;
        end
    end
end
% clean up
HideCursor;
end


function status = showHeadPositioningAdvanced(wpnt,iView,scrInfo,settings,textSetup,debugLevel)
% TODO: hardcoded ref view dist etc in draw part of this code
% setup text
Screen('TextFont',  wpnt, textSetup.font);
Screen('TextSize',  wpnt, textSetup.size);
Screen('TextStyle', wpnt, textSetup.style);
% setup box
REDmBox = [31 21]; % at 60 cm, doesn't matter as we need aspect ratio
boxSize = round(500.*REDmBox./REDmBox(1));
[boxCenter(1),boxCenter(2)] = RectCenter([0 0 boxSize]);
% setup eye image
margin      = 80;
ret = 0;
while ret~=1
    [ret,eyeImage] = iView.getEyeImage();
end
if ret==1
    eyeImageRect= [0 0 size(eyeImage,2) size(eyeImage,1)];
end
% setup buttons
buttonSz    = [300 45];
buttonOff   = 80;
yposBase    = round(scrInfo.rect(2)*.95);
eoButSz     = [174 buttonSz(2)];
eoButMargin = [15 20];
eyeButClrs  = {[37  97 163],[11 122 244]};

% position eye image, head box and buttons
% center headbox and eye image on screen
offsetV         = (scrInfo.rect(2)-boxSize(2)-margin-RectHeight(eyeImageRect))/2;
offsetH         = (scrInfo.rect(1)-boxSize(1))/2;
boxRect         = OffsetRect([0 0 boxSize],offsetH,offsetV);
eyeImageRect    = OffsetRect(eyeImageRect,scrInfo.center(1)-eyeImageRect(3)/2,offsetV+margin+RectHeight(boxRect));
% place buttons for back to simple interface, or calibrate
baseRect            = OffsetRect([0 0 buttonSz],scrInfo.center(1),yposBase-buttonSz(2)); % left is now at screen center, bottom at right height
basicButRect        = OffsetRect(baseRect,-buttonOff/2-buttonSz(1),0);
basicButTextCache   = getButtonTextCache(wpnt,'basic (<i>b<i>)'          ,   basicButRect,textSetup);
continueButRect     = OffsetRect(baseRect, buttonOff/2            ,0);
continueButTextCache= getButtonTextCache(wpnt,'continue (<i>spacebar<i>)',continueButRect,textSetup);
% place buttons for overlays in the eye image, draw text once to get cache
contourButRect      = OffsetRect([0 0 eoButSz],eyeImageRect(3)+eoButMargin(1),eyeImageRect(4)-eoButSz(2));
contourButTextCache = getButtonTextCache(wpnt,'contour (<i>c<i>)',contourButRect,textSetup);
pupilButRect        = OffsetRect([0 0 eoButSz],eyeImageRect(3)+eoButMargin(1),eyeImageRect(4)-eoButSz(2)*2-eoButMargin(2));
pupilButTextCache   = getButtonTextCache(wpnt,'pupil (<i>p<i>)'  ,pupilButRect,textSetup);
glintButRect        = OffsetRect([0 0 eoButSz],eyeImageRect(3)+eoButMargin(1),eyeImageRect(4)-eoButSz(2)*3-eoButMargin(2)*2);
glintButTextCache   = getButtonTextCache(wpnt,'glint (<i>g<i>)'  ,glintButRect,textSetup);
Screen('FillRect', wpnt, scrInfo.bgclr); % clear what we've just drawn

% setup fixation points in the corners of the screen
fixPos = [.1 .1; .1 .9; .9 .9; .9 .1] .* repmat(scrInfo.rect(1:2),4,1);

% setup arrows + their positions
aSize = 26;
arrow = [
    -0.52  -0.64
     0.52  -0.64
     0.52  -0.16
     1.00  -0.16
     0.00   0.64
    -1.00  -0.16
    -0.52  -0.16];
arrowsLRUDNF = {[-arrow(:,2) arrow(:,1)],[arrow(:,2) -arrow(:,1)],arrow,-arrow,arrow,-arrow};
arrowsLRUDNF{5}(1:2,1) = arrowsLRUDNF{5}(1:2,1)*.75;
arrowsLRUDNF{5}( : ,2) = arrowsLRUDNF{5}( : ,2)*.6;
arrowsLRUDNF{6}(1:2,1) = arrowsLRUDNF{6}(1:2,1)/.75;
arrowsLRUDNF{6}( : ,2) = arrowsLRUDNF{6}( : ,2)*.6;
arrowsLRUDNF = cellfun(@(x) round(x.*aSize),arrowsLRUDNF,'uni',false);
% positions relative to boxRect. add position to arrowsLRDUNF to get
% position of vertices in boxRect;
margin = 4;
arrowPos = cell(1,6);
arrowPos{1} = [boxSize(1)-margin-max(arrowsLRUDNF{1}(:,1)) boxCenter(2)];
arrowPos{2} = [           margin-min(arrowsLRUDNF{2}(:,1)) boxCenter(2)];
% down is special as need space underneath for near and far arrows
arrowPos{3} = [boxCenter(1)            margin-min(arrowsLRUDNF{3}(:,2))];
arrowPos{4} = [boxCenter(1) boxSize(2)-margin-max(arrowsLRUDNF{4}(:,2))-max(arrowsLRUDNF{5}(:,2))+min(arrowsLRUDNF{5}(:,2))];
arrowPos{5} = [boxCenter(1) boxSize(2)-margin-max(arrowsLRUDNF{5}(:,2))];
arrowPos{6} = [boxCenter(1) boxSize(2)-margin-max(arrowsLRUDNF{6}(:,2))];
% setup arrow colors and thresholds
col1 = [255 255 0]; % color for arrow when just visible, exceeding first threshold
col2 = [255 155 0]; % color for arrow when just visible, jhust before exceeding second threshold
col3 = [255 0   0]; % color for arrow when extreme, exceeding second threshold
xThresh = [0 .68];
yThresh = [0 .8];
zThresh = [0 .8];

% setup cursors
cursors.rect    = {basicButRect.' continueButRect.' contourButRect.' pupilButRect.' glintButRect.'};
cursors.cursor  = [2 2 2 2 2];  % Hand
cursors.other   = 0;            % Arrow
if debugLevel<2  % for cleanup
    cursors.reset = -1; % hide cursor (else will reset to cursor.other by default, so we're good with that default
end
cursor          = cursorUpdater(cursors);


% get tracking status and visualize along with eye image
tex = 0;
arrowColor = zeros(3,6);
pTrackingStatusS= getSMIStructEnum('TrackingStatusStruct');
pSampleS        = getSMIStructEnum('SampleStruct');
pImageDataS     = getSMIStructEnum('ImageStruct');
eyeKeyDown      = false;
eyeClickDown    = false;
relPos          = zeros(3);
% for overlays in eye image. disable them all initially
iView.setTrackingParameter('ET_PARAM_EYE_BOTH','ET_PARAM_SHOW_CONTOUR',0);
iView.setTrackingParameter('ET_PARAM_EYE_BOTH','ET_PARAM_SHOW_PUPIL',0);
iView.setTrackingParameter('ET_PARAM_EYE_BOTH','ET_PARAM_SHOW_REFLEX',0);
overlays        = false(3);
toggleKeys      = KbName({'c','g','p'});
while true
    % get tracking status info
    [~,pTrackingStatus]=iView.getTrackingStatus(pTrackingStatusS);  % for position in headbox
    [~,pSample]=iView.getSample(pSampleS);                          % for distance
    
    % get average eye distance. use distance from one eye if only one eye
    % available
    distL   = pSample.leftEye .eyePositionZ/10;
    distR   = pSample.rightEye.eyePositionZ/10;
    dists   = [distL distR];
    avgDist = mean(dists(~isnan(dists)));
    % if missing, estimate where eye would be in depth if user kept head
    % yaw constant
    if isnan(distL)
        distL = distR-relPos(3);
    elseif isnan(distR)
        distR = distL+relPos(3);
    end
    
    % see which arrows to draw
    qDrawArrow = false(1,6);
    if abs(pTrackingStatus.total.positionRatingX)>xThresh(1)
        idx = 1 + (pTrackingStatus.total.positionRatingX<0);  % if too far on the left, arrow should point to the right, etc below
        qDrawArrow(idx) = true;
        arrowColor(:,idx) = getArrowColor(pTrackingStatus.total.positionRatingX,xThresh,col1,col2,col3);
    end
    if abs(pTrackingStatus.total.positionRatingY)>yThresh(1)
        idx = 3 + (pTrackingStatus.total.positionRatingY<0);
        qDrawArrow(idx) = true;
        arrowColor(:,idx) = getArrowColor(pTrackingStatus.total.positionRatingY,yThresh,col1,col2,col3);
    end
    if abs(pTrackingStatus.total.positionRatingZ)>zThresh(1)
        idx = 5 + (pTrackingStatus.total.positionRatingZ>0);
        qDrawArrow(idx) = true;
        arrowColor(:,idx) = getArrowColor(pTrackingStatus.total.positionRatingZ,zThresh,col1,col2,col3);
    end
    % get eye image
    [ret,eyeImage] = iView.getEyeImage(pImageDataS);
    if ret==1
        % clean up old one, if any
        if tex
            Screen('Close',tex);
        end
        tex = Screen('MakeTexture',wpnt,eyeImage,[],8);   % 8 to prevent mipmap generation, we don't need it
    end
    
    % do drawing
    % draw box
    Screen('FillRect',wpnt,80,boxRect);
    % draw distance
    if ~isnan(avgDist)
        Screen('TextSize',  wpnt, 10);
        Screen('DrawText',wpnt,sprintf('%.0f cm',avgDist) ,boxRect(3)-40,boxRect(4)-16,255);
    end
    % draw eyes in box
    Screen('TextSize',  wpnt, textSetup.size);
    % scale up size of oval. define size/rect at standard distance (60cm),
    % have a gain for how much to scale as distance changes
    if pTrackingStatus.leftEye.validity || pTrackingStatus.rightEye.validity
        posL = [pTrackingStatus.leftEye .relativePositionX -pTrackingStatus.leftEye .relativePositionY]/2+.5;  %-Y as +1 is upper and -1 is lower edge. needs to be reflected for screen drawing
        posR = [pTrackingStatus.rightEye.relativePositionX -pTrackingStatus.rightEye.relativePositionY]/2+.5;
        % determine size of eye. based on distance to standard distance of
        % 60cm, calculate size change
        fac  = 60/avgDist;
        facL = 60/distL;
        facR = 60/distR;
        gain = 1.5;  % 1.5 is a gain to make differences larger
        sz   = 15;
        % left eye
        style = Screen('TextStyle',  wpnt, 1);
        drawEye(wpnt,pTrackingStatus.leftEye .validity,posL,posR, relPos*fac,[255 120 120],[220 186 186],round(sz*facL*gain),'L',boxRect);
        % right eye
        drawEye(wpnt,pTrackingStatus.rightEye.validity,posR,posL,-relPos*fac,[120 255 120],[186 220 186],round(sz*facR*gain),'R',boxRect);
        Screen('TextStyle',  wpnt, style);
        % update relative eye positions - used for drawing estimated
        % position of missing eye. X and Y are relative position in
        % headbox, Z is difference in measured eye depths
        if pTrackingStatus.leftEye.validity&&pTrackingStatus.rightEye.validity
            relPos = [(posR-posL)/fac min(max(distR-distL,-8),8)];   % keep a distance normalized to eye-tracker distance of 60 cm, so we can scale eye distance with subject's distance from tracker correctly
        end
        % draw center
        if 0 && pTrackingStatus.total.validity
            pos = [pTrackingStatus.total.relativePositionX -pTrackingStatus.total.relativePositionY]/2+.5;
            pos = pos.*[diff(boxRect([1 3])) diff(boxRect([2 4]))]+boxRect(1:2);
            Screen('gluDisk',wpnt,[0 0 255],pos(1),pos(2),10)
        end
    end
    % draw arrows
    for p=find(qDrawArrow)
        Screen('FillPoly', wpnt, arrowColor(:,p), bsxfun(@plus,arrowsLRUDNF{p},arrowPos{p}+boxRect(1:2)) ,0);
    end
    % draw eye image, if any
    if tex
        Screen('DrawTexture', wpnt, tex,[],eyeImageRect);
    end
    % draw buttons
    Screen('FillRect',wpnt,[11 122 244],basicButRect);
    DrawMonospacedText(basicButTextCache);
    Screen('FillRect',wpnt,[ 0 120   0],continueButRect);
    DrawMonospacedText(continueButTextCache);
    Screen('FillRect',wpnt,eyeButClrs{overlays(1)+1},contourButRect);
    DrawMonospacedText(contourButTextCache);
    Screen('FillRect',wpnt,eyeButClrs{overlays(2)+1},pupilButRect);
    DrawMonospacedText(pupilButTextCache);
    Screen('FillRect',wpnt,eyeButClrs{overlays(3)+1},glintButRect);
    DrawMonospacedText(glintButTextCache);
    % draw fixation points
    drawfixpoint(wpnt,fixPos,[settings.cal.fixBackSize settings.cal.fixFrontSize],{settings.cal.fixBackColor settings.cal.fixFrontColor});
    
    % drawing done, show
    Screen('Flip',wpnt);

    % check for keypresses or button clicks
    [mx,my,buttons] = GetMouse;
    [~,~,keyCode] = KbCheck;
    % update cursor look if needed
    cursor.update(mx,my);
    if any(buttons)
        % don't care which button for now. determine if clicked on either
        % of the buttons
        qIn = inRect([mx my],[basicButRect.' continueButRect.' contourButRect.' pupilButRect.' glintButRect.']);
        if any(qIn)
            if qIn(1)
                status = 5;
                break;
            elseif qIn(2)
                status = 1;
                break;
            elseif ~eyeClickDown
                if qIn(3)
                    overlays(1) = ~overlays(1);
                    iView.setTrackingParameter('ET_PARAM_EYE_BOTH','ET_PARAM_SHOW_CONTOUR',overlays(1));
                elseif qIn(4)
                    overlays(2) = ~overlays(2);
                    iView.setTrackingParameter('ET_PARAM_EYE_BOTH','ET_PARAM_SHOW_PUPIL',overlays(2));
                elseif qIn(5)
                    overlays(3) = ~overlays(3);
                    iView.setTrackingParameter('ET_PARAM_EYE_BOTH','ET_PARAM_SHOW_REFLEX',overlays(3));
                end
                eyeClickDown = any(qIn);
            end
        end
    elseif any(keyCode)
        keys = KbName(keyCode);
        if any(strcmpi(keys,'b'))
            status = 5;
            break;
        elseif any(strcmpi(keys,'space'))
            status = 1;
            break;
        elseif any(strcmpi(keys,'escape')) && any(strcmpi(keys,'shift'))
            status = -3;
            break;
        elseif any(strcmpi(keys,'s')) && any(strcmpi(keys,'shift'))
            % skip calibration
            iView.abortCalibration();
            status = 2;
            break;
        end
        if ~eyeKeyDown
            if any(strcmpi(keys,'c'))
                overlays(1) = ~overlays(1);
                iView.setTrackingParameter('ET_PARAM_EYE_BOTH','ET_PARAM_SHOW_CONTOUR',overlays(1));
            elseif any(strcmpi(keys,'p'))
                overlays(2) = ~overlays(2);
                iView.setTrackingParameter('ET_PARAM_EYE_BOTH','ET_PARAM_SHOW_PUPIL',overlays(2));
            elseif any(strcmpi(keys,'g'))
                overlays(3) = ~overlays(3);
                iView.setTrackingParameter('ET_PARAM_EYE_BOTH','ET_PARAM_SHOW_REFLEX',overlays(3));
            end
        end
    end
    eyeKeyDown   = any(keyCode(toggleKeys));        % maintain button state so only one press counted until after key up
    eyeClickDown = eyeClickDown && any(buttons);    % maintain button state so only one press counted until after mouse up
end
% clean up
if tex
    Screen('Close',tex);
end
% just to be safe, disable these overlays
iView.setTrackingParameter('ET_PARAM_EYE_BOTH','ET_PARAM_SHOW_CONTOUR',0);
iView.setTrackingParameter('ET_PARAM_EYE_BOTH','ET_PARAM_SHOW_PUPIL',0);
iView.setTrackingParameter('ET_PARAM_EYE_BOTH','ET_PARAM_SHOW_REFLEX',0);
HideCursor;
end

function drawCircle(wpnt,refClr,center,refSz,lineWidth)
nStep = 200;
alpha = linspace(0,2*pi,nStep);
alpha = [alpha(1:end-1); alpha(2:end)]; alpha = alpha(:).';
xy = refSz.*[cos(alpha); sin(alpha)];
Screen('DrawLines', wpnt, xy, lineWidth ,refClr ,center,2);
end

function cache = getButtonTextCache(wpnt,lbl,rect,textSetup)
[~,~,~,cache] = DrawMonospacedText(wpnt,lbl,'center','center',0,[],[],[],OffsetRect(rect,0,textSetup.lineCentOff));
end

function arrowColor = getArrowColor(posRating,thresh,col1,col2,col3)
if abs(posRating)>thresh(2)
    arrowColor = col3;
else
    arrowColor = col1+(abs(posRating)-thresh(1))./diff(thresh)*(col2-col1);
end
end

function drawEye(wpnt,validity,pos,posOther,relPos,clr1,clr2,sz,lbl,boxRect)
if validity
    clr = clr1;
else
    clr = clr2;
    if any(relPos)
        pos = posOther-relPos(1:2);
    else
        return
    end
end
pos = pos.*[diff(boxRect([1 3])) diff(boxRect([2 4]))]+boxRect(1:2);
Screen('gluDisk',wpnt,clr,pos(1),pos(2),sz)
if validity
    bbox = Screen('TextBounds',wpnt,lbl);
    pos  = round(pos-bbox(3:4)/2);
    Screen('DrawText',wpnt,lbl,pos(1),pos(2),0);
end
end

function drawfixpoint(wpnt,pos,sz,clr)
% draws Thaler et al. 2012's ABC fixation point 

% setup
assert(isequal(sort(size(sz)),[1 2]),'if drawing fixation type ''thaler'', size should be 1x2')
assert(iscell(clr) && isequal(sort(size(clr)),[1 2]),'if drawing fixation type ''thaler'', color should be a 1x2 cell')
sz = sz(:).';   % ensure row vector

% draw
for p=1:size(pos,1)
    rectH = CenterRectOnPointd([0 0 sz(1:2)], pos(p,1), pos(p,2));
    rectV = CenterRectOnPointd([0 0 fliplr(sz(1:2))], pos(p,1), pos(p,2));
    Screen('gluDisk', wpnt,clr{1}, pos(p,1), pos(p,2), sz(1)/2);
    Screen('FillRect',wpnt,clr{2}, rectH);
    Screen('FillRect',wpnt,clr{2}, rectV);
    Screen('gluDisk', wpnt,clr{1}, pos(p,1), pos(p,2), sz(2)/2);
end
end

function [status,out] = DoCalAndVal(wpnt,iView,calSetup,startRecording,qClearBuffer,stopRecording,ETSendMessageFun)
% disable SMI key listeners, we'll deal with key presses
iView.setUseCalibrationKeys(0);
% calibrate
startRecording(qClearBuffer);
% enter calibration mode
ETSendMessageFun('CALIBRATION START');
iView.calibrate();
% show display
[status,out.cal] = DoCalPointDisplay(wpnt,iView,calSetup,ETSendMessageFun);
ETSendMessageFun('CALIBRATION END');
if status~=1
    return;
end

% validate
% enter validation mode
ETSendMessageFun('VALIDATION START');
iView.validate();
% show display
[status,out.val] = DoCalPointDisplay(wpnt,iView,calSetup,ETSendMessageFun);
ETSendMessageFun('VALIDATION END');
stopRecording();

% clear flip
Screen('Flip',wpnt);
end

function [status,out] = DoCalPointDisplay(wpnt,iView,calSetup,ETSendMessageFun)
% status output:
%  1: finished succesfully (you should query SMI software whether they think
%     calibration was succesful though)
%  2: skip calibration and continue with task (shift+s)
% -1: restart calibration (escape key)
% -2: abort calibration and go back to setup
% -3: Exit completely (control+escape)

% clear screen, anchor timing, get ready for displaying calibration points
out.flips = Screen('Flip',wpnt);
out.point = nan;
out.pointPos = [];

% wait till keys released
keyDown = 1;
while keyDown
    WaitSecs('YieldSecs', 0.002);
    keyDown = KbCheck;
end

pCalibrationPoint = getSMIStructEnum('CalibrationPointStruct');
while true
    nextFlipT = out.flips(end)+1/1000;
    ret = iView.getCurrentCalibrationPoint(pCalibrationPoint);
    if ret==2   % RET_NO_VALID_DATA
        % calibration/validation finished
        Screen('Flip',wpnt);    % clear
        ETSendMessageFun(sprintf('POINT OFF %d',out.point(end)));
        status = 1;
        break;
    end
    pos = [pCalibrationPoint.positionX pCalibrationPoint.positionY];
    drawfixpoint(wpnt,pos,[calSetup.fixBackSize calSetup.fixFrontSize],{calSetup.fixBackColor calSetup.fixFrontColor})
    
    out.point(end+1) = pCalibrationPoint.number;
    out.flips(end+1) = Screen('Flip',wpnt,nextFlipT);
    if out.point(end)~=out.point(end-1)
        ETSendMessageFun(sprintf('POINT ON %d (%d %d)',out.point(end),pos));
        out.pointPos(end+1,1:3) = [out.point(end) pos];
    end
    % check for keys
    [keyPressed,~,keyCode] = KbCheck();
    if keyPressed
        keys = KbName(keyCode);
        if any(strcmpi(keys,'space')) && pCalibrationPoint.number==1
            iView.acceptCalibrationPoint();
        elseif any(strcmpi(keys,'escape'))
            iView.abortCalibration();
            if any(strcmpi(keys,'shift'))
                status = -3;
            else
                status = -1;
            end
            break;
        elseif any(strcmpi(keys,'s')) && any(strcmpi(keys,'shift'))
            % skip calibration
            iView.abortCalibration();
            status = 2;
            break;
        end
    end
end
end

function [status,selection] = showValidationResult(wpnt,cal,kCal,scrInfo,textSetup,iView)
% status output:
%  1: calibration/validation accepted, continue (a)
%  2: just continue with task (shift+s)
% -1: restart calibration (escape key)
% -2: go back to setup (s)
% -3: Exit completely (control+escape)
%
% additional buttons
% c: chose other calibration (if have more than one valid)
% g: show gaze (and fixation points)

% find how many valid calibrations we have:
selection = kCal;
iValid = find(cellfun(@(x) isfield(x,'calStatusSMI')&&strcmp(x.calStatusSMI,'calibrationValid'),cal));
qHaveMultipleValidCals = ~isscalar(iValid);

% setup buttons
% 1. below screen
yposBase    = round(scrInfo.rect(2)*.95);
buttonSz    = {[200 45] [300 45] [350 45]};
buttonSz    = buttonSz(1:2+qHaveMultipleValidCals);  % third button only when more than one calibration available
buttonOff   = 80;
buttonWidths= cellfun(@(x) x(1),buttonSz);
totWidth    = sum(buttonWidths)+(length(buttonSz)-1)*buttonOff;
buttonRectsX= cumsum([0 buttonWidths]+[0 ones(1,length(buttonWidths))]*buttonOff)-totWidth/2;
acceptButRect       = OffsetRect([buttonRectsX(1) 0 buttonRectsX(2)-buttonOff buttonSz{1}(2)],scrInfo.center(1),yposBase-buttonSz{1}(2));
acceptButTextCache  = getButtonTextCache(wpnt,'accept (<i>a<i>)'       ,acceptButRect,textSetup);
recalButRect        = OffsetRect([buttonRectsX(2) 0 buttonRectsX(3)-buttonOff buttonSz{2}(2)],scrInfo.center(1),yposBase-buttonSz{2}(2));
recalButTextCache   = getButtonTextCache(wpnt,'recalibrate (<i>esc<i>)', recalButRect,textSetup);
if qHaveMultipleValidCals
    selectButRect       = OffsetRect([buttonRectsX(3) 0 buttonRectsX(4)-buttonOff buttonSz{3}(2)],scrInfo.center(1),yposBase-buttonSz{3}(2));
    selectButTextCache  = getButtonTextCache(wpnt,'select other cal (<i>c<i>)', selectButRect,textSetup);
else
    selectButRect = [-100 -90 -100 -90]; % offscreen so mouse handler doesn't fuck up because of it
end
% 2. atop screen
topMargin           = 50;
buttonSz            = {[200 45] [250 45]};
buttonOff           = 400;
showGazeButClrs     = {[37  97 163],[11 122 244]};
setupButRect        = OffsetRect([0 0 buttonSz{1}],scrInfo.center(1)-buttonOff/2-buttonSz{1}(1),topMargin+buttonSz{1}(2));
setupButTextCache   = getButtonTextCache(wpnt,'setup (<i>s<i>)'    ,   setupButRect,textSetup);
showGazeButRect     = OffsetRect([0 0 buttonSz{2}],scrInfo.center(1)+buttonOff/2               ,topMargin+buttonSz{1}(2));
showGazeButTextCache= getButtonTextCache(wpnt,'show gaze (<i>g<i>)',showGazeButRect,textSetup);

% setup menu, if any
if qHaveMultipleValidCals
    margin      = 10;
    pad         = 3;
    height      = 45;
    nElem       = length(iValid);
    totHeight   = nElem*(height+pad)-pad;
    width       = 700;
    % menu background
    menuBackRect= [-.5*width+scrInfo.center(1)-margin -.5*totHeight+scrInfo.center(2)-margin .5*width+scrInfo.center(1)+margin .5*totHeight+scrInfo.center(2)+margin];
    % menuRects
    menuRects = repmat([-.5*width+scrInfo.center(1) -height/2+scrInfo.center(2) .5*width+scrInfo.center(1) height/2+scrInfo.center(2)],length(iValid),1);
    menuRects = menuRects+bsxfun(@times,[height*([0:nElem-1]+.5)+[0:nElem-1]*pad-totHeight/2].',[0 1 0 1]);
    % text in each rect
    for c=1:length(iValid)
        str = sprintf('(%d): <color=ff0000>Left<color>: (%.2f�,%.2f�), <color=00ff00>Right<color>: (%.2f�,%.2f�)',c,cal{iValid(c)}.validateAccuracy.deviationLX,cal{iValid(c)}.validateAccuracy.deviationLY,cal{iValid(c)}.validateAccuracy.deviationRX,cal{iValid(c)}.validateAccuracy.deviationRY);
        [~,~,~,menuTextCache(c)] = DrawMonospacedText(wpnt,str,'center','center',0,[],[],[],OffsetRect(menuRects(c,:),0,textSetup.lineCentOff));
    end
end
        
qDoneCalibSelection = false;
qSelectMenuOpen     = false;
qShowGaze           = false;
tex = 0;
pSampleS            = getSMIStructEnum('SampleStruct');
while ~qDoneCalibSelection
    % draw validation screen image
    if tex~=0
        Screen('Close',tex);
    end
    tex   = Screen('MakeTexture',wpnt,cal{selection}.validateImage,[],8);   % 8 to prevent mipmap generation, we don't need it
    
    % setup cursors
    if qSelectMenuOpen
        cursors.rect    = {menuRects.',acceptButRect.',recalButRect.'};
        cursors.cursor  = 2*ones(1,size(menuRects,1)+2);    % 2: Hand
    else
        cursors.rect    = {acceptButRect.',recalButRect.',selectButRect.',setupButRect.',showGazeButRect.'};
        cursors.cursor  = [2 2 2 2 2];  % 2: Hand
    end
    cursors.other   = 0;    % 0: Arrow
    cursors.qReset  = false;
    % NB: don't reset cursor to invisible here as it will then flicker every
    % time you click something. default behaviour is good here
    cursor = cursorUpdater(cursors);
    
    while true % draw loop
        Screen('DrawTexture', wpnt, tex);   % its a fullscreen image, so just draw
        % setup text
        Screen('TextFont',  wpnt, textSetup.font);
        Screen('TextSize',  wpnt, textSetup.size);
        Screen('TextStyle', wpnt, textSetup.style);
        % draw text with validation accuracy info
        valText = sprintf('<font=Consolas><size=20>accuracy   X       Y\n   <color=ff0000>Left<color>: % 2.2f�  % 2.2f�\n  <color=00ff00>Right<color>: % 2.2f�  % 2.2f�',cal{selection}.validateAccuracy.deviationLX,cal{selection}.validateAccuracy.deviationLY,cal{selection}.validateAccuracy.deviationRX,cal{selection}.validateAccuracy.deviationRY);
        DrawMonospacedText(wpnt,valText,'center',100,255,[],textSetup.vSpacing);
        % draw buttons
        Screen('FillRect',wpnt,[0 120 0],acceptButRect);
        DrawMonospacedText(acceptButTextCache);
        Screen('FillRect',wpnt,[150 0 0],recalButRect);
        DrawMonospacedText(recalButTextCache);
        if qHaveMultipleValidCals
            Screen('FillRect',wpnt,[150 150 0],selectButRect);
            DrawMonospacedText(selectButTextCache);
        end
        Screen('FillRect',wpnt,[150 0 0],setupButRect);
        DrawMonospacedText(setupButTextCache);
        Screen('FillRect',wpnt,showGazeButClrs{qShowGaze+1},showGazeButRect);
        DrawMonospacedText(showGazeButTextCache);
        % if selection menu open, draw on top
        if qSelectMenuOpen
            % menu background
            Screen('FillRect',wpnt,140,menuBackRect);
            % menuRects
            Screen('FillRect',wpnt,110,menuRects.');
            % text in each rect
            for c=1:length(iValid)
                DrawMonospacedText(menuTextCache(c));
            end
        end
        % if showing gaze, draw
        if qShowGaze
            [ret,pSample] = iView.getSample(pSampleS);
            if ret==1
                % draw
                Screen('gluDisk', wpnt,[255 0 0], pSample. leftEye.gazeX, pSample. leftEye.gazeY, 10);
                Screen('gluDisk', wpnt,[0 255 0], pSample.rightEye.gazeX, pSample.rightEye.gazeX, 10);
            end
        end
        % drawing done, show
        Screen('Flip',wpnt);
        
        % get user response
        [keyPressed,~,keyCode]  = KbCheck();
        [mx,my,buttons]         = GetMouse;
        cursor.update(mx,my);
        if any(buttons)
            % don't care which button for now. determine if clicked on either
            % of the buttons
            if qSelectMenuOpen
                iIn = find(inRect([mx my],[menuRects.' menuBackRect.']),1);   % press on button is also in rect of whole menu, so we get multiple returns here in this case. ignore all but first, which is the actual menu button pressed
                if ~isempty(iIn) && iIn<=length(iValid)
                    selection = iValid(iIn);
                    loadOtherCal(iView,selection);
                    qSelectMenuOpen = false;
                    break;
                else
                    qSelectMenuOpen = false;
                    break;
                end
            end
            if ~qSelectMenuOpen     % if pressed outside the menu, check if pressed any of these menu buttons
                qIn = inRect([mx my],[acceptButRect.' recalButRect.' selectButRect.']);
                if any(qIn)
                    if qIn(1)
                        status = 1;
                        qDoneCalibSelection = true;
                    elseif qIn(2)
                        status = -1;
                        qDoneCalibSelection = true;
                    elseif qIn(3)
                        qSelectMenuOpen     = true;
                    elseif qIn(4)
                        status = -2;
                        qDoneCalibSelection = true;
                    elseif qIn(5)
                        qShowGaze           = ~qShowGaze;
                    end
                    break;
                end
            end
        elseif keyPressed
            keys = KbName(keyCode);
            if qSelectMenuOpen
                if any(strcmpi(keys,'escape'))
                    qSelectMenuOpen = false;
                    break;
                elseif ismember(keys(1),{'1','2','3','4','5','6','7','8','9'})  % key 1 is '1!', for instance
                    idx = str2double(keys(1));
                    selection = iValid(idx);
                    loadOtherCal(iView,selection);
                    qSelectMenuOpen = false;
                    break;
                end
            else
                if any(strcmpi(keys,'a'))
                    status = 1;
                    qDoneCalibSelection = true;
                    break;
                elseif any(strcmpi(keys,'escape')) && ~any(strcmpi(keys,'shift'))
                    status = -1;
                    qDoneCalibSelection = true;
                    break;
                elseif any(strcmpi(keys,'s')) && ~any(strcmpi(keys,'shift'))
                    status = -2;
                    qDoneCalibSelection = true;
                    break;
                elseif any(strcmpi(keys,'c')) && qHaveMultipleValidCals
                    qSelectMenuOpen     = true;
                    break;
                elseif any(strcmpi(keys,'g'))
                    qShowGaze           = ~qShowGaze;
                    break;
                end
            end
            
            % these two key combinations should always be available
            if any(strcmpi(keys,'escape')) && any(strcmpi(keys,'shift'))
                status = -2;
                qDoneCalibSelection = true;
                break;
            elseif any(strcmpi(keys,'s')) && any(strcmpi(keys,'shift'))
                % skip calibration
                iView.abortCalibration();
                status = 2;
                qDoneCalibSelection = true;
                break;
            end
        end
    end
end
% done, clean up
cursor.reset();
Screen('Close',tex);
if status~=1
    selection = NaN;
end
HideCursor;
end

function loadOtherCal(iView,which)
iView.loadCalibration(num2str(which));
% check correct one is loaded -- well, apparently below function returns
% last calibration's accuracy, not loaded calibration. So we can't check
% this way..... I have verified that loading works on the REDm.
% [~,validateAccuracy] = iView.getAccuracy([], 0);
% assert(isequal(validateAccuracy,out.attempt{selection}.validateAccuracy),'failed to load selected calibration');
end
