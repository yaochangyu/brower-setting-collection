[CmdletBinding()]
param(
    [string]$UserDataPath = (Join-Path $env:LOCALAPPDATA "Google\Chrome\User Data"),
    [string[]]$Profiles,
    [string[]]$Origin,
    [switch]$NoExport,
    [string]$Output,
    [switch]$IncludeRawFiles
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:CollectorRoot = if ($PSScriptRoot) { $PSScriptRoot } elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
$script:ConvertFromJsonSupportsDepth = $null
$script:PwshPath = $null
$script:LegacyJsonParserReady = $false

function ConvertTo-CompatJsonObject {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $result[[string]$key] = ConvertTo-CompatJsonObject -Value $Value[$key]
        }

        return [pscustomobject]$result
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        return @($Value | ForEach-Object { ConvertTo-CompatJsonObject -Value $_ })
    }

    return $Value
}

function Get-PwshPath {
    if ($null -eq $script:PwshPath) {
        $command = Get-Command pwsh.exe -ErrorAction SilentlyContinue
        $script:PwshPath = if ($command) { $command.Source } else { "" }
    }

    if ([string]::IsNullOrWhiteSpace($script:PwshPath)) {
        return $null
    }

    return $script:PwshPath
}

function ConvertTo-PsSingleQuotedLiteral {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return "'" + ($Value -replace "'", "''") + "'"
}

function Read-JsonFileWithPwsh {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $pwshPath = Get-PwshPath
    if (-not $pwshPath) {
        throw "PowerShell 7 (pwsh.exe) is not available for JSON fallback parsing."
    }

    $tempPath = Join-Path $env:TEMP ("copilot-json-" + [guid]::NewGuid().ToString("N") + ".clixml")
    $literalSourcePath = ConvertTo-PsSingleQuotedLiteral -Value $Path
    $literalTempPath = ConvertTo-PsSingleQuotedLiteral -Value $tempPath
    $command = "& { `$obj = Get-Content -LiteralPath $literalSourcePath -Raw | ConvertFrom-Json -Depth 100; `$obj | Export-Clixml -LiteralPath $literalTempPath }"

    try {
        & $pwshPath -NoProfile -Command $command | Out-Null
        if (-not (Test-Path -LiteralPath $tempPath -PathType Leaf)) {
            throw "pwsh fallback did not produce CLIXML output."
        }

        return (Import-Clixml -LiteralPath $tempPath)
    } finally {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
}

function ConvertFrom-JsonCompat {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Json
    )

    if ($null -eq $script:ConvertFromJsonSupportsDepth) {
        $script:ConvertFromJsonSupportsDepth = (Get-Command ConvertFrom-Json).Parameters.ContainsKey("Depth")
    }

    if ($script:ConvertFromJsonSupportsDepth) {
        return ($Json | ConvertFrom-Json -Depth 100)
    }

    if (-not $script:LegacyJsonParserReady) {
        Add-Type -AssemblyName System.Web.Extensions
        $script:LegacyJsonParserReady = $true
    }

    $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $serializer.MaxJsonLength = [int]::MaxValue
    $serializer.RecursionLimit = 1024
    return (ConvertTo-CompatJsonObject -Value ($serializer.DeserializeObject($Json)))
}

function Get-RequiredFilePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file not found: $Path"
    }

    return $Path
}

function Read-JsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        return (ConvertFrom-JsonCompat -Json (Get-Content -LiteralPath $Path -Raw))
    } catch {
        try {
            return (Read-JsonFileWithPwsh -Path $Path)
        } catch {
            throw "Failed to parse JSON file '$Path'. Close Chrome and try again. $($_.Exception.Message)"
        }
    }
}

function Get-ObjectProperty {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }

        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return $property.Value
    }

    return $null
}

function Get-NestedValue {
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string[]]$Path
    )

    $current = $Object
    foreach ($segment in $Path) {
        if ($null -eq $current) {
            return $null
        }

        $current = Get-ObjectProperty -Object $current -Name $segment
    }

    return $current
}

function Get-PropertyCount {
    param(
        [AllowNull()]
        [object]$Object
    )

    if ($null -eq $Object) {
        return 0
    }

    if ($Object -is [System.Collections.IDictionary]) {
        return $Object.Count
    }

    if ($Object -is [System.Management.Automation.PSCustomObject]) {
        return @($Object.PSObject.Properties).Count
    }

    if ($Object -is [System.Collections.IEnumerable] -and -not ($Object -is [string])) {
        return @($Object).Count
    }

    return 0
}

function Resolve-CookieControlsMode {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    switch ([string]$Value) {
        "0" { return "0 (raw enum: allow or no special restriction)" }
        "1" { return "1 (raw enum: limit third-party cookies in Incognito)" }
        "2" { return "2 (raw enum: block third-party cookies)" }
        "3" { return "3 (raw enum: Chrome-specific cookie restriction mode)" }
        default { return "$Value (raw enum: unknown mapping)" }
    }
}

function Get-RiskLevelRank {
    param(
        [AllowNull()]
        [string]$Level
    )

    switch ($Level) {
        "high" { return 3 }
        "medium" { return 2 }
        default { return 1 }
    }
}

function Get-HigherRiskLevel {
    param(
        [AllowNull()]
        [string]$CurrentLevel,

        [AllowNull()]
        [string]$CandidateLevel
    )

    if ((Get-RiskLevelRank -Level $CandidateLevel) -gt (Get-RiskLevelRank -Level $CurrentLevel)) {
        return $CandidateLevel
    }

    return $(if ([string]::IsNullOrWhiteSpace($CurrentLevel)) { "low" } else { $CurrentLevel })
}

