require 'fileutils'
require 'tmpdir'
require 'yaml'

def test_asset_path(asset_file_name)
  File.join(File.dirname(__FILE__), '..', 'assets', asset_file_name)
end

def convert_slashes(path)
  if RUBY_PLATFORM.downcase.match(/mingw|win32/)
    path.gsub("/","\\")
  else
    path
  end
end

class GemDirLayout
  attr_reader :gem_dir_base_name

  def initialize(install_dir)
    @gem_dir_base_name = "gems"
    @d = File.join install_dir, @gem_dir_base_name
    FileUtils.mkdir_p @d
  end

  def install_dir; convert_slashes(@d)  end
  def bin;         File.join(@d, 'bin') end
  def lib;         File.join(@d, 'lib') end
end

class SystemContext
  class VerificationFailed < Exception; end
  class InvalidBackupEnv < Exception; end

  attr_reader :dir, :gem

  def initialize
    @dir = Dir.mktmpdir
    @gem = GemDirLayout.new(@dir)
  end

  def done!
    FileUtils.rm_rf(@dir)
  end

  def deploy_gem
    git_repo = File.expand_path(File.join(File.dirname(__FILE__), '..'))
    bundler_gem_file_data = [ %Q{source "http://rubygems.org/"},
                              %Q{gem "rake"},
                              %Q{gem "ceedling", :path => '#{git_repo.to_s}'}
                            ].join("\n")

    File.open(File.join(@dir, "Gemfile"), "w+") do |f|
      f.write(bundler_gem_file_data)
    end

    Dir.chdir @dir do
      with_constrained_env do
        `bundle install --path #{@gem.install_dir}`
        checks = ["bundle exec ruby -S ceedling 2>&1"]
        checks.each do |c|
          `#{c}`
          #raise VerificationFailed.new(c) unless $?.success?
        end
      end
    end
  end

  # Does a few things:
  #   - Configures the environment.
  #   - Runs the command from the temporary context directory.
  #   - Restores everything to where it was when finished.
  def context_exec(cmd, *args)
    with_context do
      `#{args.unshift(cmd).join(" ")}`
    end
  end

  def with_context
    Dir.chdir @dir do |current_dir|
      with_constrained_env do
        ENV['RUBYLIB'] = @gem.lib
        ENV['RUBYPATH'] = @gem.bin

        yield
      end
    end
  end

  def backup_env
    # Force a deep clone. Hacktacular, but works.
    @_env = YAML.load(ENV.to_hash.to_yaml)
  end

  def reduce_env(destroy_keys=[])
    ENV.keys.each {|k| ENV.delete(k) if destroy_keys.include?(k) }
  end

  def constrain_env
    destroy_keys = %w{BUNDLE_GEMFILE BUNDLE_BIN_PATH RUBYOPT}
    reduce_env(destroy_keys)
  end

  def restore_env
    if @_env
      @_env.each_pair {|k,v| ENV[k] = v}
    else
      raise InvalidBackupEnv.new
    end
  end

  def with_constrained_env
    begin
      backup_env
      constrain_env
      yield
    ensure
      restore_env
    end
  end
end

