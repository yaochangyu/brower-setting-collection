[CmdletBinding()]
param(
    [string]$ScriptUrl = "https://github.com/yaochangyu/brower-setting-collection/blob/master/chrome-settings-collector.ps1",
    [string]$DownloadDirectory = (Join-Path $env:TEMP "chrome-settings-collector"),
    [string]$UserDataPath,
    [string[]]$Profiles,
    [string[]]$Origin,
    [switch]$NoExport,
    [string]$Output,
    [switch]$IncludeRawFiles
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$launcherRoot = if ($PSScriptRoot) { $PSScriptRoot } elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }

function Resolve-CollectorDownloadUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) {
        throw "Invalid ScriptUrl: $Url"
    }

    if ($uri.Host -ieq "raw.githubusercontent.com") {
        return $uri.AbsoluteUri
    }

    if ($uri.Host -iin @("github.com", "www.github.com")) {
        $segments = $uri.AbsolutePath.Trim("/").Split("/")
        if ($segments.Length -lt 5 -or $segments[2] -ine "blob") {
            throw "ScriptUrl must be a GitHub blob URL or raw.githubusercontent.com URL."
        }

        $owner = $segments[0]
        $repo = $segments[1]
        $branch = $segments[3]
        $path = [string]::Join("/", $segments[4..($segments.Length - 1)])
        return "https://raw.githubusercontent.com/$owner/$repo/$branch/$path"
    }

    throw "ScriptUrl must be a GitHub blob URL or raw.githubusercontent.com URL."
}

$downloadUrl = Resolve-CollectorDownloadUrl -Url $ScriptUrl
$localScriptPath = Join-Path $DownloadDirectory "chrome-settings-collector.ps1"

New-Item -ItemType Directory -Path $DownloadDirectory -Force | Out-Null
Invoke-WebRequest -Uri $downloadUrl -OutFile $localScriptPath
Unblock-File -Path $localScriptPath -ErrorAction SilentlyContinue

$collectorArgs = @{}

if ($PSBoundParameters.ContainsKey("UserDataPath")) {
    $collectorArgs["UserDataPath"] = $UserDataPath
}

if ($PSBoundParameters.ContainsKey("Profiles")) {
    $collectorArgs["Profiles"] = $Profiles
}

if ($PSBoundParameters.ContainsKey("Origin")) {
    $collectorArgs["Origin"] = $Origin
}

if ($NoExport) {
    $collectorArgs["NoExport"] = $true
}

if ($PSBoundParameters.ContainsKey("Output")) {
    $collectorArgs["Output"] = $Output
} elseif (-not $NoExport) {
    $collectorArgs["Output"] = Join-Path $launcherRoot "export"
}

if ($IncludeRawFiles) {
    $collectorArgs["IncludeRawFiles"] = $true
}

& $localScriptPath @collectorArgs