function Get-LocalStorageRiskAssessment {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Profile,

        [int]$EnterprisePolicyKeyCount = 0
    )

    $riskLevel = "low"
    $findings = New-Object System.Collections.Generic.List[string]

    if ($EnterprisePolicyKeyCount -gt 0) {
        $riskLevel = Get-HigherRiskLevel -CurrentLevel $riskLevel -CandidateLevel "high"
        $findings.Add("Enterprise policy keys were detected at the global Chrome level ($EnterprisePolicyKeyCount).")
    }

    if ($Profile.clearBrowsingDataSelection.cookies -eq $true) {
        $riskLevel = Get-HigherRiskLevel -CurrentLevel $riskLevel -CandidateLevel "medium"
        $findings.Add("Clear browsing data last had cookies/site data selected.")
    }

    if ($Profile.clearBrowsingDataSelection.siteSettings -eq $true) {
        $riskLevel = Get-HigherRiskLevel -CurrentLevel $riskLevel -CandidateLevel "medium"
        $findings.Add("Clear browsing data last had site settings selected.")
    }

    if ($Profile.clearBrowsingDataSelection.hostedAppsData -eq $true) {
        $riskLevel = Get-HigherRiskLevel -CurrentLevel $riskLevel -CandidateLevel "medium"
        $findings.Add("Clear browsing data last had hosted app data selected.")
    }

    if ($Profile.cookieControlsModeRaw -eq 2) {
        $riskLevel = Get-HigherRiskLevel -CurrentLevel $riskLevel -CandidateLevel "medium"
        $findings.Add("cookie_controls_mode indicates blocking third-party cookies.")
    }

    if ($Profile.blockThirdPartyCookies -eq $true) {
        $riskLevel = Get-HigherRiskLevel -CurrentLevel $riskLevel -CandidateLevel "medium"
        $findings.Add("block_third_party_cookies is enabled.")
    }

    if ($Profile.exitType -and $Profile.exitType -ne "Normal") {
        $riskLevel = Get-HigherRiskLevel -CurrentLevel $riskLevel -CandidateLevel "medium"
        $findings.Add("Profile exit_type was '$($Profile.exitType)'.")
    }

    if ($Profile.exitedCleanly -eq $false) {
        $riskLevel = Get-HigherRiskLevel -CurrentLevel $riskLevel -CandidateLevel "medium"
        $findings.Add("Profile reports exited_cleanly=false.")
    }

    if ($findings.Count -eq 0) {
        $findings.Add("No clear automatic localStorage cleanup signal was found in collected settings.")
    }

    $summary = switch ($riskLevel) {
        "high" { "High risk signals were found. Investigate policy and per-site storage evidence first." }
        "medium" { "Some settings may affect site data retention or cross-site behavior, but they do not prove automatic localStorage deletion." }
        default { "No strong signal suggests automatic localStorage deletion in collected settings." }
    }

    return [pscustomobject][ordered]@{
        riskLevel = $riskLevel
        summary = $summary
        findings = @($findings)
        signals = [pscustomobject][ordered]@{
            enterprisePolicyKeyCount = $EnterprisePolicyKeyCount
            clearBrowsingDataCookiesSelected = $Profile.clearBrowsingDataSelection.cookies
            clearBrowsingDataSiteSettingsSelected = $Profile.clearBrowsingDataSelection.siteSettings
            clearBrowsingDataHostedAppsDataSelected = $Profile.clearBrowsingDataSelection.hostedAppsData
            cookieControlsModeRaw = $Profile.cookieControlsModeRaw
            blockThirdPartyCookies = $Profile.blockThirdPartyCookies
            exitType = $Profile.exitType
            exitedCleanly = $Profile.exitedCleanly
        }
    }
}

function ConvertTo-OriginTarget {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Origin
    )

    if ([string]::IsNullOrWhiteSpace($Origin)) {
        throw "Origin cannot be empty."
    }

    $uri = $null
    if (-not [System.Uri]::TryCreate($Origin, [System.UriKind]::Absolute, [ref]$uri)) {
        throw "Origin must be an absolute URI, for example: https://example.com"
    }

    if ($uri.Scheme -notin @("http", "https")) {
        throw "Origin scheme must be http or https: $Origin"
    }

    if (-not [string]::IsNullOrWhiteSpace($uri.AbsolutePath) -and $uri.AbsolutePath -ne "/") {
        throw "Origin must not include a path: $Origin"
    }

    if (-not [string]::IsNullOrWhiteSpace($uri.Query) -or -not [string]::IsNullOrWhiteSpace($uri.Fragment)) {
        throw "Origin must not include query string or fragment: $Origin"
    }

    $normalizedOrigin = $uri.GetComponents([System.UriComponents]::SchemeAndServer, [System.UriFormat]::UriEscaped).ToLowerInvariant()
    $portToken = if ($uri.IsDefaultPort) { "0" } else { [string]$uri.Port }

    return [pscustomobject][ordered]@{
        origin = $normalizedOrigin
        scheme = $uri.Scheme.ToLowerInvariant()
        host = $uri.Host.ToLowerInvariant()
        port = if ($uri.IsDefaultPort) { $null } else { $uri.Port }
        authority = $uri.Authority.ToLowerInvariant()
        indexedDbPrefix = ("{0}_{1}_{2}" -f $uri.Scheme.ToLowerInvariant(), $uri.Host.ToLowerInvariant(), $portToken)
        searchTokens = @(
            $normalizedOrigin
            $uri.Host.ToLowerInvariant()
            $uri.Authority.ToLowerInvariant()
        ) | Sort-Object -Unique
    }
}

function Find-MatchingExceptionKeys {
    param(
        [AllowNull()]
        [object]$Exceptions,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$Target
    )

    if ($null -eq $Exceptions) {
        return @()
    }

    $matches = New-Object System.Collections.Generic.List[string]
    foreach ($property in $Exceptions.PSObject.Properties) {
        $name = [string]$property.Name
        $lowerName = $name.ToLowerInvariant()
        if ($lowerName.Contains($Target.origin) -or $lowerName.Contains($Target.host) -or $lowerName.Contains($Target.authority)) {
            $matches.Add($name)
        }
    }

    return @($matches | Sort-Object -Unique)
}

