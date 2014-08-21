function optimizeXGUI(varargin)
% Uses FEX tool "settingsdlg.m" (http://goo.gl/DFvcQ5)

%% Request Major Settings from User
try 
[params, button] = settingsdlg(...
    'title'                 ,       'OptimizeX Settings', ...
    'separator'                ,   'General Settings', ...
    {'TR (s)'; 'TR'}, 1, ...
    {'High-Pass Filter Cutoff (s)'; 'hpf'}, 128, ...'
    'separator'             ,       'Task Settings', ...
    {'N Conditions';'nconds'}                       ,       4, ...
    {'N Trials Per Condition';'trialsPerCond'}      ,       '20 20 20 20', ...
    {'Maximum Block Size'; 'maxRep'}    ,       3, ...
    'separator'             ,       'Timing (s)', ...
    {'Trial Duration'; 'trialDur'}, 0, ...
    {'Mean ISI';'meanISI'}          ,       3, ...
    {'Min ISI';'minISI'}            ,       2, ...
    {'Max ISI';'maxISI'}            ,       6, ...
    {'Time before first trial'; 'restBegin'}, 10, ...
    {'Time after last trial'; 'restEnd'}, 10, ...
    'separator'             ,       'Optimization Settings', ...
    {'N Designs to Save'; 'keep'},      5, ...
    {'N Generations to Run';'ngen'}            ,       50, ...
    {'N Designs Per Generation';'gensize'}            ,       1000, ...
    {'Max Time to Run (minutes)';'maxtime'}            ,       1);
catch err
    rethrow err
end
    
%% Check User Input
if strcmp(button, 'cancel') || isempty(button), return; end % canceled
params.trialsPerCond = str2num(params.trialsPerCond); 
if length(params.trialsPerCond)==1, params.trialsPerCond = repmat(params.trialsPerCond, 1, params.nconds); 
elseif length(params.trialsPerCond)~=params.nconds
    msg = sprintf('The number of entries in "N Trials Per Condition" does not match the number of conditions'); 
    errordlg(msg);
    optimizeXGUI
end
if params.minISI > params.meanISI | params.maxISI < params.meanISI
    msg = sprintf('The ISI values you''ve specified look odd: Min ISI cannot be greater than the Mean ISI, and the Max ISI cannot be less than the Mean ISI'); 
    errordlg(msg); 
    optimizeXGUI
end

%% Now, figure out contrasts of interest and importance weights
[condata, button] = settingsdlg(...
    'title'                 ,       'Settings', ...
    {'How many contrasts of interest?';'ncontrast'}                    ,       1);
if strcmp(button, 'cancel') || isempty(button), return; end
vec = repmat('0 ', 1, params.nconds);
all = [];
for c = 1:condata.ncontrast
    tmp = [{{sprintf('Vector for Contrast %d', c); sprintf('con%d', c)}}, 
        {vec}, 
        {{sprintf('Weight for Contrast %d', c); sprintf('con%dw', c)}}, 
        {1}];
    all = [all; tmp];
end
[data2, button] = settingsdlg(...
    'title', 'Contrast Specification', ...
    all{:}); 
if strcmp(button, 'cancel') || isempty(button), return; end
con = struct2cell(data2); 
params.L = [];
convec = con(1:2:end);
conweight = con(2:2:end);
params.L = []; 
params.conWeights = [];
for c = 1:length(conweight)
    params.L = [params.L; str2num(convec{c})]; 
    params.conWeights(c) = conweight{c}; 
end


%% Get X params structure, including jitter
params = defineX(params); 
%% Search for the best
optimizeX(params); 
        
end
function params = defineX(params)

%% Pulse Sequence Parameters %%
params.nslices = 16;   % number of time bins in each TR (SPM default = 16)

% Derive Some Additional Parameters %
params.ntrials=sum(params.trialsPerCond);  % computes total number of trials
params.scan_length=ceil((params.restBegin + params.restEnd + params.ntrials*(params.meanISI+params.trialDur))/params.TR);  % computes total scan length (in TRs)
params.TReff=params.TR/params.nslices;            % computes effective TR

% Get a pseudoexponential distribution of ISIs %
minISI = params.minISI;
maxISI = params.maxISI;
meanISI = params.meanISI;
TReff = params.TReff;

mu = TReff:TReff:meanISI; 
jitSample = zeros(1000,length(mu)); 
for s = 1:length(mu)
    jitSample(:,s) = random('Rayleigh', mu(s), 1000, 1);
end
jitSample(jitSample<minISI) = NaN; 
jitSample(jitSample>maxISI) = NaN;
jitdist = abs(meanISI - nanmean(jitSample));
minIDX = find(jitdist==min(jitdist));
params.jitSample = jitSample(:,minIDX(1));
params.jitSample(isnan(params.jitSample)) = []; 
% save params.mat params % save the Xparams variable

%% VISUALIZE THE RESULTS
% strucdisp(params); 
% f = figure('color', 'white', 'units', 'normal', 'position', [.25 .30 .25 .30], 'menubar','none', 'name', 'Result');
% facecolor = [0.50196      0.69412      0.82745];  
% hist(params.jitSample); 
% h = findobj(gca,'Type','patch');
% set(h,'FaceColor',facecolor)
% xlabel('SOA (s)', 'fontname', 'Arial', 'fontsize', 16);
% ylabel('Frequency', 'fontname', 'Arial', 'fontsize', 16);
% title('Jitter will be sampled from this population of SOAs', 'fontname', 'Arial', 'fontsize', 18);
% box off

end
function optimizeX(params)

% paramfile = 'params.mat';
keep = params.keep; 
L = params.L;
conWeights = params.conWeights; 
gensize = params.gensize; 
ngen = params.ngen; 
maxtime = params.maxtime; 

%% Derive Some Settings %%
nalpha = round(gensize*.005);
halfgen = gensize/2;
quartgen = gensize/4;
threequartgen = halfgen + quartgen;
L(:,end+1) = 0;
L = L';

ncontrasts = size(L,2);
genbins = gensize/10:gensize/10:gensize;

%% Check Settings %%
% try load(paramfile), catch ME, error('Problem loading paramfile'); end
if size(L,1)~=params.nconds+1, error('# of columns in contrast matrix ''L'' does not equal # of conditions defined in params'); end
if length(conWeights)~=size(L,2), error('# of contrast weights does not equal # of contrasts'); end

%% Begin Optimization %%
[d, t] = get_timestamp;
fprintf('\nDesign Optimization Started %s on %s', t, d); 
fprintf('\n\n\tDESIGN PARAMETERS\n');
strucdisp(params)
tic; % start the timer

%% Create First Generation %%
fprintf('\nGeneration 001/%03d ', ngen);
efficiency = zeros(gensize,1);
order = cell(gensize,1);
jitter = cell(gensize,1);
for i = 1:gensize
    
    d=makeX(params);
    X=d.X;
    X(:,end+1) = 1;
    for c = 1:ncontrasts
        eff(c) = 1/trace(L(:,c)'*pinv(X'*X)*L(:,c));
    end
    efficiency(i) = eff*conWeights';
    order{i} = d.combined(:,2);
    jitter{i} = d.combined(:,5);
    if ismember(i,genbins), fprintf('.'), end

end
fprintf(' Max Efficiency = %2.15f', max(efficiency));
maxgeneff(1) = max(efficiency);

%% Visualize the Best and Worst %%
winneridx = find(efficiency==max(efficiency)); 
loseridx = find(efficiency==min(efficiency)); 
winner = breedX(params, order{winneridx(1)}, jitter{winneridx(1)});
winner = scalemat(winner(1).X);
winner = [winner ones(size(winner,1), 1)];
loser = breedX(params, order{loseridx(1)}, jitter{loseridx(1)});
loser = scalemat(loser(1).X);
loser = [loser ones(size(loser,1), 1)];

%% Visualize the Best Design
% figure('color', 'white', 'units', 'normal', 'position', [.30 .30 .60 .40], 'menubar','none', 'name', 'Result');
% subplot(1,2,1); vx(1) = imagesc(winner); colormap('gray');
% set(gca, 'FontName', 'Arial', 'FontSize', 18);
% ylabel('TR', 'fontsize', 18, 'fontweight', 'bold');
% title('Best X So Far', 'fontsize', ceil(18*1.10), 'fontweight', 'bold');
% subplot(1,2,2); vx(2) = imagesc(loser); colormap('gray');
% set(gca, 'FontName', 'Arial', 'FontSize', 18);
% ylabel('TR', 'fontsize', 18, 'fontweight', 'bold');
% title('Worst X So Far', 'fontsize', ceil(18*1.10), 'fontweight', 'bold');

