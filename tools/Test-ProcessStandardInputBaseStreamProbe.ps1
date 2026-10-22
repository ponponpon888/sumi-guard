<#
    Measures whether writing to Process.StandardInput.BaseStream preserves the
    supplied bytes in Windows PowerShell 5.1.  It deliberately does not use
    StandardInput.Write/WriteLine: the child reads Console.OpenStandardInput()
    as bytes and reports only their length and SHA-256.
#>
[CmdletBinding()]
param(
    [switch]$Child,
    [string]$ResultPath,
    [string]$StatusPath,
    [int]$TimeoutMilliseconds = 10000,
    [switch]$KeepWorkDirectory
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-ByteHash {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Read-StandardInputByteStream {
    $inputStream = [Console]::OpenStandardInput()
    $buffer = New-Object byte[] 4096
    $bytes = New-Object System.Collections.Generic.List[byte]
    try {
        while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            for ($index = 0; $index -lt $read; $index++) {
                $bytes.Add($buffer[$index])
            }
        }
        # Keep even an empty byte[] as one pipeline object.  Without the
        # unary comma PowerShell emits no pipeline value for an empty array,
        # so the caller receives $null instead of the bytes it must hash.
        return ,($bytes.ToArray())
    }
    finally {
        $inputStream.Dispose()
    }
}

if ($Child) {
    $childFailure = $null
    try {
        if ([string]::IsNullOrEmpty($ResultPath) -or [string]::IsNullOrEmpty($StatusPath)) {
            throw 'Child result and status paths are required.'
        }

        $received = Read-StandardInputByteStream
        $observation = [ordered]@{
            byte_count = $received.Length
            sha256 = Get-ByteHash -Bytes $received
        }
        [IO.File]::WriteAllText(
            $ResultPath,
            ([pscustomobject]$observation | ConvertTo-Json -Compress),
            (New-Object Text.UTF8Encoding($false)))
    }
    catch {
        $childFailure = $_
    }
    finally {
        if (-not [string]::IsNullOrEmpty($StatusPath)) {
            $childStatus = [pscustomobject][ordered]@{
                success = ($null -eq $childFailure)
                stage = if ($null -eq $childFailure) { 'CHILD_COMPLETE' } else { 'CHILD_EXCEPTION' }
                line = if ($null -eq $childFailure) { $null } else { [Int32]$childFailure.InvocationInfo.ScriptLineNumber }
                exception_type = if ($null -eq $childFailure) { $null } else { $childFailure.Exception.GetType().FullName }
                hresult = if ($null -eq $childFailure) { $null } else { [Int32]$childFailure.Exception.HResult }
            }
            try {
                [IO.File]::WriteAllText(
                    $StatusPath,
                    ($childStatus | ConvertTo-Json -Compress),
                    (New-Object Text.UTF8Encoding($false)))
            }
            catch {
                # A missing status file is reported by the parent.  Do not
                # write an exception message to either redirected stream.
                Write-Verbose 'CHILD_STATUS_WRITE_FAILED'
            }
        }
    }
    if ($null -ne $childFailure) { exit 1 }
    exit 0
}

if ($TimeoutMilliseconds -le 0) {
    throw 'TimeoutMilliseconds must be positive.'
}

$powerShell51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $powerShell51 -PathType Leaf)) {
    throw 'Windows PowerShell 5.1 powershell.exe was not found.'
}

$utf8NoBom = New-Object Text.UTF8Encoding($false, $true)
$utf8Bom = New-Object Text.UTF8Encoding($true, $true)
$invalidUtf8 = [byte[]](0xff, 0xfe, 0xc3, 0x28, 0x80)
$sampleText = (-join @(0x30C6, 0x30B9, 0x30C8, 0x6f22, 0x5b57 | ForEach-Object { [char]$_ })) + [char]::ConvertFromUtf32(0x1f512)
$cases = @(
    [pscustomobject]@{ name = 'empty'; bytes = [byte[]]@() },
    [pscustomobject]@{ name = 'utf8_no_bom'; bytes = $utf8NoBom.GetBytes($sampleText) },
    [pscustomobject]@{ name = 'utf8_with_bom'; bytes = [byte[]]($utf8Bom.GetPreamble() + $utf8Bom.GetBytes('bom')) },
    [pscustomobject]@{ name = 'invalid_utf8'; bytes = $invalidUtf8 }
)