function Get-OriginExceptionMatches {
    param(
        [AllowNull()]
        [object]$Preferences,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$Target
    )

    $exceptionRoot = Get-NestedValue -Object $Preferences -Path @("profile", "content_settings", "exceptions")
    $categories = @(
        "cookies",
        "cookie_controls_metadata",
        "durable_storage",
        "legacy_cookie_access",
        "legacy_cookie_scope"
    )

    $matches = foreach ($category in $categories) {
        $categoryExceptions = Get-ObjectProperty -Object $exceptionRoot -Name $category
        $keys = @(Find-MatchingExceptionKeys -Exceptions $categoryExceptions -Target $Target)
        if ($keys.Count -gt 0) {
            [pscustomobject][ordered]@{
                category = $category
                keys = $keys
            }
        }
    }

    return @($matches)
}

function Test-FileContainsToken {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string[]]$Tokens
    )

    $fileInfo = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($fileInfo.Length -gt 16MB) {
        return $false
    }

    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
    } catch [System.IO.IOException] {
        return $false
    } catch [System.UnauthorizedAccessException] {
        return $false
    }

    $asciiText = [System.Text.Encoding]::ASCII.GetString($bytes)
    foreach ($token in $Tokens) {
        if (-not [string]::IsNullOrWhiteSpace($token) -and $asciiText.IndexOf($token, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }

    return $false
}

function Get-LevelDbOriginEvidence {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StoragePath,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$Target
    )

    if (-not (Test-Path -LiteralPath $StoragePath -PathType Container)) {
        return [pscustomobject][ordered]@{
            storagePath = $StoragePath
            exists = $false
            scanMethod = "ascii-token-scan"
            scannedFileCount = 0
            matchedFiles = @()
        }
    }

    $candidateFiles = @(
        Get-ChildItem -LiteralPath $StoragePath -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @(".ldb", ".log") -or $_.Name -in @("LOG", "CURRENT") } |
            Select-Object -First 60
    )

    $matchedFiles = New-Object System.Collections.Generic.List[string]
    foreach ($file in $candidateFiles) {
        if (Test-FileContainsToken -Path $file.FullName -Tokens $Target.searchTokens) {
            $matchedFiles.Add($file.FullName)
        }
    }

    return [pscustomobject][ordered]@{
        storagePath = $StoragePath
        exists = $true
        scanMethod = "ascii-token-scan"
        scannedFileCount = $candidateFiles.Count
        matchedFiles = @($matchedFiles | Sort-Object -Unique)
    }
}

function Get-IndexedDbOriginEvidence {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IndexedDbPath,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$Target
    )

    if (-not (Test-Path -LiteralPath $IndexedDbPath -PathType Container)) {
        return [pscustomobject][ordered]@{
            storagePath = $IndexedDbPath
            exists = $false
            scanMethod = "directory-name-match"
            matchedPaths = @()
        }
    }

    $matchedPaths = @(
        Get-ChildItem -LiteralPath $IndexedDbPath -Directory -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name.ToLowerInvariant().Contains($Target.indexedDbPrefix) -or
                $_.Name.ToLowerInvariant().Contains($Target.host)
            } |
            Select-Object -ExpandProperty FullName
    )

    return [pscustomobject][ordered]@{
        storagePath = $IndexedDbPath
        exists = $true
        scanMethod = "directory-name-match"
        matchedPaths = @($matchedPaths | Sort-Object -Unique)
    }
}

function Get-OriginRiskImpact {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$BaseRiskAssessment,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$MatchedExceptions,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$LocalStorageEvidence,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$IndexedDbEvidence,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$SessionStorageEvidence
    )

    $hasDirectEvidence =
        @($LocalStorageEvidence.matchedFiles).Count -gt 0 -or
        @($IndexedDbEvidence.matchedPaths).Count -gt 0 -or
        @($SessionStorageEvidence.matchedFiles).Count -gt 0

    $hasExceptionMatches = @($MatchedExceptions).Count -gt 0
    $riskLevel = $BaseRiskAssessment.riskLevel

    if ((-not $hasDirectEvidence) -and (-not $hasExceptionMatches) -and $BaseRiskAssessment.riskLevel -eq "low") {
        $riskLevel = "medium"
    }

    $summary = if ($hasDirectEvidence) {
        "Direct storage evidence was found for the requested origin."
    } elseif ($hasExceptionMatches) {
        "No direct storage evidence was found, but matching site setting exceptions exist for the requested origin."
    } else {
        "No direct origin-specific storage evidence was found with the current heuristic scan."
    }

    return [pscustomobject][ordered]@{
        riskLevel = $riskLevel
        summary = $summary
        hasDirectEvidence = $hasDirectEvidence
        hasExceptionMatches = $hasExceptionMatches
    }
}

function Get-OriginCheckSummary {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfileRoot,

        [AllowNull()]
        [object]$Preferences,

        [Parameter(Mandatory = $true)]
        [string[]]$Origins,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$BaseRiskAssessment
    )

    $checks = foreach ($origin in $Origins) {
        $target = ConvertTo-OriginTarget -Origin $origin
        $matchedExceptions = @(Get-OriginExceptionMatches -Preferences $Preferences -Target $target)
        $localStorageEvidence = Get-LevelDbOriginEvidence -StoragePath (Join-Path $ProfileRoot "Local Storage\leveldb") -Target $target
        $indexedDbEvidence = Get-IndexedDbOriginEvidence -IndexedDbPath (Join-Path $ProfileRoot "IndexedDB") -Target $target
        $sessionStorageEvidence = Get-LevelDbOriginEvidence -StoragePath (Join-Path $ProfileRoot "Session Storage") -Target $target
        $riskImpact = Get-OriginRiskImpact -BaseRiskAssessment $BaseRiskAssessment -MatchedExceptions $matchedExceptions -LocalStorageEvidence $localStorageEvidence -IndexedDbEvidence $indexedDbEvidence -SessionStorageEvidence $sessionStorageEvidence

        $notes = New-Object System.Collections.Generic.List[string]
        if (@($matchedExceptions).Count -gt 0) {
            $notes.Add("Matching content setting exceptions were found for this origin.")
        }

        if (@($indexedDbEvidence.matchedPaths).Count -gt 0) {
            $notes.Add("IndexedDB directories matched this origin by directory name.")
        }

        if ((@($localStorageEvidence.matchedFiles).Count -eq 0) -and (@($sessionStorageEvidence.matchedFiles).Count -eq 0)) {
            $notes.Add("Local Storage and Session Storage use LevelDB, so origin evidence is heuristic and may not prove absence.")
        }

        [pscustomobject][ordered]@{
            origin = $target.origin
            profileDirectory = (Split-Path -Leaf $ProfileRoot)
            matchedExceptions = @($matchedExceptions)
            localStorageEvidence = $localStorageEvidence
            indexedDbEvidence = $indexedDbEvidence
            sessionStorageEvidence = $sessionStorageEvidence
            riskImpact = $riskImpact
            notes = @($notes)
        }
    }

    return @($checks)
}

