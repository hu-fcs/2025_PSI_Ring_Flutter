param (
    [Parameter(Mandatory = $true)]
    [int]$Count
)

$OutputPath = "assets/dummy_keys.txt"

Write-Host "Generating $Count dummy EC public keys (P-256, compressed)"
Write-Host "Output: $OutputPath"
Write-Host ""

$dir = Split-Path $OutputPath
if (-not (Test-Path $dir)) {
    Write-Error "Directory not found: $dir"
    exit 1
}

$out = New-Object System.Collections.Generic.List[string]
$start = Get-Date

for ($i = 1; $i -le $Count; $i++) {

    # ---- 進捗（1単位・行上書き）----
    $percent = [int](($i / $Count) * 100)
    Write-Host -NoNewline "`r[$percent%] $i / $Count"

    $tmp = [System.IO.Path]::GetTempFileName()

    & openssl ecparam -name prime256v1 -genkey -noout -out $tmp 2>$null
    if ($LASTEXITCODE -ne 0) {
        Remove-Item $tmp -Force
        $i--
        continue
    }

    $lines = & openssl ec -in $tmp -pubout -conv_form compressed -text -noout 2>$null
    Remove-Item $tmp -Force

    $collect = $false
    $hex = ""

    foreach ($line in $lines) {
        if ($line -match '^\s*pub:\s*$') {
            $collect = $true
            continue
        }
        if ($collect) {
            if ($line -match '^\s*[0-9a-fA-F:]+\s*$') {
                $hex += ($line -replace '[:\s]', '')
            } else {
                break
            }
        }
    }

    if ($hex.Length -eq 66 -and ($hex.StartsWith("02") -or $hex.StartsWith("03"))) {
        $out.Add($hex.ToLower())
    } else {
        $i--
    }
}

# 最後に改行
Write-Host ""

$out | Out-File -Encoding ascii $OutputPath

$elapsed = (Get-Date) - $start
Write-Host "Done. Generated: $($out.Count) keys"
Write-Host ("Elapsed: {0:N2} sec" -f $elapsed.TotalSeconds)
