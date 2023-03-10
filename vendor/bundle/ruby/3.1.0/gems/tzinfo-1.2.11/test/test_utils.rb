tests_dir = File.expand_path(File.dirname(__FILE__))
tests_dir.untaint if RUBY_VERSION < '2.7'
TESTS_DIR = tests_dir
TZINFO_LIB_DIR = File.expand_path(File.join(TESTS_DIR, '..', 'lib'))
TZINFO_TEST_DATA_DIR = File.join(TESTS_DIR, 'tzinfo-data')
TZINFO_TEST_ZONEINFO_DIR = File.join(TESTS_DIR, 'zoneinfo')

$:.unshift(TZINFO_LIB_DIR) unless $:.include?(TZINFO_LIB_DIR)

# tzinfo-data contains a cut down copy of tzinfo-data for use in the tests.
# Add it to the load path.
$:.unshift(TZINFO_TEST_DATA_DIR) unless $:.include?(TZINFO_TEST_DATA_DIR)

require 'minitest/autorun'
require 'tzinfo'
require 'fileutils'
require 'rbconfig'

module TestUtils
  ZONEINFO_SYMLINKS = [
    ['localtime', 'America/New_York'],
    ['UTC', 'Etc/UTC']]
  

  def self.prepare_test_zoneinfo_dir
    ZONEINFO_SYMLINKS.each do |file, target|
      path = File.join(TZINFO_TEST_ZONEINFO_DIR, file)
      
      File.delete(path) if File.exist?(path)
    
      begin
        FileUtils.ln_s(target, path)
      rescue NotImplementedError, Errno::EACCES
        # Symlinks not supported on this platform, or permission denied
        # (administrative rights are required on Windows). Copy instead.
        target_path = File.join(TZINFO_TEST_ZONEINFO_DIR, target)
        FileUtils.cp(target_path, path)
      end
    end
  end
end

TestUtils.prepare_test_zoneinfo_dir