function Resolve-ExtensionState {
    param(
        [AllowNull()]
        [object]$DisableReasons
    )

    if ($null -eq $DisableReasons -or $DisableReasons -eq "") {
        return "enabled-or-component"
    }

    try {
        if ([int]$DisableReasons -eq 0) {
            return "enabled"
        }

        return "disabled"
    } catch {
        return "unknown"
    }
}

function Get-ExtensionSettingsSourcePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfileRoot
    )

    $securePreferencesPath = Join-Path $ProfileRoot "Secure Preferences"
    if (Test-Path -LiteralPath $securePreferencesPath -PathType Leaf) {
        return $securePreferencesPath
    }

    $preferencesPath = Join-Path $ProfileRoot "Preferences"
    if (Test-Path -LiteralPath $preferencesPath -PathType Leaf) {
        return $preferencesPath
    }

    return $null
}

function Get-ExtensionDirectoryIndex {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfileRoot
    )

    $index = @{}
    $extensionsRoot = Join-Path $ProfileRoot "Extensions"
    if (-not (Test-Path -LiteralPath $extensionsRoot -PathType Container)) {
        return [pscustomobject]@{
            rootPath = $extensionsRoot
            byId = $index
        }
    }

    foreach ($extensionDirectory in Get-ChildItem -LiteralPath $extensionsRoot -Directory) {
        $versions = @()
        foreach ($versionDirectory in Get-ChildItem -LiteralPath $extensionDirectory.FullName -Directory -ErrorAction SilentlyContinue) {
            $manifestPath = Join-Path $versionDirectory.FullName "manifest.json"
            $versions += [pscustomobject]@{
                version = $versionDirectory.Name
                path = $versionDirectory.FullName
                manifestPath = if (Test-Path -LiteralPath $manifestPath -PathType Leaf) { $manifestPath } else { $null }
            }
        }

        $index[$extensionDirectory.Name] = @($versions | Sort-Object version -Descending)
    }

    return [pscustomobject]@{
        rootPath = $extensionsRoot
        byId = $index
    }
}

function Get-ManifestInfoFromFile {
    param(
        [AllowNull()]
        [string]$ManifestPath
    )

    if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
        return $null
    }

    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        return $null
    }

    try {
        return (ConvertFrom-JsonCompat -Json (Get-Content -LiteralPath $ManifestPath -Raw))
    } catch {
        try {
            return (Read-JsonFileWithPwsh -Path $ManifestPath)
        } catch {
            return $null
        }
    }
}

function Get-ExtensionSummaries {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfileRoot
    )

    $settingsSourcePath = Get-ExtensionSettingsSourcePath -ProfileRoot $ProfileRoot
    $settingsJson = $null
    if ($settingsSourcePath) {
        $settingsJson = Read-JsonFile -Path $settingsSourcePath
    }

    $extensionSettings = Get-NestedValue -Object $settingsJson -Path @("extensions", "settings")
    $directoryIndex = Get-ExtensionDirectoryIndex -ProfileRoot $ProfileRoot
    $allIds = New-Object System.Collections.Generic.HashSet[string]

    if ($null -ne $extensionSettings) {
        foreach ($property in $extensionSettings.PSObject.Properties) {
            [void]$allIds.Add($property.Name)
        }
    }

    foreach ($extensionId in $directoryIndex.byId.Keys) {
        [void]$allIds.Add($extensionId)
    }

    $items = foreach ($extensionId in ($allIds | Sort-Object)) {
        $setting = $null
        if ($null -ne $extensionSettings) {
            $setting = Get-ObjectProperty -Object $extensionSettings -Name $extensionId
        }

        $fileVersions = @()
        if ($directoryIndex.byId.ContainsKey($extensionId)) {
            $fileVersions = @($directoryIndex.byId[$extensionId])
        }

        $preferredFileVersion = if ($fileVersions.Count -gt 0) { $fileVersions[0] } else { $null }
        $manifest = Get-ObjectProperty -Object $setting -Name "manifest"
        if ($null -eq $manifest -and $null -ne $preferredFileVersion) {
            $manifest = Get-ManifestInfoFromFile -ManifestPath $preferredFileVersion.manifestPath
        }

        $pathValue = Get-ObjectProperty -Object $setting -Name "path"
        $resolvedPath = $null
        if (-not [string]::IsNullOrWhiteSpace($pathValue)) {
            if ([System.IO.Path]::IsPathRooted($pathValue)) {
                $resolvedPath = $pathValue
            } else {
                $resolvedPath = Join-Path $ProfileRoot "Extensions\$pathValue"
            }
        } elseif ($null -ne $preferredFileVersion) {
            $resolvedPath = $preferredFileVersion.path
        }

        $disableReasons = Get-ObjectProperty -Object $setting -Name "disable_reasons"
        [pscustomobject][ordered]@{
            id = $extensionId
            name = (Get-ObjectProperty -Object $manifest -Name "name")
            description = (Get-ObjectProperty -Object $manifest -Name "description")
            version = if ($null -ne $manifest) { Get-ObjectProperty -Object $manifest -Name "version" } elseif ($null -ne $preferredFileVersion) { $preferredFileVersion.version } else { $null }
            state = (Resolve-ExtensionState -DisableReasons $disableReasons)
            disableReasonsRaw = $disableReasons
            fromWebStore = (Get-ObjectProperty -Object $setting -Name "from_webstore")
            installLocation = (Get-ObjectProperty -Object $setting -Name "location")
            path = $resolvedPath
            settingsSourcePath = $settingsSourcePath
            manifestPath = if ($null -ne $preferredFileVersion) { $preferredFileVersion.manifestPath } else { $null }
            permissions = @(
                if ($null -ne $manifest) {
                    @(Get-ObjectProperty -Object $manifest -Name "permissions")
                }
            )
            hostPermissions = @(
                if ($null -ne $manifest) {
                    @(Get-ObjectProperty -Object $manifest -Name "host_permissions")
                }
            )
            updateUrl = (Get-ObjectProperty -Object $manifest -Name "update_url")
            lastUpdateTime = (Get-ObjectProperty -Object $setting -Name "last_update_time")
            fileSystemVersions = @($fileVersions | ForEach-Object { $_.version })
        }
    }

    return [pscustomobject]@{
        settingsSourcePath = $settingsSourcePath
        extensionsRoot = $directoryIndex.rootPath
        items = @($items)
    }
}

