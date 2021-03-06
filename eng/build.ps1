#
# This script controls the Roslyn build process. This encompasess everything from build, testing to
# publishing of NuGet packages. The intent is to structure it to allow for a simple flow of logic
# between the following phases:
#
#   - restore
#   - build
#   - sign
#   - pack
#   - test
#   - publish
#
# Each of these phases has a separate command which can be executed independently. For instance
# it's fine to call `build.ps1 -build -testDesktop` followed by repeated calls to
# `.\build.ps1 -testDesktop`.

[CmdletBinding(PositionalBinding=$false)]
param (
    [string][Alias('c')]$configuration = "Debug",
    [string][Alias('v')]$verbosity = "m",
    [string]$msbuildEngine = "vs",

    # Actions
    [switch][Alias('r')]$restore,
    [switch][Alias('b')]$build,
    [switch]$rebuild,
    [switch]$sign,
    [switch]$pack,
    [switch]$publish,
    [switch]$launch,
    [switch]$help,

    # Options
    [switch]$bootstrap,
    [string]$bootstrapConfiguration = "Release",
    [switch][Alias('bl')]$binaryLog,
    [switch]$ci,
    [switch]$procdump,
    [switch]$skipAnalyzers,
    [switch][Alias('d')]$deployExtensions,
    [switch]$prepareMachine,
    [switch]$useGlobalNuGetCache = $true,
    [switch]$warnAsError = $false,

    # official build settings
    [string]$officialBuildId = "",
    [string]$vsDropName = "",
    [string]$vsBranch = "",
    [string]$vsDropAccessToken = "",

    # Test actions
    [switch]$test32,
    [switch]$test64,
    [switch]$testVsi,
    [switch][Alias('test')]$testDesktop,
    [switch]$testCoreClr,
    [switch]$testIOperation,

    [parameter(ValueFromRemainingArguments=$true)][string[]]$properties)

Set-StrictMode -version 2.0
$ErrorActionPreference = "Stop"

function Print-Usage() {
    Write-Host "Common settings:"
    Write-Host "  -configuration <value>    Build configuration: 'Debug' or 'Release' (short: -c)"
    Write-Host "  -verbosity <value>        Msbuild verbosity: q[uiet], m[inimal], n[ormal], d[etailed], and diag[nostic]"
    Write-Host "  -deployExtensions         Deploy built vsixes (short: -d)"
    Write-Host "  -binaryLog                Create MSBuild binary log (short: -bl)"
    Write-Host ""
    Write-Host "Actions:"
    Write-Host "  -restore                  Restore packages (short: -r)"
    Write-Host "  -build                    Build main solution (short: -b)"
    Write-Host "  -rebuild                  Rebuild main solution"
    Write-Host "  -pack                     Build NuGet packages, VS insertion manifests and installer"
    Write-Host "  -sign                     Sign our binaries"
    Write-Host "  -publish                  Publish build artifacts (e.g. symbols)"
    Write-Host "  -launch                   Launch Visual Studio in developer hive"
    Write-Host "  -help                     Print help and exit"
    Write-Host ""
    Write-Host "Test actions"
    Write-Host "  -test32                   Run unit tests in the 32-bit runner"
    Write-Host "  -test64                   Run units tests in the 64-bit runner"
    Write-Host "  -testDesktop              Run Desktop unit tests (short: -test)"
    Write-Host "  -testCoreClr              Run CoreClr unit tests"
    Write-Host "  -testVsi                  Run all integration tests"
    Write-Host "  -testIOperation           Run extra checks to validate IOperations"
    Write-Host ""
    Write-Host "Advanced settings:"
    Write-Host "  -ci                       Set when running on CI server"
    Write-Host "  -bootstrap                Build using a bootstrap compilers"
    Write-Host "  -bootstrapConfiguration   Build configuration for bootstrap compiler: 'Debug' or 'Release'"
    Write-Host "  -msbuildEngine <value>    Msbuild engine to use to run build ('dotnet', 'vs', or unspecified)."
    Write-Host "  -procdump                 Monitor test runs with procdump"
    Write-Host "  -skipAnalyzers            Do not run analyzers during build operations"
    Write-Host "  -prepareMachine           Prepare machine for CI run, clean up processes after build"
    Write-Host "  -useGlobalNuGetCache      Use global NuGet cache."
    Write-Host "  -warnAsError              Treat all warnings as errors"
    Write-Host ""    
    Write-Host "Official build settings:"
    Write-Host "  -officialBuildId          An official build id, e.g. 20190102.3"
    Write-Host "  -vsDropName               Visual Studio product drop name"
    Write-Host "  -vsBranch                 Visual Studio insertion branch"
    Write-Host "  -vsDropAccessToken        Visual Studio drop access token"
    Write-Host ""
    Write-Host "Command line arguments starting with '/p:' are passed through to MSBuild."
}

