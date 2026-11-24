# frozen_string_literal: true

# ─── Coverage (must start before loading main.rb) ─────────────────────────────
unless defined?(Coverage) && Coverage.running?
  require 'coverage'
  Coverage.start
end

# ─── Dependencies ─────────────────────────────────────────────────────────────
require 'rspec'
require 'rspec/core/formatters/base_formatter'
require 'open3'
require 'fileutils'
require 'tmpdir'
require 'stringio'

MAIN_RB      = File.expand_path('../main.rb', __dir__)
PROJECT_ROOT = File.dirname(MAIN_RB)

require MAIN_RB

# ─── Custom Formatter ─────────────────────────────────────────────────────────
class ReadableFormatter < RSpec::Core::Formatters::BaseFormatter
  RSpec::Core::Formatters.register(
    self,
    :example_group_started,
    :example_group_finished,
    :example_passed,
    :example_failed,
    :example_pending,
    :dump_summary
  )

  PASS  = "\e[32;1m[ PASS ]\e[0m"
  FAIL  = "\e[31;1m[ FAIL ]\e[0m"
  ERROR = "\e[31;1m[ERROR ]\e[0m"
  SKIP  = "\e[33;1m[ SKIP ]\e[0m"

  DIVIDER     = "\e[90m#{'─' * 72}\e[0m"
  DIVIDER_FAT = "\e[90m#{'═' * 72}\e[0m"

  def initialize(output)
    super
    @depth    = 0
    @failures = []
    @counts   = { passed: 0, failed: 0, pending: 0 }
  end

  # Top-level describe groups cycle through distinct colors
  GROUP_COLORS = [
    "\e[34;1m",  # bold blue
    "\e[35;1m",  # bold magenta
    "\e[36;1m",  # bold cyan
    "\e[33;1m",  # bold yellow
  ].freeze

  def example_group_started(notification)
    group = notification.group
    if group.parent_groups.size <= 1
      output.puts if @depth.zero?
      color = GROUP_COLORS[@depth % GROUP_COLORS.size]
      output.puts "  #{color}#{group.description}\e[0m"
    else
      output.puts "    #{'  ' * (@depth - 1)}\e[90m▸ \e[0m\e[37m#{group.description}\e[0m"
    end
    @depth += 1
  end

  def example_group_finished(_notification)
    @depth -= 1 if @depth > 0
  end

  def example_passed(notification)
    @counts[:passed] += 1
    print_example(PASS, notification.example)
  end

  def example_failed(notification)
    @counts[:failed] += 1
    ex    = notification.example
    exc   = ex.execution_result.exception
    badge = exc.is_a?(RSpec::Expectations::ExpectationNotMetError) ? FAIL : ERROR
    print_example(badge, ex)
    @failures << notification
  end

  def example_pending(notification)
    @counts[:pending] += 1
    ex = notification.example
    output.puts "    #{'  ' * [0, @depth - 1].max}#{SKIP}  #{ex.description}"
  end

  def dump_summary(notification)
    output.puts
    output.puts DIVIDER_FAT

    unless @failures.empty?
      output.puts "\n  \e[1;31mFailures:\e[0m\n"
      @failures.each_with_index do |n, i|
        ex  = n.example
        exc = ex.execution_result.exception
        output.puts "  \e[1m#{i + 1}) #{ex.full_description}\e[0m"
        exc.message.lines.first(6).each do |line|
          output.puts "     \e[31m#{line.rstrip}\e[0m"
        end
        output.puts "     \e[90m# #{ex.location}\e[0m"
        output.puts
      end
      output.puts DIVIDER
    end

    t   = notification.examples.size
    p   = @counts[:passed]
    f   = @counts[:failed]
    s   = @counts[:pending]
    sec = format('%.3fs', notification.duration)

    parts = ["\e[32m#{p} passed\e[0m"]
    parts << "\e[31m#{f} failed\e[0m"  if f > 0
    parts << "\e[33m#{s} pending\e[0m" if s > 0

    overall = f.zero? ? "\e[32;1m✔  All #{t} tests passed\e[0m" : "\e[31;1m✖  #{f} of #{t} tests failed\e[0m"
    output.puts "\n  #{overall}"
    output.puts "  #{parts.join('  |  ')}  \e[90m(#{sec})\e[0m"
    output.puts DIVIDER_FAT
  end

  private

  def print_example(badge, example)
    indent = '  ' * [0, @depth - 1].max
    time   = format('%.3fs', example.execution_result.run_time)
    output.puts "    #{indent}#{badge}  #{example.description}  \e[90m(#{time})\e[0m"
  end