%% Loop Over Remaining Generations %%
for g = 2:ngen

    fprintf('\nGeneration %03d/%03d ', g, ngen);
    
    %% Grab the Alphas %%
    tmp = sortrows([(1:length(efficiency))' efficiency], -2);
    fitidx = tmp(1:nalpha,1);
    fit.efficiency = efficiency(fitidx);
    fit.order = order(fitidx);
    fit.jitter = jitter(fitidx);
    
    %% Use the Alphas to Breed %%
    cross.efficiency = zeros(halfgen,1);
    cross.order = cell(halfgen,1);
    cross.jitter = cell(halfgen,1);
    for i = 1:halfgen
        
        %% Combine Orders %%
        conidx = randperm(params.nconds);
        orderidx = randperm(length(fit.order));
        fixcon = conidx(1); 
        varcon = conidx(2:end);
        calpha = fit.order{orderidx(1)};
        mate = fit.order{orderidx(2)};
        calpha(ismember(calpha,varcon)) = mate(ismember(mate,varcon));
        d=makeX(params, calpha);
        X=d.X;
        X(:,end+1) = 1;
        for c = 1:ncontrasts
            eff(c) = 1/trace(L(:,c)'*pinv(X'*X)*L(:,c));
        end
        cross.efficiency(i) = eff*conWeights';
        cross.order{i} = d.combined(:,2);
        cross.jitter{i} = d.combined(:,5);
        if ismember(i,genbins), fprintf('.'), end

    end
    
    %% Introduce Some Nasty Mutants %%
    if g>2 && maxgeneff(g-1)==maxgeneff(g-2)
        mutsize = gensize;
    else
        mutsize = halfgen;
    end
    mut.efficiency = zeros(mutsize,1);
    mut.order = cell(mutsize,1);
    mut.jitter = cell(mutsize,1);
    for i = 1:mutsize
        d=makeX(params);
        X=d.X;
        X(:,end+1) = 1;
        for c = 1:ncontrasts
            eff(c) = 1/trace(L(:,c)'*pinv(X'*X)*L(:,c));
        end
        mut.efficiency(i) = eff*conWeights';
        mut.order{i} = d.combined(:,2);
        mut.jitter{i} = d.combined(:,5);
        if ismember(i,genbins), fprintf('.'), end
    end
    
     %% Combine this Genertation and Compute Max Efficiency %%
    efficiency = [fit.efficiency; cross.efficiency; mut.efficiency];
    order = [fit.order; cross.order; mut.order];
    jitter = [fit.jitter; cross.jitter; mut.jitter];
    fprintf(' Max Efficiency = %2.15f', max(efficiency));
    maxgeneff(g) = max(efficiency);
    
    %% Break if Over Time %%
    if toc>=maxtime*60, break, end
    
    %% UPDATE VISUALIZATION
%     winneridx = find(efficiency==max(efficiency)); 
%     loseridx = find(efficiency==min(efficiency)); 
%     winner = breedX(params, order{winneridx(1)}, jitter{winneridx(1)});
%     winner = scalemat(winner(1).X);
%     winner = [winner ones(size(winner,1), 1)];
%     loser = breedX(params, order{loseridx(1)}, jitter{loseridx(1)});
%     loser = scalemat(loser(1).X);
%     loser = [loser ones(size(loser,1), 1)];
%     set(vx(1), 'CData', winner); 
%     set(vx(2), 'CData', loser); 

end

