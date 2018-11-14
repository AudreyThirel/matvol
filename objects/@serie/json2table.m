function Table = json2table( serieArray, par )
% Syntax  : uses serie/readSeqParam then tansform into table
% Example : table = serieArray.json2table('json$');
%
% See also serie/getJson


%% Check inputs

if nargin < 2
    par = '';
end

defpar            = struct;

% common
defpar.verbose    = 1;

% getJson
defpar.regex      = 'json$';
defpar.type       = 'tag';

% get_sequence_param_from_json
defpar.pct        = 0;
defpar.all_fields = 2;

par = complet_struct(par,defpar);


%% Fetch json objects

jsonArray = serieArray.getJson(par.regex,par.type,par.verbose);


%% Read sequence parameters + first level fields

data_cellArray = jsonArray.readSeqParam(par.all_fields,par.pct);


%% In case of different fields, split in groups, and merge smartly

N = numel(data_cellArray);

% Print all fields name inside a cell, for comparaison
names = cell( N, 0 );
for i = 1 : N
    fields = fieldnames(data_cellArray{i});
    ncol = length(fields);
    names(i,1:ncol) = fields;
end

% Fortmat the cell of fieldnames and only keep the unique ones
names = names(:); % change from 2d to 1d
names( cellfun(@isempty,names) ) = []; % remove empty
list = unique(names,'stable');

% Compare current structure fields with the definitive 'list' of fields
for i = 1 : N
    f = fieldnames(data_cellArray{i});
    d = setxor(fields,f); % non-commin fields
    for dm = 1 : length(d)
        data_cellArray{i}.(d{dm}) = NaN; % create the missing field
        data_cellArray{i} = orderfields(data_cellArray{i}, list); % fields need to be in the same order for conversion
    end
end


%% Transform the cell of struct to array of struct, then into a table

data_structArray = cell2mat(data_cellArray); % cell array of struct cannot be converted to table
data_structArray = reshape( data_structArray, [numel(data_structArray) 1]); % reshape into single row structArray

Table = struct2table( data_structArray );

% Remove beguining of the path when it's common to all
examArray = [serieArray.exam];

exam_name = {examArray.name}';
if length(unique(exam_name)) == length(exam_name) % easy method, use exam.anem
    Table.Properties.RowNames = exam_name; % RowNames
else % harder method, use exam.path but crop it
    p = examArray.print;
    c = 0;
    while 1
        c = c + 1;
        line = p(:,c);
        if length(unique(line))>1
            break
        end
    end
    p = cellstr(p(:,c:end));
    Table.Properties.RowNames = p; % RowNames
end


end % function