end


# ─── Helpers ──────────────────────────────────────────────────────────────────

STEP_ENV_KEYS = %w[
  AC_SCHEME AC_REPOSITORY_DIR AC_PROJECT_PATH AC_WORKSPACE_PATH AC_COVERAGE_FORMAT
  AC_SLATHER_OPTIONS AC_CONFIGURATION_NAME AC_OUTPUT_DIR AC_TEST_RESULT_PATH
  AC_SLATHER_OUTPUT_PATH AC_ENV_FILE_PATH
].freeze

COVERAGE_FLAGS = {
  'cobertura'   => '-x',
  'sonarqube'   => '-sq',
  'gutter-json' => '-g',
  'llvm-cov'    => '-r',
  'json'        => '--json',
  'html'        => '--html',
  'simple'      => '-s'
}.freeze

XCODE_DEV_DIR = '/Applications/Xcode-16.2.app/Contents/Developer'

# Top-level object main.rb runs against when it is `load`ed. The step calls
# `which slather` on it, so that backtick call is stubbed on this object.
MAIN_OBJECT = TOPLEVEL_BINDING.receiver

# Saves and clears every variable the step reads, runs the block, then restores them.
def with_clean_env
  old = STEP_ENV_KEYS.to_h { |k| [k, ENV[k]] }
  STEP_ENV_KEYS.each { |k| ENV.delete(k) }
  yield
ensure
  STEP_ENV_KEYS.each { |k| ENV.delete(k) }
  old.each { |k, v| ENV[k] = v unless v.nil? }
end

def fake_status(success)
  double('Process::Status', success?: success)
end

# Stubs Open3.popen3 so no real command runs. Each call records the command and
# yields fake stdin/stdout/stderr streams plus a wait thread whose value is the
# next response's status; the last response is reused once exhausted.
def stub_popen3(*responses, recorder: nil)
  queue = responses.empty? ? [['', '', true]] : responses.dup
  allow(Open3).to receive(:popen3) do |cmd, &block|
    recorder&.<<(cmd)
    stdout, stderr, success = queue.size > 1 ? queue.shift : queue.first
    wait_thr = double('Process::Waiter', value: fake_status(success))
    block.call(StringIO.new, StringIO.new(stdout), StringIO.new(stderr), wait_thr)
  end
end

