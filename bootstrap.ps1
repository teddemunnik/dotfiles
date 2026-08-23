<#
.SYNOPSIS
    Links dotfiles into place, one opt-in module at a time.

.DESCRIPTION
    Reads bootstrap/modules.json and, for each enabled module, links its files to
    their platform-specific targets. Safe by default: an existing real file whose
    content differs from the repo copy is never touched without -Force, and every
    replacement is backed up first. Idempotent - a second run does nothing.

.PARAMETER List
    Show every module and the current state of its links. Changes nothing.

.PARAMETER Modules
    Apply only these module ids. Non-interactive.

.PARAMETER All
    Apply every enabled module. Non-interactive.

.PARAMETER Apply
    Re-apply the module set this machine chose last time, from
    bootstrap/state.local.json. Non-interactive - the form to use from a login script.

.PARAMETER Force
    Replace conflicting real files instead of skipping them. Always backs up first.

.EXAMPLE
    .\bootstrap.ps1
    Interactive: shows each module's status and asks whether to apply it.

.EXAMPLE
    .\bootstrap.ps1 -Modules claude -WhatIf
    Print exactly what would happen to the claude module. Changes nothing.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string[]] $Modules,
    [switch]   $All,
    [switch]   $List,
    [switch]   $Apply,
    [switch]   $Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$RepoRoot     = $PSScriptRoot
$RegistryPath = Join-Path $RepoRoot 'bootstrap\modules.json'
$StatePath    = Join-Path $RepoRoot 'bootstrap\state.local.json'

# Probed once, lazily, by Test-SymlinkCapability. StrictMode requires it to exist.
$script:SymlinkCapable = $null

# Tallies that decide the exit code.
$script:Applied   = 0
$script:AlreadyOk = 0
$script:Conflicts = @()
$script:Failures  = @()
$script:Fallbacks = @()


# ---------------------------------------------------------------- presentation

function Write-Head($Text) {
    Write-Host ''
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ('-' * $Text.Length) -ForegroundColor DarkGray
}

function Write-Mark($Mark, $Text, $Color) {
    Write-Host ('  {0,-7} ' -f $Mark) -ForegroundColor $Color -NoNewline
    Write-Host $Text
}

function Write-Note($Text) {
    Write-Host ('          ' + $Text) -ForegroundColor DarkGray
}


# ------------------------------------------------------------------- platform

function Get-Platform {
    # $IsWindows only exists on PS Core; on 5.1 the absence of it means Windows.
    if (Test-Path Variable:\IsWindows) {
        if ($IsWindows) { return 'windows' }
        if ($IsLinux)   { return 'linux' }
        if ($IsMacOS)   { return 'macos' }
        return 'unknown'
    }
    return 'windows'
}

function Expand-TargetPath($Raw) {
    # modules.json uses %VAR% on Windows and $HOME elsewhere; normalise both.
    $expanded = [Environment]::ExpandEnvironmentVariables($Raw)
    $expanded = $expanded.Replace('$HOME', $HOME)
    return $expanded
}

