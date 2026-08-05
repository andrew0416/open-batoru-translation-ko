$ErrorActionPreference = "Stop"

$DefaultConfig = @{
    owner = "andrew0416"
    repo = "open-batoru-translation-ko"
    branch = "main"
    languagePrefix = "ko"
    dbFileName = "translate.db"
    manifestFileName = "translate-manifest.json"
    releaseBody = "Korean translate.db update."
}

function Write-Step {
    param([string]$Message)
    Write-Host "[uploader] $Message"
}

function Read-JsonFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($content)) {
        return $null
    }

    return $content | ConvertFrom-Json
}

function Get-UploaderConfig {
    $configPath = Join-Path -Path $PSScriptRoot -ChildPath "uploader-config.json"
    $fileConfig = Read-JsonFile -Path $configPath
    $config = @{}

    foreach ($key in $DefaultConfig.Keys) {
        $value = $DefaultConfig[$key]
        if ($null -ne $fileConfig -and $null -ne $fileConfig.$key -and -not [string]::IsNullOrWhiteSpace($fileConfig.$key.ToString())) {
            $value = $fileConfig.$key.ToString()
        }
        $config[$key] = $value
    }

    return $config
}

function Get-Token {
    $tokenPath = Join-Path -Path $PSScriptRoot -ChildPath "github-token.txt"
    if (-not (Test-Path -LiteralPath $tokenPath)) {
        throw "github-token.txt file was not found. Put a GitHub personal access token in that file."
    }

    $token = (Get-Content -LiteralPath $tokenPath -Raw -Encoding UTF8).Trim()
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "github-token.txt is empty."
    }

    return $token
}

function Get-ApiHeaders {
    param([string]$Token)

    return @{
        Accept = "application/vnd.github+json"
        Authorization = "Bearer $Token"
        "X-GitHub-Api-Version" = "2022-11-28"
        "User-Agent" = "open-batoru-translation-uploader"
    }
}

function Get-Sha256 {
    param([string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-SqliteDatabase {
    param([string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 16) {
        throw "translate.db is too small to be a SQLite database."
    }

    $header = [System.Text.Encoding]::ASCII.GetString($bytes, 0, 16)
    if ($header -ne "SQLite format 3`0") {
        throw "translate.db does not look like a SQLite database."
    }
}

function Invoke-GitHubJson {
    param(
        [string]$Method,
        [string]$Uri,
        [hashtable]$Headers,
        [object]$Body = $null
    )

    if ($null -eq $Body) {
        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers
    }

    $json = $Body | ConvertTo-Json -Depth 10
    return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -Body $json -ContentType "application/json; charset=utf-8"
}

function Get-LatestRelease {
    param(
        [hashtable]$Config,
        [hashtable]$Headers
    )

    $uri = "https://api.github.com/repos/$($Config.owner)/$($Config.repo)/releases/latest"
    try {
        return Invoke-GitHubJson -Method "GET" -Uri $uri -Headers $Headers
    } catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) {
            return $null
        }
        throw
    }
}

function Get-Releases {
    param(
        [hashtable]$Config,
        [hashtable]$Headers
    )

    $uri = "https://api.github.com/repos/$($Config.owner)/$($Config.repo)/releases?per_page=100"
    try {
        return Invoke-GitHubJson -Method "GET" -Uri $uri -Headers $Headers
    } catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) {
            return @()
        }
        throw
    }
}

function New-VersionTag {
    param(
        [hashtable]$Config,
        [hashtable]$Headers
    )

    $today = (Get-Date).ToString("yyyy-MM-dd")
    $prefix = $Config.languagePrefix
    $pattern = "^$([regex]::Escape($prefix))-$([regex]::Escape($today))-(\d{2})$"
    $maxNumber = 0
    $releases = Get-Releases -Config $Config -Headers $Headers

    foreach ($release in $releases) {
        if ($release.tag_name -match $pattern) {
            $number = [int]$Matches[1]
            if ($number -gt $maxNumber) {
                $maxNumber = $number
            }
        }
    }

    return "{0}-{1}-{2:D2}" -f $prefix, $today, ($maxNumber + 1)
}

function Ensure-RepositoryInitialized {
    param(
        [hashtable]$Config,
        [hashtable]$Headers
    )

    $uri = "https://api.github.com/repos/$($Config.owner)/$($Config.repo)/contents/README.md`?ref=$($Config.branch)"
    try {
        Invoke-GitHubJson -Method "GET" -Uri $uri -Headers $Headers | Out-Null
        return
    } catch {
        if (-not ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404)) {
            throw
        }
    }

    Write-Step "initializing repository README.md..."

    $readme = @"
# open-batoru-translation-ko

Korean translation database distribution for open-batoru-translater.

Manifest URL:

https://raw.githubusercontent.com/$($Config.owner)/$($Config.repo)/$($Config.branch)/$($Config.manifestFileName)
"@

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($readme + "`n")
    $encoded = [System.Convert]::ToBase64String($bytes)
    $body = @{
        message = "Initialize translation repository"
        content = $encoded
    }

    $createUri = "https://api.github.com/repos/$($Config.owner)/$($Config.repo)/contents/README.md"
    Invoke-GitHubJson -Method "PUT" -Uri $createUri -Headers $Headers -Body $body | Out-Null
}