# Process the command line arguments and establish defaults for the values which are not
# specified.
#
# In this function it's okay to use two arguments to extend the effect of another. For
# example it's okay to look at $testVsi and infer $skipAnalyzers. It's not okay though to infer
# $build based on say $testDesktop. It's possible the developer wanted only for testing
# to execute, not any build.
function Process-Arguments() {
    if ($help -or (($properties -ne $null) -and ($properties.Contains("/help") -or $properties.Contains("/?")))) {
       Print-Usage
       exit 0
    }
    
    if (!$vsBranch) {
        if ($officialBuildId) {
            Write-Host "vsBranch must be specified for official builds"
            exit 1
        }

        $script:vsBranch = "dummy/ci"
    }

    if (!$vsDropName) {
        if ($officialBuildId) {
            Write-Host "vsDropName must be specified for official builds"
            exit 1
        }

        $script:vsDropName = "Products/DummyDrop"
    }

    if (!$vsDropAccessToken -and $officialBuildId) {
        Write-Host "vsDropAccessToken must be specified for official builds"
        exit 1
    }
    
    if ($test32 -and $test64) {
        Write-Host "Cannot combine -test32 and -test64"
        exit 1
    }

    $anyUnit = $testDesktop -or $testCoreClr
    if ($anyUnit -and $testVsi) {
        Write-Host "Cannot combine unit and VSI testing"
        exit 1
    }

    if ($testVsi) {
        # Avoid spending time in analyzers when requested, and also in the slowest integration test builds
        $script:skipAnalyzers = $true
        $script:bootstrap = $false
    }

    if ($build -and $launch -and -not $deployExtensions) {
        Write-Host -ForegroundColor Red "Cannot combine -build and -launch without -deployExtensions"
        exit 1
    }

    $script:test32 = -not $test64

    foreach ($property in $properties) {
        if (!$property.StartsWith("/p:", "InvariantCultureIgnoreCase")) {
            Write-Host "Invalid argument: $property"
            Print-Usage
            exit 1
        }
    }
}

