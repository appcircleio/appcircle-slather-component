require 'open3'
require 'pathname'

def get_env_variable(key)
	return (ENV[key] == nil || ENV[key] == "") ? nil : ENV[key]
end

def runCommand(command, isLogReturn = false)
    puts "@@[command] #{command}"
    status = nil
    stderr_str = nil
    stdout_all_lines = ""
    Open3.popen3(command) do |stdin, stdout, stderr, wait_thr|
        stdout.each_line do |line|
            if isLogReturn
                stdout_all_lines += line
            end
            puts line
        end
        stderr_str = stderr.read
        status = wait_thr.value
    end

    unless status.success?
        puts stderr_str
        raise stderr_str
    end
    return stdout_all_lines
end

scheme = get_env_variable("AC_SCHEME") || abort('Missing scheme')
repository_path = get_env_variable("AC_REPOSITORY_DIR")
project_path = get_env_variable("AC_PROJECT_PATH") || abort('Missing .xcodeproj path.')
workspace_path = get_env_variable("AC_WORKSPACE_PATH") || ""
coverage_format = get_env_variable("AC_COVERAGE_FORMAT") || "cobertura"
extra_options = get_env_variable("AC_SLATHER_OPTIONS")
config_option = get_env_variable("AC_CONFIGURATION_NAME")
ac_output_path = get_env_variable("AC_OUTPUT_DIR") || abort('Missing output path.')
test_result_path = get_env_variable("AC_TEST_RESULT_PATH") || abort('Missing test result path.')
if test_result_path.include?("/test.xcresult")
    test_result_path = test_result_path.gsub("/test.xcresult", "")
end
slather_output_path = get_env_variable("AC_SLATHER_OUTPUT_PATH") || (Pathname.new ac_output_path).join("slather_output")
xcodeproj_path = repository_path ?  (Pathname.new repository_path).join(project_path) : project_path

# --simple-output, -s                      Output coverage results to the terminal
# --gutter-json, -g                        Output coverage results as Gutter JSON format
# --cobertura-xml, -x                      Output coverage results as Cobertura XML format
# --sonarqube-xml, -sq                     Output coverage results as SonarQube XML format
# --llvm-cov, -r                           Output coverage as llvm-cov format
# --json                                   Output coverage results as simple JSON
# --html                                   Output coverage results as static html pages

available_formats = {
    "cobertura" => "-x",
    "sonarqube" => "-sq",
    "gutter-json" => "-g",
    "llvm-cov" => "-r",
    "json" => "--json",
    "html" => "--html",
    "simple" => "-s"
}

if !available_formats.has_key?(coverage_format)
    raise "Unknown coverage format!"
end

format_commandline = available_formats[coverage_format]

commandline = "slather coverage #{format_commandline} --scheme #{scheme} --output-directory #{slather_output_path} -b #{test_result_path}"
if workspace_path
    xcodeworkspace_path = repository_path ? (Pathname.new repository_path).join(workspace_path) : workspace_path
    commandline += " --workspace #{xcodeworkspace_path}"
end

if config_option
    commandline += " --configuration #{config_option}"
end
if extra_options
    commandline += " #{extra_options}"
end

commandline += " #{xcodeproj_path}"
if `which slather`.empty?
    # Install slather on macOS
    xcode_developer_dir_path = runCommand('xcode-select -p',true).strip
    runCommand("sudo xcode-select -r")
    runCommand("sudo gem install slather --no-document --platform x86_64-darwin")
    # Setting back the xcode version.
    runCommand("sudo xcode-select --switch \"#{xcode_developer_dir_path}\"")
end

runCommand(commandline)

puts "AC_SLATHER_OUTPUT_PATH : #{slather_output_path}"

#Write Environment Variable
open(ENV['AC_ENV_FILE_PATH'], 'a') { |f|
    f.puts "AC_SLATHER_OUTPUT_PATH=#{slather_output_path}"
}

exit 0
