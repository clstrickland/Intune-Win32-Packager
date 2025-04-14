# .github/actions/package-intune-app/Package-IntuneApp.ps1

#Requires -Version 5.1

# --- (Synopsis, Description, Parameters remain the same as previous version) ---
param(
    [Parameter(Mandatory = $true, HelpMessage = "Full path to the application source FOLDER.")]
    [string]$AppSourceFolderPath,
    [Parameter(Mandatory = $true, HelpMessage = "Full path to the PowerShell install script. Must handle running installer from '../App'.")]
    [string]$InstallScriptPath,
    [Parameter(Mandatory = $true, HelpMessage = "Full path to the PowerShell uninstall script.")]
    [string]$UninstallScriptPath,
    [Parameter(Mandatory = $false, HelpMessage = "Full path to the PowerShell detection script (optional).")]
    [string]$DetectionScriptPath,
    [Parameter(Mandatory = $true, HelpMessage = "Name for the output folder containing .intunewin, scripts, instructions.")]
    [string]$OutputBundleName,
    [Parameter(Mandatory = $true, HelpMessage = "Name for the output folder containing source files (App/, DeploymentScripts/).")]
    [string]$SourceBundleName
    [Parameter(Mandatory = $true, HelpMessage = "The desired application name (used for naming and instructions).")]
    [string]$AppName
)

# --- Configuration & Setup (remain the same) ---
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:ExitCode = 0

$actionPath = $PSScriptRoot
$workspacePath = $env:GITHUB_WORKSPACE
$intuneUtilPath = Join-Path -Path $actionPath -ChildPath "IntuneWinAppUtil.exe"

if (-not (Test-Path -Path $intuneUtilPath -PathType Leaf)) { Write-Error "IntuneWinAppUtil.exe not found: $intuneUtilPath"; exit 1 }
if (-not (Test-Path -Path $AppSourceFolderPath -PathType Container)) { Write-Error "Application source FOLDER not found: $AppSourceFolderPath"; exit 1 }
if (-not (Test-Path -Path $InstallScriptPath -PathType Leaf)) { Write-Error "Install script not found: $InstallScriptPath"; exit 1 }
if (-not (Test-Path -Path $UninstallScriptPath -PathType Leaf)) { Write-Error "Uninstall script not found: $UninstallScriptPath"; exit 1 }
$detectionScriptProvided = $false
if ($PSBoundParameters.ContainsKey('DetectionScriptPath') -and (-not [string]::IsNullOrEmpty($DetectionScriptPath))) {
    if (-not (Test-Path -Path $DetectionScriptPath -PathType Leaf)) {
        Write-Error "Detection script provided but not found: $DetectionScriptPath"; exit 1
    }
    $detectionScriptProvided = $true
}

$stagingDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("IntunePkg_" + [System.Guid]::NewGuid().ToString().Substring(0, 8))
$stagingAppDir = Join-Path -Path $stagingDir -ChildPath "App"
$stagingScriptsDir = Join-Path -Path $stagingDir -ChildPath "DeploymentScripts"
$outputBundleFullPath = Join-Path -Path $workspacePath -ChildPath $OutputBundleName
$sourceBundleFullPath = Join-Path -Path $workspacePath -ChildPath $SourceBundleName

