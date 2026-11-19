#Requires -Version 5.1
<#
.SYNOPSIS
    发布 dsh-session-token-rollover：打包 → 提交 → 建 GitHub 仓库 → 推送。

.DESCRIPTION
    1. `npm pack` 出 dist/*.tgz（可直接挂到 GitHub Release，或用 file: 依赖安装）
    2. 初始化 git 仓库并提交（已 init 过就只提交增量）
    3. 有 token 时用 API 建仓库并推送 main 与 tag；没有 token 时打印剩下两条手动命令
    4. 第一版提交用的是占位作者，脚本会自动改成你自己的 git 身份

.PARAMETER Owner
    GitHub 用户名或组织名。

.PARAMETER Repo
    仓库名，默认 dsh-session-token-rollover。

.PARAMETER Visibility
    public / private。

.PARAMETER Token
    GitHub PAT（需要 repo 权限）。默认读环境变量 GH_TOKEN。不传就停在"请手动建仓库并 push"。

.PARAMETER SkipPack
    跳过 npm pack。

.EXAMPLE
    ./publish.ps1 -Owner octocat

.EXAMPLE
    $env:GH_TOKEN = 'ghp_xxx'; ./publish.ps1 -Owner octocat -Visibility public
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $Owner,
    [string] $Repo = 'dsh-session-token-rollover',
    [ValidateSet('public', 'private')][string] $Visibility = 'public',
    [string] $Token = $env:GH_TOKEN,
    [switch] $SkipPack
)

# 原生命令（npm / git）把进度和信息写到 stderr，PS 5.1 会当成错误记录；
# 这里用 Continue，关键步骤手动检查 $LASTEXITCODE。
$ErrorActionPreference = 'Continue'
Set-Location $PSScriptRoot

function Step($text) { Write-Host "`n=== $text ===" -ForegroundColor Cyan }
function Info($text) { Write-Host "    $text" }
function Warn($text) { Write-Host "    $text" -ForegroundColor Yellow }

# ---------------------------------------------------------------- 0. 身份
Step 'git 身份'
$email = (git config user.email) 2>$null
$name = (git config user.name) 2>$null
if (-not $email -or -not $name -or $email -eq 'noreply@example.invalid') {
    throw "先设置 git 身份：`n    git config --global user.name `"你的名字`"`n    git config --global user.email `"you@example.com`""
}
Info "name  = $name"
Info "email = $email"

$version = (Get-Content (Join-Path $PSScriptRoot 'package.json') -Raw | ConvertFrom-Json).version

# ---------------------------------------------------------------- 1. 打包
if (-not $SkipPack) {
    Step 'npm pack'
    $dist = Join-Path $PSScriptRoot 'dist'
    New-Item -ItemType Directory -Force -Path $dist | Out-Null
    npm pack --pack-destination $dist 2>$null | Out-Null
    $tgz = Get-ChildItem $dist -Filter *.tgz -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
    if (-not $tgz) { throw 'npm pack 失败：dist 里没有生成 tgz' }
    Info "已打包：dist/$($tgz.Name)"
}

# ---------------------------------------------------------------- 2. 提交
Step 'git 提交'
if (-not (Test-Path (Join-Path $PSScriptRoot '.git'))) {
    git init -b main | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'git init 失败' }
    Info '已初始化仓库（main）'
}
git add -A
if (git status --porcelain) {
    git commit -m "release: v$version" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'git commit 失败' }
    Info "已提交：release: v$version"
}
else {
    Info '工作区干净'
}

# 第一版提交是占位作者，这里顺手改成当前 git 身份
if ((git log -1 --format=%ae) -eq 'noreply@example.invalid') {
    git commit --amend --reset-author --no-edit | Out-Null
    Info '已把占位作者替换成你的 git 身份'
}

# ---------------------------------------------------------------- 3. 建仓库
Step "GitHub 仓库 $Owner/$Repo"
$repoUrl = "https://github.com/$Owner/$Repo"
if (-not $Token) {
    Warn '没有 GH_TOKEN：请在网页上建一个空仓库（不要勾 README / .gitignore / LICENSE）'
    Warn '建好后执行下面两条命令即可完成发布'
    Write-Host ""
    Write-Host "    git remote add origin $repoUrl.git" -ForegroundColor Green
    Write-Host "    git push -u origin main --tags" -ForegroundColor Green
    Write-Host ""
    exit 0
}

$headers = @{
    Authorization          = "Bearer $Token"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'           = 'dsh-session-token-rollover'
}
$body = @{
    name        = $Repo
    private     = ($Visibility -eq 'private')
    description = 'DSH plugin: roll a conversation into a fresh session when its token budget runs out.'
    has_issues  = $true
} | ConvertTo-Json

try {
    $created = Invoke-RestMethod -Method Post -Uri 'https://api.github.com/user/repos' -Headers $headers -Body $body -ContentType 'application/json'
    Info "已创建：$($created.html_url)"
}
catch {
    $status = $_.Exception.Response.StatusCode.value__
    if ($status -eq 422) { Warn '仓库已存在，直接推送' }
    else {
        Warn "建仓失败（HTTP $status）：请检查 token 是否有 repo 权限"
        throw
    }
}

# ---------------------------------------------------------------- 4. 推送
Step '推送到 GitHub'
git remote remove origin 2>$null | Out-Null
git remote add origin "$repoUrl.git"
git tag -f "v$version" | Out-Null

# token 只走命令行，不写进 .git/config
$pushUrl = "https://x-access-token:$Token@github.com/$Owner/$Repo.git"
git push $pushUrl "HEAD:main"
if ($LASTEXITCODE -ne 0) {
    Warn '推送被拒（远端可能已有 README 等提交）'
    Warn "先执行 git pull --rebase $repoUrl.git main，再重跑本脚本"
    exit 1
}
git push $pushUrl "refs/tags/v$version"

Info "完成：$repoUrl"
Info "Release 建议：用 tag v$version 新建 release，附件用 dist/*.tgz"