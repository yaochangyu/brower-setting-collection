[CmdletBinding()]
param(
    [string]$UserDataPath = (Join-Path $env:LOCALAPPDATA "Google\Chrome\User Data"),
    [string[]]$Profiles,
    [switch]$Export,
    [string]$OutputDirectory,
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
        [object]$LocalState
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
        [pscustomobject]$Profile
    )

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
        [object]$EnterprisePolicy
    )

    $reportProfiles = @($ProfilesSummary | ForEach-Object { New-ProfileSectionMap -Profile $_ })

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
                enterprisePolicyKeyCount = (Get-PropertyCount -Object $EnterprisePolicy)
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
                "Extension inventory is inferred from Secure Preferences or Preferences plus the profile Extensions directory.",
                "Use -Export to save summary files. Use -IncludeRawFiles only if you also want raw Local State and Preferences copies."
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
    Get-ProfileSummary -RootPath $UserDataPath -ProfileDirectory $profileDirectory -LocalState $localState
}

$enterprisePolicy = Get-ObjectProperty -Object (Get-ObjectProperty -Object $localState -Name "policy") -Name "user_policies"
$summary = Build-ReportSummary -UserDataPath $UserDataPath -LocalStatePath $localStatePath -ChromeVersion $chromeVersion -LastUsedProfile (Get-NestedValue -Object $localState -Path @("profile", "last_used")) -ProfilesSummary $profilesSummary -EnterprisePolicy $enterprisePolicy

$textReport = Format-TextReport -Summary $summary
Write-Output $textReport

if ($Export) {
    $resolvedOutputDirectory = New-OutputDirectory -Path $OutputDirectory
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