$workRoot = Join-Path ([IO.Path]::GetTempPath()) ('sumi-guard-stdin-basestream-' + [Guid]::NewGuid().ToString('N'))
$results = New-Object System.Collections.Generic.List[object]
$failure = $null
$cleanupAttempted = $false
$cleanupSucceeded = $null

try {
    [IO.Directory]::CreateDirectory($workRoot) | Out-Null
    foreach ($case in $cases) {
        $resultFile = Join-Path $workRoot ($case.name + '.json')
        $statusFile = Join-Path $workRoot ($case.name + '.status.json')
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = $powerShell51
        $startInfo.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Child -ResultPath "{1}" -StatusPath "{2}"' -f $PSCommandPath, $resultFile, $statusFile
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true

        $process = New-Object Diagnostics.Process
        $process.StartInfo = $startInfo
        $processStarted = $false
        try {
            $savedConsoleInputEncoding = $null
            $consoleInputEncodingNeutralized = $false
            try {
                $savedConsoleInputEncoding = [Console]::InputEncoding
                if ($savedConsoleInputEncoding.GetPreamble().Length -gt 0) {
                    [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
                    $consoleInputEncodingNeutralized = $true
                }
            }
            catch {
                throw [System.InvalidOperationException]::new('STDIN_PREAMBLE_NOT_NEUTRALIZED', $_.Exception)
            }
            try {
                if (-not $process.Start()) { throw 'The probe child did not start.' }
            }
            finally {
                if ($consoleInputEncodingNeutralized) {
                    try { [Console]::InputEncoding = $savedConsoleInputEncoding }
                    catch { throw [System.InvalidOperationException]::new('STDIN_PREAMBLE_NOT_NEUTRALIZED', $_.Exception) }
                }
            }
            $processStarted = $true
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
            # A case property can hold any PowerShell collection.  Bind a
            # concrete byte[] before selecting Stream.Write(byte[], int, int).
            [byte[]]$payload = $case.bytes
            $standardInput = $process.StandardInput
            try {
                # .NET Framework creates StandardInput's StreamWriter at
                # Start using Console.InputEncoding. A preamble can be sent
                # before BaseStream: UTF-8 BOM made {} arrive as 5 bytes
                # (EF BB BF 7B 7D) in the measured reproduction.
                try { $standardInputPreambleLength = $standardInput.Encoding.GetPreamble().Length }
                catch { throw [System.InvalidOperationException]::new('STDIN_PREAMBLE_NOT_NEUTRALIZED', $_.Exception) }
                if ($standardInputPreambleLength -ne 0) {
                    throw [System.InvalidOperationException]::new('STDIN_PREAMBLE_NOT_NEUTRALIZED')
                }
                # This is intentionally the underlying pipe stream, not any
                # StreamWriter text API. Close sends EOF after all bytes flush.
                $standardInput.BaseStream.Write($payload, 0, $payload.Length)
                $standardInput.BaseStream.Flush()
            }
            finally {
                try {
                    $standardInput.Close()
                }
                finally {
                    $standardInput.Dispose()
                }
            }

            if (-not $process.WaitForExit($TimeoutMilliseconds)) {
                throw 'The probe child did not exit before the timeout.'
            }
            $process.WaitForExit()

            $childExitConfirmed = $process.HasExited
            $outputReadCompleted = $false
            try {
                $stdoutTask.Wait()
                $stderrTask.Wait()
                $outputReadCompleted = $true
            }
            catch {
                # Stream completion is represented below; no child text is emitted.
                Write-Verbose 'CHILD_OUTPUT_READ_INCOMPLETE'
            }
            $statusFileExists = Test-Path -LiteralPath $statusFile -PathType Leaf
            $resultFileExists = Test-Path -LiteralPath $resultFile -PathType Leaf
            $childStatus = $null
            if ($statusFileExists) {
                try { $childStatus = Get-Content -LiteralPath $statusFile -Raw | ConvertFrom-Json }
                catch {
                    $childStatus = $null
                    Write-Verbose 'CHILD_STATUS_READ_FAILED'
                }
            }

            $expectedHash = Get-ByteHash -Bytes $payload
            if (($process.ExitCode -ne 0) -or -not $childExitConfirmed -or -not $outputReadCompleted -or
                -not $statusFileExists -or -not $resultFileExists -or $null -eq $childStatus -or
                -not [bool]$childStatus.success) {
                $results.Add([pscustomobject][ordered]@{
                    name = $case.name
                    pass = $false
                    sent_byte_count = $payload.Length
                    sent_sha256 = $expectedHash
                    child_exit_code = $process.ExitCode
                    child_exit_confirmed = $childExitConfirmed
                    output_read_completed = $outputReadCompleted
                    result_file_exists = $resultFileExists
                    status_file_exists = $statusFileExists
                    child_stage = if ($null -eq $childStatus) { $null } else { [string]$childStatus.stage }
                    child_line = if ($null -eq $childStatus) { $null } else { $childStatus.line }
                    child_exception_type = if ($null -eq $childStatus) { $null } else { [string]$childStatus.exception_type }
                    child_hresult = if ($null -eq $childStatus) { $null } else { $childStatus.hresult }
                })
                continue
            }

            $received = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
            $matched = ($process.ExitCode -eq 0) -and
                ([Int64]$received.byte_count -eq [Int64]$payload.Length) -and
                ([string]$received.sha256 -ceq $expectedHash)
            $results.Add([pscustomobject][ordered]@{
                name = $case.name
                pass = $matched
                sent_byte_count = $payload.Length
                sent_sha256 = $expectedHash
                received_byte_count = [Int64]$received.byte_count
                received_sha256 = [string]$received.sha256
                child_exit_code = $process.ExitCode
                child_exit_confirmed = $childExitConfirmed
                output_read_completed = $outputReadCompleted
                result_file_exists = $resultFileExists
                status_file_exists = $statusFileExists
                child_stage = [string]$childStatus.stage
                child_line = $childStatus.line
                child_exception_type = [string]$childStatus.exception_type
                child_hresult = $childStatus.hresult
            })
        }
        finally {
            try {
                if ($processStarted -and -not $process.HasExited) {
                    $process.Kill()
                    if (-not $process.WaitForExit($TimeoutMilliseconds)) {
                        throw 'The timed-out probe child could not be reaped.'
                    }
                }
            }
            finally {
                $process.Dispose()
            }
        }
    }
}
catch {
    $failure = $_
}
finally {
    if (-not $KeepWorkDirectory -and (Test-Path -LiteralPath $workRoot)) {
        $cleanupAttempted = $true
        try {
            Remove-Item -LiteralPath $workRoot -Recurse -Force
            $cleanupSucceeded = -not (Test-Path -LiteralPath $workRoot)
        }
        catch {
            $cleanupSucceeded = $false
        }
    }
    $report = [pscustomobject][ordered]@{
        success = ($null -eq $failure) -and ($cleanupSucceeded -ne $false) -and (@($results | Where-Object { -not $_.pass }).Count -eq 0) -and ($results.Count -eq $cases.Count)
        cases = $results.ToArray()
        work_root = $workRoot
        failure_stage = if ($null -eq $failure) { $null } else { 'TOP_LEVEL' }
        failure_line = if ($null -eq $failure) { $null } else { [Int32]$failure.InvocationInfo.ScriptLineNumber }
        failure_type = if ($null -eq $failure) { $null } else { $failure.Exception.GetType().FullName }
        failure_hresult = if ($null -eq $failure) { $null } else { [Int32]$failure.Exception.HResult }
        cleanup_attempted = $cleanupAttempted
        cleanup_succeeded = $cleanupSucceeded
    }
    $report | ConvertTo-Json -Depth 4
}

if ($null -ne $failure) { throw $failure }
if ($cleanupSucceeded -eq $false -or @($results | Where-Object { -not $_.pass }).Count -ne 0 -or $results.Count -ne $cases.Count) { exit 1 }
exit 0
