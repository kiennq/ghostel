param(
    [int]$Iterations = 3,
    [int]$Chunks = 3000,
    [int]$ChunkBytes = 4096,
    [double]$PauseSeconds = 0.001,
    [string]$BaselineSource = '.build\refresh-bench\baseline-source\lisp',
    [string]$BaselineModule = '.build\refresh-bench\baseline-native\bin',
    [string]$CandidateSource = 'lisp',
    [string]$CandidateModule = '.build\refresh-bench\candidate-native\bin',
    [string]$OutputDirectory = '.build\refresh-bench\results'
)

$ErrorActionPreference = 'Stop'
if ($Iterations -lt 1 -or $Chunks -lt 1 -or $ChunkBytes -lt 2 -or $PauseSeconds -lt 0) {
    throw 'Iterations and chunks must be positive, chunk size at least two, and pause non-negative.'
}
if (-not $IsWindows) {
    throw 'This driver measures Windows main-thread CPU time; run the Elisp harness separately on other systems.'
}
$root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $root
$emacs = (Get-Command emacs).Source
$baselineSourcePath = (Resolve-Path -LiteralPath $BaselineSource).Path
$baselineModulePath = (Resolve-Path -LiteralPath $BaselineModule).Path
$candidateSourcePath = (Resolve-Path -LiteralPath $CandidateSource).Path
$candidateModulePath = (Resolve-Path -LiteralPath $CandidateModule).Path
$outputPath = [IO.Path]::GetFullPath((Join-Path $root $OutputDirectory))
if (Test-Path -LiteralPath $outputPath) {
    throw "Use a new output directory: $outputPath"
}
New-Item -ItemType Directory -Path $outputPath | Out-Null
$variants = @(
    @{ Name = 'baseline'; Source = $baselineSourcePath; Module = $baselineModulePath },
    @{ Name = 'candidate'; Source = $candidateSourcePath; Module = $candidateModulePath }
)
$results = [Collections.Generic.List[object]]::new()

function Wait-TrialFile($Path, $Process) {
    $deadline = [DateTime]::UtcNow.AddSeconds(90)
    while (-not (Test-Path -LiteralPath $Path)) {
        if ($Process.HasExited) {
            throw "Benchmark exited early ($($Process.ExitCode)) while waiting for $Path; inspect the trial's err.log"
        }
        if ([DateTime]::UtcNow -gt $deadline) {
            throw "Timed out waiting for $Path"
        }
        Start-Sleep -Milliseconds 10
    }
}

for ($iteration = 1; $iteration -le $Iterations; $iteration++) {
    # Alternate which build runs first to reduce order/host-load bias.
    $order = if ($iteration % 2) { @(0, 1) } else { @(1, 0) }
    foreach ($mode in @('active', 'hidden', 'unselected', 'copy')) {
        foreach ($index in $order) {
            $variant = $variants[$index]
            $prefix = Join-Path $outputPath "$iteration-$mode-$($variant.Name)"
            $start = [Diagnostics.ProcessStartInfo]::new()
            $start.FileName = $emacs
            $start.WorkingDirectory = $root
            $start.UseShellExecute = $false
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            foreach ($argument in @(
                '--batch', '-Q', '-L', (Join-Path $root 'lisp'), '-L', $variant.Source,
                '--eval', '(setq load-prefer-newer t ghostel-module-directory (getenv "GHOSTEL_REFRESH_BENCH_MODULE"))',
                '-l', (Join-Path $variant.Source 'ghostel-module-install.el'),
                '-l', (Join-Path $variant.Source 'ghostel.el'),
                '-l', (Join-Path $root 'bench\ghostel-refresh-bench.el'),
                '-f', 'ghostel-refresh-bench-run'
            )) {
                $start.ArgumentList.Add($argument)
            }
            $start.Environment['GHOSTEL_REFRESH_BENCH_MODULE'] = $variant.Module
            $start.Environment['GHOSTEL_REFRESH_BENCH_MODE'] = $mode
            $start.Environment['GHOSTEL_REFRESH_BENCH_PREFIX'] = $prefix
            $start.Environment['GHOSTEL_REFRESH_BENCH_CHUNKS'] = "$Chunks"
            $start.Environment['GHOSTEL_REFRESH_BENCH_BYTES'] = "$ChunkBytes"
            $start.Environment['GHOSTEL_REFRESH_BENCH_PAUSE'] =
                $PauseSeconds.ToString([Globalization.CultureInfo]::InvariantCulture)
            $process = [Diagnostics.Process]::Start($start)
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            try {
                Wait-TrialFile "$prefix.ready" $process
                $ready = Get-Content -Raw -LiteralPath "$prefix.ready" | ConvertFrom-Json
                $process.Refresh()
                # Emacs' initial thread predates its native reader and runtime workers.
                $mainThread = $process.Threads | Sort-Object StartTime | Select-Object -First 1
                $mainId = $mainThread.Id
                $cpuStart = $mainThread.TotalProcessorTime.TotalMilliseconds
                [IO.File]::WriteAllText("$prefix.go", '')
                Wait-TrialFile "$prefix.timed" $process
                $process.Refresh()
                $mainThread = $process.Threads | Where-Object Id -EQ $mainId
                $cpuMs = $mainThread.TotalProcessorTime.TotalMilliseconds - $cpuStart
                [IO.File]::WriteAllText("$prefix.sampled", '')
                Wait-TrialFile "$prefix.json" $process
                if (-not $process.WaitForExit(15000)) {
                    throw "Benchmark cleanup did not finish: $prefix"
                }
                if ($process.ExitCode -ne 0) {
                    throw "Benchmark failed ($($process.ExitCode)): $prefix"
                }
                $row = Get-Content -Raw -LiteralPath "$prefix.json" | ConvertFrom-Json
                $row | Add-Member -NotePropertyName variant -NotePropertyValue $variant.Name
                $row | Add-Member -NotePropertyName iteration -NotePropertyValue $iteration
                $row | Add-Member -NotePropertyName main_thread_cpu_ms -NotePropertyValue $cpuMs
                $row | Add-Member -NotePropertyName module_version -NotePropertyValue $ready.module_version
                $results.Add($row)
                Write-Output ("{0} {1,-10} {2,-9} main={3,8:N2}ms filter={4,6} elapsed={5:N3}s catchup={6:N2}ms" -f
                    $iteration, $mode, $variant.Name, $cpuMs, $row.filter_calls,
                    $row.wall_seconds, $row.catchup_ms)
                $results | ConvertTo-Json -Depth 5 |
                    Set-Content -LiteralPath (Join-Path $outputPath 'results.json') -Encoding utf8NoBOM
            }
            finally {
                if (-not $process.HasExited) {
                    Stop-Process -Id $process.Id
                    $process.WaitForExit()
                }
                [IO.File]::WriteAllText("$prefix.out.log", $stdout.GetAwaiter().GetResult())
                [IO.File]::WriteAllText("$prefix.err.log", $stderr.GetAwaiter().GetResult())
                $process.Dispose()
            }
        }
    }
}