function Get-RemoteDbHash {
    param(
        [hashtable]$Config,
        [object]$LatestRelease,
        [hashtable]$Headers
    )

    if ($null -eq $LatestRelease) {
        return $null
    }

    $asset = $LatestRelease.assets | Where-Object { $_.name -eq $Config.dbFileName } | Select-Object -First 1
    if ($null -eq $asset) {
        return $null
    }

    $tempPath = Join-Path -Path $env:TEMP -ChildPath "open-batoru-remote-translate.db"
    if (Test-Path -LiteralPath $tempPath) {
        Remove-Item -LiteralPath $tempPath -Force
    }

    Invoke-WebRequest -Uri $asset.browser_download_url -Headers $Headers -OutFile $tempPath
    try {
        return Get-Sha256 -Path $tempPath
    } finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force
        }
    }
}

function New-Release {
    param(
        [hashtable]$Config,
        [hashtable]$Headers,
        [string]$Tag
    )

    $uri = "https://api.github.com/repos/$($Config.owner)/$($Config.repo)/releases"
    $body = @{
        tag_name = $Tag
        target_commitish = $Config.branch
        name = $Tag
        body = $Config.releaseBody
        draft = $false
        prerelease = $false
    }

    return Invoke-GitHubJson -Method "POST" -Uri $uri -Headers $Headers -Body $body
}

function Upload-ReleaseAsset {
    param(
        [hashtable]$Config,
        [object]$Release,
        [hashtable]$Headers,
        [string]$DbPath
    )

    $uploadUrl = $Release.upload_url -replace "\{\?name,label\}", ""
    $assetUrl = "$uploadUrl`?name=$($Config.dbFileName)"

    $uploadHeaders = @{
        Accept = $Headers["Accept"]
        Authorization = $Headers["Authorization"]
        "X-GitHub-Api-Version" = $Headers["X-GitHub-Api-Version"]
        "User-Agent" = $Headers["User-Agent"]
    }

    return Invoke-RestMethod -Method "POST" -Uri $assetUrl -Headers $uploadHeaders -ContentType "application/octet-stream" -InFile $DbPath
}

function Get-ManifestContent {
    param(
        [hashtable]$Config,
        [hashtable]$Headers
    )

    $uri = "https://api.github.com/repos/$($Config.owner)/$($Config.repo)/contents/$($Config.manifestFileName)`?ref=$($Config.branch)"
    try {
        return Invoke-GitHubJson -Method "GET" -Uri $uri -Headers $Headers
    } catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) {
            return $null
        }
        throw
    }
}

function Update-Manifest {
    param(
        [hashtable]$Config,
        [hashtable]$Headers,
        [string]$Tag,
        [string]$Sha256
    )

    $current = Get-ManifestContent -Config $Config -Headers $Headers
    $manifest = [ordered]@{
        version = $Tag
        url = "https://github.com/$($Config.owner)/$($Config.repo)/releases/latest/download/$($Config.dbFileName)"
        sha256 = $Sha256
    }

    $manifestJson = ($manifest | ConvertTo-Json -Depth 5) + "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($manifestJson)
    $encoded = [System.Convert]::ToBase64String($bytes)

    $body = @{
        message = "Update translate.db manifest to $Tag"
        content = $encoded
        branch = $Config.branch
    }

    if ($null -ne $current) {
        $body.sha = $current.sha
    }

    $uri = "https://api.github.com/repos/$($Config.owner)/$($Config.repo)/contents/$($Config.manifestFileName)"
    Invoke-GitHubJson -Method "PUT" -Uri $uri -Headers $Headers -Body $body | Out-Null
}

try {
    $config = Get-UploaderConfig
    $dbPath = Join-Path -Path $PSScriptRoot -ChildPath $config.dbFileName
    if (-not (Test-Path -LiteralPath $dbPath)) {
        throw "$($config.dbFileName) was not found next to this uploader."
    }

    Assert-SqliteDatabase -Path $dbPath

    $token = Get-Token
    $headers = Get-ApiHeaders -Token $token
    $localHash = Get-Sha256 -Path $dbPath

    Write-Step "target repository: $($config.owner)/$($config.repo)"
    Write-Step "local $($config.dbFileName) sha256: $localHash"
    Ensure-RepositoryInitialized -Config $config -Headers $headers

    Write-Step "checking latest GitHub release..."

    $latestRelease = Get-LatestRelease -Config $config -Headers $headers
    $remoteHash = Get-RemoteDbHash -Config $config -LatestRelease $latestRelease -Headers $headers

    if ($remoteHash -eq $localHash) {
        Write-Step "same file. No upload is needed."
        exit 0
    }

    if ($remoteHash) {
        Write-Step "remote translate.db sha256: $remoteHash"
    } else {
        Write-Step "remote $($config.dbFileName) was not found."
    }

    $tag = New-VersionTag -Config $config -Headers $headers
    Write-Step "creating release $tag..."
    $release = New-Release -Config $config -Headers $headers -Tag $tag

    Write-Step "uploading $($config.dbFileName)..."
    Upload-ReleaseAsset -Config $config -Release $release -Headers $headers -DbPath $dbPath | Out-Null

    Write-Step "updating $($config.manifestFileName)..."
    Update-Manifest -Config $config -Headers $headers -Tag $tag -Sha256 $localHash

    Write-Step "done."
    Write-Step "manifest: https://raw.githubusercontent.com/$($config.owner)/$($config.repo)/$($config.branch)/$($config.manifestFileName)"
    exit 0
} catch {
    Write-Host "[uploader] error: $($_.Exception.Message)"
    exit 1
}