function Get-ProfileDirectories {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,

        [AllowNull()]
        [object]$LocalState
    )

    $profileNames = New-Object System.Collections.Generic.List[string]
    $infoCache = Get-NestedValue -Object $LocalState -Path @("profile", "info_cache")

    if ($null -ne $infoCache) {
        foreach ($property in $infoCache.PSObject.Properties) {
            if (-not [string]::IsNullOrWhiteSpace($property.Name)) {
                $profileNames.Add($property.Name)
            }
        }
    }

    foreach ($directory in Get-ChildItem -LiteralPath $RootPath -Directory) {
        if (Test-Path -LiteralPath (Join-Path $directory.FullName "Preferences") -PathType Leaf) {
            $profileNames.Add($directory.Name)
        }
    }

    return $profileNames | Sort-Object -Unique
}

function Get-ProfileSummary {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,

        [Parameter(Mandatory = $true)]
        [string]$ProfileDirectory,

        [AllowNull()]
        [object]$LocalState,

        [string[]]$Origins
    )

    $preferencesPath = Get-RequiredFilePath -Path (Join-Path (Join-Path $RootPath $ProfileDirectory) "Preferences")
    $preferences = Read-JsonFile -Path $preferencesPath

    $infoCache = Get-NestedValue -Object $LocalState -Path @("profile", "info_cache")
    $profileInfo = Get-ObjectProperty -Object $infoCache -Name $ProfileDirectory
    $profileRoot = Join-Path $RootPath $ProfileDirectory
    $extensionData = Get-ExtensionSummaries -ProfileRoot $profileRoot

    $cookieControlsModeRaw = Get-NestedValue -Object $preferences -Path @("account_values", "profile", "cookie_controls_mode")
    if ($null -eq $cookieControlsModeRaw) {
        $cookieControlsModeRaw = Get-NestedValue -Object $preferences -Path @("profile", "cookie_controls_mode")
    }

    $summary = [ordered]@{
        profileDirectory = $ProfileDirectory
        profileName = (Get-NestedValue -Object $preferences -Path @("profile", "name"))
        localStateProfileName = (Get-ObjectProperty -Object $profileInfo -Name "name")
        localStateGaiaName = (Get-ObjectProperty -Object $profileInfo -Name "gaia_name")
        isUsingDefaultDirectory = ($ProfileDirectory -eq "Default")
        preferencesPath = $preferencesPath
        extensionSettingsSourcePath = $extensionData.settingsSourcePath
        extensionsRootPath = $extensionData.extensionsRoot
        exitType = (Get-NestedValue -Object $preferences -Path @("profile", "exit_type"))
        exitedCleanly = (Get-NestedValue -Object $preferences -Path @("profile", "exited_cleanly"))
        restoreOnStartup = (Get-NestedValue -Object $preferences -Path @("session", "restore_on_startup"))
        promptForDownload = (Get-NestedValue -Object $preferences -Path @("download", "prompt_for_download"))
        backgroundModeEnabled = (Get-NestedValue -Object $preferences -Path @("background_mode", "enabled"))
        cookieControlsMode = (Resolve-CookieControlsMode -Value $cookieControlsModeRaw)
        cookieControlsModeRaw = $cookieControlsModeRaw
        blockThirdPartyCookies = (Get-NestedValue -Object $preferences -Path @("profile", "block_third_party_cookies"))
        clearBrowsingDataSelection = [ordered]@{
            browsingHistory = (Get-NestedValue -Object $preferences -Path @("browser", "clear_data", "browsing_history"))
            cache = (Get-NestedValue -Object $preferences -Path @("browser", "clear_data", "cache"))
            cookies = (Get-NestedValue -Object $preferences -Path @("browser", "clear_data", "cookies"))
            downloadHistory = (Get-NestedValue -Object $preferences -Path @("browser", "clear_data", "download_history"))
            formData = (Get-NestedValue -Object $preferences -Path @("browser", "clear_data", "form_data"))
            hostedAppsData = (Get-NestedValue -Object $preferences -Path @("browser", "clear_data", "hosted_apps_data"))
            siteSettings = (Get-NestedValue -Object $preferences -Path @("browser", "clear_data", "site_settings"))
        }
        siteSettingExceptionCounts = [ordered]@{
            cookies = (Get-PropertyCount -Object (Get-NestedValue -Object $preferences -Path @("profile", "content_settings", "exceptions", "cookies")))
            cookieControlsMetadata = (Get-PropertyCount -Object (Get-NestedValue -Object $preferences -Path @("profile", "content_settings", "exceptions", "cookie_controls_metadata")))
            durableStorage = (Get-PropertyCount -Object (Get-NestedValue -Object $preferences -Path @("profile", "content_settings", "exceptions", "durable_storage")))
            legacyCookieAccess = (Get-PropertyCount -Object (Get-NestedValue -Object $preferences -Path @("profile", "content_settings", "exceptions", "legacy_cookie_access")))
            legacyCookieScope = (Get-PropertyCount -Object (Get-NestedValue -Object $preferences -Path @("profile", "content_settings", "exceptions", "legacy_cookie_scope")))
        }
        extensionCount = @($extensionData.items).Count
        extensions = @($extensionData.items)
        originChecks = @()
        notes = @()
    }

    $notes = New-Object System.Collections.Generic.List[string]
    if ($summary.exitType -and $summary.exitType -ne "Normal") {
        $notes.Add("Profile was not closed normally (exit_type=$($summary.exitType)).")
    }

    if ($summary.exitedCleanly -eq $false) {
        $notes.Add("Profile reports exited_cleanly=false.")
    }

    if ($summary.cookieControlsModeRaw -ne $null) {
        $notes.Add("cookie_controls_mode is a raw Chrome enum from Preferences.")
    }

    if ($summary.clearBrowsingDataSelection.cookies -eq $true) {
        $notes.Add("Clear browsing data dialog last had cookies/site data selected. This is not proof of automatic cleanup.")
    }

    if ($summary.extensionSettingsSourcePath) {
        $notes.Add("Extension settings were read from '$($summary.extensionSettingsSourcePath)'.")
    }

    $summary.notes = @($notes)
    $baseRiskAssessment = Get-LocalStorageRiskAssessment -Profile ([pscustomobject]$summary)
    if ($Origins -and @($Origins).Count -gt 0) {
        $summary.originChecks = @(Get-OriginCheckSummary -ProfileRoot $profileRoot -Preferences $preferences -Origins $Origins -BaseRiskAssessment $baseRiskAssessment)
    }

    return [pscustomobject]$summary
}