function BuildSolution() {
    # Roslyn.sln can't be built with dotnet due to WPF and VSIX build task dependencies
    $solution = if ($msbuildEngine -eq 'dotnet') { "Compilers.sln" } else { "Roslyn.sln" }
    
    Write-Host "$($solution):"

    $bl = if ($binaryLog) { "/bl:" + (Join-Path $LogDir "Build.binlog") } else { "" }
    $projects = Join-Path $RepoRoot $solution
    $enableAnalyzers = !$skipAnalyzers
    $toolsetBuildProj = InitializeToolset
    $quietRestore = !$ci
    $testTargetFrameworks = if ($testCoreClr) { "netcoreapp2.1" } else { "" }
    
    # Do not set the property to true explicitly, since that would override value projects might set.
    $suppressExtensionDeployment = if (!$deployExtensions) { "/p:DeployExtension=false" } else { "" } 

    $optDataDir = if ($applyOptimizationData) { $IbcOptimizationDataDir } else { "" }

    # Setting /p:TreatWarningsAsErrors=true is a workaround for https://github.com/Microsoft/msbuild/issues/3062.
    # We don't pass /warnaserror to msbuild ($warnAsError is set to $false by default above), but set 
    # /p:TreatWarningsAsErrors=true so that compiler reported warnings, other than IDE0055 are treated as errors. 
    # Warnings reported from other msbuild tasks are not treated as errors for now.
    MSBuild $toolsetBuildProj `
        $bl `
        /p:Configuration=$configuration `
        /p:Projects=$projects `
        /p:RepoRoot=$RepoRoot `
        /p:Restore=$restore `
        /p:Build=$build `
        /p:Test=$testCoreClr `
        /p:Rebuild=$rebuild `
        /p:Pack=$pack `
        /p:Sign=$sign `
        /p:Publish=$publish `
        /p:ContinuousIntegrationBuild=$ci `
        /p:OfficialBuildId=$officialBuildId `
        /p:UseRoslynAnalyzers=$enableAnalyzers `
        /p:BootstrapBuildPath=$bootstrapDir `
        /p:QuietRestore=$quietRestore `
        /p:QuietRestoreBinaryLog=$binaryLog `
        /p:TestTargetFrameworks=$testTargetFrameworks `
        /p:VisualStudioDropName=$vsDropName `
        /p:TreatWarningsAsErrors=true `
        /p:IbcOptimizationDataDir=$optDataDir `
        $suppressExtensionDeployment `
        @properties
}

function Restore-OptProfData() {
    $dropToolDir = Get-PackageDir "Drop.App"
    $dropToolPath = Join-Path $dropToolDir "lib\net45\drop.exe"

    if (!(Test-Path $dropToolPath)) {

        # Only report error when running in an official build.
        # Allows to test optimization data operations locally by running 
        # cibuild.cmd after manually restoring internal tools project.
        if (!$officialBuildId) {
            $script:applyOptimizationData = $false
            return
        }

        Write-Host "Internal tool not found: '$dropToolPath'." -ForegroundColor Red 
        Write-Host "Run nuget restore `"$EngRoot\internal\Toolset.csproj`"." -ForegroundColor DarkGray 
        ExitWithExitCode 1
    }
    
    function find-latest-drop($drops) {
         $result = $null
         [DateTime]$latest = [DateTime]::New(0)
         foreach ($drop in $drops) {
             $dt = [DateTime]::Parse($drop.CreatedDateUtc)
             if ($result -eq $null -or ($drop.UploadComplete -and !$drop.DeletePending -and ($dt -gt $latest))) {
                 $result = $drop
                 $latest = $dt
             }
         }

         return $result
    }
   
    Write-Host "Acquiring optimization data"

    Create-Directory $IbcOptimizationDataDir

    $dropServiceUrl = "https://devdiv.artifacts.visualstudio.com"
    $dropNamePrefix = "OptimizationData/dotnet/roslyn/master-vs-deps"
    $patAuth = if ($officialBuildId) { "--patAuth `"$vsDropAccessToken`"" } else { "" }

    $dropsJsonPath = Join-Path $IbcOptimizationDataDir "AvailableDrops.json"
    $logFile = Join-Path $LogDir "OptimizationDataAcquisition.log"

    Exec-Console $dropToolPath "list --dropservice `"$dropServiceUrl`" $patAuth --pathPrefixFilter `"$dropNamePrefix`" --toJsonFile `"$dropsJsonPath`" --traceto `"$logFile`""
    $dropsJson = Get-Content -Raw -Path $dropsJsonPath | ConvertFrom-Json
    $latestDrop = find-latest-drop($dropsJson)
    
    if ($latestDrop -eq $null) {
        Write-Host "No drop matching given name found: $dropServiceUrl/$dropNamePrefix/*" -ForegroundColor Red 
        ExitWithExitCode 1
    }

    Write-Host "Downloading optimization data from drop $dropServiceUrl/$($latestDrop.Name)"
    Exec-Console $dropToolPath "get --dropservice `"$dropServiceUrl`" $patAuth --name `"$($latestDrop.Name)`" --dest `"$IbcOptimizationDataDir`" --traceto `"$logFile`""
}

function Build-OptProfData() {
    $insertionDir = Join-Path $VSSetupDir "Insertion"
    $optProfDir = Join-Path $ArtifactsDir "OptProf\$configuration"
    $optProfDataDir = Join-Path $optProfDir "Data"
    $optProfBranchDir = Join-Path $optProfDir "BranchInfo"

    $optProfConfigFile = Join-Path $EngRoot "config\OptProf.json"
    $optProfToolDir = Get-PackageDir "RoslynTools.OptProf"
    $optProfToolExe = Join-Path $optProfToolDir "tools\roslyn.optprof.exe"

    Write-Host "Generating optimization data using '$optProfConfigFile' into '$optProfDataDir'"
    Exec-Console $optProfToolExe "--configFile $optProfConfigFile --insertionFolder $insertionDir --outputFolder $optProfDataDir"

    # Write out branch we are inserting into
    Create-Directory $optProfBranchDir
    $vsBranchFile = Join-Path $optProfBranchDir "vsbranch.txt"
    $vsBranch >> $vsBranchFile

    # Set VSO variables used by MicroBuildBuildVSBootstrapper pipeline task
    $manifestList = [string]::Join(',', (Get-ChildItem "$insertionDir\*.vsman"))

    Write-Host "##vso[task.setvariable variable=VisualStudio.SetupManifestList;]$manifestList"
}

# Core function for running our unit / integration tests tests
function TestUsingOptimizedRunner() {

    # Tests need to locate .NET Core SDK
    $dotnet = InitializeDotNetCli

    if ($testVsi) {
        Deploy-VsixViaTool

        if ($ci) {
            # Minimize all windows to avoid interference during integration test runs
            $shell = New-Object -ComObject "Shell.Application"
            $shell.MinimizeAll()
        }
    }

    if ($testIOperation) {
        $env:ROSLYN_TEST_IOPERATION = "true"
    }

    $testResultsDir = Join-Path $ArtifactsDir "TestResults\$configuration"
    $binDir = Join-Path $ArtifactsDir "bin" 
    $runTests = GetProjectOutputBinary "RunTests.exe"

    if (!(Test-Path $runTests)) {
        Write-Host "Test runner not found: '$runTests'. Run Build.cmd first." -ForegroundColor Red 
        ExitWithExitCode 1
    }

    $xunitDir = Join-Path (Get-PackageDir "xunit.runner.console") "tools\net472"
    $args = "`"$xunitDir`""
    $args += " `"-out:$testResultsDir`""
    $args += " -nocache"
    $args += " -tfm:net472"

    if ($testDesktop -or $testIOperation) {
        if ($test32) {
            $dlls = Get-ChildItem -Recurse -Include "*.UnitTests.dll" $binDir
        } else {
            $dlls = Get-ChildItem -Recurse -Include "*.UnitTests.dll" -Exclude "*InteractiveHost*" $binDir
        }
    } elseif ($testVsi) {
        # Since they require Visual Studio to be installed, ensure that the MSBuildWorkspace tests run along with our VS
        # integration tests in CI.
        if ($ci) {
            $dlls += @(Get-Item (GetProjectOutputBinary "Microsoft.CodeAnalysis.Workspaces.MSBuild.UnitTests.dll"))
        }

        $dlls += @(Get-ChildItem -Recurse -Include "*.IntegrationTests.dll" $binDir)
    } else {
        $dlls = Get-ChildItem -Recurse -Include "*.IntegrationTests.dll" $binDir
        $args += " -trait:Feature=NetCore"
    }

    # Exclude out the multi-targetted netcore app projects
    $dlls = $dlls | ?{ -not ($_.FullName -match ".*netcoreapp.*") }

    # Exclude out the ref assemblies
    $dlls = $dlls | ?{ -not ($_.FullName -match ".*\\ref\\.*") }
    $dlls = $dlls | ?{ -not ($_.FullName -match ".*/ref/.*") }

    if ($ci) {
        $args += " -xml"
        if ($testVsi) {
            $args += " -timeout:120"
        } else {
            $args += " -timeout:65"
        }
    }

    $procdumpPath = Ensure-ProcDump
    $args += " -procdumppath:$procDumpPath"
    if ($procdump) {
        $args += " -useprocdump";
    }

    if ($test64) {
        $args += " -test64"
    }

    foreach ($dll in $dlls) {
        $args += " $dll"
    }

    try {
        Exec-Console $runTests $args
    } finally {
        Get-Process "xunit*" -ErrorAction SilentlyContinue | Stop-Process
        if ($testIOperation) {
            Remove-Item env:\ROSLYN_TEST_IOPERATION
        }
    }
}

# Deploy our core VSIX libraries to Visual Studio via the Roslyn VSIX tool.  This is an alternative to
# deploying at build time.
function Deploy-VsixViaTool() { 
    $vsixDir = Get-PackageDir "RoslynTools.VSIXExpInstaller"
    $vsixExe = Join-Path $vsixDir "tools\VsixExpInstaller.exe"
    
    $vsInfo = LocateVisualStudio
    if ($vsInfo -eq $null) {
        throw "Unable to locate required Visual Studio installation"
    }

    $vsDir = $vsInfo.installationPath.TrimEnd("\")
    $vsId = $vsInfo.instanceId
    $vsMajorVersion = $vsInfo.installationVersion.Split('.')[0]

    $hive = "RoslynDev"
    Write-Host "Using VS Instance $vsId at `"$vsDir`""
    $baseArgs = "/rootSuffix:$hive /vsInstallDir:`"$vsDir`""

    Write-Host "Uninstalling old Roslyn VSIX"

    # Actual uninstall is failing at the moment using the uninstall options. Temporarily using
    # wildfire to uninstall our VSIX extensions
    $extDir = Join-Path ${env:USERPROFILE} "AppData\Local\Microsoft\VisualStudio\$vsMajorVersion.0_$vsid$hive"
    if (Test-Path $extDir) {
        foreach ($dir in Get-ChildItem -Directory $extDir) {
            $name = Split-Path -leaf $dir
            Write-Host "`tUninstalling $name"
        }
        Remove-Item -re -fo $extDir
    }

    Write-Host "Installing all Roslyn VSIX"

    # VSIX files need to be installed in this specific order:
    $orderedVsixFileNames = @(	
        "Roslyn.Compilers.Extension.vsix",
        "Roslyn.VisualStudio.Setup.vsix",
        "Roslyn.VisualStudio.Setup.Dependencies.vsix",
        "Roslyn.VisualStudio.InteractiveComponents.vsix",
        "ExpressionEvaluatorPackage.vsix",
        "Roslyn.VisualStudio.DiagnosticsWindow.vsix",
        "Microsoft.VisualStudio.IntegrationTest.Setup.vsix")

    foreach ($vsixFileName in $orderedVsixFileNames) {
        $vsixFile = Join-Path $VSSetupDir $vsixFileName
        $fullArg = "$baseArgs $vsixFile"
        Write-Host "`tInstalling $vsixFileName"
        Exec-Console $vsixExe $fullArg
    }
}

