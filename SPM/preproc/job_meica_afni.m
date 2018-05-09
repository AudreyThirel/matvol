function [ job ] = job_meica_afni( dir_func, dir_anat, par )
%JOB_MEICA_AFNI


%% Check input arguments

if ~exist('par','var')
    par = ''; % for defpar
end


%% defpar

defpar.anat_file_reg = '^s.*nii';
defpar.subdir        = 'meica';

defpar.nrCPU         = 2;
defpar.pct           = 0;
defpar.sge           = 0;
defpar.slice_timing  = 1; % can be (1) (recommended, will fetch automaticaly the pattern in the dic_.*json), (0) or a (char) such as 'alt+z', check 3dTshift -help
defpar.MNI           = 1; % normalization

defpar.redo          = 0;
defpar.fake          = 0;

defpar.verbose       = 1;


par = complet_struct(par,defpar);


parsge  = par.sge;
par.sge = -1; % only prepare commands

parverbose  = par.verbose;
par.verbose = 0; % don't print anything yet


%% Main

assert( length(dir_func) == length(dir_anat), 'dir_func & dir_anat must be the same length' )

if iscell(dir_func{1})
    nrSubject = length(dir_func);
else
    nrSubject = 1;
end

job = cell(nrSubject,1);

fprintf('\n')

