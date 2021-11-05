# Appcircle Slather

Convert Xcode's test results to different formats by using [Slather](https://github.com/SlatherOrg/slather)

Required Input Variables
- `$AC_SCHEME`: Specifies the project scheme for build
- `$AC_PROJECT_PATH`  Specifies the project path. For example : ./appcircle.xcodeproj

Optional Input Variables
- `$AC_WORKSPACE_PATH`: Specifies the project path. For example : ./appcircle.xcworkspace
- `$AC_COVERAGE_FORMAT`: Coverage report format(cobertura,sonarqube,gutter-json,llvm-cov,json,html,simple)
- `$AC_CONFIGURATION_NAME`: Xcode configuration name
- `$AC_SLATHER_OPTIONS`: Extra options for Slather

Output Variable
- `$AC_SLATHER_OUTPUT_PATH`: Report output file path.