module CeedlingTestCases
  def can_create_projects
    @c.with_context do
      Dir.chdir @proj_name do
        expect(File.exists?("project.yml")).to eq true
        expect(File.exists?("rakefile.rb")).to eq true
        expect(File.exists?("src")).to eq true
        expect(File.exists?("test")).to eq true
      end
    end
  end

  def can_upgrade_projects
    @c.with_context do
      output = `bundle exec ruby -S ceedling upgrade #{@proj_name} 2>&1`
      expect($?.exitstatus).to match(0)
      expect(output).to match(/upgraded!/i)
      Dir.chdir @proj_name do
        expect(File.exists?("project.yml")).to eq true
        expect(File.exists?("rakefile.rb")).to eq true
        expect(File.exists?("src")).to eq true
        expect(File.exists?("test")).to eq true
        all_docs = Dir["vendor/ceedling/docs/*.pdf"].length + Dir["vendor/ceedling/docs/*.md"].length
        expect(all_docs).to be >= 4
      end
    end
  end

  def contains_a_vendor_directory
    @c.with_context do
      Dir.chdir @proj_name do
        expect(File.exists?("vendor/ceedling")).to eq true
      end
    end
  end

  def does_not_contain_a_vendor_directory
    @c.with_context do
      Dir.chdir @proj_name do
        expect(File.exists?("vendor/ceedling")).to eq false
      end
    end
  end

  def contains_documentation
    @c.with_context do
      Dir.chdir @proj_name do
        all_docs = Dir["vendor/ceedling/docs/*.pdf"].length + Dir["vendor/ceedling/docs/*.md"].length
        expect(all_docs).to be >= 4
      end
    end
  end

  def does_not_contain_documentation
    @c.with_context do
      Dir.chdir @proj_name do
        expect(File.exists?("vendor/ceedling/docs")).to eq false
        expect(Dir["vendor/ceedling/**/*.pdf"].length).to eq 0
      end
    end
  end

  def can_test_projects_with_success
    @c.with_context do
      Dir.chdir @proj_name do
        FileUtils.cp test_asset_path("example_file.h"), 'src/'
        FileUtils.cp test_asset_path("example_file.c"), 'src/'
        FileUtils.cp test_asset_path("test_example_file_success.c"), 'test/'

        output = `bundle exec ruby -S ceedling test:all`
        expect($?.exitstatus).to match(0) # Since a test either pass or are ignored, we return success here
        expect(output).to match(/TESTED:\s+\d/)
        expect(output).to match(/PASSED:\s+\d/)
        expect(output).to match(/FAILED:\s+\d/)
        expect(output).to match(/IGNORED:\s+\d/)
      end
    end
  end

  def can_test_projects_with_fail
    @c.with_context do
      Dir.chdir @proj_name do
        FileUtils.cp test_asset_path("example_file.h"), 'src/'
        FileUtils.cp test_asset_path("example_file.c"), 'src/'
        FileUtils.cp test_asset_path("test_example_file.c"), 'test/'

        output = `bundle exec ruby -S ceedling test:all`
        expect($?.exitstatus).to match(1) # Since a test fails, we return error here
        expect(output).to match(/TESTED:\s+\d/)
        expect(output).to match(/PASSED:\s+\d/)
        expect(output).to match(/FAILED:\s+\d/)
        expect(output).to match(/IGNORED:\s+\d/)
      end
    end
  end

  def can_test_projects_with_compile_error
    @c.with_context do
      Dir.chdir @proj_name do
        FileUtils.cp test_asset_path("example_file.h"), 'src/'
        FileUtils.cp test_asset_path("example_file.c"), 'src/'
        FileUtils.cp test_asset_path("test_example_file_boom.c"), 'test/'

        output = `bundle exec ruby -S ceedling test:all`
        expect($?.exitstatus).to match(1) # Since a test explodes, we return error here
        expect(output).to match(/ERROR: Shell command failed/)
        expect(output).to match(/> And exited with status:\s+/)
        expect(output).to match(/rake aborted!/)
      end
    end
  end


  def can_fetch_non_project_help
    @c.with_context do
      #notice we don't change directory into the project
        output = `bundle exec ruby -S ceedling help`
        expect($?.exitstatus).to match(0)
        expect(output).to match(/ceedling example/i)
        expect(output).to match(/ceedling new/i)
        expect(output).to match(/ceedling upgrade/i)
        expect(output).to match(/ceedling version/i)
    end
  end

  def can_fetch_project_help
    @c.with_context do
      Dir.chdir @proj_name do
        output = `bundle exec ruby -S ceedling help`
        expect($?.exitstatus).to match(0)
        expect(output).to match(/ceedling clean/i)
        expect(output).to match(/ceedling clobber/i)
        expect(output).to match(/ceedling logging/i)
        expect(output).to match(/ceedling module:create/i)
        expect(output).to match(/ceedling module:destroy/i)
        expect(output).to match(/ceedling summary/i)
        expect(output).to match(/ceedling test:\*/i)
        expect(output).to match(/ceedling test:all/i)
        expect(output).to match(/ceedling test:delta/i)
        expect(output).to match(/ceedling version/i)
      end
    end
  end

  def can_use_the_module_plugin
    @c.with_context do
      Dir.chdir @proj_name do
        output = `bundle exec ruby -S ceedling module:create[ponies]`
        expect($?.exitstatus).to match(0)
        expect(output).to match(/Generate Complete/i)
        output = `bundle exec ruby -S ceedling test:all`
        expect($?.exitstatus).to match(0)
        expect(output).to match(/Need to Implement ponies/)
        output = `bundle exec ruby -S ceedling module:destroy[ponies]`
        expect($?.exitstatus).to match(0)
        expect(output).to match(/Destroy Complete/i)
      end
    end
  end

  def handles_creating_the_same_module_twice_using_the_module_plugin
    @c.with_context do
      Dir.chdir @proj_name do
        output = `bundle exec ruby -S ceedling module:create[unicorns]`
        expect($?.exitstatus).to match(0)
        expect(output).to match(/Generate Complete/i)

        output = `bundle exec ruby -S ceedling module:create[unicorns]`
        expect($?.exitstatus).to match(1)
        expect(output).to match(/rake aborted!/i)
        expect(output).to match(/ERROR: File unicorns already exists\. Exiting\./)
      end
    end
  end

  def handles_destroying_a_module_that_does_not_exist_using_the_module_plugin
    @c.with_context do
      Dir.chdir @proj_name do
        output = `bundle exec ruby -S ceedling module:destroy[unknown]`
        expect($?.exitstatus).to match(0)

        expect(output).to match(/File src\/unknown\.c does not exist so cannot be removed\./)
        expect(output).to match(/File src\/unknown\.h does not exist so cannot be removed\./)
        expect(output).to match(/File test\/test_unknown\.c does not exist so cannot be removed\./)
        expect(output).to match(/Destroy Complete/)
      end
    end
  end

end
