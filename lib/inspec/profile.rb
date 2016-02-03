# encoding: utf-8
# Copyright 2015 Dominik Richter. All rights reserved.
# author: Dominik Richter
# author: Christoph Hartmann

require 'inspec/metadata'
require 'pathname'

module Inspec
  class Profile # rubocop:disable Metrics/ClassLength
    def self.from_path(path, options = nil)
      opt = {}
      options.each { |k, v| opt[k.to_sym] = v } unless options.nil?
      opt[:path] = path
      Profile.new(opt)
    end

    attr_reader :params
    attr_reader :path
    attr_reader :metadata

    def initialize(options = nil)
      @options = options || {}

      @params = {}
      @logger = options[:logger] || Logger.new(nil)

      @path = @options[:path]
      fail 'Cannot read an empty path.' if @path.nil? || @path.empty?
      fail "Cannot find directory #{@path}" unless File.directory?(@path)

      @metadata = read_metadata
      @params = @metadata.params
      # use the id from parameter, name or fallback to nil
      @profile_id = options[:id] || params[:name] || nil
      @params[:name] = @profile_id

      @params[:rules] = rules = {}
      @runner = Runner.new(
        id: @profile_id,
        backend: :mock,
        test_collector: @options.delete(:test_collector),
      )
      @runner.add_tests([@path], @options)
      @runner.rules.each do |id, rule|
        file = rule.instance_variable_get(:@__file)
        rules[file] ||= {}
        rules[file][id] = {
          title: rule.title,
          desc: rule.desc,
          impact: rule.impact,
          checks: rule.instance_variable_get(:@checks),
          code: rule.instance_variable_get(:@__code),
          source_location: rule.instance_variable_get(:@__source_location),
          group_title: rule.instance_variable_get(:@__group_title),
        }
      end
    end

    def info
      res = @params.dup
      rules = {}
      res[:rules].each do |gid, group|
        next if gid.to_s.empty?
        path = gid.sub(File.join(@path, ''), '')
        rules[path] = { title: path, rules: {} }
        group.each do |id, rule|
          next if id.to_s.empty?
          data = rule.dup
          data.delete(:checks)
          data[:impact] ||= 0.5
          data[:impact] = 1.0 if data[:impact] > 1.0
          data[:impact] = 0.0 if data[:impact] < 0.0
          rules[path][:rules][id] = data
          # TODO: temporarily flatten the group down; replace this with
          # proper hierarchy later on
          rules[path][:title] = data[:group_title]
        end
      end
      res[:rules] = rules
      res
    end

    # Check if the profile is internall well-structured. The logger will be
    # used to print information on errors and warnings which are found.
    #
    # @return [Boolean] true if no errors were found, false otherwise
    def check # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

      # initial values for response object
      result = {
        :summary => {
          :valid => false,
          :timestamp => Time.now.iso8601,
          :location => @path,
          :profile => nil,
          :controls => 0,
        },
        :errors => [],
        :warnings => [],
      }

      entry = lambda { |file, line, column, control, msg|
        {
          :file => file,
          :line => line,
          :column => column,
          :control_id => control,
          :msg => msg,
        }
      }

      warn = lambda { |file, line, column, control, msg|
        @logger.warn(msg)
        result[:warnings].push(entry.call(file, line, column, control, msg))
      }

      error = lambda { |file, line, column, control, msg|
        @logger.error(msg)
        result[:errors].push(entry.call(file, line, column, control, msg))
      }

      @logger.info "Checking profile in #{@path}"

      if Pathname.new(path).join('metadata.rb').exist?
        warn.call(Pathname.new(path).join('metadata.rb'), 0,0,nil, 'The use of `metadata.rb` is deprecated. Use `inspec.yml`.')
      end

      @logger.info 'Metadata OK.' if @metadata.valid?
      result[:summary][:profile] = @metadata.params[:name]

      # check if the profile is using the old test directory instead of the
      # new controls directory
      if Pathname.new(path).join('test').exist? && !Pathname.new(path).join('controls').exist?
        warn.call(Pathname.new(path).join('test'), 0,0,nil, 'Profile uses deprecated `test` directory, rename it to `controls`.')
      end

      count = rules_count
      result[:summary][:controls] = count
      if count == 0
        warn.call(nil, nil, nil, nil, 'No controls or tests were defined.')
      else
        @logger.info("Found #{count} controls.")
      end

      # iterate over hash of groups
      @params[:rules].each { |group, controls|
        @logger.info "Verify all controls in  #{group}"
        controls.each { |id, control|
          sfile, sline = control[:source_location]
          error.call(sfile, sline, nil, id, 'Avoid controls with empty IDs') if id.nil? or id.empty?
          next if id.start_with? '(generated '
          warn.call(sfile, sline, nil, id, "Control #{id} has no title") if control[:title].to_s.empty?
          warn.call(sfile, sline, nil, id, "Control #{id} has no description") if control[:desc].to_s.empty?
          warn.call(sfile, sline, nil, id, "Control #{id} has impact > 1.0") if control[:impact].to_f > 1.0
          warn.call(sfile, sline, nil, id, "Control #{id} has impact < 0.0") if control[:impact].to_f < 0.0
          warn.call(sfile, sline, nil, id, "Control #{id} has no tests defined") if control[:checks].nil? or control[:checks].empty?
        }
      }

      @logger.info 'Control definitions OK.' if result[:warnings].empty?
      [result[:errors].empty?, result]
    end

    def rules_count
      @params[:rules].values.map { |hm| hm.values.length }.inject(:+) || 0
    end

    # generates a archive of a folder profile
    def archive(opts) # rubocop:disable Metrics/AbcSize
      check_result = check

      if check_result && !opts.ignore_errors == false
        @logger.info 'Profile check failed. Please fix the profile before generating an archive.'
        return false
      end

      profile_name = @params[:name]

      ext = opts[:zip] ? 'zip' : 'tar.gz'
      slug = profile_name.downcase.strip.tr(' ', '-').gsub(/[^\w-]/, '_')
      archive = Pathname.new(File.dirname(__FILE__)).join('../..', "#{slug}.#{ext}")

      # check if file exists otherwise overwrite the archive
      if archive.exist? && !opts[:overwrite]
        @logger.info "Archive #{archive} exists already. Use --overwrite."
        return false
      end

      # remove existing archive
      File.delete(archive) if archive.exist?

      @logger.info "Profile check finished. Generate archive #{archive}."

      # find all files
      files = Dir.glob("#{path}/**/*")

      # filter files that should not be part of the profile
      # TODO ignore all .files, but add the files to debug output

      # map absolute paths to relative paths
      files = files.collect { |f| Pathname.new(f).relative_path_from(Pathname.new(path)).to_s }

      # display all files that will be part of the archive
      @logger.debug 'Add the following files to archive:'
      files.each { |f|
        @logger.debug '    ' + f
      }

      if opts[:zip]
        # generate zip archive
        require 'inspec/archive/zip'
        zag = Inspec::Archive::ZipArchiveGenerator.new
        zag.archive(path, files, archive)
      else
        # generate tar archive
        require 'inspec/archive/tar'
        tag = Inspec::Archive::TarArchiveGenerator.new
        tag.archive(path, files, archive)
      end

      @logger.info 'Finished archive generation.'
      true
    end

    private

    def read_metadata
      mpath = Pathname.new(path).join('inspec.yml')

      # fallback to metadata.rb if inspec.yml does not exist
      # TODO deprecated, will be removed in InSpec 1.0
      mpath = File.join(@path, 'metadata.rb') if !mpath.exist?
      Metadata.from_file(mpath, @profile_id, @logger)
    end
  end
end
