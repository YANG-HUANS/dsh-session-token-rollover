#Requires -Version 5.1
<#
.SYNOPSIS
    只靠一个 token 把仓库发布到 GitHub：建仓库 → 提交全部文件 → 建 Release 并上传 tgz → 打开发布页。

.DESCRIPTION
    本机 github.com:443 被 TLS 阻断（api.github.com 仍然可用），所以：
      - 优先 SSH 推送（需要 token 带 admin:public_key，可保留完整 git 历史与 tag）
      - 退路：Git Data API（只靠 public_repo 就够）
    两条路都不碰 github.com:443。

    注意：全新的空仓库不能直接 POST /git/blobs（会返回 409 "Git Repository is empty."），
    必须先用 Contents API 落一个文件产生首个 commit，之后 Git Data API 才可用。

.PARAMETER Token
    有 public_repo（或 repo）权限的 PAT；要 SSH 推送还需 admin:public_key。默认读 GH_TOKEN。

.PARAMETER Repo
    仓库名，默认 dsh-session-token-rollover。

.PARAMETER ApiOnly
    跳过 SSH 路径，直接用 Git Data API 提交。

.PARAMETER NoBrowser
    不自动打开浏览器。

.EXAMPLE
    $env:GH_TOKEN = 'ghp_xxx'
    ./publish-github.ps1
#>
[CmdletBinding()]
param(
    [string] $Token = $env:GH_TOKEN,
    [string] $Repo = 'dsh-session-token-rollover',
    [string] $Description = 'DSH plugin: roll a conversation into a fresh session when its token budget runs out.',
    [switch] $ApiOnly,
    [switch] $NoBrowser
)

$ErrorActionPreference = 'Continue'
Set-Location $PSScriptRoot

function Step($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Info($t) { Write-Host "    $t" }
function Warn($t) { Write-Host "    $t" -ForegroundColor Yellow }

if (-not $Token) {
    throw "缺少 token：`n    `$env:GH_TOKEN = 'ghp_xxx'   # 需要 public_repo 权限`n    ./publish-github.ps1"
}

$ApiBase = 'https://api.github.com'
$Headers = @{
    Authorization          = "Bearer $Token"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'           = $Repo
}
$version = (Get-Content (Join-Path $PSScriptRoot 'package.json') -Raw | ConvertFrom-Json).version
$repoApi = $null

function Api($method, $uri, $bodyObj) {
    $p = @{ Method = $method; Uri = $uri; Headers = $Headers }
    $p.TimeoutSec = 60
    if ($null -ne $bodyObj) {
        $p.Body = [System.Text.Encoding]::UTF8.GetBytes(($bodyObj | ConvertTo-Json -Depth 8 -Compress))
        $p.ContentType = 'application/json; charset=utf-8'
    }
    Invoke-RestMethod @p
}

# ---------------------------------------------------------------- 1. 身份
Step 'GitHub 身份'
$me = Api 'GET' "$ApiBase/user" $null
$Owner = $me.login
Info "登录为 $Owner"

# ---------------------------------------------------------------- 2. 建仓库
Step "仓库 $Owner/$Repo"
$repoApi = "$ApiBase/repos/$Owner/$Repo"
try {
    $repoInfo = Api 'GET' $repoApi $null
    Info "仓库已存在：$($repoInfo.html_url)"
}
catch {
    $body = @{ name = $Repo; private = $false; description = $Description; has_issues = $true; auto_init = $false }
    try {
        $repoInfo = Api 'POST' "$ApiBase/user/repos" $body
        Info "已创建：$($repoInfo.html_url)"
    }
    catch {
        $status = $_.Exception.Response.StatusCode.value__
        if ($status -eq 404 -or $status -eq 403) {
            throw "建仓被拒（HTTP $status）：这个 token 没有 public_repo 权限"
        }
        throw "建仓失败（HTTP $status）"
    }
}

# ---------------------------------------------------------------- 3. 推送
$pushed = $false

if (-not $ApiOnly) {
    Step '尝试 SSH 推送（保留完整历史）'
    $keyDir = Join-Path $env:TEMP "dsh-publish-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Force -Path $keyDir | Out-Null
    $keyPath = Join-Path $keyDir 'id_ed25519'
    # 用 cmd 传空口令：PowerShell 原生参数会吞掉空字符串
    & cmd.exe /c "ssh-keygen -t ed25519 -N """" -C dsh-publish-temp -f ""$keyPath""" | Out-Null
    if (Test-Path "$keyPath.pub") {
        $keyBody = @{ title = "dsh-publish-temp-$version"; key = (Get-Content "$keyPath.pub" -Raw).Trim() }
        try {
            $addedKey = Api 'POST' "$ApiBase/user/keys" $keyBody
            Info "临时公钥 id=$($addedKey.id)"
            try {
                git remote remove origin 2>$null | Out-Null
                git remote add origin "git@github.com:$Owner/$Repo.git"
                $env:GIT_SSH_COMMAND = "ssh -i `"$keyPath`" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
                git push -u origin main --tags
                if ($LASTEXITCODE -ne 0) {
                    Warn 'github.com:22 不通，改走 ssh.github.com:443'
                    git remote set-url origin "ssh://git@ssh.github.com:443/$Owner/$Repo.git"
                    $env:GIT_SSH_COMMAND = "ssh -i `"$keyPath`" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -p 443"
                    git push -u origin main --tags
                }
                if ($LASTEXITCODE -eq 0) { $pushed = $true; Info 'SSH 推送成功' }
                else { Warn 'SSH 推送失败，转用 Git Data API' }
            }
            finally {
                try { Api 'DELETE' "$ApiBase/user/keys/$($addedKey.id)" $null | Out-Null; Info '临时公钥已撤销' }
                catch { Warn "撤销临时公钥失败，请手动删除 id=$($addedKey.id)" }
            }
        }
        catch { Warn '没有 admin:public_key 权限，转用 Git Data API' }
    }
    Remove-Item Env:\GIT_SSH_COMMAND -ErrorAction SilentlyContinue
    Remove-Item $keyDir -Recurse -Force -ErrorAction SilentlyContinue
}