%% Save Best Designs %%
[d, t] = get_timestamp;
outdir = sprintf('best_designs_%s_%s', d, t); mkdir(outdir);
tmp = sortrows([(1:length(efficiency))' efficiency], -2);
fitidx = tmp(1:keep,1);
best.efficiency = efficiency(fitidx);
best.order = order(fitidx);
best.jitter = jitter(fitidx);
design = cell(keep,1);
for i = 1:keep
    design{i}=breedX(params, best.order{i}, best.jitter{i});
    fname = [outdir filesep 'design' num2str(i) '.txt'];
    dlmwrite(fname, design{i}.combined, 'delimiter', '\t')
    fname2 = [outdir filesep 'design' num2str(i) '.csv'];
    cc = [{'Trial' 'Condition' 'Onset' 'Duration' 'ISI'}; num2cell(design{i}.combined)]; 
    writedesign(cc, fname2); 
end
save([outdir filesep 'designinfo.mat'], 'design', 'params');
fprintf('\n\nFinished in %d minutes at %s on %s\n\n', round(toc/60), t, d);

%% Visualize the Best Design
figure('color', 'white', 'units', 'normal', 'position', [.30 .30 .30 .40]); 
winner = scalemat(design{1}.X);
winner = [winner ones(size(winner,1), 1)];
imagesc(winner); colormap('gray');
set(gca, 'FontName', 'Arial', 'FontSize', 18);
ylabel('TR', 'fontsize', 18, 'fontweight', 'bold');
title('The "Best" Design Matrix', 'fontsize', ceil(18*1.10), 'fontweight', 'bold');
end
function design = makeX(params, order)
if nargin==1, makeorder = 1; else makeorder = 0; end

%-----------------------------------------------------------------
% Get a pseudoexponential distribution of ISIs 
%-----------------------------------------------------------------
goodJit=0;
while goodJit==0
    jitters=randsample(params.jitSample,params.ntrials-1,1);
    if mean(jitters) < params.meanISI+params.TReff && mean(jitters) > params.meanISI-params.TReff
       goodJit=1;
    end
end

%-----------------------------------------------------------------
% Determine stimulus onset times
%-----------------------------------------------------------------
onset=zeros(1,params.ntrials);
onset(1)=params.restBegin;
for t=2:params.ntrials,
  onset(t)=onset(t-1) + params.trialDur + jitters(t-1);
end;
jitters(end+1)=params.restEnd;

%-----------------------------------------------------------------
% Make some trial orders
%-----------------------------------------------------------------
if makeorder
    order = [];
    for i = 1:params.nconds, order = [order; repmat(i, params.trialsPerCond(i), 1)];end
    move_on = 0;
    while ~move_on
        tmp = order(randperm(params.ntrials)); 
        nchunk = getchunks(tmp); 
        if ~any(nchunk>params.maxRep), move_on = 1; end
    end
    order = tmp; 
end
%------------------------------------------------------------------------
% Create the design matrix (oversample the HRF depending on effective TR)
%------------------------------------------------------------------------
cond=order;
oversamp_rate=params.TR/params.TReff;
dmlength=params.scan_length*oversamp_rate;
oversamp_onset=(onset/params.TR)*oversamp_rate;
hrf=spm_hrf(params.TReff);  
desmtx=zeros(dmlength,params.nconds);
for c=1:params.nconds
  r=zeros(1,dmlength);
  cond_trials= cond==c;
  cond_ons=fix(oversamp_onset(cond_trials))+1;
  r(cond_ons)=1;
  cr=conv(r,hrf);
  desmtx(:,c)=cr(1:dmlength)';
  onsets{c}=onset(cond==c);  % onsets in actual TR timescale
end;
% sample the design matrix back into TR timescale
desmtx=desmtx(1:oversamp_rate:dmlength,:);

%------------------------------------------------------------------------
% Filter the design matrix
%------------------------------------------------------------------------
K.RT = params.TR;
K.HParam = params.hpf;
K.row = 1:length(desmtx);
K = spm_filter(K);
for c=1:params.nconds
    desmtx(:,c)=spm_filter(K,desmtx(:,c));
end

%------------------------------------------------------------------------
% Save the design matrix
%------------------------------------------------------------------------
design.X = desmtx;
design.combined=zeros(params.ntrials,5);
design.combined(:,1)=1:params.ntrials;
design.combined(:,2)=cond;
design.combined(:,3)=onset;
design.combined(:,4)=repmat(params.trialDur,params.ntrials,1);
design.combined(:,5)=jitters;
design.duration=(params.scan_length*params.TR)/60;
end
function design = breedX(params, order, jitters)
% USAGE: design = breedX(params, order, jitters)
if nargin<3, display('USAGE: design = breedX(params, order, jitters)'), return, end

%-----------------------------------------------------------------
% Determine stimulus onset times
%-----------------------------------------------------------------
onset=zeros(1,params.ntrials);
onset(1)=params.restBegin;
for t=2:params.ntrials,
  onset(t)=onset(t-1) + params.trialDur + jitters(t-1);
end;

%------------------------------------------------------------------------
% Create the design matrix (oversample the HRF depending on effective TR)
%------------------------------------------------------------------------
cond=order;
oversamp_rate=params.TR/params.TReff;
dmlength=params.scan_length*oversamp_rate;
oversamp_onset=(onset/params.TR)*oversamp_rate;
hrf=spm_hrf(params.TReff);  
desmtx=zeros(dmlength,params.nconds);
for c=1:params.nconds
  r=zeros(1,dmlength);
  cond_trials= cond==c;
  cond_ons=fix(oversamp_onset(cond_trials))+1;
  r(cond_ons)=1;
  cr=conv(r,hrf);
  desmtx(:,c)=cr(1:dmlength)';
  onsets{c}=onset(cond==c);  % onsets in actual TR timescale
end;
% sample the design matrix back into TR timescale
desmtx=desmtx(1:oversamp_rate:dmlength,:);

%------------------------------------------------------------------------
% Filter the design matrix
%------------------------------------------------------------------------
K.RT = params.TR;
K.HParam = params.hpf;
K.row = 1:length(desmtx);
K = spm_filter(K);
for c=1:params.nconds
    desmtx(:,c)=spm_filter(K,desmtx(:,c));
end

%------------------------------------------------------------------------
% Save the design matrix
%------------------------------------------------------------------------
design.X = desmtx;
design.combined=zeros(params.ntrials,5);
design.combined(:,1)=1:params.ntrials;
design.combined(:,2)=cond;
design.combined(:,3)=onset;
design.combined(:,4)=repmat(params.trialDur,params.ntrials,1);
design.combined(:,5)=jitters;
design.duration=(params.scan_length*params.TR)/60;
end
function [settings, button] = settingsdlg(varargin)
% SETTINGSDLG             Default dialog to produce a settings-structure
%
% settings = SETTINGSDLG('fieldname', default_value, ...) creates a modal
% dialog box that returns a structure formed according to user input. The
% input should be given in the form of 'fieldname', default_value - pairs,
% where 'fieldname' is the fieldname in the structure [settings], and
% default_value the initial value displayed in the dialog box. 
%
% SETTINGSDLG uses UIWAIT to suspend execution until the user responds.
%
% settings = SETTINGSDLG(settings) uses the structure [settings] to form
% the various input fields. This is the most basic (and limited) usage of
% SETTINGSDLG.
%
% [settings, button] = SETTINGSDLG(settings) returns which button was
% pressed, in addition to the (modified) structure [settings]. Either 'ok',
% 'cancel' or [] are possible values. The empty output means that the
% dialog was closed before either Cancel or OK were pressed. 
%
% SETTINGSDLG('title', 'window_title') uses 'window_title' as the dialog's
% title. The default is 'Adjust settings'. 
%
% SETTINGSDLG('description', 'brief_description',...) starts the dialog box
% with 'brief_description', followed by the input fields.   
%
% SETTINGSDLG('windowposition', P, ...) positions the dialog box according to
% the string or vector [P]; see movegui() for valid values.  
%
% SETTINGSDLG( {'display_string', 'fieldname'}, default_value,...) uses the
% 'display_string' in the dialog box, while assigning the corresponding
% user-input to fieldname 'fieldname'. 
%
% SETTINGSDLG(..., 'checkbox_string', true, ...) displays a checkbox in
% stead of the default edit box, and SETTINGSDLG('fieldname', {'string1', 
% 'string2'},... ) displays a popup box with the strings given in 
% the second cell-array.
%
% Additionally, you can put [..., 'separator', 'seperator_string',...]
% anywhere in the argument list, which will divide all the arguments into
% sections, with section headings 'seperator_string'.
%
% You can also modify the display behavior in the case of checkboxes. When
% defining checkboxes with a 2-element logical array, the second boolean
% determines whether all fields below that checkbox are initially disabled
% (true) or not (false). 
%
% Example:
% 
% [settings, button] = settingsdlg(...
%     'Description', 'This dialog will set the parameters used by FMINCON()',... 
%     'title'      , 'FMINCON() options',...
%     'separator'  , 'Unconstrained/General',...
%     {'This is a checkbox'; 'Check'}, [true true],...
%     {'Tolerance X';'TolX'}, 1e-6,...
%     {'Tolerance on Function';'TolFun'}, 1e-6,...
%     'Algorithm'  , {'active-set','interior-point'},...
%     'separator'  , 'Constrained',...    
%     {'Tolerance on Constraints';'TolCon'}, 1e-6)
% 
% See also inputdlg, dialog, errordlg, helpdlg, listdlg, msgbox, questdlg, textwrap, 
% uiwait, warndlg.
    

% Please report bugs and inquiries to: 
%
% Name       : Rody P.S. Oldenhuis
% E-mail     : oldenhuis@gmail.com    (personal)
%              oldenhuis@luxspace.lu  (professional)
% Affiliation: LuxSpace s�rl
% Licence    : BSD


% Changelog
%{
2014/July/07 (Rody Oldenhuis)
- FIXED: The example in the help section didn't work correctly 
  (thanks Elco Bakker)

2014/February/14 (Rody Oldenhuis)
- Implemented window positioning option as suggested by Terrance Nearey.
  The option is called 'WindowPosition', with valid values equal to those
  of movegui().
- Updated contact info, donation link
- Started changelog

%}


% If you find this work useful, please consider a donation:
% https://www.paypal.com/cgi-bin/webscr?cmd=_s-xclick&hosted_button_id=6G3S5UYM7HJ3N
    
    %% Initialize
        
    % errortraps
    narg = nargin;
    error(nargchk(1, inf, narg, 'struct'));
        
    % parse input (+errortrap) 
    have_settings = 0;
    if isstruct(varargin{1})
        settings = varargin{1}; have_settings = 1; end
    if (narg == 1)
        if isstruct(varargin{1})
            parameters = fieldnames(settings);
            values = cellfun(@(x)settings.(x), parameters, 'UniformOutput', false);
        else
            error('settingsdlg:incorrect_input',...
                'When pasing a single argument, that argument must be a structure.')
        end
    else
        parameters = varargin(1+have_settings : 2 : end);
        values     = varargin(2+have_settings : 2 : end);
    end
    
    % Initialize data    
    button = [];
    fields = cell(numel(parameters),1);
    tags   = fields;
    
    % Fill [settings] with default values & collect data
    for ii = 1:numel(parameters)
        
        % Extract fields & tags
        if iscell(parameters{ii})
            tags{ii}   = parameters{ii}{1};
            fields{ii} = parameters{ii}{2};            
        else 
            % More errortraps
            if ~ischar(parameters{ii})
                error('settingsdlg:nonstring_parameter',...
                'Arguments should be given as [''parameter'', value,...] pairs.')
            end
            tags{ii}   = parameters{ii};
            fields{ii} = parameters{ii};            
        end
        
        % More errortraps
        if ~ischar(fields{ii})
            error('settingsdlg:fieldname_not_char',...
                'Fieldname should be a string.')
        end
        if ~ischar(tags{ii})
            error('settingsdlg:tag_not_char',...
                'Display name should be a string.')
        end
        
        % NOTE: 'Separator' is now in 'fields' even though 
        % it will not be used as a fieldname
        
        % Make sure all fieldnames are properly formatted
        % (alternating capitals, no whitespace)
        if ~strcmpi(fields{ii}, {'Separator';'Title';'Description'})
            whitespace = isspace(fields{ii});
            capitalize = circshift(whitespace,[0,1]);
            fields{ii}(capitalize) = upper(fields{ii}(capitalize));
            fields{ii} = fields{ii}(~whitespace);
            % insert associated value in output
            if iscell(values{ii})
                settings.(fields{ii}) = values{ii}{1};
            elseif (length(values{ii}) > 1)
                settings.(fields{ii}) = values{ii}(1);
            else
                settings.(fields{ii}) = values{ii};
            end
        end        
    end
    
    % Avoid (some) confusion
    clear parameters
    
    % Use default colorscheme from the OS
    bgcolor = get(0, 'defaultUicontrolBackgroundColor');
    bgcolor = [234 234 230]/255;
    fgcolor = [0 0 0];
    % Default fontsize
    fontsize = get(0, 'defaultuicontrolfontsize'); 
    fontsize = fontsize*1.33; 
    % Edit-bgcolor is platform-dependent. 
    % MS/Windows: white. 
    % UNIX: same as figure bgcolor
%     if ispc, edit_bgcolor = 'White';
%     else     edit_bgcolor = bgcolor;
%     end

% TODO: not really applicable since defaultUicontrolBackgroundColor 
% doesn't really seem to work on Unix...
edit_bgcolor = 'White';
    
    % Get basic window properties
    title         = getValue('Adjust settings', 'Title');
    description   = getValue( [], 'Description');
    total_width   = getValue(325, 'WindowWidth');     
    control_width = getValue(100, 'ControlWidth');       
    
    % Window positioning:     
    % Put the window in the center of the screen by default.
    % This will usually work fine, except on some  multi-monitor setups.     
    scz  = get(0, 'ScreenSize'); 
    scxy = round(scz(3:4)/2-control_width/2);    
    scx  = min(scz(3),max(1,scxy(1)));
    scy  = min(scz(4),max(1,scxy(2)));
    
    % String to pass on to movegui
    window_position = getValue('center', 'WindowPosition');   
    
        
    % Calculate best height for all uicontrol()
    control_height = max(18, (fontsize+6));
    
    % Calculate figure height (will be adjusted later according to description)
    total_height = numel(fields)*1.25*control_height + ... % to fit all controls
                     1.5*control_height + 20; % to fit "OK" and "Cancel" buttons
                 
    % Total number of separators
    num_separators = nnz(strcmpi(fields,'Separator'));
        
    % Draw figure in background
    fighandle = figure(...
         'integerhandle'   , 'off',...         % use non-integers for the handle (prevents accidental plots from going to the dialog)
         'Handlevisibility', 'off',...         % only visible from within this function
         'position'        , [scx, scy, total_width, total_height],...% figure position
         'visible'         , 'off',...         % hide the dialog while it is being constructed
         'backingstore'    , 'off',...         % DON'T save a copy in the background         
         'resize'          , 'off', ...        % but just keep it resizable
         'renderer'        , 'zbuffer', ...    % best choice for speed vs. compatibility
         'WindowStyle'     ,'modal',...        % window is modal
         'units'           , 'pixels',...      % better for drawing
         'DockControls'    , 'off',...         % force it to be non-dockable
         'name'            , title,...         % dialog title
         'menubar'         ,'none', ...        % no menubar of course
         'toolbar'         ,'none', ...        % no toolbar
         'NumberTitle'     , 'off',...         % "Figure 1.4728...:" just looks corny
         'Defaultuicontrolfontsize', fontsize, ...
         'color'           , bgcolor);         % use default colorscheme
          
    %% Draw all required uicontrols(), and unhide window 
    
    % Define X-offsets (different when separators are used)
    separator_offset_X = 2;
    if num_separators > 0
        text_offset_X = 20;
        text_width = (total_width-control_width-text_offset_X);        
    else
        text_offset_X = separator_offset_X;
        text_width = (total_width-control_width);
    end
    
    % Handle description
    description_offset = 0;
    if ~isempty(description)
        
        % create textfield (negligible height initially)
        description_panel = uicontrol(...
            'parent'  , fighandle,...
            'style'   , 'text',...
            'backgroundcolor', bgcolor, ...
                    'foreg', fgcolor, ...
            'Horizontalalignment', 'left',...
            'position', [separator_offset_X,...
                         total_height,total_width,1]);
                     
        % wrap the description
        description = textwrap(description_panel, {description});        
        
        % adjust the height of the figure        
        textheight = size(description,1)*(fontsize+6);
        description_offset = textheight + 20;        
        total_height = total_height + description_offset;
        set(fighandle,...
            'position', [scx, scy, total_width, total_height])        
        
        % adjust the position of the textfield and insert the description        
        set(description_panel, ...
            'string'  , description,...
            'position', [separator_offset_X, total_height-textheight, ...
                         total_width, textheight]);
    end
    
    % Define Y-offsets (different when descriptions are used)
    control_offset_Y = total_height-control_height-description_offset;
    
    % initialize loop
    controls = zeros(numel(tags)-num_separators,1);    
    ii = 1;             sep_ind = 1;
    enable = 'on';      separators = zeros(num_separators,1);
    
    % loop through the controls
    if numel(tags) > 0
        while true
            
            % Should we draw a separator?
            if strcmpi(tags{ii}, 'Separator')
                
                % Print separator
                uicontrol(...
                    'style'   , 'text',...
                    'parent'  , fighandle,...
                    'string'  , values{ii},...
                    'horizontalalignment', 'left',...
                    'fontweight', 'bold',...
                    'backgroundcolor', bgcolor, ...
                    'foreg',fgcolor, ...
                    'fontsize', fontsize, ...
                    'position', [separator_offset_X,control_offset_Y-4, ...
                    total_width, control_height]);
                
                % remove separator, but save its position
                fields(ii) = [];
                tags(ii)   = [];  separators(sep_ind) = ii;
                values(ii) = [];  sep_ind = sep_ind + 1;
                
                % reset enable (when neccessary)
                if strcmpi(enable, 'off')
                    enable = 'on'; end
                
                % NOTE: DON'T increase loop index
                
            % ... or a setting?
            else
                
                % logicals: use checkbox
                if islogical(values{ii})
                    
                    % First draw control
                    controls(ii) = uicontrol(...
                        'style'   , 'checkbox',...
                        'parent'  , fighandle,...
                                    'backgroundcolor', bgcolor, ...
                    'foreg', 'white', ...
                        'enable'  , enable,...
                        'string'  , tags{ii},...
                        'value'   , values{ii}(1),...
                        'position', [text_offset_X,control_offset_Y-4, ...
                        total_width, control_height]);
                    
                    % Should everything below here be OFF?
                    if (length(values{ii})>1)
                        % turn next controls off when asked for
                        if values{ii}(2)
                            enable = 'off'; end
                        % Turn on callback function
                        set(controls(ii),...
                            'Callback', @(varargin) EnableDisable(ii,varargin{:}));
                    end
                    
                % doubles      : use edit box
                % cells        : use popup
                % cell-of-cells: use table
                else
                    % First print parameter
                    uicontrol(...
                        'style'   , 'text',...
                        'parent'  , fighandle,...
                        'string'  , [tags{ii}, ':'],...
                        'horizontalalignment', 'left',...
                                    'backgroundcolor', bgcolor, ...
                    'foreg', fgcolor, ...
                        'position', [text_offset_X,control_offset_Y-4, ...
                        text_width, control_height]);
                    
                    % Popup, edit box or table?
                    style = 'edit';
                    draw_table = false;
                    if iscell(values{ii})
                        style = 'popup';
                        if all(cellfun('isclass', values{ii}, 'cell'))
                            draw_table = true; end
                    end
                    
                    % Draw appropriate control
                    if ~draw_table
                        controls(ii) = uicontrol(...
                            'enable'  , enable,...
                            'style'   , style,...
                            'Background', edit_bgcolor,...
                            'parent'  , fighandle,...
                            'string'  , values{ii},...
                            'position', [text_width,control_offset_Y,...
                            control_width, control_height]);
                    else
                        % TODO
                        % ...table? ...radio buttons? How to do this?
                        warning(...
                            'settingsdlg:not_yet_implemented',...
                            'Treatment of cells is not yet implemented.');
                        
                    end
                end
                
                % increase loop index
                ii = ii + 1;
            end
            
            % end loop?
            if ii > numel(tags)
                break, end
            
            % Decrease offset
            control_offset_Y = control_offset_Y - 1.25*control_height;
        end
    end
    
    % Draw cancel button
    uicontrol(...
        'style'   , 'pushbutton',...
        'parent'  , fighandle,...
        'string'  , 'Cancel',...
        'position', [separator_offset_X,2, total_width/2.5,control_height*1.5],...
        'Callback', @Cancel)
    
    % Draw OK button
    uicontrol(...
        'style'   , 'pushbutton',...
        'parent'  , fighandle,...
        'string'  , 'OK',...
        'position', [total_width*(1-1/2.5)-separator_offset_X,2, ...
                     total_width/2.5,control_height*1.5],...
        'Callback', @OK)  
    
    % move to center of screen and make visible
    movegui(fighandle, window_position);
    set(fighandle, 'Visible', 'on');
    
    % WAIT until OK/Cancel is pressed
    uiwait(fighandle);
    
    
    
    %% Helper funcitons
    
    % Get a value from the values array: 
    % - if it does not exist, return the default value
    % - if it exists, assign it and delete the appropriate entries from the
    %   data arrays
    function val = getValue(default, tag)        
        index = strcmpi(fields, tag);        
        if any(index)
            val = values{index};
            values(index) = [];
            fields(index) = [];
            tags(index)   = [];
        else
            val = default;
        end
    end
    
    %% callback functions
    
    % Enable/disable controls associated with (some) checkboxes
    function EnableDisable(which, varargin) %#ok<VANUS>
        
        % find proper range of controls to switch
        if (num_separators > 1)
             range = (which+1):(separators(separators > which)-1);
        else range = (which+1):numel(controls);
        end
        
        % enable/disable these controls
        if strcmpi(get(controls(range(1)), 'enable'), 'off')
            set(controls(range), 'enable', 'on')
        else
            set(controls(range), 'enable', 'off')
        end
    end
    
    % OK button: 
    % - update fields in [settings]
    % - assign [button] output argument ('ok')
    % - kill window
    function OK(varargin) %#ok<VANUS>
        
        % button pressed
        button = 'OK';
        
        % fill settings
        for i = 1:numel(controls)
            
            % extract current control's string, value & type            
            str   = get(controls(i), 'string');
            val   = get(controls(i), 'value');
            style = get(controls(i), 'style');
            
            % popups/edits
            if ~strcmpi(style, 'checkbox')
                % extract correct string (popups only)
                if strcmpi(style, 'popupmenu'), str = str{val}; end
                % try to convert string to double
                val = str2double(str); 
                % insert this double in [settings]. If it was not a 
                % double, insert string instead
                if ~isnan(val), settings.(fields{i}) = val;
                else            settings.(fields{i}) = str;
                end  
                
            % checkboxes
            else
                % we can insert value immediately
                settings.(fields{i}) = val;
            end
        end
        
        %  kill window
        delete(fighandle);
    end
    
    % Cancel button:
    % - assign [button] output argument ('cancel')
    % - delete figure (so: return default settings)
    function Cancel(varargin) %#ok<VANUS>
        button = 'cancel';
        delete(fighandle);
    end
    
end
function [day, time] = get_timestamp(varargin)
% GET_TIMESTAMP
%
%   USAGE: [day time] = get_timestamp
%
%       day: mmm_DD_YYYY
%       time: HHMMSSPM
% ===============================================%
day = strtrim(datestr(now,'mmm_DD_YYYY'));
time = strtrim(datestr(now,'HHMMSSPM'));

end
function out = scalemat(in)
% SCALEMAT
%
%   USAGE: out = scalemat(in)
% 
%   images = volumes to harvest from
%   roi = volume with roi
%   method = 0: mean, >0: pca (value specifies number of dimensions)
%
% ------------------------------------------------------------------------
if nargin<1, display('out = scalemat(in)'); return; end
out = in;
c = size(in, 2);
mn = min(in);
mx = max(in);
for i = 1:c
    out(:,i) = (in(:,i) - mn(i))/(mx(i)-mn(i));
end
end
function [d, id] = getchunks(a, opt)

%GETCHUNKS Get the number of repetitions that occur in consecutive chunks.
%   C = GETCHUNKS(A) returns an array of n elements, where n is the number
%   of consecutive chunks (2 or more repetitions) in A, and each element is
%   the number of repetitions in each chunk. A can be LOGICAL, any
%   numeric vector, or CELL array of strings. It can also be a character
%   array (see below, for its special treatment).
%
%   [C, I] = GETCHUNKS(A) also returns the indices of the beginnings of the
%   chunks.
%
%   If A is a character array, then it finds words (consecutive
%   non-spaces), returning the number of chararcters in each word and the
%   indices to the beginnings of the words.
%
%   GETCHUNKS(A, OPT) accepts an optional argument OPT, which can be any of
%   the following three:
%
%       '-reps'  : return repeating chunks only. (default)
%       '-full'  : return chunks including single-element chunks.
%       '-alpha' : (for CHAR arrays) only consider alphabets and numbers as
%                  part of words. Punctuations and symbols are regarded as
%                  spaces.
%
%   Examples:
%     A = [1 2 2 3 4 4 4 5 6 7 8 8 8 8 9];
%     getchunks(A)
%       ans =
%           2   3   4
%
%
%     B = 'This is a generic (simple) sentence';
%     [C, I] = getchunks(B)
%       C =
%            4     2     1     7     8     8
%       I =
%            1     6     9    11    19    28
%
%
%     [C, I] = getchunks(B, '-alpha')
%       C =
%            4     2     1     7     6     8
%       I =
%            1     6     9    11    20    28
%
%   See also HIST, HISTC.
%
%   VERSIONS:
%     v1.0 - first version
%     v1.0.1 - added option '-alpha'
%

% Copyright 2009 The MathWorks, Inc.

%--------------------------------------------------------------------------
% Error checking
%--------------------------------------------------------------------------
error(nargchk(1, 2, nargin));
if ndims(a) > 2 || min(size(a)) > 1
  error('Input must be a 2-D vector');
end

alphanumeric = false;
fullList     = false;

%--------------------------------------------------------------------------
% Process options
%--------------------------------------------------------------------------
if nargin == 2
  if ~ischar(opt)
    error('Additional argument must be a string array');
  end
  
  % Allow for partial arguments
  possibleOptions = ['-full '; '-reps '; '-alpha'];
  iOpt = strmatch(lower(opt), possibleOptions);
  
  if isempty(iOpt) || length(iOpt) > 1
    error('Invalid option. Allowed option: ''-full'', ''-reps'', ''-alpha''');
  else
    switch iOpt
      
      case 1  % '-full'
        % Include single-element chunks
        fullList = true;
        if ischar(a)
          fprintf('''-full'' option not applicable to CHAR arrays.\n');
        end
        
      case 2  % '-reps'
        % Only find 2 or more repeating blocks
        fullList = false;
        
      case 3  % '-alpha'
        % For char arrays, only consider alphabets and numbers as part of
        % words. Punctuations and symbols are regarded as space.
        alphanumeric = true;
        if ~ischar(a)
          fprintf('''-alpha'' option only applicable to CHAR arrays.\n');
        end
        
    end
  end
end

%--------------------------------------------------------------------------
% Convert to a row vector for STRFIND
%--------------------------------------------------------------------------
a = a(:)';

%--------------------------------------------------------------------------
% Deal with differet classes
%--------------------------------------------------------------------------
switch class(a)
  
  case 'double'
    % Leave as is
    
  case {'logical', 'uint8', 'int8', 'uint16', 'int16', 'uint32', 'int32', 'single'}
    % Convert to DOUBLE
    a = double(a);
    
  case 'char'
    if alphanumeric % Get alphabet and number locations
      try % call C-helper function directly (slightly faster)
        a = isletter(a) | ismembc(a, 48:57);
      catch %#ok<CTCH>
        a = isletter(a) | ismember(a, 48:57);
      end
      
    else  % Get non-space locations
      a = ~isspace(a);  
    end
  
  case 'cell'
    % Convert cell array of strings into unique numbers
    if all(cellfun('isclass', a, 'char'))
      [tmp, tmp, a] = unique(a); %#ok<ASGLU>
    else
      error('Cell arrays must be array of strings.');
    end
    
  otherwise
    error('Invalid type. Allowed type: CHAR, LOGICAL, NUMERIC, and CELL arrays of strings.');
end

%--------------------------------------------------------------------------
% Character arrays (now LOGICAL) are dealt differently
%--------------------------------------------------------------------------
if islogical(a)
  % Pad the array
  a  = [false, a, false];

  % Here's a very convoluted engine
  b  = diff(a);
  id = strfind(b, 1);
  d  = strfind(b, -1) - id;

%--------------------------------------------------------------------------
% Everything else (numeric arrays) are processed here
else
  % Pad the array
  a                 = [NaN, a, NaN];

  % Here's more convoluted code
  b                 = diff(a);
  b1                = b;  % to be used in fullList (below)
  ii                = true(size(b));
  ii(strfind(b, 0)) = false;
  b(ii)             = 1;
  c                 = diff(b);
  id                = strfind(c, -1);
  
  % Get single-element chunks also
  if fullList
  
    % And more convoluted code
    b1(id)          = 0;
    ii2             = find(b1(1:end-1));
    d               = [strfind(c, 1) - id + 1, ones(1, length(ii2))];
    id              = [id,ii2];
    [id,tmp]        = sort(id);
    d               = d(tmp);
    
  else
    
    d               = strfind(c, 1) - id + 1;
    
  end
end
function jitsample = makeJitters(minSOA, meanSOA, nTrials)
% MAKEJITTERS 
% Make jitters from Poisson distributin with specified min and mean values
%
% USAGE: jitsample = makeJitters(minSOA, meanSOA, nTrials)
%
goodjit = 0; 
while ~goodjit
    jitsample = minSOA + poissrnd(meanSOA-minSOA, nTrials, 1);
    if round(mean(jitsample)*100)==meanSOA*100, goodjit = 1; end
end
    
end
function strucdisp(Structure, depth, printValues, maxArrayLength, fileName)
%STRUCDISP  display structure outline
%
%   STRUCDISP(STRUC, DEPTH, PRINTVALUES, MAXARRAYLENGTH, FILENAME) displays
%   the hierarchical outline of a structure and its substructures. 
%
%   STRUC is a structure datatype with unknown field content. It can be 
%   either a scalar or a vector, but not a matrix. STRUC is the only
%   mandatory argument in this function. All other arguments are optional.
%
%   DEPTH is the number of hierarchical levels of the structure that are
%   printed. If DEPTH is smaller than zero, all levels are printed. Default
%   value for DEPTH is -1 (print all levels).
%
%   PRINTVALUES is a flag that states if the field values should be printed
%   as well. The default value is 1 (print values)
%
%   MAXARRAYLENGTH is a positive integer, which determines up to which
%   length or size the values of a vector or matrix are printed. For a
%   vector holds that if the length of the vector is smaller or equal to
%   MAXARRAYLENGTH, the values are printed. If the vector is longer than
%   MAXARRAYLENGTH, then only the size of the vector is printed.
%   The values of a 2-dimensional (m,n) array are printed if the number of
%   elements (m x n) is smaller or equal to MAXARRAYLENGTH.
%   For vectors and arrays, this constraint overrides the PRINTVALUES flag.
%
%   FILENAME is the name of the file to which the output should be printed.
%   if this argument is not defined, the output is printed to the command
%   window.
%
%   Contact author: B. Roossien <roossien@ecn.nl>
%   (c) ECN 2007-2008
%
%   Version 1.3.0


%% Creator and Version information
% Created by B. Roossien <roossien@ecn.nl> 14-12-2006
%
% Based on the idea of 
%       M. Jobse - display_structure (Matlab Central FileID 2031)
%
% Acknowledgements:
%       S. Wegerich - printmatrix (Matlab Central FileID 971)
%
% Beta tested by: 
%       K. Visscher
%
% Feedback provided by:
%       J. D'Errico
%       H. Krause
%       J.K. Kok
%       J. Kurzmann
%       K. Visscher
%
%
% (c) ECN 2006-2007
% www.ecn.nl
%
% Last edited on 08-03-2008



%% Version History
%
% 1.3.0 : Bug fixes and added logicals
% 1.2.3 : Buf fix - Solved multi-line string content bug
% 1.2.2 : Bug fix - a field being an empty array gave an error
% 1.2.1 : Bug fix
% 1.2.0 : Increased readability of code
%         Makes use of 'structfun' and 'cellfun' to increase speed and 
%         reduce the amount of code
%         Solved bug with empty fieldname parameter
% 1.1.2 : Command 'eval' removed with a more simple and efficient solution
% 1.1.1 : Solved a bug with cell array fields
% 1.1.0 : Added support for arrayed structures
%         Added small matrix size printing
% 1.0.1 : Bug with empty function parameters fixed
% 1.0.0 : Initial release



%% Main program
%%%%% start program %%%%%

    % first argument must be structure
    if ~isstruct(Structure)
        error('First input argument must be structure');
    end
    
    % first argument can be a scalar or vector, but not a matrix
    if ~isvector(Structure)
        error('First input argument can be a scalar or vector, but not a matrix');
    end
    
    % default value for second argument is -1 (print all levels)
    if nargin < 2 || isempty(depth)
        depth = -1;
    end

    % second argument must be an integer
    if ~isnumeric(depth)
        error('Second argument must be an integer');
    end

    % second argument only works if it is an integer, therefore floor it
    depth = floor(depth);
    
    % default value for third argument is 1
    if nargin < 3 || isempty(printValues)
        printValues = 1;
    end

    % default value for fourth argument is 10
    if nargin < 4 || isempty(maxArrayLength)
        maxArrayLength = 10;
    end

    
    % start recursive function   
    listStr = recFieldPrint(Structure, 0, depth, printValues, ... 
                            maxArrayLength);

    
    % 'listStr' is a cell array containing the output
    % Now it's time to actually output the data
    % Default is to output to the command window
    % However, if the filename argument is defined, output it into a file

    if nargin < 5 || isempty(fileName)
        
        % write data to screen
        for i = 1 : length(listStr)
            disp(cell2mat(listStr(i, 1)));
        end
        
    else
        
        % open file and check for errors
        fid = fopen(fileName, 'wt');
        
        if fid < 0
            error('Unable to open output file');
        end
        
        % write data to file
        for i = 1 : length(listStr)
            fprintf(fid, '%s\n', cell2mat(listStr(i, 1)));
        end
        
        % close file
        fclose(fid);
        
    end
    
end
function listStr = recFieldPrint(Structure, indent, depth, printValues, ...
                                 maxArrayLength)


% Start to initialiase the cell listStr. This cell is used to store all the
% output, as this is much faster then directly printing it to screen.

listStr = {};


% "Structure" can be a scalar or a vector.
% In case of a vector, this recursive function is recalled for each of
% the vector elements. But if the values don't have to be printed, only
% the size of the structure and its fields are printed.

if length(Structure) > 1

    if (printValues == 0)

        varStr = createArraySize(Structure, 'Structure');

        listStr = [{' '}; {['Structure', varStr]}];

        body = recFieldPrint(Structure(1), indent, depth, ...
                             printValues, maxArrayLength);

        listStr = [listStr; body; {'   O'}];

    else

        for iStruc = 1 : length(Structure)

            listStr = [listStr; {' '}; {sprintf('Structure(%d)', iStruc)}];

            body = recFieldPrint(Structure(iStruc), indent, depth, ...
                                 printValues, maxArrayLength);

            listStr = [listStr; body; {'   O'}];

        end

    end

    return

end


%% Select structure fields
% The fields of the structure are distinguished between structure and
% non-structure fields. The structure fields are printed first, by
% recalling this function recursively.

% First, select all fields.

fields = fieldnames(Structure);

% Next, structfun is used to return an boolean array with information of
% which fields are of type structure.

isStruct = structfun(@isstruct, Structure);

% Finally, select all the structure fields

strucFields = fields(isStruct == 1);


%% Recursively print structure fields 
% The next step is to select each structure field and handle it
% accordingly. Each structure can be empty, a scalar, a vector or a matrix.
% Matrices and long vectors are only printed with their fields and not with
% their values. Long vectors are defined as vectors with a length larger
% then the maxArrayLength value. The fields of an empty structure are not
% printed at all.
% It is not necessary to look at the length of the vector if the values
% don't have to be printed, as the fields of a vector or matrix structure
% are the same for each element.

% First, some indentation calculations are required.

strIndent = getIndentation(indent + 1);
listStr = [listStr; {strIndent}];

strIndent = getIndentation(indent);

% Next, select each field seperately and handle it accordingly

for iField = 1 : length(strucFields)

    fieldName = cell2mat(strucFields(iField));
    Field =  Structure.(fieldName);
    
    % Empty structure
    if isempty(Field)

        strSize = createArraySize(Field, 'Structure');

        line = sprintf('%s   |--- %s :%s', ...
                       strIndent, fieldName, strSize);

        listStr = [listStr; {line}];

    % Scalar structure
    elseif isscalar(Field)

        line = sprintf('%s   |--- %s', strIndent, fieldName);

        % Recall this function if the tree depth is not reached yet
        if (depth < 0) || (indent + 1 < depth)
            lines = recFieldPrint(Field, indent + 1, depth, ...
                                  printValues, maxArrayLength);

            listStr = [listStr; {line}; lines; ...
                       {[strIndent '   |       O']}];
        else
            listStr = [listStr; {line}];
        end

    % Short vector structure of which the values should be printed    
    elseif (isvector(Field)) &&  ...
           (printValues > 0) && ...
           (length(Field) < maxArrayLength) && ...
           ((depth < 0) || (indent + 1 < depth))

        % Use a for-loop to print all structures in the array
        for iFieldElement = 1 : length(Field)

            line = sprintf('%s   |--- %s(%g)', ...
                           strIndent, fieldName, iFieldElement);

            lines = recFieldPrint(field(iFieldElement), indent + 1, ...
                                 depth, printValues, maxArrayLength);

            listStr = [listStr; {line}; lines; ...
                       {[strIndent '   |       O']}];

            if iFieldElement ~= length(Field)
                listStr = [listStr; {[strIndent '   |    ']}];
            end

        end

    % Structure is a matrix or long vector
    % No values have to be printed or depth limit is reached
    else

        varStr = createArraySize(Field, 'Structure');

        line = sprintf('%s   |--- %s :%s', ...
                       strIndent, fieldName, varStr);

        lines = recFieldPrint(Field(1), indent + 1, depth, ...
                              0, maxArrayLength);

        listStr = [listStr; {line}; lines; ...
                   {[strIndent '   |       O']}];

    end

    % Some extra blank lines to increase readability
    listStr = [listStr; {[strIndent '   |    ']}];

end % End iField for-loop


%% Field Filler
% To properly align the field names, a filler is required. To know how long
% the filler must be, the length of the longest fieldname must be found.
% Because 'fields' is a cell array, the function 'cellfun' can be used to
% extract the lengths of all fields.
maxFieldLength = max(cellfun(@length, fields));

%% Print non-structure fields without values
% Print non-structure fields without the values. This can be done very
% quick.
if printValues == 0
    
    noStrucFields = fields(isStruct == 0);

    for iField  = 1 : length(noStrucFields)

        Field = cell2mat(noStrucFields(iField));

        filler = char(ones(1, maxFieldLength - length(Field) + 2) * 45);

        listStr = [listStr; {[strIndent '   |' filler ' ' Field]}];

    end

    return

end


%% Select non-structure fields (to print with values)
% Select fields that are not a structure and group them by data type. The
% following groups are distinguished:
%   - characters and strings
%   - numeric arrays
%   - logical
%   - empty arrays
%   - matrices
%   - numeric scalars
%   - cell arrays
%   - other data types

% Character or string (array of characters)
isChar = structfun(@ischar, Structure);
charFields = fields(isChar == 1);

% Numeric fields
isNumeric = structfun(@isnumeric, Structure);

% Numeric scalars
isScalar = structfun(@isscalar, Structure);
isScalar = isScalar .* isNumeric;
scalarFields = fields(isScalar == 1);

% Numeric vectors (arrays)
isVector = structfun(@isvector, Structure);
isVector = isVector .* isNumeric .* not(isScalar);
vectorFields = fields(isVector == 1);

% Logical fields
isLogical = structfun(@islogical, Structure);
logicalFields = fields(isLogical == 1);

% Empty arrays
isEmpty = structfun(@isempty, Structure);
emptyFields = fields(isEmpty == 1);

% Numeric matrix with dimension size 2 or higher
isMatrix = structfun(@(x) ndims(x) >= 2, Structure);
isMatrix = isMatrix .* isNumeric .* not(isVector) ...
                    .* not(isScalar) .* not(isEmpty);
matrixFields = fields(isMatrix == 1);

% Cell array
isCell = structfun(@iscell, Structure);
cellFields = fields(isCell == 1);

% Datatypes that are not checked for
isOther = not(isChar + isNumeric + isCell + isStruct + isLogical + isEmpty);
otherFields = fields(isOther == 1);



%% Print non-structure fields
% Print all the selected non structure fields
% - Strings are printed to a certain amount of characters
% - Vectors are printed as long as they are shorter than maxArrayLength
% - Matrices are printed if they have less elements than maxArrayLength
% - The values of cells are not printed


% Start with printing strings and characters. To avoid the display screen 
% becoming a mess, the part of the string that is printed is limited to 31 
% characters. In the future this might become an optional parameter in this
% function, but for now, it is placed in the code itself.
% if the string is longer than 31 characters, only the first 31  characters
% are printed, plus three dots to denote that the string is longer than
% printed.

maxStrLength = 31;

for iField = 1 : length(charFields)

    Field = cell2mat(charFields(iField));

    filler = char(ones(1, maxFieldLength - length(Field) + 2) * 45);
    
    if (size(Structure.(Field), 1) > 1) && (size(Structure.(Field), 2) > 1)
        
        varStr = createArraySize(Structure.(Field), 'char');
        
    elseif length(Field) > maxStrLength
        
        varStr = sprintf(' ''%s...''', Structure.(Field(1:maxStrLength)));
        
    else
        
        varStr = sprintf(' ''%s''', Structure.(Field));
        
    end

    listStr = [listStr; {[strIndent '   |' filler ' ' Field ' :' varStr]}];
end


% Print empty fields

for iField = 1 : length(emptyFields)
    
    
    Field = cell2mat(emptyFields(iField));
    
    filler = char(ones(1, maxFieldLength - length(Field) + 2) * 45);
    
    listStr = [listStr; {[strIndent '   |' filler ' ' Field ' : [ ]' ]}];

end


% Print logicals. If it is a scalar, print true/false, else print vector
% information

for iField = 1 : length(logicalFields)
    
    Field = cell2mat(logicalFields(iField));
    
    filler = char(ones(1, maxFieldLength - length(Field) + 2) * 45);
    
    if isscalar(Structure.(Field))
        
        logicalValue = {'False', 'True'};
        
        varStr = sprintf(' %s', logicalValue{Structure.(Field) + 1});

    else

        varStr = createArraySize(Structure.(Field), 'Logic array');
                
    end

    listStr = [listStr; {[strIndent '   |' filler ' ' Field ' :' varStr]}];
    
end


% Print numeric scalar field. The %g format is used, so that integers,
% floats and exponential numbers are printed in their own format.

for iField = 1 : length(scalarFields)
    
    Field = cell2mat(scalarFields(iField));
    
    filler = char(ones(1, maxFieldLength - length(Field) + 2) * 45);
    
    varStr = sprintf(' %g', Structure.(Field));

    listStr = [listStr; {[strIndent '   |' filler ' ' Field ' :' varStr]}];

end


% Print numeric array. If the length of the array is smaller then
% maxArrayLength, then the values are printed. Else, print the length of
% the array.

for iField = 1 : length(vectorFields)
    
    Field = cell2mat(vectorFields(iField));
    
    filler = char(ones(1, maxFieldLength - length(Field) + 2) * 45);
    
    if length(Structure.(Field)) > maxArrayLength
        
        varStr = createArraySize(Structure.(Field), 'Array');
        
    else

        varStr = sprintf('%g ', Structure.(Field));

        varStr = ['[' varStr(1:length(varStr) - 1) ']'];
                    
    end
    
    listStr = [listStr; {[strIndent '   |' filler ' ' Field ' : ' varStr]}];

end


% Print numeric matrices. If the matrix is two-dimensional and has more
% than maxArrayLength elements, only its size is printed.
% If the matrix is 'small', the elements are printed in a matrix structure.
% The top and the bottom of the matrix is indicated by a horizontal line of
% dashes. The elements are also lined out by using a fixed format
% (%#10.2e). Because the name of the matrix is only printed on the first
% line, the space is occupied by this name must be filled up on the other
% lines. This is done by defining a 'filler2'.
% This method was developed by S. Wegerich.

for iField = 1 : length(matrixFields)
    
    Field = cell2mat(matrixFields(iField));
    
    filler = char(ones(1, maxFieldLength - length(Field) + 2) * 45);
    
    if numel(Structure.(Field)) > maxArrayLength
        
        varStr = createArraySize(Structure.(Field), 'Array');

        varCell = {[strIndent '   |' filler ' ' Field ' :' varStr]};
        
    else

        matrixSize = size(Structure.(Field));
        
        filler2 = char(ones(1, maxFieldLength + 6) * 32);

        dashes = char(ones(1, 12 * matrixSize(2) + 1) * 45);

        varCell = {[strIndent '   |' filler2 dashes]};
        
        % first line with field name
        varStr = sprintf('%#10.2e |', Structure.(Field)(1, :));

        varCell = [varCell; {[strIndent '   |' filler ' ' ...
                              Field ' : |' varStr]}];

        % second and higher number rows
        for j = 2 : matrixSize(1)

            varStr = sprintf('%#10.2e |', Structure.(Field)(j, :));
            
            varCell = [varCell; {[strIndent '   |' filler2 '|' varStr]}];
        end

        varCell = [varCell; {[strIndent '   |' filler2 dashes]}];
                    
    end
    
    listStr = [listStr; varCell];

end


% Print cell array information, i.e. the size of the cell array. The
% content of the cell array is not printed.

for iField = 1 : length(cellFields)

    Field = cell2mat(cellFields(iField));
    
    filler = char(ones(1, maxFieldLength - length(Field) + 2) * 45);
    
    varStr = createArraySize(Structure.(Field), 'Cell');

    listStr = [listStr; {[strIndent '   |' filler ' ' Field ' :' varStr]}];

end


% Print unknown datatypes. These include objects and user-defined classes

for iField = 1 : length(otherFields)

    Field = cell2mat(otherFields(iField));
    
    filler = char(ones(1, maxFieldLength - length(Field) + 2) * 45);
    
    varStr = createArraySize(Structure.(Field), 'Unknown');

    listStr = [listStr; {[strIndent '   |' filler ' ' Field ' :' varStr]}];

end

end
function str = getIndentation(indent)
    x = '   |    ';
    str = '';
    
    for i = 1 : indent
        str = cat(2, str, x);
    end
end
function varStr = createArraySize(varName, type)
    varSize = size(varName);

    arraySizeStr = sprintf('%gx', varSize);
    arraySizeStr(length(arraySizeStr)) = [];
    
    varStr = [' [' arraySizeStr ' ' type ']'];
end


  
end
function writedesign(in, outname)
% CS_WRITEREPORT
%
%   USAGE: cs_writereport(in, basename)
%
%   ARGUMENTS
%       in: cell array of character arrays
%       basename: name for output csv file
%
% ===============================================%
if nargin<2, error('USAGE: writereport(in, outname)'); end
[nrow, ncol] = size(in);
for i = 1:numel(in)
    if isnumeric(in{i}), in{i} = num2str(in{i}); end
    if strcmp(in{i},'NaN'), in{i} = ''; end
end
in = regexprep(in, ',', '');
fid = fopen(outname,'w');
for r = 1:nrow
    fprintf(fid,[repmat('%s,',1,ncol) '\n'],in{r,:});
end
fclose(fid);
end
function strucdisp(Structure, depth, printValues, maxArrayLength, fileName)
%STRUCDISP  display structure outline
%
%   STRUCDISP(STRUC, DEPTH, PRINTVALUES, MAXARRAYLENGTH, FILENAME) displays
%   the hierarchical outline of a structure and its substructures. 
%
%   STRUC is a structure datatype with unknown field content. It can be 
%   either a scalar or a vector, but not a matrix. STRUC is the only
%   mandatory argument in this function. All other arguments are optional.
%
%   DEPTH is the number of hierarchical levels of the structure that are
%   printed. If DEPTH is smaller than zero, all levels are printed. Default
%   value for DEPTH is -1 (print all levels).
%
%   PRINTVALUES is a flag that states if the field values should be printed
%   as well. The default value is 1 (print values)
%
%   MAXARRAYLENGTH is a positive integer, which determines up to which
%   length or size the values of a vector or matrix are printed. For a
%   vector holds that if the length of the vector is smaller or equal to
%   MAXARRAYLENGTH, the values are printed. If the vector is longer than
%   MAXARRAYLENGTH, then only the size of the vector is printed.
%   The values of a 2-dimensional (m,n) array are printed if the number of
%   elements (m x n) is smaller or equal to MAXARRAYLENGTH.
%   For vectors and arrays, this constraint overrides the PRINTVALUES flag.
%
%   FILENAME is the name of the file to which the output should be printed.
%   if this argument is not defined, the output is printed to the command
%   window.
%
%   Contact author: B. Roossien <roossien@ecn.nl>
%   (c) ECN 2007-2008
%
%   Version 1.3.0


%% Creator and Version information
% Created by B. Roossien <roossien@ecn.nl> 14-12-2006
%
% Based on the idea of 
%       M. Jobse - display_structure (Matlab Central FileID 2031)
%
% Acknowledgements:
%       S. Wegerich - printmatrix (Matlab Central FileID 971)
%
% Beta tested by: 
%       K. Visscher
%
% Feedback provided by:
%       J. D'Errico
%       H. Krause
%       J.K. Kok
%       J. Kurzmann
%       K. Visscher
%
%
% (c) ECN 2006-2007
% www.ecn.nl
%
% Last edited on 08-03-2008



%% Version History
%
% 1.3.0 : Bug fixes and added logicals
% 1.2.3 : Buf fix - Solved multi-line string content bug
% 1.2.2 : Bug fix - a field being an empty array gave an error
% 1.2.1 : Bug fix
% 1.2.0 : Increased readability of code
%         Makes use of 'structfun' and 'cellfun' to increase speed and 
%         reduce the amount of code
%         Solved bug with empty fieldname parameter
% 1.1.2 : Command 'eval' removed with a more simple and efficient solution
% 1.1.1 : Solved a bug with cell array fields
% 1.1.0 : Added support for arrayed structures
%         Added small matrix size printing
% 1.0.1 : Bug with empty function parameters fixed
% 1.0.0 : Initial release



%% Main program
%%%%% start program %%%%%

    % first argument must be structure
    if ~isstruct(Structure)
        error('First input argument must be structure');
    end
    
    % first argument can be a scalar or vector, but not a matrix
    if ~isvector(Structure)
        error('First input argument can be a scalar or vector, but not a matrix');
    end
    
    % default value for second argument is -1 (print all levels)
    if nargin < 2 || isempty(depth)
        depth = -1;
    end

    % second argument must be an integer
    if ~isnumeric(depth)
        error('Second argument must be an integer');
    end

    % second argument only works if it is an integer, therefore floor it
    depth = floor(depth);
    
    % default value for third argument is 1
    if nargin < 3 || isempty(printValues)
        printValues = 1;
    end

    % default value for fourth argument is 10
    if nargin < 4 || isempty(maxArrayLength)
        maxArrayLength = 10;
    end

    
    % start recursive function   
    listStr = recFieldPrint(Structure, 0, depth, printValues, ... 
                            maxArrayLength);

    
    % 'listStr' is a cell array containing the output
    % Now it's time to actually output the data
    % Default is to output to the command window
    % However, if the filename argument is defined, output it into a file

    if nargin < 5 || isempty(fileName)
        
        % write data to screen
        for i = 1 : length(listStr)
            disp(cell2mat(listStr(i, 1)));
        end
        
    else
        
        % open file and check for errors
        fid = fopen(fileName, 'wt');
        
        if fid < 0
            error('Unable to open output file');
        end
        
        % write data to file
        for i = 1 : length(listStr)
            fprintf(fid, '%s\n', cell2mat(listStr(i, 1)));
        end
        
        % close file
        fclose(fid);
        
    end
    
end
function listStr = recFieldPrint(Structure, indent, depth, printValues, ...
                                 maxArrayLength)


% Start to initialiase the cell listStr. This cell is used to store all the
% output, as this is much faster then directly printing it to screen.

listStr = {};


% "Structure" can be a scalar or a vector.
% In case of a vector, this recursive function is recalled for each of
% the vector elements. But if the values don't have to be printed, only
% the size of the structure and its fields are printed.

if length(Structure) > 1

    if (printValues == 0)

        varStr = createArraySize(Structure, 'Structure');

        listStr = [{' '}; {['Structure', varStr]}];

        body = recFieldPrint(Structure(1), indent, depth, ...
                             printValues, maxArrayLength);

        listStr = [listStr; body; {'   O'}];

    else

        for iStruc = 1 : length(Structure)

            listStr = [listStr; {' '}; {sprintf('Structure(%d)', iStruc)}];

            body = recFieldPrint(Structure(iStruc), indent, depth, ...
                                 printValues, maxArrayLength);

            listStr = [listStr; body; {'   O'}];

        end

    end

    return

end


%% Select structure fields
% The fields of the structure are distinguished between structure and
% non-structure fields. The structure fields are printed first, by
% recalling this function recursively.

% First, select all fields.

fields = fieldnames(Structure);

% Next, structfun is used to return an boolean array with information of
% which fields are of type structure.

isStruct = structfun(@isstruct, Structure);

% Finally, select all the structure fields

strucFields = fields(isStruct == 1);


%% Recursively print structure fields 
% The next step is to select each structure field and handle it
% accordingly. Each structure can be empty, a scalar, a vector or a matrix.
% Matrices and long vectors are only printed with their fields and not with
% their values. Long vectors are defined as vectors with a length larger
% then the maxArrayLength value. The fields of an empty structure are not
% printed at all.
% It is not necessary to look at the length of the vector if the values
% don't have to be printed, as the fields of a vector or matrix structure
% are the same for each element.

% First, some indentation calculations are required.

strIndent = getIndentation(indent + 1);
listStr = [listStr; {strIndent}];

strIndent = getIndentation(indent);

% Next, select each field seperately and handle it accordingly

for iField = 1 : length(strucFields)

    fieldName = cell2mat(strucFields(iField));
    Field =  Structure.(fieldName);
    
    % Empty structure
    if isempty(Field)

        strSize = createArraySize(Field, 'Structure');

        line = sprintf('%s   |--- %s :%s', ...
                       strIndent, fieldName, strSize);

        listStr = [listStr; {line}];

    % Scalar structure
    elseif isscalar(Field)

        line = sprintf('%s   |--- %s', strIndent, fieldName);

        % Recall this function if the tree depth is not reached yet
        if (depth < 0) || (indent + 1 < depth)
            lines = recFieldPrint(Field, indent + 1, depth, ...
                                  printValues, maxArrayLength);

            listStr = [listStr; {line}; lines; ...
                       {[strIndent '   |       O']}];
        else
            listStr = [listStr; {line}];
        end

    % Short vector structure of which the values should be printed    
    elseif (isvector(Field)) &&  ...
           (printValues > 0) && ...
           (length(Field) < maxArrayLength) && ...
           ((depth < 0) || (indent + 1 < depth))

        % Use a for-loop to print all structures in the array
        for iFieldElement = 1 : length(Field)

            line = sprintf('%s   |--- %s(%g)', ...
                           strIndent, fieldName, iFieldElement);

            lines = recFieldPrint(field(iFieldElement), indent + 1, ...
                                 depth, printValues, maxArrayLength);

            listStr = [listStr; {line}; lines; ...
                       {[strIndent '   |       O']}];

            if iFieldElement ~= length(Field)
                listStr = [listStr; {[strIndent '   |    ']}];
            end

        end

    % Structure is a matrix or long vector
    % No values have to be printed or depth limit is reached
    else

        varStr = createArraySize(Field, 'Structure');

        line = sprintf('%s   |--- %s :%s', ...
                       strIndent, fieldName, varStr);

        lines = recFieldPrint(Field(1), indent + 1, depth, ...
                              0, maxArrayLength);

        listStr = [listStr; {line}; lines; ...
                   {[strIndent '   |       O']}];

    end

    % Some extra blank lines to increase readability
    listStr = [listStr; {[strIndent '   |    ']}];

end % End iField for-loop


%% Field Filler
% To properly align the field names, a filler is required. To know how long
% the filler must be, the length of the longest fieldname must be found.
% Because 'fields' is a cell array, the function 'cellfun' can be used to
% extract the lengths of all fields.
maxFieldLength = max(cellfun(@length, fields));

%% Print non-structure fields without values
% Print non-structure fields without the values. This can be done very
% quick.
if printValues == 0
    
    noStrucFields = fields(isStruct == 0);

    for iField  = 1 : length(noStrucFields)

        Field = cell2mat(noStrucFields(iField));

        filler = char(ones(1, maxFieldLength - length(Field) + 2) * 45);

        listStr = [listStr; {[strIndent '   |' filler ' ' Field]}];

    end

    return

end


%% Select non-structure fields (to print with values)
% Select fields that are not a structure and group them by data type. The
% following groups are distinguished:
%   - characters and strings
%   - numeric arrays
%   - logical
%   - empty arrays
%   - matrices
%   - numeric scalars
%   - cell arrays
%   - other data types

% Character or string (array of characters)
isChar = structfun(@ischar, Structure);
charFields = fields(isChar == 1);

% Numeric fields
isNumeric = structfun(@isnumeric, Structure);

% Numeric scalars
isScalar = structfun(@isscalar, Structure);
isScalar = isScalar .* isNumeric;
scalarFields = fields(isScalar == 1);

% Numeric vectors (arrays)
isVector = structfun(@isvector, Structure);
isVector = isVector .* isNumeric .* not(isScalar);
vectorFields = fields(isVector == 1);

% Logical fields
isLogical = structfun(@islogical, Structure);
logicalFields = fields(isLogical == 1);

% Empty arrays
isEmpty = structfun(@isempty, Structure);
emptyFields = fields(isEmpty == 1);

% Numeric matrix with dimension size 2 or higher
isMatrix = structfun(@(x) ndims(x) >= 2, Structure);
isMatrix = isMatrix .* isNumeric .* not(isVector) ...
                    .* not(isScalar) .* not(isEmpty);
matrixFields = fields(isMatrix == 1);

% Cell array
isCell = structfun(@iscell, Structure);
cellFields = fields(isCell == 1);

% Datatypes that are not checked for
isOther = not(isChar + isNumeric + isCell + isStruct + isLogical + isEmpty);
otherFields = fields(isOther == 1);



%% Print non-structure fields
% Print all the selected non structure fields
% - Strings are printed to a certain amount of characters
% - Vectors are printed as long as they are shorter than maxArrayLength
% - Matrices are printed if they have less elements than maxArrayLength
% - The values of cells are not printed


% Start with printing strings and characters. To avoid the display screen 
% becoming a mess, the part of the string that is printed is limited to 31 
% characters. In the future this might become an optional parameter in this
% function, but for now, it is placed in the code itself.
% if the string is longer than 31 characters, only the first 31  characters
% are printed, plus three dots to denote that the string is longer than
% printed.

maxStrLength = 31;

for iField = 1 : length(charFields)

    Field = cell2mat(charFields(iField));

    filler = char(ones(1, maxFieldLength - length(Field) + 2) * 45);
    
    if (size(Structure.(Field), 1) > 1) && (size(Structure.(Field), 2) > 1)
        
        varStr = createArraySize(Structure.(Field), 'char');
        
    elseif length(Field) > maxStrLength
        
        varStr = sprintf(' ''%s...''', Structure.(Field(1:maxStrLength)));
        
    else
        
        varStr = sprintf(' ''%s''', Structure.(Field));
        
    end

    listStr = [listStr; {[strIndent '   |' filler ' ' Field ' :' varStr]}];
end


% Print empty fields

for iField = 1 : length(emptyFields)
    
    
    Field = cell2mat(emptyFields(iField));
    
    filler = char(ones(1, maxFieldLength - length(Field) + 2) * 45);
    
    listStr = [listStr; {[strIndent '   |' filler ' ' Field ' : [ ]' ]}];

end


% Print logicals. If it is a scalar, print true/false, else print vector
% information

for iField = 1 : length(logicalFields)
    
    Field = cell2mat(logicalFields(iField));
    
    filler = char(ones(1, maxFieldLength - length(Field) + 2) * 45);
    
    if isscalar(Structure.(Field))
        
        logicalValue = {'False', 'True'};
        
        varStr = sprintf(' %s', logicalValue{Structure.(Field) + 1});

    else

        varStr = createArraySize(Structure.(Field), 'Logic array');
                
    end

    listStr = [listStr; {[strIndent '   |' filler ' ' Field ' :' varStr]}];
    
end


% Print numeric scalar field. The %g format is used, so that integers,
% floats and exponential numbers are printed in their own format.

for iField = 1 : length(scalarFields)
    
    Field = cell2mat(scalarFields(iField));
    
    filler = char(ones(1, maxFieldLength - length(Field) + 2) * 45);
    
    varStr = sprintf(' %g', Structure.(Field));

    listStr = [listStr; {[strIndent '   |' filler ' ' Field ' :' varStr]}];

end


% Print numeric array. If the length of the array is smaller then
% maxArrayLength, then the values are printed. Else, print the length of
% the array.

for iField = 1 : length(vectorFields)
    
    Field = cell2mat(vectorFields(iField));
    
    filler = char(ones(1, maxFieldLength - length(Field) + 2) * 45);
    
    if length(Structure.(Field)) > maxArrayLength
        
        varStr = createArraySize(Structure.(Field), 'Array');
        
    else

        varStr = sprintf('%g ', Structure.(Field));

        varStr = ['[' varStr(1:length(varStr) - 1) ']'];
                    
    end
    
    listStr = [listStr; {[strIndent '   |' filler ' ' Field ' : ' varStr]}];

end


% Print numeric matrices. If the matrix is two-dimensional and has more
% than maxArrayLength elements, only its size is printed.
% If the matrix is 'small', the elements are printed in a matrix structure.
% The top and the bottom of the matrix is indicated by a horizontal line of
% dashes. The elements are also lined out by using a fixed format
% (%#10.2e). Because the name of the matrix is only printed on the first
% line, the space is occupied by this name must be filled up on the other
% lines. This is done by defining a 'filler2'.
% This method was developed by S. Wegerich.

for iField = 1 : length(matrixFields)
    
    Field = cell2mat(matrixFields(iField));
    
    filler = char(ones(1, maxFieldLength - length(Field) + 2) * 45);
    
    if numel(Structure.(Field)) > maxArrayLength
        
        varStr = createArraySize(Structure.(Field), 'Array');

        varCell = {[strIndent '   |' filler ' ' Field ' :' varStr]};
        
    else

        matrixSize = size(Structure.(Field));
        
        filler2 = char(ones(1, maxFieldLength + 6) * 32);

        dashes = char(ones(1, 12 * matrixSize(2) + 1) * 45);

        varCell = {[strIndent '   |' filler2 dashes]};
        
        % first line with field name
        varStr = sprintf('%#10.2e |', Structure.(Field)(1, :));

        varCell = [varCell; {[strIndent '   |' filler ' ' ...
                              Field ' : |' varStr]}];

        % second and higher number rows
        for j = 2 : matrixSize(1)

            varStr = sprintf('%#10.2e |', Structure.(Field)(j, :));
            
            varCell = [varCell; {[strIndent '   |' filler2 '|' varStr]}];
        end

        varCell = [varCell; {[strIndent '   |' filler2 dashes]}];
                    
    end
    
    listStr = [listStr; varCell];

end


% Print cell array information, i.e. the size of the cell array. The
% content of the cell array is not printed.

for iField = 1 : length(cellFields)

    Field = cell2mat(cellFields(iField));
    
    filler = char(ones(1, maxFieldLength - length(Field) + 2) * 45);
    
    varStr = createArraySize(Structure.(Field), 'Cell');

    listStr = [listStr; {[strIndent '   |' filler ' ' Field ' :' varStr]}];

end


% Print unknown datatypes. These include objects and user-defined classes

for iField = 1 : length(otherFields)

    Field = cell2mat(otherFields(iField));
    
    filler = char(ones(1, maxFieldLength - length(Field) + 2) * 45);
    
    varStr = createArraySize(Structure.(Field), 'Unknown');

    listStr = [listStr; {[strIndent '   |' filler ' ' Field ' :' varStr]}];

end

end
function str = getIndentation(indent)
    x = '   |    ';
    str = '';
    
    for i = 1 : indent
        str = cat(2, str, x);
    end
end
function varStr = createArraySize(varName, type)
    varSize = size(varName);

    arraySizeStr = sprintf('%gx', varSize);
    arraySizeStr(length(arraySizeStr)) = [];
    
    varStr = [' [' arraySizeStr ' ' type ']'];
end