# Ensure that procdump is available on the machine.  Returns the path to the directory that contains
# the procdump binaries (both 32 and 64 bit)
function Ensure-ProcDump() {

    # Jenkins images default to having procdump installed in the root.  Use that if available to avoid
    # an unnecessary download.
    if (Test-Path "C:\SysInternals\procdump.exe") {
        return "C:\SysInternals"
    }

    $outDir = Join-Path $ToolsDir "ProcDump"
    $filePath = Join-Path $outDir "procdump.exe"
    if (-not (Test-Path $filePath)) {
        Remove-Item -Re $filePath -ErrorAction SilentlyContinue
        Create-Directory $outDir
        $zipFilePath = Join-Path $toolsDir "procdump.zip"
        Invoke-WebRequest "https://download.sysinternals.com/files/Procdump.zip" -UseBasicParsing -outfile $zipFilePath | Out-Null
        Unzip $zipFilePath $outDir
    }

    return $outDir
}

function Prepare-TempDir() {
    Copy-Item (Join-Path $RepoRoot "src\Workspaces\CoreTestUtilities\Resources\.editorconfig") $TempDir
    Copy-Item (Join-Path $RepoRoot "src\Workspaces\CoreTestUtilities\Resources\Directory.Build.props") $TempDir
    Copy-Item (Join-Path $RepoRoot "src\Workspaces\CoreTestUtilities\Resources\Directory.Build.targets") $TempDir
    Copy-Item (Join-Path $RepoRoot "src\Workspaces\CoreTestUtilities\Resources\Directory.Build.rsp") $TempDir
    Copy-Item (Join-Path $RepoRoot "src\Workspaces\CoreTestUtilities\Resources\NuGet.Config") $TempDir
}