if (-not $pushed) {
    Step '用 Git Data API 提交（不需要 git 传输）'
    $files = @(git ls-files)
    if ($files.Count -eq 0) { throw 'git ls-files 为空：确认在仓库根目录运行' }

    # 空仓库不能直接建 blob，先用 Contents API 落一个文件
    $parent = $null
    try {
        $ref = Api 'GET' "$repoApi/git/ref/heads/main" $null
        $parent = $ref.object.sha
        Info "已有 main：$($parent.Substring(0, 7))"
    }
    catch {
        Info '空仓库：先用 Contents API 建立首个提交'
        $bootPath = '.gitignore'
        $bootB64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $PSScriptRoot $bootPath)))
        $boot = Api 'PUT' "$repoApi/contents/$bootPath" @{
            message = "chore: bootstrap"; content = $bootB64; branch = 'main'
        }
        $parent = $boot.commit.sha
        Info "bootstrap：$($parent.Substring(0, 7))"
    }

    $treeItems = New-Object System.Collections.ArrayList
    foreach ($rel in $files) {
        $abs = Join-Path $PSScriptRoot ($rel -replace '/', '\')
        if (-not (Test-Path $abs)) { Warn "跳过不存在的文件 $rel"; continue }
        $b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($abs))
        $blob = Api 'POST' "$repoApi/git/blobs" @{ content = $b64; encoding = 'base64' }
        [void]$treeItems.Add(@{ path = $rel; mode = '100644'; type = 'blob'; sha = $blob.sha })
        Info "blob $rel"
    }
    $tree = Api 'POST' "$repoApi/git/trees" @{ tree = @($treeItems) }
    $commit = Api 'POST' "$repoApi/git/commits" @{ message = "release: v$version"; tree = $tree.sha; parents = @($parent) }
    Api 'PATCH' "$repoApi/git/refs/heads/main" @{ sha = $commit.sha; force = $true } | Out-Null
    Info "已提交 main：$($commit.sha.Substring(0, 7))（$($files.Count) 个文件）"
}

# ---------------------------------------------------------------- 4. Release
Step "Release v$version"
$release = $null
try {
    $release = Api 'POST' "$repoApi/releases" @{
        tag_name         = "v$version"
        target_commitish = 'main'
        name             = "v$version"
        body             = [string](Get-Content (Join-Path $PSScriptRoot 'CHANGELOG.md') -Raw -Encoding UTF8)
        draft            = $false
        prerelease       = $false
    }
    Info "Release：$($release.html_url)"
}
catch {
    $status = $_.Exception.Response.StatusCode.value__
    Warn "建 Release 失败（HTTP $status），尝试读取已存在的 release"
    try { $release = Api 'GET' "$repoApi/releases/tags/v$version" $null } catch { Warn '读不到已有 release' }
}

# ---------------------------------------------------------------- 5. 附件
$tgz = Get-ChildItem (Join-Path $PSScriptRoot 'dist') -Filter *.tgz -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
if ($release -and $tgz) {
    Step "上传附件 $($tgz.Name)"
    $uploadUrl = ($release.upload_url -replace '\{\?name,label\}', '') + "?name=$([uri]::EscapeDataString($tgz.Name))"
    try {
        Invoke-RestMethod -Method Post -Uri $uploadUrl -Headers $Headers -ContentType 'application/octet-stream' -InFile $tgz.FullName | Out-Null
        Info '附件已上传'
    }
    catch { Warn "附件上传失败：$($_.Exception.Message)" }
}
elseif (-not $release) { Warn '没有 release，跳过附件' }
else { Warn 'dist 里没有 tgz，跳过附件' }

# ---------------------------------------------------------------- 6. 页面
$page = "https://github.com/$Owner/$Repo/releases/tag/v$version"
if (-not $NoBrowser) {
    Step '打开发布页'
    try { Start-Process $page; Info $page } catch { Warn "打不开浏览器：$($_.Exception.Message)" }
}
else { Info $page }