# --- Main Logic ---
try {
    # 1. Create Staging directories (same as before)
    Write-Host "Creating temporary staging directory: $stagingDir"
    New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null; New-Item -ItemType Directory -Path $stagingAppDir -Force | Out-Null; New-Item -ItemType Directory -Path $stagingScriptsDir -Force | Out-Null

    # 2. Copy files to Staging (same as before)
    Write-Host "Copying application source folder contents to staging..."
    Copy-Item -Path "$AppSourceFolderPath\*" -Destination $stagingAppDir -Recurse -Force -ErrorAction Stop
    if (-not (Get-ChildItem -Path $stagingAppDir -ErrorAction SilentlyContinue)) { Write-Warning "The application source folder '$AppSourceFolderPath' appears empty." }
    Write-Host "Copying deployment scripts to staging..."
    Copy-Item -Path $InstallScriptPath -Destination (Join-Path -Path $stagingScriptsDir -ChildPath "Install.ps1") -Force
    Copy-Item -Path $UninstallScriptPath -Destination (Join-Path -Path $stagingScriptsDir -ChildPath "Uninstall.ps1") -Force
    if ($detectionScriptProvided) { Copy-Item -Path $DetectionScriptPath -Destination (Join-Path -Path $stagingScriptsDir -ChildPath "Detect.ps1") -Force; Write-Host "Detection script copied." }

    # 3. Create Source Bundle (same as before)
    Write-Host "Creating source bundle folder: $sourceBundleFullPath"; if (Test-Path -Path $sourceBundleFullPath) { Remove-Item -Path $sourceBundleFullPath -Recurse -Force }
    New-Item -ItemType Directory -Path $sourceBundleFullPath -Force | Out-Null; Write-Host "Copying staged files to source bundle..."; Copy-Item -Path "$stagingDir\*" -Destination $sourceBundleFullPath -Recurse -Force

    # 4. Run IntuneWinAppUtil.exe (same as before)
    $stagedIntuneWinFile = "Install.intunewin"; $stagedIntuneWinPath = Join-Path -Path $stagingDir -ChildPath $stagedIntuneWinFile
    $setupFile = Join-Path -Path $stagingScriptsDir -ChildPath "Install.ps1"
    Write-Host "Running IntuneWinAppUtil.exe..."; Write-Host "  Source Folder (-c): $stagingDir"; Write-Host "  Setup File (-s): $setupFile"; Write-Host "  Output Folder (-o): $stagingDir"
    $processInfo = New-Object System.Diagnostics.ProcessStartInfo; $processInfo.FileName = $intuneUtilPath; $processInfo.Arguments = "-c `"$stagingDir`" -s `"$setupFile`" -o `"$stagingDir`" -q"
    $processInfo.RedirectStandardOutput = $true; $processInfo.RedirectStandardError = $true; $processInfo.UseShellExecute = $false; $processInfo.CreateNoWindow = $true
    $process = New-Object System.Diagnostics.Process; $process.StartInfo = $processInfo; $process.Start() | Out-Null
    $utilOutput = $process.StandardOutput.ReadToEnd(); $utilError = $process.StandardError.ReadToEnd(); $process.WaitForExit()
    Write-Host "IntuneWinAppUtil Output:"; Write-Host $utilOutput; if (-not [string]::IsNullOrEmpty($utilError)) { Write-Warning "IntuneWinAppUtil Error Output:"; Write-Warning $utilError }
    if ($process.ExitCode -ne 0) { Write-Error "IntuneWinAppUtil.exe failed (Exit Code: $($process.ExitCode))."; $script:ExitCode = 1; throw "IntuneWinAppUtil.exe failed." }
    if (-not (Test-Path -Path $stagedIntuneWinPath -PathType Leaf)) { Write-Error "Packaging failed: Output file '$stagedIntuneWinPath' not created."; $script:ExitCode = 1; throw "IntuneWinAppUtil.exe did not produce output." }
    Write-Host "IntuneWinAppUtil.exe completed successfully."

    # 5. Create Output Bundle structure (Create folder, move .intunewin, copy scripts)
    Write-Host "Creating output bundle folder structure: $outputBundleFullPath"
    if (Test-Path -Path $outputBundleFullPath) { Remove-Item -Path $outputBundleFullPath -Recurse -Force }
    New-Item -ItemType Directory -Path $outputBundleFullPath -Force | Out-Null
    $finalIntuneWinName = "$AppName.intunewin"
    $finalIntuneWinPath = Join-Path -Path $outputBundleFullPath -ChildPath $finalIntuneWinName
    Write-Host "Moving .intunewin file to $finalIntuneWinPath"
    Move-Item -Path $stagedIntuneWinPath -Destination $finalIntuneWinPath -Force
    $outputScriptsDir = Join-Path -Path $outputBundleFullPath -ChildPath "DeploymentScripts"
    Write-Host "Copying deployment scripts to output bundle at $outputScriptsDir"
    Copy-Item -Path $stagingScriptsDir -Destination $outputScriptsDir -Recurse -Force

    # 6. Prepare Variables for instructions Template
    Write-Host "Preparing variables for instructions template processing..."
    $instructionsVars = @{
        APP_NAME                  = $AppName
        FINAL_INTUNEWIN_NAME      = $finalIntuneWinName
        INSTALL_COMMAND           = '%windir%\sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\DeploymentScripts\Install.ps1'
        UNINSTALL_COMMAND         = '%windir%\sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\DeploymentScripts\Uninstall.ps1'
        DETECTION_SCRIPT_PROVIDED = if ($detectionScriptProvided) { 'true' } else { 'false' } # EPS prefers strings for simple checks
    }

    # Build detection guidance block conditionally
    if ($detectionScriptProvided) {
        $instructionsVars.DETECTION_RULES_FORMAT = '`Use detection rules configured in a script`'
        $instructionsVars.DETECTION_RULE_GUIDANCE_BLOCK = @"
- **Detection Method:** Use a **Script** detection rule.
- **Script file:** Upload the `DeploymentScripts\Detect.ps1` file from this bundle.
- **Run script as 32-bit process on 64-bit clients:** No (Unless required by your script's logic)
- **Enforce script signature check:** No (Unless your script is signed)
"@
    }
    else {
        $instructionsVars.DETECTION_RULES_FORMAT = 'Manually configure detection rules'
        $instructionsVars.DETECTION_RULE_GUIDANCE_BLOCK = "- Use a manual detection rule (e.g., check for registry key, file/folder presence) appropriate for your application."
    }

    # Convert hashtable to multiline KEY=VALUE string for the template action
    $variablesString = ($instructionsVars.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join [Environment]::NewLine
    # Escape the variable string for use in GITHUB_OUTPUT (though EOF method handles most cases)
    # $variablesString = $variablesString -replace '%', '%25' -replace "`r", '%0D' -replace "`n", '%0A'

    # 7. Set Action Outputs (including variables for template processing)
    Write-Host "Setting action outputs..."
    # Output paths relative to workspace
    $relativeOutputBundlePath = $outputBundleFullPath.Replace($workspacePath, '').TrimStart('\/')
    $relativeSourceBundlePath = $sourceBundleFullPath.Replace($workspacePath, '').TrimStart('\/')
    Write-Output "output_bundle_path=$relativeOutputBundlePath" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
    Write-Output "source_bundle_path=$relativeSourceBundlePath" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
    # Output the instructions variables using heredoc syntax for GITHUB_OUTPUT
    Write-Output "instructions_variables<<EOF" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
    Write-Output $variablesString | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
    Write-Output "EOF" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append

}
catch {
    Write-Error "An error occurred during the packaging process: $($_.Exception.Message)"; Write-Error "ScriptStackTrace: $($_.ScriptStackTrace)"; $script:ExitCode = 1
}
finally {
    # 8. Cleanup temporary directory (same as before)
    if (Test-Path -Path $stagingDir -PathType Container) { Write-Host "Cleaning up temporary directory: $stagingDir"; Remove-Item -Path $stagingDir -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Host "Script finished with exit code $script:ExitCode."; exit $script:ExitCode
}