function New-OutputDirectory {
    param(
        [AllowNull()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $Path = Join-Path $script:CollectorRoot "chrome-settings-export-$timestamp"
    }

    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    return (Resolve-Path -LiteralPath $Path).Path
}

function Copy-RawSettingsFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,

        [Parameter(Mandatory = $true)]
        [object[]]$Profiles
    )

    $rawRoot = Join-Path $DestinationPath "raw"
    New-Item -ItemType Directory -Path $rawRoot -Force | Out-Null

    Copy-Item -LiteralPath (Get-RequiredFilePath -Path (Join-Path $RootPath "Local State")) -Destination (Join-Path $rawRoot "Local State.json") -Force

    foreach ($profile in $Profiles) {
        $profileRawRoot = Join-Path $rawRoot $profile.profileDirectory
        New-Item -ItemType Directory -Path $profileRawRoot -Force | Out-Null
        Copy-Item -LiteralPath $profile.preferencesPath -Destination (Join-Path $profileRawRoot "Preferences.json") -Force
        if (-not [string]::IsNullOrWhiteSpace($profile.extensionSettingsSourcePath) -and (Split-Path -Leaf $profile.extensionSettingsSourcePath) -eq "Secure Preferences") {
            Copy-Item -LiteralPath $profile.extensionSettingsSourcePath -Destination (Join-Path $profileRawRoot "Secure Preferences.json") -Force
        }
    }
}

function Add-TextSection {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Lines,

        [Parameter(Mandatory = $true)]
        [string]$Title,

        [AllowNull()]
        [object]$Content
    )

    $Lines.Add("")
    $Lines.Add($Title)
    $Lines.Add(("-" * $Title.Length))

    if ($null -eq $Content) {
        $Lines.Add("(no data)")
        return
    }

    if ($Content -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Content)) {
            $Lines.Add("(blank)")
        } else {
            $Lines.Add($Content)
        }

        return
    }

    if ($Content -is [System.Collections.IEnumerable] -and -not ($Content -is [string]) -and -not ($Content -is [System.Management.Automation.PSCustomObject])) {
        $items = @($Content)
        if ($items.Count -eq 0) {
            $Lines.Add("(none)")
            return
        }

        foreach ($item in $items) {
            if ($item -is [string]) {
                $Lines.Add("- $item")
            } else {
                $Lines.Add("- $($item | ConvertTo-Json -Depth 20 -Compress)")
            }
        }

        return
    }

    if ($Content -is [System.Management.Automation.PSCustomObject] -or $Content -is [hashtable]) {
        foreach ($property in $Content.PSObject.Properties) {
            $value = $property.Value
            if ($null -eq $value) {
                $Lines.Add("$($property.Name): ")
                continue
            }

            if ($value -is [string] -or $value -is [ValueType]) {
                $Lines.Add("$($property.Name): $value")
                continue
            }

            if ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string])) {
                $items = @($value)
                if ($items.Count -eq 0) {
                    $Lines.Add("$($property.Name): []")
                } elseif ($items[0] -is [string] -or $items[0] -is [ValueType]) {
                    $Lines.Add("$($property.Name): $($items -join ', ')")
                } else {
                    $Lines.Add("$($property.Name):")
                    foreach ($item in $items) {
                        $Lines.Add("- $($item | ConvertTo-Json -Depth 20 -Compress)")
                    }
                }

                continue
            }

            $Lines.Add("$($property.Name): $($value | ConvertTo-Json -Depth 20 -Compress)")
        }

        return
    }

    $Lines.Add(($Content | ConvertTo-Json -Depth 20 -Compress))
}

