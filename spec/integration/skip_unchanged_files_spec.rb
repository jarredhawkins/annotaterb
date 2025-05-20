# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "open3" # For git commands if needed, though system calls might be easier for setup

# Assuming AnnotateRb::Options and AnnotateRb::ModelAnnotator::ModelFilesGetter are autoloaded or required by spec_helper
# If not, explicit requires might be needed, e.g.:
# require "annotate_rb/options"
# require "annotate_rb/model_annotator/model_files_getter"

RSpec.describe "Integration: skip_unchanged_files feature" do
  let(:tmp_dir) { File.expand_path("../../../tmp/skip_unchanged_spec", __FILE__) }
  let(:models_dir) { File.join(tmp_dir, "app/models") }

  def run_git_command(command, dir: tmp_dir)
    stdout, stderr, status = Open3.capture3("git #{command}", chdir: dir)
    raise "Git command '#{command}' failed: #{stderr}" unless status.success?
    stdout.strip
  end

  def create_model_file(name, content = "# Dummy model: #{name}\nclass #{name.split('.').first.capitalize}; end")
    file_path = File.join(models_dir, name)
    File.write(file_path, content)
    file_path
  end

  # Helper to normalize output from ModelFilesGetter for easier assertions
  # Input: [[absolute_model_dir_path, file_name_relative_to_dir], ...]
  # Output: ["app/models/user.rb", "app/models/post.rb", ...] relative to tmp_dir
  def normalize_model_files_list(files_list)
    base_path = Pathname.new(tmp_dir)
    files_list.map do |dir_path, file_name|
      Pathname.new(dir_path).join(file_name).relative_path_from(base_path).to_s
    end.sort
  end


  before(:each) do
    FileUtils.mkdir_p(models_dir)
    run_git_command("init")
    run_git_command("config user.email 'test@example.com'")
    run_git_command("config user.name 'Test User'")
    run_git_command("commit --allow-empty -m 'Initial commit (empty)'") # Ensure main branch exists before checkout
    # Some git versions default to 'master', some to 'main'. Standardize to 'main'.
    begin
      run_git_command("branch -M main")
    rescue StandardError => e
      # If 'main' already exists or this version of git doesn't support -M in this way, it might fail.
      # Try checkout main and ensure it's the active branch.
      begin
        run_git_command("checkout main")
      rescue StandardError
        run_git_command("checkout -b main") # If main doesn't exist at all
      end
    end


    # Create initial files and commit to main
    create_model_file("user.rb")
    create_model_file("post.rb")
    run_git_command("add app/models/user.rb app/models/post.rb")
    run_git_command("commit -m 'Add user.rb and post.rb'")

    # Create and switch to a feature branch
    run_git_command("checkout -b feature-branch")

    # Modify user.rb on the feature branch
    create_model_file("user.rb", "# Modified User model\nclass User; end") # Overwrites existing
    run_git_command("add app/models/user.rb") # Stage the modification

    # Create comment.rb (new, added but not committed on feature-branch, or committed)
    # For the test, let's add it and commit it to the feature branch to ensure it's part of HEAD
    create_model_file("comment.rb")
    run_git_command("add app/models/comment.rb")
    run_git_command("commit -m 'Add comment.rb'")


    # Create product.rb (new, committed on feature-branch)
    create_model_file("product.rb")
    run_git_command("add app/models/product.rb")
    run_git_command("commit -m 'Add product.rb'")

    # At this point:
    # main branch: user.rb (v1), post.rb (v1)
    # feature-branch (HEAD): user.rb (v2), post.rb (v1), comment.rb (v1), product.rb (v1)
    # git diff --name-only main...HEAD should list:
    # app/models/comment.rb
    # app/models/product.rb
    # app/models/user.rb
  end

  after(:each) do
    FileUtils.rm_rf(tmp_dir)
  end

  context "when skip_unchanged_files is true" do
    it "annotates only modified and new files" do
      # Ensure working_args is empty so it searches model_dir
      options_hash = {
        skip_unchanged_files: true,
        model_dir: ["app/models"], # Relative to root_dir
        root_dir: [tmp_dir],
        working_args: [], # Critical: ensures ModelFilesGetter scans model_dir
        # Following are default values from AnnotateRb::Options that might be needed
        # for the getter to function correctly, depending on its internal dependencies.
        # Add them if tests fail due to missing options.
        ignore_model_sub_dir: false,
        exclude_concerns: false # Assuming concerns are typically in app/models/concerns
      }
      # We need an AnnotateRb::Options instance
      options = AnnotateRb::Options.from(options_hash)
      # Manually set state if working_args is usually set by another part of the runner
      options.set_state(:working_args, [])


      files_to_annotate = AnnotateRb::ModelAnnotator::ModelFilesGetter.call(options)
      normalized_list = normalize_model_files_list(files_to_annotate)

      expected_files = [
        "app/models/comment.rb", # New on feature branch
        "app/models/product.rb", # New on feature branch
        "app/models/user.rb"     # Modified on feature branch
      ].sort

      expect(normalized_list).to match_array(expected_files)
      expect(normalized_list).not_to include("app/models/post.rb")
    end
  end

  context "when skip_unchanged_files is false" do
    it "annotates all model files" do
      options_hash = {
        skip_unchanged_files: false,
        model_dir: ["app/models"],
        root_dir: [tmp_dir],
        working_args: []
      }
      options = AnnotateRb::Options.from(options_hash)
      options.set_state(:working_args, [])

      files_to_annotate = AnnotateRb::ModelAnnotator::ModelFilesGetter.call(options)
      normalized_list = normalize_model_files_list(files_to_annotate)

      expected_files = [
        "app/models/comment.rb",
        "app/models/post.rb",
        "app/models/product.rb",
        "app/models/user.rb"
      ].sort

      expect(normalized_list).to match_array(expected_files)
    end
  end
end
