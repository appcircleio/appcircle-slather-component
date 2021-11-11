require 'open3'
require 'pathname'

# require 'dotenv'

# Debug
#Dotenv.load

def get_env_variable(key)
	return (ENV[key] == nil || ENV[key] == "") ? nil : ENV[key]
end

def runCommand(command)
    puts "@@[command] #{command}"
    status = nil
    stdout_str = nil
    stderr_str = nil

    Open3.popen3(command) do |stdin, stdout, stderr, wait_thr|
        stdout.each_line do |line|
            puts line
        end
        stdout_str = stdout.read
        stderr_str = stderr.read
        status = wait_thr.value
    end

    unless status.success?
        puts stderr_str
        raise stderr_str
    end
end

scheme = get_env_variable("AC_SCHEME") || abort('Missing scheme')
project_path = get_env_variable("AC_PROJECT_PATH") || abort('Missing .xcodeproj path.')
workspace_path = get_env_variable("AC_WORKSPACE_PATH") || ""
coverage_format = get_env_variable("AC_COVERAGE_FORMAT") || "cobertura"
extra_options = get_env_variable("AC_SLATHER_OPTIONS") || ""
config_option = get_env_variable("AC_CONFIGURATION_NAME") || ""
temporary_path = get_env_variable("AC_TEMP_DIR") || abort('Missing temporary path.')
out_path = get_env_variable("AC_SLATHER_OUTPUT_PATH") || (Pathname.new temporary_path).join("slather_out")

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

# Install slather on macOS
runCommand("sudo gem install slather")
runCommand("slather version")

format_commandline = available_formats[coverage_format]

commandline = "slather coverage #{format_commandline} --scheme #{scheme} --output-directory #{out_path}"
if workspace_path
    commandline += " --workspace #{workspace_path}"
end

if extra_options
    commandline += " #{extra_options}"
end

commandline += " #{project_path}"
runCommand(commandline)

puts "AC_SLATHER_OUTPUT_PATH : #{out_path}"

#Write Environment Variable
open(ENV['AC_ENV_FILE_PATH'], 'a') { |f|
    f.puts "AC_SLATHER_OUTPUT_PATH=#{out_path}"
}
exit 0