function New-ProfileSectionMap {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Profile,

        [int]$EnterprisePolicyKeyCount = 0
    )

    $localStorageRiskAssessment = Get-LocalStorageRiskAssessment -Profile $Profile -EnterprisePolicyKeyCount $EnterprisePolicyKeyCount

    return [pscustomobject][ordered]@{
        profileDirectory = $Profile.profileDirectory
        sections = [pscustomobject][ordered]@{
            "chrome://settings/content/siteData" = [pscustomobject][ordered]@{
                collectionStatus = "partial"
                summary = "Only settings and exception metadata related to site data are collected in this report."
                clearBrowsingDataSelection = $Profile.clearBrowsingDataSelection
                siteSettingExceptionCounts = $Profile.siteSettingExceptionCounts
            }
            "chrome://policy" = [pscustomobject][ordered]@{
                collectionStatus = "global-only"
                summary = "Policy data is collected at the global Chrome level, not per-profile."
            }
            "Local Storage Risk Assessment" = $localStorageRiskAssessment
            "Origin Site Data Checks" = if (@($Profile.originChecks).Count -gt 0) {
                [pscustomobject][ordered]@{
                    collectionStatus = "requested"
                    checks = $Profile.originChecks
                }
            } else {
                [pscustomobject][ordered]@{
                    collectionStatus = "not-requested"
                    summary = "Use -Origin <scheme://host[:port]> to inspect site-specific storage evidence."
                }
            }
            "chrome://extensions" = [pscustomobject][ordered]@{
                collectionStatus = "collected"
                extensionSettingsSource = $Profile.extensionSettingsSourcePath
                extensionsRoot = $Profile.extensionsRootPath
                extensionCount = $Profile.extensionCount
                extensions = $Profile.extensions
            }
            "chrome://prefs-internals" = [pscustomobject][ordered]@{
                collectionStatus = "partial"
                preferencesPath = $Profile.preferencesPath
                exitType = $Profile.exitType
                exitedCleanly = $Profile.exitedCleanly
                restoreOnStartup = $Profile.restoreOnStartup
                promptForDownload = $Profile.promptForDownload
                backgroundModeEnabled = $Profile.backgroundModeEnabled
                cookieControlsMode = $Profile.cookieControlsMode
                cookieControlsModeRaw = $Profile.cookieControlsModeRaw
                blockThirdPartyCookies = $Profile.blockThirdPartyCookies
                notes = $Profile.notes
            }
            "chrome://version" = [pscustomobject][ordered]@{
                collectionStatus = "partial"
                profileDirectory = $Profile.profileDirectory
                preferencesPath = $Profile.preferencesPath
            }
            "chrome://system" = [pscustomobject][ordered]@{
                collectionStatus = "not-collected"
                summary = "This script does not currently collect chrome://system runtime diagnostics."
            }
            "Profile Metadata" = [pscustomobject][ordered]@{
                displayName = $Profile.profileName
                localStateProfileName = $Profile.localStateProfileName
                localStateGaiaName = $Profile.localStateGaiaName
                isUsingDefaultDirectory = $Profile.isUsingDefaultDirectory
            }
        }
    }
}

function Build-ReportSummary {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserDataPath,

        [Parameter(Mandatory = $true)]
        [string]$LocalStatePath,

        [AllowNull()]
        [string]$ChromeVersion,

        [AllowNull()]
        [string]$LastUsedProfile,

        [Parameter(Mandatory = $true)]
        [object[]]$ProfilesSummary,

        [AllowNull()]
        [object]$EnterprisePolicy,

        [string[]]$Origins
    )

    $enterprisePolicyKeyCount = Get-PropertyCount -Object $EnterprisePolicy
    $profileRiskAssessments = @(
        $ProfilesSummary | ForEach-Object {
            $assessment = Get-LocalStorageRiskAssessment -Profile $_ -EnterprisePolicyKeyCount $enterprisePolicyKeyCount
            [pscustomobject][ordered]@{
                profileDirectory = $_.profileDirectory
                riskLevel = $assessment.riskLevel
                summary = $assessment.summary
                findings = $assessment.findings
                signals = $assessment.signals
            }
        }
    )

    $overallRiskLevel = "low"
    foreach ($assessment in $profileRiskAssessments) {
        $overallRiskLevel = Get-HigherRiskLevel -CurrentLevel $overallRiskLevel -CandidateLevel $assessment.riskLevel
    }

    $overallRiskSummary = switch ($overallRiskLevel) {
        "high" { "High risk signals were detected. Check enterprise policy and site-specific storage evidence." }
        "medium" { "Some settings may affect site data behavior, but none alone proves automatic localStorage deletion." }
        default { "Collected settings do not show a strong signal for automatic localStorage deletion." }
    }

    $reportProfiles = @($ProfilesSummary | ForEach-Object { New-ProfileSectionMap -Profile $_ -EnterprisePolicyKeyCount $enterprisePolicyKeyCount })

    return [pscustomobject][ordered]@{
        generatedAt = (Get-Date).ToString("o")
        sections = [pscustomobject][ordered]@{
            "chrome://version" = [pscustomobject][ordered]@{
                collectionStatus = "partial"
                chromeVersion = $ChromeVersion
                userDataPath = $UserDataPath
                localStatePath = $LocalStatePath
                lastUsedProfile = $LastUsedProfile
                profileCount = @($ProfilesSummary).Count
            }
            "chrome://policy" = [pscustomobject][ordered]@{
                collectionStatus = "partial"
                enterprisePolicyKeyCount = $enterprisePolicyKeyCount
                enterprisePolicyKeys = @(
                    if ($null -ne $EnterprisePolicy) {
                        $EnterprisePolicy.PSObject.Properties.Name | Sort-Object
                    }
                )
            }
            "chrome://extensions" = [pscustomobject][ordered]@{
                collectionStatus = "collected"
                profileExtensionCounts = @(
                    $ProfilesSummary | ForEach-Object {
                        [pscustomobject][ordered]@{
                            profileDirectory = $_.profileDirectory
                            extensionCount = $_.extensionCount
                        }
                    }
                )
            }
            "chrome://prefs-internals" = [pscustomobject][ordered]@{
                collectionStatus = "partial"
                localStatePath = $LocalStatePath
                profilePreferences = @(
                    $ProfilesSummary | ForEach-Object {
                        [pscustomobject][ordered]@{
                            profileDirectory = $_.profileDirectory
                            preferencesPath = $_.preferencesPath
                            extensionSettingsSource = $_.extensionSettingsSourcePath
                        }
                    }
                )
            }
            "chrome://settings/content/siteData" = [pscustomobject][ordered]@{
                collectionStatus = "partial"
                summary = "This report only collects site data related settings and exception counts, not the full per-site storage inventory."
            }
            "Local Storage Risk Assessment" = [pscustomobject][ordered]@{
                collectionStatus = "heuristic"
                overallRiskLevel = $overallRiskLevel
                summary = $overallRiskSummary
                profileAssessments = $profileRiskAssessments
            }
            "Origin Site Data Checks" = if ($Origins -and @($Origins).Count -gt 0) {
                [pscustomobject][ordered]@{
                    collectionStatus = "requested"
                    requestedOrigins = @($Origins | ForEach-Object { (ConvertTo-OriginTarget -Origin $_).origin })
                    profileChecks = @(
                        $ProfilesSummary | ForEach-Object {
                            [pscustomobject][ordered]@{
                                profileDirectory = $_.profileDirectory
                                checks = $_.originChecks
                            }
                        }
                    )
                }
            } else {
                [pscustomobject][ordered]@{
                    collectionStatus = "not-requested"
                    summary = "Use -Origin <scheme://host[:port]> to add origin-specific storage checks."
                }
            }
            "chrome://system" = [pscustomobject][ordered]@{
                collectionStatus = "not-collected"
                summary = "This script does not currently collect chrome://system runtime diagnostics."
            }
            "Profile Metadata" = [pscustomobject][ordered]@{
                profiles = @(
                    $ProfilesSummary | ForEach-Object {
                        [pscustomobject][ordered]@{
                            profileDirectory = $_.profileDirectory
                            displayName = $_.profileName
                            localStateProfileName = $_.localStateProfileName
                            localStateGaiaName = $_.localStateGaiaName
                        }
                    }
                )
            }
            "Collection Notes" = @(
                "This script reads Local State and profile Preferences without modifying Chrome settings.",
                "localStorage is site data; Chrome does not expose a single global localStorage on/off switch in Preferences.",
                "browser.clear_data.* reflects the last clear-browsing-data dialog selection, not an automatic delete-on-exit proof.",
                "Use -Origin with a full origin such as https://example.com to inspect site-specific storage evidence.",
                "Extension inventory is inferred from Secure Preferences or Preferences plus the profile Extensions directory.",
                "Summary files are exported by default. Use -NoExport to disable file output, or -Output to choose a target folder."
            )
        }
        profiles = $reportProfiles
    }
}

