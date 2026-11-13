param (
    [string]$ScriptPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'Windows-Notification-Sound-Modification-Script.ps1'),
    [switch]$DemonstrateOriginalBug
)

$ErrorActionPreference = 'Stop'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($statement in $ast.EndBlock.Statements) {
    if ($statement -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
        Invoke-Expression $statement.Extent.Text
    }
}

function Assert-True($condition, [string]$message) {
    if (!$condition) { throw $message }
}

# Exercise the real Registry provider only below an isolated, unique test key.
$testRoot = 'HKCU:\Software\NotificationSoundScriptTests_' + [guid]::NewGuid().ToString('N')
$scheme = Join-Path $testRoot 'Scheme'
$current = Join-Path $testRoot 'Current'
$tone = 'C:\test\通知（测试）.wav'
try {
    $result = SetTone -registryItem $scheme -currentRegistryItem $current -toneFilePath $tone
    Assert-True ($result -eq $true) 'Successful writes must return true.'
    foreach ($key in @($scheme, $current)) {
        Assert-True ((Get-ItemPropertyValue -LiteralPath $key -Name '(Default)') -ceq $tone) 'Incorrect registry value.'
    }
    Write-Output 'PASS: real Registry provider writes both default values.'

    # Emit a non-terminating provider error with both keys already present.
    & {
        function Set-ItemProperty {
            [CmdletBinding()]
            param([string]$Path, [string]$LiteralPath, [string]$Name, $Value)
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                [UnauthorizedAccessException]::new('Injected access denied'),
                'InjectedAccessDenied', [System.Management.Automation.ErrorCategory]::PermissionDenied, $Path))
        }
        $caught = $false
        $result = $null
        # Match the default preference of an interactive PowerShell session.
        $ErrorActionPreference = 'Continue'
        try { $result = SetTone -registryItem $scheme -currentRegistryItem $current -toneFilePath $tone }
        catch { $caught = $true }
        if ($DemonstrateOriginalBug) {
            Assert-True (!$caught -and $result -eq $true) 'Expected to reproduce the original false success.'
            Write-Output 'REPRODUCED: original script returns success despite failed writes.'
        } else {
            Assert-True ($caught -and $null -eq $result) 'Write failure was reported as success.'
            Write-Output 'PASS: non-terminating write error reaches catch.'
        }
    }
    if ($DemonstrateOriginalBug) { return }

    # A provider may silently retain a stale value; test both destination keys.
    foreach ($staleKey in @($scheme, $current)) {
        & {
            param($staleKey)
            Set-ItemProperty -LiteralPath $staleKey -Name '(Default)' -Value 'old.wav'
            function Set-ItemProperty {
                [CmdletBinding()]
                param([string]$LiteralPath, [string]$Name, $Value)
                if ($LiteralPath -ne $staleKey) {
                    Microsoft.PowerShell.Management\Set-ItemProperty @PSBoundParameters
                }
            }
            $caught = $false
            try { $null = SetTone -registryItem $scheme -currentRegistryItem $current -toneFilePath $tone }
            catch { $caught = $_.Exception.Message -like '*校验失败*' }
            Assert-True $caught 'A stale registry value was accepted.'
        } $staleKey
    }
    Write-Output 'PASS: stale values in either destination fail verification.'

    & {
        function New-Item {
            [CmdletBinding()]
            param([string]$Path, [switch]$Force)
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                [UnauthorizedAccessException]::new('Injected key creation failure'),
                'InjectedCreateFailure', [System.Management.Automation.ErrorCategory]::PermissionDenied, $Path))
        }
        $caught = $false
        $ErrorActionPreference = 'Continue'
        try { $null = SetTone -registryItem (Join-Path $testRoot 'Missing') -currentRegistryItem $current -toneFilePath $tone }
        catch { $caught = $true }
        Assert-True $caught 'Key creation failure did not terminate.'
        Write-Output 'PASS: key creation failure reaches catch.'
    }

    & {
        function Test-Path { param([string]$LiteralPath, $ErrorAction) return $false }
        function New-Item { param([string]$Path, [switch]$Force, $ErrorAction) }
        function New-ItemProperty {
            [CmdletBinding()]
            param([string]$Path, [string]$Name, $Value, $PropertyType, [switch]$Force)
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                [UnauthorizedAccessException]::new('Injected scheme name failure'),
                'InjectedNameFailure', [System.Management.Automation.ErrorCategory]::PermissionDenied, $Path))
        }
        $caught = $false
        $ErrorActionPreference = 'Continue'
        try { $null = CreateAppEventsSchemesNamesByPackageName -tonePackageName 'Test' }
        catch { $caught = $true }
        Assert-True $caught 'Scheme name failure did not terminate.'
        Write-Output 'PASS: scheme name failure reaches catch.'
    }

    # Execute the actual top-level try/catch/finally with registry writes mocked.
    $main = $ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] }
    foreach ($scenario in @('success', 'schemeFailure', 'currentFailure', 'mismatch', 'empty')) {
        & {
            param($scenario)
            $script:messages = @()
            $script:waits = 0
            $script:values = @{}
            $script:createdSchemes = 0
            function ReadEventLabelsFromJsonFile {
                return @([pscustomobject]@{App='.Default'; EventLabels=@([pscustomobject]@{ID='Notification.Default'; ZH='通知'; EN='Notification'})})
            }
            function Read-Host {
                param($Prompt)
                if ($Prompt -like '*文件夹*') { return $PSScriptRoot }
                $script:waits++
            }
            function Write-Host { param($Object, $ForegroundColor) $script:messages += [string]$Object }
            function Test-Path { param($LiteralPath, $PathType, $ErrorAction) return $true }
            function GetAllToneFilesInfo {
                param($toneFolderPath)
                if ($scenario -eq 'empty') { return @{} }
                return @{'通知（测试）' = $tone}
            }
            function CreateAppEventsSchemesNamesByPackageName {
                param($tonePackageName)
                $script:createdSchemes++
                return 'Test0'
            }
            function Set-ItemProperty {
                [CmdletBinding()]
                param($LiteralPath, $Name, $Value)
                $fail = ($scenario -eq 'schemeFailure' -and $LiteralPath -notlike '*.Current') -or
                    ($scenario -eq 'currentFailure' -and $LiteralPath -like '*.Current')
                if ($fail) {
                    $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                        [UnauthorizedAccessException]::new('Injected write failure'),
                        'InjectedWriteFailure', [System.Management.Automation.ErrorCategory]::PermissionDenied, $LiteralPath))
                } else { $script:values[$LiteralPath] = $Value }
            }
            function Get-ItemPropertyValue {
                param($LiteralPath, $Name, $ErrorAction)
                if ($scenario -eq 'mismatch') { return 'old.wav' }
                return $script:values[$LiteralPath]
            }
            $ErrorActionPreference = 'Continue'
            & ([scriptblock]::Create($main.Extent.Text))
            $text = $script:messages -join "`n"
            Assert-True ($script:waits -eq 1) 'Finally must wait exactly once.'
            if ($scenario -eq 'success') {
                Assert-True ($text -match '已成功注册' -and $text -notmatch '运行失败') 'Success flow failed.'
            } else {
                Assert-True ($text -match '运行失败' -and $text -notmatch '已成功注册|已设置：') 'Failure flow printed a success message.'
            }
            if ($scenario -eq 'empty') {
                Assert-True ($script:createdSchemes -eq 0) 'Empty folder created an unused scheme.'
            }
            Write-Output "PASS: main flow $scenario."
        } $scenario
    }

    $labels = Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) 'EventLabels.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $lookup = NewEventLabelLookup $labels
    Assert-True ((GetEventLabel '通知（测试）' $lookup).id -eq 'Notification.Default') 'Annotated filename regression.'
    Assert-True ((GetEventLabel 'NFP完成' $lookup).id -eq 'Notification.Proximity') 'Whitespace matching regression.'
    Assert-True ((GetEventLabel 'NOTIFICATION' $lookup).id -eq 'Notification.Default') 'Case matching regression.'
    Write-Output 'PASS: filename matching regressions.'
} finally {
    # Validate the exact unique root before removing only this test's keys.
    if ($testRoot -notmatch '^HKCU:\\Software\\NotificationSoundScriptTests_[0-9a-f]{32}$') {
        throw 'Refusing to remove an unexpected registry test root.'
    }
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction Stop
    }
}