# Stubs the step's `which slather` lookup. installed=false sends the step down
# the "install slather" branch.
def stub_slather_installed(installed)
  allow(MAIN_OBJECT).to receive(:`).with('which slather')
                                   .and_return(installed ? "/usr/local/bin/slather\n" : '')
end

# Runs the block with $stdout and $stderr captured.
# Returns [stdout, stderr, SystemExit or nil].
def capture_io
  old_out = $stdout
  old_err = $stderr
  $stdout = StringIO.new
  $stderr = StringIO.new
  exit_error = nil
  begin
    yield
  rescue SystemExit => e
    exit_error = e
  end
  [$stdout.string, $stderr.string, exit_error]
ensure
  $stdout = old_out
  $stderr = old_err
end

# Ruby's Coverage resets a file's counters on every `load`, so a snapshot is
# taken before each load and summed into the final report.
COVERAGE_SNAPSHOTS = []

def snapshot_coverage
  return unless defined?(Coverage) && Coverage.running?

  data = Coverage.peek_result[MAIN_RB]
  COVERAGE_SNAPSHOTS << data if data
end

# Runs main.rb's step body in-process with the given ENV.
# Returns [stdout, stderr, SystemExit or nil].
def run_step(env)
  with_clean_env do
    env.each { |k, v| ENV[k] = v }
    old_program_name = $PROGRAM_NAME
    $PROGRAM_NAME = MAIN_RB
    snapshot_coverage
    begin
      capture_io { load MAIN_RB }
    ensure
      $PROGRAM_NAME = old_program_name
    end
  end
end

# Runs main.rb in a subprocess with the given ENV. Every variable the step reads
# is unset first (a nil value unsets it in the child), so the ambient
# environment cannot leak in.
def run_main(env = {})
  clean_env = STEP_ENV_KEYS.to_h { |k| [k, nil] }
  Open3.capture3(clean_env.merge(env), "ruby #{MAIN_RB}")
end

# Writes fake `which`, `slather`, `sudo` and `xcode-select` executables into
# bin_dir. They append their arguments to $FAKE_TOOL_LOG and never execute
# anything else, so the subprocess tests run the real step without touching
# the host toolchain or installing gems.
#   FAKE_SLATHER_MISSING=1 -> `which slather` prints nothing (install branch)
#   FAKE_SLATHER_FAIL=1    -> slather prints an error to stderr and exits 1
#   FAKE_SUDO_FAIL=1       -> sudo prints an error to stderr and exits 1
def write_fake_tools(bin_dir)
  FileUtils.mkdir_p(bin_dir)
  {
    'which' => <<~SH,
      #!/bin/sh
      if [ "$1" = "slather" ]; then
        [ "$FAKE_SLATHER_MISSING" = "1" ] && exit 1
        echo "#{bin_dir}/slather"
        exit 0
      fi
      exec /usr/bin/which "$@"
    SH
    'slather' => <<~SH,
      #!/bin/sh
      echo "slather $*" >> "$FAKE_TOOL_LOG"
      if [ "$FAKE_SLATHER_FAIL" = "1" ]; then
        echo "slather: error: no coverage data found" >&2
        exit 1
      fi
      echo "Slathering..."
    SH
    'sudo' => <<~SH,
      #!/bin/sh
      echo "sudo $*" >> "$FAKE_TOOL_LOG"
      if [ "$FAKE_SUDO_FAIL" = "1" ]; then
        echo "ERROR: could not install gem" >&2
        exit 1
      fi
    SH
    'xcode-select' => <<~SH
      #!/bin/sh
      echo "xcode-select $*" >> "$FAKE_TOOL_LOG"
      echo "#{XCODE_DEV_DIR}"
    SH
  }.each do |name, body|
    path = File.join(bin_dir, name)
    File.write(path, body)
    File.chmod(0o755, path)
  end
  bin_dir
end

# ─── Tests ────────────────────────────────────────────────────────────────────

RSpec.describe '#get_env_variable' do
  around do |example|
    old = ENV['_TEST_VAR']
    example.run
    old.nil? ? ENV.delete('_TEST_VAR') : ENV['_TEST_VAR'] = old
  end

  context 'positive path' do
    it 'returns the value when the key is set' do
      ENV['_TEST_VAR'] = 'MyScheme'
      expect(get_env_variable('_TEST_VAR')).to eq('MyScheme')
    end

    it 'keeps whitespace-only values as-is' do
      ENV['_TEST_VAR'] = '  '
      expect(get_env_variable('_TEST_VAR')).to eq('  ')
    end
  end

  context 'negative path' do
    it 'returns nil when the key is missing' do
      ENV.delete('_TEST_VAR')
      expect(get_env_variable('_TEST_VAR')).to be_nil
    end

    it 'returns nil when the value is an empty string' do
      ENV['_TEST_VAR'] = ''
      expect(get_env_variable('_TEST_VAR')).to be_nil
    end

    it 'raises TypeError for a nil key' do
      expect { get_env_variable(nil) }.to raise_error(TypeError)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#runCommand' do
  let(:commands) { [] }

  context 'positive path' do
    it 'passes the command string to Open3.popen3 unchanged' do
      stub_popen3(['', '', true], recorder: commands)
      capture_io { runCommand('slather coverage -x --scheme "My App"') }
      expect(commands).to eq(['slather coverage -x --scheme "My App"'])
    end

    it 'logs the command and streams stdout line by line' do
      stub_popen3(["Slathering...\nDone\n", '', true])
      out, _err, error = capture_io { runCommand('slather coverage') }
      expect(error).to be_nil
      expect(out).to eq("@@[command] slather coverage\nSlathering...\nDone\n")
    end

    it 'returns an empty string by default (isLogReturn = false)' do
      stub_popen3(["line 1\nline 2\n", '', true])
      result = nil
      capture_io { result = runCommand('xcode-select -p') }
      expect(result).to eq('')
    end

    it 'returns the full stdout when isLogReturn = true' do
      stub_popen3(["#{XCODE_DEV_DIR}\n", '', true])
      result = nil
      capture_io { result = runCommand('xcode-select -p', true) }
      expect(result).to eq("#{XCODE_DEV_DIR}\n")
    end

    it 'prints only the command log when the command succeeds silently' do
      stub_popen3(['', '', true])
      out, _err, _error = capture_io { runCommand('true') }
      expect(out).to eq("@@[command] true\n")
    end

    it 'does not raise or print stderr when a successful command writes to stderr' do
      stub_popen3(["ok\n", 'warning: something', true])
      out, _err, error = capture_io { runCommand('slather coverage') }
      expect(error).to be_nil
      expect(out).not_to include('warning: something')
    end
  end

  context 'negative path' do
    it 'raises RuntimeError with stderr when the command fails' do
      stub_popen3(['', 'slather: error: no coverage data found', false])
      expect { capture_io { runCommand('slather coverage') } }
        .to raise_error(RuntimeError, 'slather: error: no coverage data found')
    end

    it 'prints stdout produced before the failure and then the stderr text' do
      stub_popen3(["partial output\n", 'boom', false])
      old_out = $stdout
      $stdout = StringIO.new
      begin
        expect { runCommand('slather coverage') }.to raise_error(RuntimeError, 'boom')
        out = $stdout.string
      ensure
        $stdout = old_out
      end
      expect(out).to eq("@@[command] slather coverage\npartial output\nboom\n")
    end

    it 'still raises when isLogReturn = true and the command fails' do
      stub_popen3(["#{XCODE_DEV_DIR}\n", 'xcode-select: error', false])
      expect { capture_io { runCommand('xcode-select -p', true) } }
        .to raise_error(RuntimeError, 'xcode-select: error')
    end

    it 'raises RuntimeError with an empty message when a failing command has empty stderr' do
      stub_popen3(['', '', false])
      expect { capture_io { runCommand('false') } }.to raise_error(RuntimeError, '')
    end

    it 'propagates errors raised by Open3.popen3 (e.g. executable not found)' do
      allow(Open3).to receive(:popen3).and_raise(Errno::ENOENT, 'slather')
      expect { capture_io { runCommand('slather coverage') } }.to raise_error(Errno::ENOENT)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'step execution' do
  let(:tmpdir)   { Dir.mktmpdir('slather_step') }
  let(:env_file) { File.join(tmpdir, 'env_file') }
  let(:commands) { [] }
  let(:base_env) do
    {
      'AC_SCHEME'           => 'MyApp',
      'AC_REPOSITORY_DIR'   => '/repo',
      'AC_PROJECT_PATH'     => 'MyApp.xcodeproj',
      'AC_OUTPUT_DIR'       => '/ac/output',
      'AC_TEST_RESULT_PATH' => '/ac/test_results/test.xcresult',
      'AC_ENV_FILE_PATH'    => env_file
    }
  end
  let(:default_command) do
    'slather coverage -x --scheme MyApp --output-directory /ac/output/slather_output ' \
      '-b /ac/test_results --workspace /repo /repo/MyApp.xcodeproj'
  end

  after { FileUtils.rm_rf(tmpdir) }

  def without(env, *keys)
    env.reject { |k, _| keys.include?(k) }
  end

  context 'positive path – slather already installed' do
    before do
      stub_slather_installed(true)
      stub_popen3(['', '', true], recorder: commands)
    end

    it 'runs only the slather command with the default (cobertura) format and exits 0' do
      _out, err, error = run_step(base_env)
      expect(error).to be_a(SystemExit)
      expect(error.status).to eq(0)
      expect(err).to eq('')
      expect(commands).to eq([default_command])
    end

    it 'appends AC_SLATHER_OUTPUT_PATH to AC_ENV_FILE_PATH' do
      File.write(env_file, "EXISTING=1\n")
      run_step(base_env)
      expect(File.read(env_file)).to eq("EXISTING=1\nAC_SLATHER_OUTPUT_PATH=/ac/output/slather_output\n")
    end

    it 'prints the command log and the output path' do
      out, _err, _error = run_step(base_env)
      expect(out).to include("@@[command] #{default_command}")
      expect(out).to include('AC_SLATHER_OUTPUT_PATH : /ac/output/slather_output')
    end

    COVERAGE_FLAGS.each do |format, flag|
      it "maps AC_COVERAGE_FORMAT=#{format} to '#{flag}'" do
        run_step(base_env.merge('AC_COVERAGE_FORMAT' => format))
        expect(commands.last).to start_with("slather coverage #{flag} --scheme MyApp ")
      end
    end

    it 'falls back to cobertura when AC_COVERAGE_FORMAT is empty' do
      run_step(base_env.merge('AC_COVERAGE_FORMAT' => ''))
      expect(commands).to eq([default_command])
    end

    it 'strips "/test.xcresult" from AC_TEST_RESULT_PATH' do
      run_step(base_env.merge('AC_TEST_RESULT_PATH' => '/build/tests/test.xcresult'))
      expect(commands.last).to include(' -b /build/tests ')
    end

    it 'keeps AC_TEST_RESULT_PATH unchanged when it has no "/test.xcresult" segment' do
      run_step(base_env.merge('AC_TEST_RESULT_PATH' => '/build/tests/MyTests.xcresult'))
      expect(commands.last).to include(' -b /build/tests/MyTests.xcresult ')
    end

    it 'uses AC_SLATHER_OUTPUT_PATH when set, for the command and the env file' do
      run_step(base_env.merge('AC_SLATHER_OUTPUT_PATH' => '/custom/out'))
      expect(commands.last).to include(' --output-directory /custom/out ')
      expect(File.read(env_file)).to eq("AC_SLATHER_OUTPUT_PATH=/custom/out\n")
    end

    it 'joins AC_WORKSPACE_PATH onto AC_REPOSITORY_DIR' do
      run_step(base_env.merge('AC_WORKSPACE_PATH' => 'MyApp.xcworkspace'))
      expect(commands.last).to include(' --workspace /repo/MyApp.xcworkspace /repo/MyApp.xcodeproj')
    end

    it 'uses relative project and workspace paths when AC_REPOSITORY_DIR is missing' do
      run_step(without(base_env, 'AC_REPOSITORY_DIR').merge('AC_WORKSPACE_PATH' => 'MyApp.xcworkspace'))
      expect(commands.last).to end_with(' --workspace MyApp.xcworkspace MyApp.xcodeproj')
    end

    it 'keeps an absolute AC_PROJECT_PATH as-is' do
      run_step(base_env.merge('AC_PROJECT_PATH' => '/abs/MyApp.xcodeproj'))
      expect(commands.last).to end_with(' /abs/MyApp.xcodeproj')
    end

    it 'adds --configuration when AC_CONFIGURATION_NAME is set' do
      run_step(base_env.merge('AC_CONFIGURATION_NAME' => 'Debug'))
      expect(commands.last).to end_with(' --workspace /repo --configuration Debug /repo/MyApp.xcodeproj')
    end

    it 'appends AC_SLATHER_OPTIONS verbatim before the project path' do
      run_step(base_env.merge('AC_SLATHER_OPTIONS' => '--ignore "Pods/*" --verbose'))
      expect(commands.last).to end_with(' --workspace /repo --ignore "Pods/*" --verbose /repo/MyApp.xcodeproj')
    end

    it 'orders configuration before extra options' do
      run_step(base_env.merge('AC_CONFIGURATION_NAME' => 'Release', 'AC_SLATHER_OPTIONS' => '--verbose'))
      expect(commands.last).to end_with(' --configuration Release --verbose /repo/MyApp.xcodeproj')
    end

    it 'omits --configuration and extra options when they are empty' do
      run_step(base_env.merge('AC_CONFIGURATION_NAME' => '', 'AC_SLATHER_OPTIONS' => ''))
      expect(commands).to eq([default_command])
    end
  end

  context 'positive path – slather not installed' do
    before { stub_slather_installed(false) }

    it 'installs slather, restores the Xcode developer dir, then runs slather' do
      stub_popen3(["#{XCODE_DEV_DIR}\n", '', true], ['', '', true], recorder: commands)
      _out, _err, error = run_step(base_env)
      expect(error.status).to eq(0)
      expect(commands).to eq([
        'xcode-select -p',
        'sudo xcode-select -r',
        'sudo gem install slather --no-document --platform x86_64-darwin',
        "sudo xcode-select --switch \"#{XCODE_DEV_DIR}\"",
        default_command
      ])
      expect(File.read(env_file)).to eq("AC_SLATHER_OUTPUT_PATH=/ac/output/slather_output\n")
    end
  end

  context 'negative path – required variables' do
    before do
      stub_slather_installed(true)
      stub_popen3(['', '', true], recorder: commands)
    end

    {
      'AC_SCHEME'           => 'Missing scheme',
      'AC_PROJECT_PATH'     => 'Missing .xcodeproj path.',
      'AC_OUTPUT_DIR'       => 'Missing output path.',
      'AC_TEST_RESULT_PATH' => 'Missing test result path.'
    }.each do |key, message|
      it "aborts with \"#{message}\" when #{key} is missing, before running any command" do
        _out, err, error = run_step(without(base_env, key))
        expect(error.status).to eq(1)
        expect(err).to eq("#{message}\n")
        expect(commands).to be_empty
        expect(File.exist?(env_file)).to be(false)
      end

      it "aborts with \"#{message}\" when #{key} is empty" do
        _out, err, error = run_step(base_env.merge(key => ''))
        expect(error.status).to eq(1)
        expect(err).to eq("#{message}\n")
        expect(commands).to be_empty
      end
    end
  end

  context 'negative path – unknown coverage format' do
    before do
      stub_slather_installed(true)
      stub_popen3(['', '', true], recorder: commands)
    end

    it 'raises "Unknown coverage format!" and runs no command' do
      expect { run_step(base_env.merge('AC_COVERAGE_FORMAT' => 'xml')) }
        .to raise_error(RuntimeError, 'Unknown coverage format!')
      expect(commands).to be_empty
      expect(File.exist?(env_file)).to be(false)
    end

    it 'is case-sensitive ("Cobertura" is rejected)' do
      expect { run_step(base_env.merge('AC_COVERAGE_FORMAT' => 'Cobertura')) }
        .to raise_error(RuntimeError, 'Unknown coverage format!')
    end
  end

  context 'negative path – edge-case inputs (current behaviour pinned)' do
    before do
      stub_slather_installed(true)
      stub_popen3(['', '', true], recorder: commands)
    end

    it 'passes AC_REPOSITORY_DIR as --workspace when AC_WORKSPACE_PATH is missing' do
      run_step(base_env)
      expect(commands.last).to include(' --workspace /repo /repo/MyApp.xcodeproj')
    end

    it 'passes an empty --workspace when both AC_WORKSPACE_PATH and AC_REPOSITORY_DIR are missing' do
      run_step(without(base_env, 'AC_REPOSITORY_DIR'))
      expect(commands.last).to end_with(' --workspace  MyApp.xcodeproj')
    end

    it 'does not quote a scheme containing spaces' do
      run_step(base_env.merge('AC_SCHEME' => 'My App'))
      expect(commands.last).to include(' --scheme My App --output-directory ')
    end
  end

  context 'negative path – slather fails' do
    before do
      stub_slather_installed(true)
      stub_popen3(['', 'slather: error: no coverage data found', false], recorder: commands)
    end

    it 'raises with the slather error and does not write the env file' do
      expect { run_step(base_env) }.to raise_error(RuntimeError, 'slather: error: no coverage data found')
      expect(commands).to eq([default_command])
      expect(File.exist?(env_file)).to be(false)
    end
  end

  context 'negative path – slather installation fails' do
    before { stub_slather_installed(false) }

    it 'raises when "xcode-select -p" fails and stops before installing' do
      stub_popen3(['', 'xcode-select: error: unable to get active developer directory', false],
                  recorder: commands)
      expect { run_step(base_env) }
        .to raise_error(RuntimeError, 'xcode-select: error: unable to get active developer directory')
      expect(commands).to eq(['xcode-select -p'])
    end

    it 'raises when "gem install" fails and never runs slather' do
      stub_popen3(["#{XCODE_DEV_DIR}\n", '', true], ['', '', true], ['', 'ERROR: could not install gem', false],
                  recorder: commands)
      expect { run_step(base_env) }.to raise_error(RuntimeError, 'ERROR: could not install gem')
      expect(commands.last).to eq('sudo gem install slather --no-document --platform x86_64-darwin')
      expect(commands).not_to include(default_command)
      expect(File.exist?(env_file)).to be(false)
    end
  end

  context 'negative path – AC_ENV_FILE_PATH' do
    before do
      stub_slather_installed(true)
      stub_popen3(['', '', true], recorder: commands)
    end

    it 'raises TypeError when missing, after slather has already run' do
      expect { run_step(without(base_env, 'AC_ENV_FILE_PATH')) }
        .to raise_error(TypeError, /no implicit conversion of nil into String/)
      expect(commands).to eq([default_command])
    end

    it 'raises Errno::ENOENT when empty' do
      expect { run_step(base_env.merge('AC_ENV_FILE_PATH' => '')) }.to raise_error(Errno::ENOENT)
    end

    it 'raises Errno::ENOENT when its directory does not exist' do
      missing = File.join(tmpdir, 'missing_dir', 'env_file')
      expect { run_step(base_env.merge('AC_ENV_FILE_PATH' => missing)) }.to raise_error(Errno::ENOENT)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'ENV validation (subprocess)' do
  let(:tmpdir)    { Dir.mktmpdir('slather_env') }
  let(:bin_dir)   { write_fake_tools(File.join(tmpdir, 'bin')) }
  let(:tool_log)  { File.join(tmpdir, 'tool.log') }
  let(:env_file)  { File.join(tmpdir, 'env_file') }
  let(:repo_dir)  { File.join(tmpdir, 'repo') }
  let(:out_dir)   { File.join(tmpdir, 'output') }
  let(:result_dir) { File.join(tmpdir, 'test_results') }
  let(:base_env) do
    {
      'PATH'                => "#{bin_dir}#{File::PATH_SEPARATOR}#{ENV['PATH']}",
      'FAKE_TOOL_LOG'       => tool_log,
      'AC_SCHEME'           => 'MyApp',
      'AC_REPOSITORY_DIR'   => repo_dir,
      'AC_PROJECT_PATH'     => 'MyApp.xcodeproj',
      'AC_OUTPUT_DIR'       => out_dir,
      'AC_TEST_RESULT_PATH' => File.join(result_dir, 'test.xcresult')
    }
  end
  let(:slather_call) do
    "slather coverage -x --scheme MyApp --output-directory #{out_dir}/slather_output " \
      "-b #{result_dir} --workspace #{repo_dir} #{repo_dir}/MyApp.xcodeproj"
  end

  after { FileUtils.rm_rf(tmpdir) }

  def tool_calls
    File.exist?(tool_log) ? File.read(tool_log).lines.map(&:chomp) : []
  end

  shared_examples 'aborts with message' do |env_override, expected_pattern|
    it "exits non-zero and stderr matches /#{expected_pattern.source}/" do
      env = instance_exec(&env_override)
      _out, err, status = run_main(env)
      expect(status.exitstatus).not_to eq(0)
      expect(err).to match(expected_pattern)
    end
  end

  {
    'AC_SCHEME'           => /Missing scheme/,
    'AC_PROJECT_PATH'     => /Missing \.xcodeproj path\./,
    'AC_OUTPUT_DIR'       => /Missing output path\./,
    'AC_TEST_RESULT_PATH' => /Missing test result path\./
  }.each do |key, pattern|
    context "required variable: #{key}" do
      context 'when missing' do
        include_examples 'aborts with message',
                         -> { base_env.reject { |k, _| k == key }.merge('AC_ENV_FILE_PATH' => env_file) },
                         pattern
      end

      context 'when an empty string' do
        include_examples 'aborts with message',
                         -> { base_env.merge(key => '', 'AC_ENV_FILE_PATH' => env_file) },
                         pattern
      end

      it 'runs no tool and writes no env file when missing' do
        run_main(base_env.reject { |k, _| k == key }.merge('AC_ENV_FILE_PATH' => env_file))
        expect(tool_calls).to be_empty
        expect(File.exist?(env_file)).to be(false)
      end
    end
  end

  context 'required variable: AC_ENV_FILE_PATH' do
    context 'when missing' do
      include_examples 'aborts with message', -> { base_env }, /no implicit conversion of nil into String/
    end

    context 'when an empty string' do
      include_examples 'aborts with message', -> { base_env.merge('AC_ENV_FILE_PATH' => '') },
                       /No such file or directory/
    end
  end

  context 'invalid AC_COVERAGE_FORMAT' do
    include_examples 'aborts with message',
                     -> { base_env.merge('AC_COVERAGE_FORMAT' => 'pdf', 'AC_ENV_FILE_PATH' => env_file) },
                     /Unknown coverage format!/
  end

  context 'toolchain failures' do
    it 'exits non-zero with the slather error and does not write the env file' do
      _out, err, status = run_main(base_env.merge('AC_ENV_FILE_PATH' => env_file, 'FAKE_SLATHER_FAIL' => '1'))
      expect(status.exitstatus).not_to eq(0)
      expect(err).to include('slather: error: no coverage data found')
      expect(File.exist?(env_file)).to be(false)
    end

    it 'exits non-zero when installing slather fails and never runs slather' do
      _out, err, status = run_main(base_env.merge('AC_ENV_FILE_PATH' => env_file,
                                                  'FAKE_SLATHER_MISSING' => '1', 'FAKE_SUDO_FAIL' => '1'))
      expect(status.exitstatus).not_to eq(0)
      expect(err).to include('ERROR: could not install gem')
      expect(tool_calls).to eq(['xcode-select -p', 'sudo xcode-select -r'])
      expect(File.exist?(env_file)).to be(false)
    end
  end

  context 'all required variables set' do
    it 'runs slather, writes AC_SLATHER_OUTPUT_PATH and exits 0' do
      out, err, status = run_main(base_env.merge('AC_ENV_FILE_PATH' => env_file))
      expect(err).to eq('')
      expect(status.exitstatus).to eq(0)
      expect(tool_calls).to eq([slather_call])
      expect(out).to include("@@[command] #{slather_call}")
      expect(out).to include('Slathering...')
      expect(File.read(env_file)).to eq("AC_SLATHER_OUTPUT_PATH=#{out_dir}/slather_output\n")
    end

    it 'installs slather first when it is not on PATH' do
      _out, err, status = run_main(base_env.merge('AC_ENV_FILE_PATH' => env_file, 'FAKE_SLATHER_MISSING' => '1'))
      expect(err).to eq('')
      expect(status.exitstatus).to eq(0)
      expect(tool_calls).to eq([
        'xcode-select -p',
        'sudo xcode-select -r',
        'sudo gem install slather --no-document --platform x86_64-darwin',
        "sudo xcode-select --switch #{XCODE_DEV_DIR}",
        slather_call
      ])
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'loading main.rb' do
  it 'does not execute the step when required from another script' do
    out, err, status = Open3.capture3(STEP_ENV_KEYS.to_h { |k| [k, nil] },
                                      "ruby -e 'require %q(#{MAIN_RB}); puts :loaded'")
    expect(status.exitstatus).to eq(0)
    expect(err).to eq('')
    expect(out.strip).to eq('loaded')
  end

  it 'defines get_env_variable and runCommand' do
    expect(respond_to?(:get_env_variable, true)).to be(true)
    expect(respond_to?(:runCommand, true)).to be(true)
  end
end

# ─── Coverage Report ──────────────────────────────────────────────────────────
def print_coverage_report
  return unless defined?(Coverage) && Coverage.running?

  result = begin
    Coverage.result(stop: false, clear: false)
  rescue ArgumentError
    Coverage.result
  end

  main_path = result.keys.find { |p| p&.end_with?('main.rb') }
  return puts("\nCoverage: main.rb not found in results") unless main_path

  data      = COVERAGE_SNAPSHOTS.reduce(result[main_path]) do |acc, snap|
    acc.zip(snap).map { |a, b| a.nil? ? nil : a + b.to_i }
  end
  lines     = data.each_with_index.reject { |c, _| c.nil? }
  total     = lines.size
  covered   = lines.count { |c, _| c.to_i > 0 }
  pct       = total.positive? ? (covered * 100.0 / total).round(1) : 100.0
  uncovered = lines.select { |c, _| c.to_i == 0 }.map { |_, i| i + 1 }

  color = pct == 100 ? "\e[32;1m" : pct >= 80 ? "\e[33m" : "\e[31m"
  bar_filled = (pct / 5).round
  bar = "\e[32m" + '█' * bar_filled + "\e[90m" + '░' * (20 - bar_filled) + "\e[0m"

  puts "\n\e[90m#{'═' * 72}\e[0m"
  puts '  Coverage Report'
  puts "\e[90m#{'─' * 72}\e[0m"
  puts "  main.rb  #{bar}  #{color}#{pct}%\e[0m  (#{covered}/#{total} lines)"
  if uncovered.any? && uncovered.size <= 20
    puts "  Uncovered lines: \e[90m#{uncovered.join(', ')}\e[0m"
  elsif uncovered.any?
    puts "  Uncovered lines: \e[90m#{uncovered.first(15).join(', ')} … (+#{uncovered.size - 15} more)\e[0m"
  end
  puts "\e[90m#{'═' * 72}\e[0m"
end

# ─── Runner ───────────────────────────────────────────────────────────────────
if __FILE__ == $PROGRAM_NAME
  RSpec.configure do |config|
    config.add_formatter ReadableFormatter
    config.color        = true
    config.order        = :defined
  end

  exit_code = RSpec::Core::Runner.run(['--order', 'defined'])
  print_coverage_report
  exit exit_code
end