for subj = 1 : nrSubject
    
    % Extract subject name, and print it
    subjectName = get_parent_path(dir_func{subj}(1));
    
    % Echo in terminal & initialize job_subj
    fprintf('[%s]: Preparing JOB %d/%d for %s \n', mfilename, subj, nrSubject, subjectName{1});
    job_subj = sprintf('#################### [%s] JOB %d/%d for %s #################### \n', mfilename, subj, nrSubject, dir_func{subj}{1}); % initialize
    
    nrRun = length(dir_func{subj});
    
    nrEchoAllRuns = zeros(nrRun,1);
    
    working_dir = char(r_mkdir(subjectName,par.subdir));
    
    %-Anat
    %======================================================================
    
    % Make symbolic link of tha anat in the working directory
    A_src = char(get_subdir_regex_files( dir_anat{subj}, par.anat_file_reg, 1 ));
    assert( exist(A_src,'file')==2 , 'file does not exist : %s', A_src )
    
    job_subj = [job_subj sprintf('### Anat @ %s \n', dir_anat{subj}) ]; %#ok<*AGROW>
    
    % File extension ?
    if strcmp(A_src(end-6:end),'.nii.gz')
        ext_anat = '.nii.gz';
    elseif strcmp(A_src(end-3:end),'.nii')
        ext_anat = '.nii';
    else
        error('WTF ? supported files are .nii and .nii.gz')
    end
    anat_filename = sprintf('anat%s',ext_anat);
    
    A_dst = fullfile(working_dir,anat_filename);
    [ ~ , job_tmp ] = r_movefile(A_src, A_dst, 'linkn', par);
    job_subj = [job_subj char(job_tmp) sprintf('\n')];
    
    %-All echos
    %======================================================================
    
    for run = 1 : nrRun
        
        % Check if dir exist
        run_path = dir_func{subj}{run};
        assert( exist(run_path,'dir')==7 , 'not a dir : %s', run_path )
        fprintf('In run dir %s ', run_path);
        
        job_subj = [job_subj sprintf('### Run %d/%d @ %s \n', run, nrRun, dir_func{subj}{run}) ];
        
        % Fetch json dics
        jsons = get_subdir_regex_files(run_path,'^dic.*json',struct('verbose',0));
        assert(~isempty(jsons), 'no ^dic.*json file detected in : %s', run_path)
        
        % Verify the number of echos
        nrEchoAllRuns(run) = size(jsons{1},1);
        assert( all( nrEchoAllRuns(1) == nrEchoAllRuns(run) ) , 'all dir_func does not have the same number of echos' )
        
        % Fetch all TE and reorder them
        res = get_string_from_json(cellstr(jsons{1}),'EchoTime','numeric');
        allTE = cell2mat([res{:}]);
        [sortedTE,order] = sort(allTE);
        fprintf(['TEs are : ' repmat('%g ',[1,length(allTE)]) ], allTE)
        
        % Fetch volume corrsponding to the echo
        allEchos = cell(length(order),1);
        for echo = 1 : length(order)
            if order(echo) == 1
                allEchos(echo) = get_subdir_regex_files(run_path,         '^f.*B\d.nii'                   , 1);
            else
                allEchos(echo) = get_subdir_regex_files(run_path, sprintf('^f.*B\\d_V%.3d.nii',order(echo)), 1);
            end
        end % echo
        fprintf(['sorted as : ' repmat('%g ',[1,length(sortedTE)]) 'ms \n'], sortedTE)
        
        % Make symbolic link of the echo in the working directory
        E_src = cell(length(allEchos),1);
        E_dst = cell(length(allEchos),1);
        for echo = 1 : length(allEchos)
            
            E_src{echo} = allEchos{echo};
            
            % File extension ?
            if strcmp(E_src{echo}(end-6:end),'.nii.gz')
                ext_echo = '.nii.gz';
            elseif strcmp(E_src{echo}(end-3:end),'.nii')
                ext_echo = '.nii';
            else
                error('WTF ? supported files are .nii and .nii.gz')
            end
            
            filename = sprintf('run%.3d_e%.3d%s',run,echo,ext_echo);
            
            E_dst{echo} = fullfile(working_dir,filename);
            [ ~ , job_tmp ] = r_movefile(E_src{echo}, E_dst{echo}, 'linkn', par);
            job_subj = [job_subj char(job_tmp)];
            
            E_dst{echo} = filename;
            
        end % echo
        
        %-Prepare slice timing info
        %==================================================================
        
        if isnumeric(par.slice_timing) && par.slice_timing == 1
            
            % Read the slice timings directly in the dic_.*json
            [ out ] = get_string_from_json( deblank(jsons{1}(1,:)) , 'CsaImage.MosaicRefAcqTimes' , 'vect' );
            
            % Right field found ?
            assert( ~isempty(out{1}), 'Did not detect the right field ''CsaImage.MosaicRefAcqTimes'' in the file %s', deblank(jsons{1}(1,:)) )
            
            % Destination file :
            tpattern = fullfile(working_dir,'sliceorder.txt');
            fileID = fopen( tpattern , 'w' , 'n' , 'UTF-8' );
            if fileID < 0
                warning('[%s]: Could not open %s', mfilename, filename)
            end
            fprintf(fileID, '%f\n', out{1}/1000 );
            fclose(fileID);
            tpattern = ['@' tpattern]; % 3dTshift syntax to use a file is 3dTshift -tpattern @filename
            
        elseif ischar(par.slice_timing)
            
            tpattern = par.slice_timing;
            
        end
        
        % Fetch TR
        res = get_string_from_json( deblank(jsons{1}(1,:)) ,'RepetitionTime','numeric');
        TR = res{1}/1000;
        
        %-Prepare command : meica.py
        %==================================================================
        
        data_sprintf = repmat('%s,',[1 length(E_dst)]);
        data_sprintf(end) = [];
        data_arg = sprintf(data_sprintf,E_dst{:});
        
        echo_sprintf = repmat('%g,',[1 length(sortedTE)]);
        echo_sprintf(end) = [];
        echo_arg = sprintf(echo_sprintf,sortedTE);
        
        prefix = sprintf('run%.3d',run);
        
        % Main command
        cmd = sprintf('cd %s;\n meica.py -d %s -e %s -a %s --prefix %s --cpus %d --TR=%g --daw=5',... % kdaw = 5 makes ICA converge mucgh easier : https://bitbucket.org/prantikk/me-ica/issues/28/meice-ocnvergence-issue-mdpnodeexception
            working_dir, data_arg, echo_arg, anat_filename , prefix, par.nrCPU, TR );
        
        % Options :
        
        if par.MNI
            cmd = sprintf('%s --MNI', cmd);
        end
        
        if ( isnumeric(par.slice_timing) && par.slice_timing == 1 ) || ischar(par.slice_timing)
            cmd = sprintf('%s --tpattern %s', cmd, tpattern);
        end
        
        cmd = sprintf('%s \n',cmd);
        
        if ~( exist(fullfile(working_dir,[prefix '_medn' ext_echo]),'file') == 2 ) || par.redo
            job_subj = [job_subj cmd];
        end
        
        
        %-Move meica-processed volumes in run dirs, using symbolic links
        %==================================================================
        
        list_volume_base = {
            '_medn'
            '_mefc'
            '_mefl'
            '_tsoc'
            };
        
        list_volume_src = addprefixtofilenames(list_volume_base, prefix);
        list_volume_src = addsuffixtofilenames(list_volume_src,ext_echo);
        list_volume_src{end+1} = sprintf('%s_%s',prefix,'ctab.txt'); % coregistration paramters ?
        list_volume_src{end+1} = sprintf('meica.%s_e001',prefix);
        list_volume_src = addprefixtofilenames(list_volume_src,working_dir);
        list_volume_src{end} = fullfile( list_volume_src{end} , 'motion.1D' );
        
        list_volume_dst = addprefixtofilenames(list_volume_base,prefix);
        list_volume_dst = addsuffixtofilenames(list_volume_dst,ext_echo);
        list_volume_dst{end+1} = sprintf('%s_%s',prefix,'ctab.txt'); % coregistration paramters ?
        list_volume_dst{end+1} = sprintf('rp_%s.txt',prefix);
        list_volume_dst = addprefixtofilenames(list_volume_dst,dir_func{subj}{run});
        
        
        [ ~ , job_tmp ] = r_movefile(list_volume_src, list_volume_dst, 'linkn', par);
        job_subj = [job_subj [job_tmp{:}] sprintf('\n')];
        
    end % run
    
    %-Move meica-processed anat in anat dir, using symbolic links
    %==================================================================
    
    job_subj = [job_subj sprintf('### Anat @ %s \n', dir_anat{subj}) ];
    
    list_anat_base = {
        'anat_do'
        'anat_ns_at' % MNI space
        'anat_ns'
        'anat_u'
        };
    
    list_anat_src = addsuffixtofilenames(list_anat_base,ext_anat);
    list_anat_src{end+1} = 'anat_ns2at.aff12.1D'; % coregistration paramters ?
    list_anat_src = addprefixtofilenames(list_anat_src,working_dir);
    
    list_anat_dst = addsuffixtofilenames(list_anat_base,ext_anat);
    list_anat_dst{end+1} = 'anat_ns2at.aff12.1D'; % coregistration paramters ?
    list_anat_dst = addprefixtofilenames(list_anat_dst,dir_anat{subj});
    
    [ ~ , job_tmp ] = r_movefile(list_anat_src, list_anat_dst, 'linkn', par);
    job_subj = [job_subj [job_tmp{:}]];
    
    % Save job_subj
    job{subj} = job_subj;
    
end % subj

par.sge     = parsge;
par.verbose = parverbose;

job = do_cmd_sge(job, par);

end % function
