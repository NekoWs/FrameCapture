$ErrorActionPreference = 'Stop'
$main = 'NekoWs/NekoCapture'
$release = gh api "repos/$main/releases/latest" | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Cannot read main release' }
$version = $release.tag_name.TrimStart('v')
if ([version]$version -lt [version]'0.9.36') { exit 0 }
$tag = "v$version"
$existing = gh release view $tag --json isDraft 2>$null
if ($LASTEXITCODE -eq 0 -and -not ($existing | ConvertFrom-Json).isDraft) { exit 0 }
$directory = Join-Path $env:RUNNER_TEMP ('legacy-' + $version)
New-Item -ItemType Directory -Force -Path $directory | Out-Null
$newName = "NekoCapture-Setup-$version-x64.exe"
gh release download $tag --repo $main --pattern $newName --pattern update.json --dir $directory --clobber
if ($LASTEXITCODE -ne 0) { throw 'Cannot download main release' }
$envelope = Get-Content (Join-Path $directory 'update.json') -Raw | ConvertFrom-Json
$bytes = [Convert]::FromBase64String($envelope.manifest)
$public = [Security.Cryptography.RSA]::Create()
$signer = [Security.Cryptography.RSA]::Create()
try {
    $public.ImportFromPem([IO.File]::ReadAllText((Join-Path $PSScriptRoot '../assets/update-public.pem')))
    if (-not $public.VerifyData($bytes, [Convert]::FromBase64String($envelope.signature), [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)) { throw 'Main release signature is invalid' }
    $source = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
    $installer = Join-Path $directory $newName
    $hash = (Get-FileHash $installer -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($source.repository -ne $main -or $source.version -ne $version -or $source.installer -ne $newName -or $source.length -ne (Get-Item $installer).Length -or $source.sha256 -ne $hash) { throw 'Main installer does not match signed manifest' }
    $signer.ImportFromPem($env:UPDATE_SIGNING_KEY)
    if ([Convert]::ToBase64String($signer.ExportSubjectPublicKeyInfo()) -ne [Convert]::ToBase64String($public.ExportSubjectPublicKeyInfo())) { throw 'Compatibility signing key does not match' }
    $oldName = "FrameCapture-Setup-$version-x64.exe"
    Copy-Item $installer (Join-Path $directory $oldName)
    $manifest = [ordered]@{schema=1; repository='NekoWs/FrameCapture'; version=$version; installer=$oldName; length=(Get-Item $installer).Length; sha256=$hash; publishedUtc=[DateTime]::UtcNow.ToString('O')}
    $signed = [Text.Encoding]::UTF8.GetBytes(($manifest | ConvertTo-Json -Compress))
    $signature = $signer.SignData($signed, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    [IO.File]::WriteAllText((Join-Path $directory 'update.json'), ([ordered]@{manifest=[Convert]::ToBase64String($signed);signature=[Convert]::ToBase64String($signature)} | ConvertTo-Json -Compress))
    [IO.File]::WriteAllText((Join-Path $directory 'SHA256SUMS.txt'), "$hash  $oldName`n")
    $notes = Join-Path $directory 'notes.md'
    [IO.File]::WriteAllText($notes, "# NekoCapture $version`n`nFrameCapture 兼容升级入口。安装后使用 NekoCapture，保留已有设置及组件。`n`n[主项目与对应源码](https://github.com/$main/releases/tag/$tag)。`n`n安装包与主仓库安装包的 SHA256 相同。")
    $files = @((Join-Path $directory $oldName),(Join-Path $directory 'update.json'),(Join-Path $directory 'SHA256SUMS.txt'))
    if ($existing) { gh release upload $tag @files --clobber }
    else { gh release create $tag @files --draft --title "NekoCapture $version compatibility update" --notes-file $notes }
    if ($LASTEXITCODE -ne 0) { throw 'Cannot upload compatibility release' }
    gh release edit $tag --draft=false --latest
    if ($LASTEXITCODE -ne 0) { throw 'Cannot publish compatibility release' }
} finally { $public.Dispose(); $signer.Dispose() }