function List-Processes() {
    Write-Host "Listing running build processes..."
    Get-Process -Name "msbuild" -ErrorAction SilentlyContinue | Out-Host
    Get-Process -Name "vbcscompiler" -ErrorAction SilentlyContinue | Out-Host
    Get-Process -Name "dotnet" -ErrorAction SilentlyContinue | where { $_.Modules | select { $_.ModuleName -eq "VBCSCompiler.dll" } } | Out-Host
    Get-Process -Name "devenv" -ErrorAction SilentlyContinue | Out-Host
}

try {
    Process-Arguments

    . (Join-Path $PSScriptRoot "build-utils.ps1")

    # IBC merge is only invoked in official build, but we want to enable running IBCMerge locally as well.
    $applyOptimizationData = $ci -and $configuration -eq "Release" -and $msbuildEngine -eq "vs"

    if ($testVsi) {
        $processesToStopOnExit += "devenv"
    }

    Push-Location $RepoRoot

    if ($ci) {
        List-Processes
        Prepare-TempDir
    }

    if ($applyOptimizationData -and $restore) {
        Restore-OptProfData
    }

    if ($bootstrap) {
        $bootstrapDir = Make-BootstrapBuild
    }

    if ($restore -or $build -or $rebuild -or $pack -or $sign -or $publish -or $testCoreClr) {
        BuildSolution
    }
    
    if ($applyOptimizationData -and $build) {
        Build-OptProfData
    }

    if ($testDesktop -or $testVsi -or $testIOperation) {
        TestUsingOptimizedRunner
    }

    if ($launch) {
        $devenvExe = Join-Path $env:VSINSTALLDIR 'Common7\IDE\devenv.exe'
        &$devenvExe /rootSuffix RoslynDev
    }

    ExitWithExitCode 0
}
catch {
    Write-Host $_
    Write-Host $_.Exception
    Write-Host $_.ScriptStackTrace
    ExitWithExitCode 1
}
finally {
    Pop-Location
}