function Test-SymlinkCapability {
    <#
      Windows only grants symlink creation to elevated processes, or to any process
      once Developer Mode is on. Probe once per run so we can tell "linked, but via a
      fallback we can now improve on" apart from "linked correctly".
    #>
    if ($null -ne $script:SymlinkCapable) { return $script:SymlinkCapable }

    $probeDir = Join-Path ([System.IO.Path]::GetTempPath()) ("dotfiles-symlink-probe-" + [guid]::NewGuid().ToString('N'))
    $script:SymlinkCapable = $false
    try {
        New-Item -ItemType Directory -Path $probeDir -Force | Out-Null
        $realFile = Join-Path $probeDir 'real.txt'
        $linkFile = Join-Path $probeDir 'link.txt'
        Set-Content -LiteralPath $realFile -Value 'probe'
        New-Item -ItemType SymbolicLink -Path $linkFile -Target $realFile -ErrorAction Stop | Out-Null
        $script:SymlinkCapable = $true
    } catch {
        $script:SymlinkCapable = $false
    } finally {
        if (Test-Path -LiteralPath $probeDir) {
            Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    return $script:SymlinkCapable
}

function Get-ComparablePath($Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $p = $Path.TrimEnd('\', '/')
    try { $p = [System.IO.Path]::GetFullPath($p) } catch { }
    return $p.ToLowerInvariant()
}


# ---------------------------------------------------------------- link probing

function Get-LinkState {
    <#
      Classifies one link into exactly one state:
        SourceMissing - the repo copy is not there (registry bug)
        Linked        - already points at the repo copy; nothing to do
        Missing       - target absent; free to create
        WrongLink     - a link, but aimed somewhere else
        RealSame      - a real file whose content matches the repo copy
        RealDiffer    - a real file with different content; the one we refuse to
                        clobber without -Force
    #>
    param($SourceFull, $TargetFull)

    if (-not (Test-Path -LiteralPath $SourceFull)) {
        return @{ State = 'SourceMissing'; Detail = $SourceFull }
    }

    if (-not (Test-Path -LiteralPath $TargetFull)) {
        return @{ State = 'Missing'; Detail = '' }
    }

    $item     = Get-Item -LiteralPath $TargetFull -Force
    $linkType = $null
    if ($item.PSObject.Properties.Name -contains 'LinkType') { $linkType = $item.LinkType }

    if ($linkType -eq 'SymbolicLink' -or $linkType -eq 'Junction') {
        $current = ''
        if ($item.Target -and $item.Target.Count -gt 0) { $current = $item.Target[0] }
        if ((Get-ComparablePath $current) -eq (Get-ComparablePath $SourceFull)) {
            return @{ State = 'Linked'; Detail = $linkType }
        }
        return @{ State = 'WrongLink'; Detail = $current }
    }

    if ($linkType -eq 'HardLink') {
        # A hardlink has no single "target"; identity is same-content plus same volume.
        # Content equality is the check that actually matters for our purposes.
        if ((Test-SameContent $SourceFull $TargetFull)) {
            # A hardlink is the privilege-free fallback. If symlinks have since become
            # available (elevated run, or Developer Mode switched on), say so - otherwise
            # a machine would stay on the weaker link type forever.
            if (Test-SymlinkCapability) {
                return @{ State = 'Upgrade'; Detail = 'HardLink' }
            }
            return @{ State = 'Linked'; Detail = 'HardLink' }
        }
        return @{ State = 'RealDiffer'; Detail = 'stale hardlink' }
    }

    if (Test-SameContent $SourceFull $TargetFull) {
        return @{ State = 'RealSame'; Detail = '' }
    }
    return @{ State = 'RealDiffer'; Detail = '' }
}

function Test-SameContent($A, $B) {
    if ((Test-Path -LiteralPath $A -PathType Container) -or
        (Test-Path -LiteralPath $B -PathType Container)) {
        return $false   # directories: never claim equality, fall through to conflict
    }
    try {
        $ha = (Get-FileHash -LiteralPath $A -Algorithm SHA256).Hash
        $hb = (Get-FileHash -LiteralPath $B -Algorithm SHA256).Hash
        return ($ha -eq $hb)
    } catch {
        return $false
    }
}


# --------------------------------------------------------------- link creation

function Remove-ExistingTarget($Path) {
    $item = Get-Item -LiteralPath $Path -Force
    $isReparse = ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0

    if ($item.PSIsContainer) {
        if ($isReparse) {
            # Delete the junction itself, never recurse into what it points at.
            [System.IO.Directory]::Delete($Path, $false)
        } else {
            Remove-Item -LiteralPath $Path -Recurse -Force
        }
    } else {
        Remove-Item -LiteralPath $Path -Force
    }
}

function Backup-Target($Path) {
    $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = "$Path.bak-$stamp"
    Move-Item -LiteralPath $Path -Destination $backup -Force
    return $backup
}

function New-ConfigLink {
    <#
      Symlink first. Windows needs admin or Developer Mode for those, so fall back to
      a hardlink (files) or junction (dirs), neither of which needs privileges.
      Returns the mechanism actually used.
    #>
    param($LinkPath, $SourceFull, $Kind)

    $parent = Split-Path -Parent $LinkPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $symlinkError = 'not permitted (needs elevation or Developer Mode)'
    if (Test-SymlinkCapability) {
        try {
            New-Item -ItemType SymbolicLink -Path $LinkPath -Target $SourceFull -ErrorAction Stop | Out-Null
            return 'SymbolicLink'
        } catch {
            $symlinkError = $_.Exception.Message
        }
    }

    try {
        if ($Kind -eq 'dir') {
            New-Item -ItemType Junction -Path $LinkPath -Target $SourceFull -ErrorAction Stop | Out-Null
            return 'Junction'
        }
        New-Item -ItemType HardLink -Path $LinkPath -Target $SourceFull -ErrorAction Stop | Out-Null
        return 'HardLink'
    } catch {
        throw ("symlink failed ({0}); fallback failed ({1})" -f $symlinkError, $_.Exception.Message)
    }
}


# -------------------------------------------------------------------- registry

function Get-Registry {
    if (-not (Test-Path -LiteralPath $RegistryPath)) {
        throw "Module registry not found at $RegistryPath"
    }
    return (Get-Content -LiteralPath $RegistryPath -Raw | ConvertFrom-Json)
}

function Resolve-ModuleLinks($Module, $Platform) {
    # Flattens a module's links into resolved source/target pairs for this platform.
    $out = @()
    foreach ($link in $Module.links) {
        $targetRaw = $null
        if ($link.target.PSObject.Properties.Name -contains $Platform) {
            $targetRaw = $link.target.$Platform
        }
        if ([string]::IsNullOrWhiteSpace($targetRaw)) { continue }  # not for this platform

        $kind = 'file'
        if ($link.PSObject.Properties.Name -contains 'type') { $kind = $link.type }

        $out += [pscustomobject]@{
            Source     = $link.source
            SourceFull = (Join-Path $RepoRoot ($link.source -replace '/', '\'))
            TargetFull = (Expand-TargetPath $targetRaw)
            Kind       = $kind
        }
    }
    return $out
}


# ---------------------------------------------------------------------- report

function Show-Module($Module, $Platform) {
    $label = $Module.id
    if (-not $Module.enabled) { $label = "$($Module.id)  (stub)" }
    Write-Head $label
    Write-Host "  $($Module.description)" -ForegroundColor Gray

    if (-not $Module.enabled) {
        if ($Module.PSObject.Properties.Name -contains 'todo') {
            Write-Host ''
            Write-Note ("TODO: " + $Module.todo)
        }
        return
    }

    $links = Resolve-ModuleLinks $Module $Platform
    if ($links.Count -eq 0) {
        Write-Note 'no links defined for this platform'
        return
    }

    Write-Host ''
    foreach ($l in $links) {
        $st = Get-LinkState $l.SourceFull $l.TargetFull
        switch ($st.State) {
            'Linked'        { Write-Mark '[ok]'     $l.TargetFull  'Green'
                              Write-Note ("already linked ({0})" -f $st.Detail) }
            'Upgrade'       { Write-Mark '[upgrade]' $l.TargetFull 'Yellow'
                              Write-Note ("linked via {0}; symlinks now available, will re-link" -f $st.Detail) }
            'Missing'       { Write-Mark '[new]'    $l.TargetFull  'Yellow'
                              Write-Note ("will link -> {0}" -f $l.Source) }
            'WrongLink'     { Write-Mark '[repoint]' $l.TargetFull 'Yellow'
                              Write-Note ("currently points at {0}" -f $st.Detail) }
            'RealSame'      { Write-Mark '[adopt]'  $l.TargetFull  'Yellow'
                              Write-Note 'real file, identical content - safe to replace' }
            'RealDiffer'    { Write-Mark '[CONFLICT]' $l.TargetFull 'Red'
                              Write-Note 'real file with different content - needs -Force (backs up first)' }
            'SourceMissing' { Write-Mark '[BROKEN]' $l.Source      'Red'
                              Write-Note 'repo copy is missing' }
        }
    }

    Show-Requirements $Module
}

function Show-Requirements($Module) {
    if (-not ($Module.PSObject.Properties.Name -contains 'requires')) { return }
    if ($Module.requires.Count -eq 0) { return }

    foreach ($req in $Module.requires) {
        if ($req.kind -ne 'command') { continue }
        $found = Get-Command $req.name -ErrorAction SilentlyContinue
        Write-Host ''
        if ($found) {
            Write-Mark '[dep]' ("{0} found" -f $req.name) 'Green'
        } else {
            Write-Mark '[dep]' ("{0} NOT installed" -f $req.name) 'Yellow'
            Write-Note $req.reason
            Write-Note ("install with: " + $req.install)
        }
    }
}


# ----------------------------------------------------------------------- apply

function Invoke-Module($Module, $Platform) {
    Write-Head ("applying: " + $Module.id)

    foreach ($l in (Resolve-ModuleLinks $Module $Platform)) {
        $st     = Get-LinkState $l.SourceFull $l.TargetFull
        $backup = $null

        # Guard clauses, deliberately if/continue rather than a switch: `continue`
        # inside a PowerShell switch exits the switch, not the enclosing loop, which
        # would let a skipped conflict fall through and be linked anyway.
        if ($st.State -eq 'Linked') {
            $script:AlreadyOk++
            Write-Mark '[ok]' $l.TargetFull 'Green'
            continue
        }

        if ($st.State -eq 'SourceMissing') {
            $script:Failures += ("{0}: repo copy missing at {1}" -f $Module.id, $l.SourceFull)
            Write-Mark '[BROKEN]' $l.Source 'Red'
            continue
        }

        if ($st.State -eq 'RealDiffer' -and -not $Force) {
            $script:Conflicts += ("{0} -> differs from {1}" -f $l.TargetFull, $l.Source)
            Write-Mark '[SKIP]' $l.TargetFull 'Red'
            Write-Note 'real file with different content; left untouched. Re-run with -Force to back it up and link.'
            continue
        }

        $action = "link to $($l.Source)"
        if (-not $PSCmdlet.ShouldProcess($l.TargetFull, $action)) { continue }

        try {
            if (Test-Path -LiteralPath $l.TargetFull) {
                # Only a differing real file is worth preserving. RealSame is provably
                # byte-identical to the repo copy, so a backup would be pure clutter.
                if ($st.State -eq 'RealDiffer') {
                    $backup = Backup-Target $l.TargetFull
                } else {
                    Remove-ExistingTarget $l.TargetFull
                }
            }

            $mech = New-ConfigLink $l.TargetFull $l.SourceFull $l.Kind
            $script:Applied++

            Write-Mark '[done]' $l.TargetFull 'Green'
            Write-Note ("{0} -> {1}" -f $mech, $l.Source)
            if ($backup) { Write-Note ("backed up original to " + (Split-Path -Leaf $backup)) }

            if ($mech -ne 'SymbolicLink') {
                $script:Fallbacks += ("{0} ({1})" -f $l.TargetFull, $mech)
            }
        } catch {
            $script:Failures += ("{0}: {1}" -f $l.TargetFull, $_.Exception.Message)
            Write-Mark '[FAIL]' $l.TargetFull 'Red'
            Write-Note $_.Exception.Message
            if ($backup) { Write-Note ("original preserved at " + $backup) }
        }
    }

    Show-Requirements $Module
}


# ----------------------------------------------------------------------- state

function Get-SavedModules {
    if (-not (Test-Path -LiteralPath $StatePath)) { return @() }
    try {
        $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
        return @($state.enabledModules)
    } catch {
        return @()
    }
}

function Save-Modules($Ids) {
    if ($WhatIfPreference) { return }
    $state = [pscustomobject]@{
        '$comment'      = 'Per-machine bootstrap choices. Gitignored - not shared.'
        enabledModules  = @($Ids)
        lastRun         = (Get-Date -Format 'o')
        machine         = $env:COMPUTERNAME
    }
    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StatePath -Encoding UTF8
}


# ------------------------------------------------------------------------ main

$platform = Get-Platform
$registry = Get-Registry
$enabled  = @($registry.modules | Where-Object { $_.enabled })

Write-Host ''
Write-Host 'dotfiles bootstrap' -ForegroundColor White
Write-Host ("repo: {0}   platform: {1}" -f $RepoRoot, $platform) -ForegroundColor DarkGray

# --- report-only mode
if ($List) {
    foreach ($m in $registry.modules) { Show-Module $m $platform }
    Write-Host ''
    Write-Host 'Nothing was changed. Run without -List to apply.' -ForegroundColor DarkGray
    Write-Host ''
    exit 0
}

# --- work out which modules to act on
$selected = @()

if ($All) {
    $selected = @($enabled | ForEach-Object { $_.id })
}
elseif ($Modules) {
    foreach ($id in $Modules) {
        $match = $registry.modules | Where-Object { $_.id -eq $id }
        if (-not $match)        { throw "Unknown module '$id'. Run -List to see what exists." }
        if (-not $match.enabled) { throw "Module '$id' is a stub and has nothing to link yet." }
        $selected += $id
    }
}
elseif ($Apply) {
    $selected = @(Get-SavedModules)
    if ($selected.Count -eq 0) {
        Write-Host ''
        Write-Host 'No saved module set for this machine. Run interactively once first.' -ForegroundColor Yellow
        Write-Host ''
        exit 1
    }
    Write-Host ("replaying saved selection: {0}" -f ($selected -join ', ')) -ForegroundColor DarkGray
}
else {
    # --- interactive
    if (-not [Environment]::UserInteractive) {
        throw 'No console available. Pass -Modules, -All, -Apply or -List.'
    }

    $saved = Get-SavedModules
    foreach ($m in $enabled) {
        Show-Module $m $platform

        $default = 'n'
        if ($m.enabledByDefault -or ($saved -contains $m.id)) { $default = 'y' }

        Write-Host ''
        $prompt = "  Apply '$($m.id)'? [Y/n]"
        if ($default -eq 'n') { $prompt = "  Apply '$($m.id)'? [y/N]" }

        $answer = (Read-Host $prompt).Trim().ToLowerInvariant()
        if ($answer -eq '') { $answer = $default }
        if ($answer -eq 'y' -or $answer -eq 'yes') { $selected += $m.id }
    }

    $stubs = @($registry.modules | Where-Object { -not $_.enabled })
    if ($stubs.Count -gt 0) {
        Write-Host ''
        Write-Host ("Stub modules not offered: {0}" -f (($stubs | ForEach-Object { $_.id }) -join ', ')) -ForegroundColor DarkGray
        Write-Host '  Run -List to see what each still needs.' -ForegroundColor DarkGray
    }
}

if ($selected.Count -eq 0) {
    Write-Host ''
    Write-Host 'No modules selected. Nothing to do.' -ForegroundColor DarkGray
    Write-Host ''
    exit 0
}

foreach ($id in $selected) {
    $m = $registry.modules | Where-Object { $_.id -eq $id }
    Invoke-Module $m $platform
}

Save-Modules $selected


# --------------------------------------------------------------------- summary

Write-Head 'summary'
Write-Host ("  linked      {0}" -f $script:Applied)
Write-Host ("  already ok  {0}" -f $script:AlreadyOk)

$hardlinked = @($script:Fallbacks | Where-Object { $_ -like '*(HardLink)' })
if ($hardlinked.Count -gt 0) {
    Write-Host ''
    Write-Host '  Symlinks unavailable - used hardlinks instead:' -ForegroundColor Yellow
    foreach ($f in $hardlinked) { Write-Host ("    " + $f) -ForegroundColor Yellow }
    Write-Host '    A hardlink breaks silently if a tool replaces the file rather than' -ForegroundColor DarkGray
    Write-Host '    editing it in place, and edits then stop reaching the repo.' -ForegroundColor DarkGray
    Write-Host '    For real symlinks: turn on Windows Developer Mode (Settings > System >' -ForegroundColor DarkGray
    Write-Host '    For developers), or run this script from an elevated shell once, then' -ForegroundColor DarkGray
    Write-Host '    re-run - it detects the hardlinks and upgrades them.' -ForegroundColor DarkGray
}

if ($script:Conflicts.Count -gt 0) {
    Write-Host ''
    Write-Host ("  Skipped {0} conflict(s):" -f $script:Conflicts.Count) -ForegroundColor Red
    foreach ($c in $script:Conflicts) { Write-Host ("    " + $c) -ForegroundColor Red }
    Write-Host '    Re-run with -Force to back these up and link.' -ForegroundColor DarkGray
}

if ($script:Failures.Count -gt 0) {
    Write-Host ''
    Write-Host ("  {0} failure(s):" -f $script:Failures.Count) -ForegroundColor Red
    foreach ($f in $script:Failures) { Write-Host ("    " + $f) -ForegroundColor Red }
}

Write-Host ''
if ($script:Conflicts.Count -gt 0 -or $script:Failures.Count -gt 0) { exit 1 }
exit 0
