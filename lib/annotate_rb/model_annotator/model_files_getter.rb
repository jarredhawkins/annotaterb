# frozen_string_literal: true

require "open3"
require "pathname"

module AnnotateRb
  module ModelAnnotator
    class ModelFilesGetter
      class << self
        # Return a list of the model files to annotate.
        # If :skip_unchanged_files is true, it filters by git diff.
        def call(options)
          all_model_files = _get_all_model_files(options)
          return [] if all_model_files.nil? || all_model_files.empty?

          if options[:skip_unchanged_files]
            # Determine the project's root directory.
            # options[:root_dir] is an array of strings. Use its first element or PWD.
            # Ensure it's an absolute path.
            root_dir_config = options[:root_dir]&.first
            current_root_dir = (root_dir_config.nil? || root_dir_config.empty?) ? Dir.pwd : root_dir_config
            root_pathname = Pathname.new(current_root_dir).expand_path

            # Execute git diff command
            git_command = "git diff --name-only main...HEAD"
            stdout_str, stderr_str, status = Open3.capture3(git_command, chdir: root_pathname.to_s)

            if status.success?
              changed_files_from_git = stdout_str.lines.map(&:strip).reject(&:empty?)

              # Convert all_model_files to paths relative to root_pathname for comparison
              all_model_files_with_relative_paths = all_model_files.map do |model_dir_path_str, file_in_dir_str|
                # model_dir_path_str is already absolute from _get_all_model_files
                absolute_model_file_path = Pathname.new(model_dir_path_str).join(file_in_dir_str)
                relative_path_to_root = absolute_model_file_path.relative_path_from(root_pathname).to_s
                [model_dir_path_str, file_in_dir_str, relative_path_to_root]
              end

              filtered_model_files = all_model_files_with_relative_paths.select do |_, _, relative_path|
                changed_files_from_git.include?(relative_path)
              end.map { |dir, file_in_dir, _| [dir, file_in_dir] }

              if filtered_model_files.empty? && all_model_files.any?
                warn "INFO: No model files found that changed based on 'git diff main...HEAD'."
              end
              return filtered_model_files
            else
              warn "WARNING: Failed to get git diff. Command `#{git_command}` in directory `#{root_pathname}` failed with: #{stderr_str.strip.empty? ? stdout_str.strip : stderr_str.strip}"
              warn "Falling back to annotating all model files."
              # Fall through to return all_model_files
            end
          end

          all_model_files
        end

        private

        # Original logic to get all model files, refactored.
        # Ensures that the directory part of the returned pairs is an absolute path.
        def _get_all_model_files(options)
          model_files = list_model_files_from_argument(options) # Returns [absolute_dir, relative_file_to_dir]

          return model_files if model_files.any?

          # If no command line arguments, search in model_dir
          # options[:model_dir] is an array of directory patterns
          searched_model_files = []
          options[:model_dir].each do |dir_pattern|
            # Expand dir_pattern, which could be relative or absolute, or contain globs
            # We need to ensure dir_pattern is relative to root_dir for globbing if it's not absolute
            root_dir_config = options[:root_dir]&.first
            current_root_dir = (root_dir_config.nil? || root_dir_config.empty?) ? Dir.pwd : root_dir_config
            base_path_for_glob = Pathname.new(current_root_dir).expand_path

            # If dir_pattern is absolute, use it as is. Otherwise, join with base_path_for_glob.
            absolute_dir_pattern = Pathname.new(dir_pattern).absolute? ? Pathname.new(dir_pattern) : base_path_for_glob.join(dir_pattern)

            Dir.glob(absolute_dir_pattern.to_s).each do |dir|
              next unless File.directory?(dir) # Ensure it's a directory

              # Store current PWD, change to model dir, then revert
              original_pwd = Dir.pwd
              begin
                Dir.chdir(dir) # Change to the actual model directory found
                absolute_current_dir = Pathname.new(dir).expand_path.to_s # This is the absolute path to the model's directory

                list = if options[:ignore_model_sub_dir]
                         Dir["*.rb"].map { |f| [absolute_current_dir, f] }
                       else
                         Dir["**/*.rb"]
                           .reject { |f| f.include?("concerns/") } # Simple check for "concerns/"
                           .map { |f| [absolute_current_dir, f] }
                       end
                searched_model_files.concat(list)
              ensure
                Dir.chdir(original_pwd)
              end
            end
          end
          model_files.concat(searched_model_files.uniq)


          if model_files.empty? && !options.get_state(:working_args)&.any?
            warn "No models found in directory patterns: '#{options[:model_dir].join("', '")}'."
            warn "Either specify models on the command line, or use the --model-dir option."
            warn "Call 'annotaterb --help' for more info."
          end
          model_files.uniq # Ensure final list is unique
        end

        # Processes command-line file arguments.
        # Returns an array of [absolute_dir_path, file_name_relative_to_dir]
        def list_model_files_from_argument(options)
          working_args = options.get_state(:working_args)
          return [] if working_args.nil? || working_args.empty?

          # Project root for resolving relative paths if needed.
          root_dir_config = options[:root_dir]&.first
          current_root_dir = (root_dir_config.nil? || root_dir_config.empty?) ? Dir.pwd : root_dir_config
          root_pathname = Pathname.new(current_root_dir).expand_path

          processed_files = []
          specified_files_full_paths = working_args.map { |file| root_pathname.join(file).expand_path }

          # Model directories to check against. These can be patterns.
          # We need to find which specified files belong to which model directory.
          # For simplicity, we assume specified files are models and attempt to find their containing dir
          # relative to the model_dir patterns.
          # A more robust way: for each specified file, find its actual directory.
          # Then, confirm this directory (or a parent) matches a model_dir pattern.
          # This is complex. The original logic was simpler:
          # For each model_dir, find which specified_files are under it.

          model_files_from_args = []
          options[:model_dir].each do |dir_pattern|
            # Resolve dir_pattern relative to root if not absolute
            absolute_dir_pattern_path = Pathname.new(dir_pattern).absolute? ? Pathname.new(dir_pattern) : root_pathname.join(dir_pattern)
            
            # Glob to find all directories matching the pattern
            Dir.glob(absolute_dir_pattern_path.to_s).each do |matched_dir_str|
              next unless File.directory?(matched_dir_str)
              absolute_matched_dir_path = Pathname.new(matched_dir_str).expand_path

              specified_files_full_paths.each do |sf_path|
                if sf_path.to_s.start_with?(absolute_matched_dir_path.to_s + File::SEPARATOR)
                  relative_file = sf_path.relative_path_from(absolute_matched_dir_path).to_s
                  model_files_from_args << [absolute_matched_dir_path.to_s, relative_file]
                end
              end
            end
          end
          
          model_files_from_args.uniq!

          # Warning if not all specified files were mapped.
          # This means some files passed as arguments were not found under any of the model_dir patterns.
          if model_files_from_args.map { |d, f| Pathname.new(d).join(f).to_s }.sort != specified_files_full_paths.map(&:to_s).sort
            # This comparison is a bit complex due to potential duplicates or different ways to specify paths.
            # A simpler check: if specified_files_full_paths is not empty and model_files_from_args is empty for some.
            # Or count unique resolved paths.
            unfound_files = specified_files_full_paths.reject do |sf_path|
              model_files_from_args.any? { |d, f| Pathname.new(d).join(f).expand_path == sf_path }
            end
            
            if unfound_files.any?
              warn "WARNING: The following specified files were not found under any model directory patterns (#{options[:model_dir].join(", ")}): #{unfound_files.join(', ')}"
            end
          end
          
          model_files_from_args
        end
      end
    end
  end
end
