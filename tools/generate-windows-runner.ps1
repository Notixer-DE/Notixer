$ErrorActionPreference = 'Stop'

flutter create --platforms=windows --project-name notixer .
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# path_provider and flutter_secure_storage use ProductName for existing files.
$resource = 'windows/runner/Runner.rc'
$versionInfo = Get-Content -LiteralPath $resource -Raw
$versionInfo = $versionInfo.Replace('VALUE "ProductName", "notixer"', 'VALUE "ProductName", "noter"')
if (-not $versionInfo.Contains('VALUE "ProductName", "noter"')) {
    throw 'Missing legacy Windows storage identity in Runner.rc'
}
Set-Content -LiteralPath $resource -Value $versionInfo -Encoding utf8 -NoNewline