module Kernel
  # Suppresses any warnings raised in a specified block.
  def without_warnings
    old_verbose = $VERBOSE
    begin
      $VERBOSE = nil
      yield
    ensure
      $-v = old_verbose
    end
  end
  
  def safe_test(options = {})
    # Ruby >= 2.7, JRuby and Rubinus don't support SAFE levels.
    available = RUBY_VERSION < '2.7' && !(defined?(RUBY_ENGINE) && %w(jruby rbx).include?(RUBY_ENGINE))
   
    if available || options[:unavailable] != :skip
      thread = Thread.new do
        orig_diff = Minitest::Assertions.diff

        if available
          orig_safe = $SAFE
          $SAFE = options[:level] || 1
        end
        begin
          # Disable the use of external diff tools during safe mode tests (since
          # safe mode will prevent their use). The initial value is retrieved
          # before activating safe mode because the first time
          # Minitest::Assertions.diff is called, it will attempt to find a diff
          # tool. Finding the diff tool will also fail in safe mode.
          Minitest::Assertions.diff = nil
          begin
            yield
          ensure
            Minitest::Assertions.diff = orig_diff
          end
        ensure
          if available
            # On Ruby < 2.6, setting $SAFE affects only the current thread
            # and the $SAFE level cannot be downgraded. Catch and ignore the
            # SecurityError.
            # On Ruby >= 2.6, setting $SAFE is global, and the $SAFE level
            # can be downgraded. Restore $SAFE back to the original level.
            begin
              $SAFE = orig_safe
            rescue SecurityError
            end
          end
        end
      end
      
      thread.join
    end
  end

  def skip_if_has_bug_14060
    # On Ruby 2.4.4 in safe mode, require will fail with a SecurityError for
    # any file that has not previously been loaded, regardless of whether the
    # file name is tainted.
    # See https://bugs.ruby-lang.org/issues/14060#note-5.
    if defined?(RUBY_ENGINE) && RUBY_ENGINE == 'ruby' && RUBY_VERSION == '2.4.4'
      skip('Skipping test due to Ruby 2.4.4 being affected by Bug 14060 (see https://bugs.ruby-lang.org/issues/14060#note-5)')
    end
  end

  # Object#taint is deprecated in Ruby >= 2.7 and will be removed in 3.2.
  # 2.7 makes it a no-op with a warning.
  # Define a method that will skip for use in tests that deal with tainted
  # objects.
  if Object.respond_to?(:taint)
    if RUBY_VERSION >= '2.7'
      def skip_if_taint_is_undefined_or_no_op
        skip('Object#taint is a no-op')
      end
    else
      def skip_if_taint_is_undefined_or_no_op
      end
    end
  else
    def skip_if_taint_is_undefined_or_no_op
      skip('Object#taint is not defined')
    end
  end
  
  def assert_array_same_items(expected, actual, msg = nil)
    full_message = message(msg, '') { diff(expected, actual) }
    condition = (expected.size == actual.size) && (expected - actual == [])
    assert(condition, full_message)
  end
  
  def assert_sub_process_returns(expected_lines, code, extra_load_path = [], required = ['tzinfo'])
    if defined?(RUBY_ENGINE) && RUBY_ENGINE == 'jruby' && JRUBY_VERSION.start_with?('9.0.') && RbConfig::CONFIG['host_os'] =~ /mswin/
      skip('JRuby 9.0 on Windows cannot handle writing to the IO instance returned by popen')
    end

    ruby = File.join(RbConfig::CONFIG['bindir'], 
      RbConfig::CONFIG['ruby_install_name'] + RbConfig::CONFIG['EXEEXT'])
      
    load_path = [TZINFO_LIB_DIR] + extra_load_path
    
    # If RubyGems is loaded in the current process, then require it in the
    # sub-process, as it may be needed in order to require dependencies.
    if defined?(Gem) && Gem.instance_of?(Module)
      required = ['rubygems'] + required
    end
    
    if defined?(RUBY_ENGINE) && RUBY_ENGINE == 'rbx'
      # Stop Rubinus from operating as irb.
      args = ' -'
    else
      args = ''
    end

    IO.popen("\"#{ruby}\"#{args}", 'r+') do |process|
      load_path.each do |p|
        process.puts("$:.unshift('#{p.gsub("'", "\\\\'")}')")        
      end
      
      required.each do |r|
        process.puts("require '#{r.gsub("'", "\\\\'")}'")
      end
      
      process.puts(code)
      process.flush
      process.close_write
      
      actual_lines = process.readlines
      actual_lines = actual_lines.collect {|l| l.chomp}

      # Ignore warnings from JRuby 1.7 and 9.0 on modern versions of Java:
      # https://github.com/tzinfo/tzinfo/runs/1664655982#step:8:1893
      #
      # Ignore untaint deprecation warnings from Bundler 1 on Ruby 3.0.
      actual_lines = actual_lines.reject do |l|
        l.start_with?('unsupported Java version') ||
          l.start_with?('WARNING: An illegal reflective access operation has occurred') ||
          l.start_with?('WARNING: Illegal reflective access by') ||
          l.start_with?('WARNING: Please consider reporting this to the maintainers of') ||
          l.start_with?('WARNING: All illegal access operations will be denied in a future release') ||
          l.start_with?('WARNING: Use --illegal-access=warn to enable warnings of further illegal reflective access operations') ||
          l.start_with?('io/console on JRuby shells out to stty for most operations') ||
          l =~ /\/bundler-1\..*\/lib\/bundler\/.*\.rb:\d+: warning: (Object|Pathname)#untaint is deprecated and will be removed in Ruby 3\.2\.\z/
      end

      assert_equal(expected_lines, actual_lines)
    end
  end

  def assert_nothing_raised(msg = nil)
    begin
      yield
    rescue => e
      full_message = message(msg) { exception_details(e, 'Exception raised: ') }
      assert(false, full_message)
    end
  end
end


# JRuby 1.7.5 to 1.7.9 consider DateTime instances that differ by less than 
# 1 millisecond to be equivalent (https://github.com/jruby/jruby/issues/1311).
#
# A few test cases compare at a resolution of 1 microsecond, so this causes
# failures on JRuby 1.7.5 to 1.7.9.
#
# Determine what the platform supports and adjust the tests accordingly.
DATETIME_RESOLUTION = (0..5).collect {|i| 10**i}.find {|i| (DateTime.new(2013,1,1,0,0,0) <=> DateTime.new(2013,1,1,0,0,Rational(i,1000000))) < 0}
raise 'Unable to compare DateTimes at a resolution less than one second on this platform' unless DATETIME_RESOLUTION
