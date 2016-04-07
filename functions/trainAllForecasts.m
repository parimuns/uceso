function [ trainedModels, trainTime ] = ...
    trainAllForecasts(cfg, demandDataTrain)

% trainAllForecasts: Train forecast models and forecast-free controller.
%   Run through each instance and each method and output trained models.

%% INPUTS:
% cfg:              Structure containing all of the running options
% demandDataTrain:  Matrix with demand data [nIntervalsTrain x nInstances]

%% OUTPUTS:
% trainedModels:    Trained forecast and forecast-free controller models

tic;

%% Pre-Allocation:
timeTaken = zeros(cfg.sim.nInstances, cfg.sim.nMethods);
trainedModels = cell(cfg.sim.nInstances, cfg.sim.nMethods);

% Choose the appropriate forecast training function
switch cfg.fc.modelType
    case 'FFNN'
        trainHandle = @trainFfnnMultipleStarts;
        disp('== USING FFNN MODELS ===');
        
    case 'RF'
        trainHandle = @trainRandomForestForecast;
        disp('== USING RANDOM FOREST MODELS ===');
        
    otherwise
        error('Selected cfg.fc.modelType not implemented');
end


%% Train Models
% Delete parrallel pool if it exists
poolobj = gcp('nocreate');
delete(poolobj);

parfor instance = 1:cfg.sim.nInstances
% for instance = 1:cfg.sim.nInstances

    tempModels = cell(1, cfg.sim.nMethods);     % prevent parfor issues
    tempTimeTaken = zeros(1, cfg.sim.nMethods);

    for methodTypeIdx = 1:cfg.sim.nMethods
        
        switch cfg.sim.methodList{methodTypeIdx} %#ok<*PFBNS>
            
            % Train forecast-free controller
            case 'IMFC'
                tempTic = tic;
                
                tempModels{1, methodTypeIdx} = ...
                    trainForecastFreeController(cfg, ...
                    demandDataTrain(:, instance));
                
                tempTimeTaken(1, methodTypeIdx) = toc(tempTic);
                
            % Skip if method doesn't need training
            case 'NPFC'
                continue;
                
            case 'PFFC'
                continue;
                
            case 'SP'
                continue;
                
            % Train forecast model
            case 'MFFC'
                tempTic = tic;
                
                tempModels{1, methodTypeIdx} = trainHandle(...
                    cfg, demandDataTrain(:, instance));
                
                tempTimeTaken(1, methodTypeIdx) = toc(tempTic);
                
            otherwise
                error('Selected method has not been implemented');
                
        end
        disp([cfg.sim.methodList{methodTypeIdx} ' training done!']);
    end
    
    % save temporary cellArray of models to the full array:
    trainedModels(instance, :) = tempModels;
    timeTaken(instance, :) = tempTimeTaken;
    
end

% Kill the parrallel pool (errors tend to occur if pool kept open too long)
poolobj = gcp('nocreate');
delete(poolobj);

trainTime = timeTaken;

disp('Time to train models: '); disp(toc);

end