function Format-TextReport {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Summary
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Chrome Settings Collection")
    $lines.Add("=====================")
    $lines.Add("GeneratedAt: $($Summary.generatedAt)")

    foreach ($section in $Summary.sections.PSObject.Properties) {
        Add-TextSection -Lines $lines -Title $section.Name -Content $section.Value
    }

    foreach ($profile in $Summary.profiles) {
        $lines.Add("")
        $lines.Add("Profile: $($profile.profileDirectory)")
        $lines.Add("----------------------------------------")
        foreach ($section in $profile.sections.PSObject.Properties) {
            Add-TextSection -Lines $lines -Title $section.Name -Content $section.Value
        }
    }

    return ($lines -join [Environment]::NewLine)
}

if (-not (Test-Path -LiteralPath $UserDataPath -PathType Container)) {
    throw "Chrome user data directory not found: $UserDataPath"
}

$localStatePath = Get-RequiredFilePath -Path (Join-Path $UserDataPath "Local State")
$localState = Read-JsonFile -Path $localStatePath
$profileDirectories = @(Get-ProfileDirectories -RootPath $UserDataPath -LocalState $localState)

if ($Profiles) {
    $requestedProfiles = @($Profiles | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    $missingProfiles = @($requestedProfiles | Where-Object { $_ -notin $profileDirectories })
    if ($missingProfiles.Count -gt 0) {
        throw "Requested profiles not found: $($missingProfiles -join ', ')"
    }

    $profileDirectories = $requestedProfiles
}

$chromeVersion = $null
$lastVersionPath = Join-Path $UserDataPath "Last Version"
if (Test-Path -LiteralPath $lastVersionPath -PathType Leaf) {
    $chromeVersion = (Get-Content -LiteralPath $lastVersionPath -Raw).Trim()
}

$profilesSummary = foreach ($profileDirectory in $profileDirectories) {
    Get-ProfileSummary -RootPath $UserDataPath -ProfileDirectory $profileDirectory -LocalState $localState -Origins $Origin
}

$enterprisePolicy = Get-ObjectProperty -Object (Get-ObjectProperty -Object $localState -Name "policy") -Name "user_policies"
$summary = Build-ReportSummary -UserDataPath $UserDataPath -LocalStatePath $localStatePath -ChromeVersion $chromeVersion -LastUsedProfile (Get-NestedValue -Object $localState -Path @("profile", "last_used")) -ProfilesSummary $profilesSummary -EnterprisePolicy $enterprisePolicy -Origins $Origin

$textReport = Format-TextReport -Summary $summary
Write-Output $textReport

if (-not $NoExport) {
    $resolvedOutputDirectory = New-OutputDirectory -Path $Output
    $summaryJsonPath = Join-Path $resolvedOutputDirectory "summary.json"
    $summaryTextPath = Join-Path $resolvedOutputDirectory "summary.txt"

    $summary | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $summaryJsonPath -Encoding UTF8
    $textReport | Set-Content -LiteralPath $summaryTextPath -Encoding UTF8

    if ($IncludeRawFiles) {
        Copy-RawSettingsFiles -RootPath $UserDataPath -DestinationPath $resolvedOutputDirectory -Profiles $profilesSummary
    }

    Write-Output ""
    Write-Output "ExportedTo: $resolvedOutputDirectory"
}
