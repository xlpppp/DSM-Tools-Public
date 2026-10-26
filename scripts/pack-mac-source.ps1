# 打包当前提交的源码，供 Mac 编译。不接收参数。
# 排除开发文档、.cursor、.git、.github。编译不读取这些内容。
# powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\pack-mac-source.ps1
$ErrorActionPreference = "Stop"
$repo = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location -LiteralPath $repo

$sha = (git rev-parse --short=12 HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw "无法读取当前提交" }
$branch = (git rev-parse --abbrev-ref HEAD).Trim()
$safeBranch = ($branch -replace '[\\/:*?"<>|]', "-")

if ($env:DSM_TOOLS_PACK_DIR) {
    $downloads = $env:DSM_TOOLS_PACK_DIR
} else {
    $downloads = Join-Path $repo "download"
}
if (-not (Test-Path -LiteralPath $downloads)) {
    New-Item -ItemType Directory -Path $downloads | Out-Null
}
$out = Join-Path $downloads "DSM-Tools-$safeBranch-$sha-no-docs.zip"
if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }

git archive --format=zip -o $out HEAD -- . ":(exclude).github" ":(exclude).cursor" ":(exclude)docs" ":(exclude)*.md"
if ($LASTEXITCODE -ne 0) { throw "git archive 失败，退出码 $LASTEXITCODE" }

Write-Host "已打包：$out"
