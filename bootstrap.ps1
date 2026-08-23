<#
.SYNOPSIS
    Links dotfiles into place, one opt-in module at a time.

.DESCRIPTION
    Reads bootstrap/modules.json and, for each enabled module, links its files to
    their platform-specific targets and installs the packages it declares. Safe by
    default: an existing real file whose content differs from the repo copy is never
    touched without -Force, and every replacement is backed up first. Idempotent - a
    second run does nothing.

    A module may declare dependencies in `requires`, each with a `kind`:
      winget  - a Windows package, by exact id (find one with `winget search <name>`)
      npm     - a global npm package
      font    - a TrueType file vendored in this repo, installed for the current
                user (no elevation). For fonts winget does not carry.
      command - advisory only: report if absent, never install
    Entries marked "autoInstall": true are installed when a module is applied;
    everything else is only reported. -SkipPackages suppresses installs entirely.

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

.PARAMETER SkipPackages
    Link files only. Missing packages are reported but never installed.

.PARAMETER Reload
    Link nothing; just re-create the existing links so a watching app notices and
    hot-reloads. Use after editing a config in this repo. See Reset-Link for why an
    edit made here is otherwise invisible to the app reading it.

.EXAMPLE
    .\bootstrap.ps1 -Modules windows-terminal -Reload
    Make a running Windows Terminal pick up settings.json edits made in this repo,
    without restarting it.

.EXAMPLE
    .\bootstrap.ps1 -Modules packages
    Install the baseline winget apps, touching no config files.

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
    [switch]   $Force,
    [switch]   $SkipPackages,
    [switch]   $Reload
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$RepoRoot     = $PSScriptRoot
$RegistryPath = Join-Path $RepoRoot 'bootstrap\modules.json'
$StatePath    = Join-Path $RepoRoot 'bootstrap\state.local.json'

# Probed once, lazily, by Test-SymlinkCapability. StrictMode requires it to exist.
$script:SymlinkCapable   = $null
$script:LastSymlinkError = ''

# Tallies that decide the exit code.
$script:Applied   = 0
$script:AlreadyOk = 0
$script:Conflicts = @()
$script:Failures  = @()
$script:Fallbacks = @()
$script:MissingDeps = @()
$script:EnvChanged  = @()
$script:Reloaded    = 0


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
    <#
      modules.json uses %VAR% on Windows and $HOME elsewhere; normalise both, plus a
      few tokens for locations that cannot be written down literally in a shared file:

        {documents}    - the real Documents folder, redirection and locale included.
                         Not %USERPROFILE%\Documents: it is frequently redirected to
                         OneDrive and localised (it is "Documenten" on this machine),
                         so any literal spelling is wrong somewhere.
        {repo}         - wherever this clone happens to live.

      There is deliberately no {psprofiledir} token. It could only come from
      $PROFILE, which resolves against whichever host runs this script -
      WindowsPowerShell under 5.1, PowerShell under 7 - so bootstrapping from pwsh
      would aim both profile links at the same path and silently leave Windows
      PowerShell unlinked. Both directories are fixed names under {documents}, so
      spell them out and stay host-independent.
    #>
    $s = [string]$Raw
    $s = $s.Replace('{documents}',    [Environment]::GetFolderPath('MyDocuments'))
    $s = $s.Replace('{repo}',         $RepoRoot)
    $expanded = [Environment]::ExpandEnvironmentVariables($s)
    $expanded = $expanded.Replace('$HOME', $HOME)
    return $expanded
}

function New-Symlink {
    <#
      Creates a symlink via cmd's mklink rather than New-Item -ItemType SymbolicLink.

      This is deliberate. Windows PowerShell 5.1 does not pass
      SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE, so its New-Item demands
      elevation even when Developer Mode is on - it only learned the flag in
      PowerShell 7. mklink does pass it, so with Developer Mode enabled this
      succeeds as a normal user and no elevation (or sudo) is needed anywhere.

      Returns $true on success. Never throws.
    #>
    param($LinkPath, $SourceFull, [switch] $Directory)

    $out = if ($Directory) {
        & cmd.exe /c mklink /D $LinkPath $SourceFull 2>&1
    } else {
        & cmd.exe /c mklink $LinkPath $SourceFull 2>&1
    }

    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $LinkPath)) { return $true }
    $script:LastSymlinkError = ($out | Out-String).Trim()
    return $false
}

function Test-SymlinkCapability {
    <#
      Symlink creation needs either elevation or Developer Mode. Probe once per run,
      through the same mklink path used for real links, so the answer reflects what
      will actually happen. Lets us tell "linked, but via a fallback we can now
      improve on" apart from "linked correctly".
    #>
    if ($null -ne $script:SymlinkCapable) { return $script:SymlinkCapable }

    $probeDir = Join-Path ([System.IO.Path]::GetTempPath()) ("dotfiles-symlink-probe-" + [guid]::NewGuid().ToString('N'))
    $script:SymlinkCapable = $false
    # -WhatIf:$false throughout: this is a question about the environment, answered in
    # a scratch directory. Letting -WhatIf suppress it would make the probe report "no
    # symlinks" and the dry run would then describe a different plan than the real run.
    try {
        New-Item -ItemType Directory -Path $probeDir -Force -WhatIf:$false | Out-Null
        $realFile = Join-Path $probeDir 'real.txt'
        $linkFile = Join-Path $probeDir 'link.txt'
        Set-Content -LiteralPath $realFile -Value 'probe' -WhatIf:$false
        $script:SymlinkCapable = (New-Symlink $linkFile $realFile)
    } catch {
        $script:SymlinkCapable = $false
    } finally {
        if (Test-Path -LiteralPath $probeDir) {
            Remove-Item -LiteralPath $probeDir -Recurse -Force -WhatIf:$false -ErrorAction SilentlyContinue
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
        # Where a link points is spelled differently per host: Windows PowerShell 5.1
        # gives .Target as a String[], PowerShell 7 gives it as a plain String and adds
        # .LinkTarget. Under StrictMode, reading .Count off the 7.x string throws and
        # takes the whole run down, so read whichever this host actually offers.
        $current = ''
        if (($item.PSObject.Properties.Name -contains 'LinkTarget') -and $item.LinkTarget) {
            $current = [string]$item.LinkTarget
        } else {
            foreach ($t in @($item.Target)) { if ($t) { $current = [string]$t; break } }
        }
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

function Reset-Link {
    <#
      Re-points a link at the same source, atomically, purely to make the target
      directory emit a change notification.

      Why this exists: an app that hot-reloads its config watches the directory the
      config lives in (ReadDirectoryChangesW). When that config is a link into this
      repo, editing the repo file changes a file in a directory nobody is watching, so
      no notification is ever raised and the app keeps running stale settings. Writing
      *through* the link does not help either - measured, the notification follows the
      data to the target's directory, not the link's.

      Re-creating the link entry in the watched directory does raise one. Doing it as
      create-temp-then-rename rather than delete-then-create means the config path is
      never momentarily absent, so the app cannot observe a missing file and fall back
      to defaults.

      Measured, on this machine, writing to the repo file:

        file symlink in the watched dir ......... no notification
        hardlink in the watched dir ............. no notification
        write *through* the link ................ no notification
        directory symlink / junction AS the
          watched dir ........................... FIRES
        re-create the link entry (this) ......... FIRES

      So the notification follows the directory entry that was written, not the file
      identity - which is also why a hardlink does not help: it only fires when the
      write goes through the watched name, and the whole point here is that edits
      arrive via the repo name.

      Linking the enclosing directory instead does propagate, and is worth reaching
      for when an app keeps its config in a folder you can own outright. It is wrong
      for a packaged app such as Windows Terminal, whose LocalState is its own data
      folder: it also holds machine-local runtime state, and turning it into a reparse
      point invites trouble from package servicing and ACLs.

      Files only. A directory link cannot be replaced by a rename, and no app we link
      directories for needs this.
    #>
    param($LinkPath, $SourceFull, $Kind)

    if ($Kind -eq 'dir') { return 'skipped-dir' }
    if (-not (Test-Path -LiteralPath $LinkPath)) { return 'absent' }

    $dir  = Split-Path -Parent $LinkPath
    $leaf = Split-Path -Leaf $LinkPath
    $tmp  = Join-Path $dir ('.' + $leaf + '.' + [guid]::NewGuid().ToString('N') + '.tmp')

    try {
        $mech = New-ConfigLink $tmp $SourceFull $Kind
        Move-Item -LiteralPath $tmp -Destination $LinkPath -Force
        return $mech
    } catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        throw
    }
}

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

    $script:LastSymlinkError = 'not permitted (needs Developer Mode or elevation)'
    if (Test-SymlinkCapability) {
        if (New-Symlink $LinkPath $SourceFull -Directory:($Kind -eq 'dir')) {
            return 'SymbolicLink'
        }
    }

    # No symlink: fall back to something that needs no privilege at all.
    try {
        if ($Kind -eq 'dir') {
            New-Item -ItemType Junction -Path $LinkPath -Target $SourceFull -ErrorAction Stop | Out-Null
            return 'Junction'
        }
        New-Item -ItemType HardLink -Path $LinkPath -Target $SourceFull -ErrorAction Stop | Out-Null
        return 'HardLink'
    } catch {
        throw ("symlink failed ({0}); fallback failed ({1})" -f $script:LastSymlinkError, $_.Exception.Message)
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

        # skipIfParentMissing: the target lives inside an app's own folder. If that
        # folder is absent the app is not installed here, and creating it would leave
        # a bogus directory behind rather than a working link.
        $targetExpanded = Expand-TargetPath $targetRaw
        if ((Get-Prop $link 'skipIfParentMissing' $false)) {
            $parent = Split-Path -Parent $targetExpanded
            if (-not (Test-Path -LiteralPath $parent)) { continue }
        }

        # skipUnlessCommand: gate on the tool itself rather than on its config folder.
        # Needed when the folder legitimately does not exist yet and we intend to
        # create it - PowerShell 7 has no profile directory until something writes one,
        # so "is the directory there" would answer no on a machine that has pwsh.
        $needs = Get-Prop $link 'skipUnlessCommand' $null
        if ($needs -and -not (Get-Command $needs -ErrorAction SilentlyContinue)) { continue }

        $out += [pscustomobject]@{
            Source     = $link.source
            SourceFull = (Join-Path $RepoRoot ($link.source -replace '/', '\'))
            TargetFull = $targetExpanded
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

    $links = @(Resolve-ModuleLinks $Module $Platform)
    if ($links.Count -eq 0) {
        # A module may legitimately be packages-only, so fall through to requirements
        # rather than returning - only a module with neither is genuinely empty here.
        if (@($Module.requires).Count -eq 0 -and (Get-EnvEntries $Module).Count -eq 0) {
            Write-Note 'nothing defined for this platform'
            return
        }
        Show-EnvVars $Module
        Show-Requirements $Module
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

function Get-Prop($Object, $Name, $Default) {
    if ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $Default
}

function Get-RequirementName($Req) {
    switch ($Req.kind) {
        'winget'  { return (Get-Prop $Req 'id' '?') }
        'npm'     { return (Get-Prop $Req 'package' '?') }
        'font'    { return (Get-Prop $Req 'family' '?') }
        default   { return (Get-Prop $Req 'name' '?') }
    }
}

function Update-ProcessPath {
    # Rebuild this process's PATH from the persisted Machine and User values, so a
    # tool installed during this run becomes findable without starting a new shell.
    $parts = @(
        [Environment]::GetEnvironmentVariable('Path', 'Machine')
        [Environment]::GetEnvironmentVariable('Path', 'User')
    ) | Where-Object { $_ }
    if ($parts) { $env:Path = ($parts -join ';') }
}

function Test-FontInstalled($Family) {
    # Asks the system what families it actually has, so a font installed by any
    # route counts - not just one this script put there.
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $c = New-Object System.Drawing.Text.InstalledFontCollection
        return (@($c.Families | Where-Object { $_.Name -eq $Family }).Count -gt 0)
    } catch {
        return $false
    }
}

function Install-Font($Req) {
    <#
      Installs a TrueType file for the current user only: copy into
      %LOCALAPPDATA%\Microsoft\Windows\Fonts and add one HKCU registry value.

      Per-user on purpose. The machine-wide equivalent (%WINDIR%\Fonts plus HKLM)
      needs elevation, and nothing else in this bootstrap asks for that. Windows 10
      1809 and later resolve per-user fonts for every desktop app.

      The font is vendored in the repo rather than fetched: winget has no FiraCode
      Nerd Font package - only JetBrainsMono - so there is nothing to install from,
      and 2.5 MB of OFL-licensed font is cheaper than a download step that can fail
      offline or drift with upstream releases.
    #>
    $src = Join-Path $RepoRoot ((Get-Prop $Req 'file' '') -replace '/', '\')
    if (-not (Test-Path -LiteralPath $src)) {
        Write-Mark '[dep]' ("font file missing from repo: {0}" -f $src) 'Red'
        return $false
    }

    $dir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $dest = Join-Path $dir (Split-Path -Leaf $src)

    # A font file already in place is usually memory-mapped by the font cache, and
    # copying over it fails with "user-mapped section open". Skip the copy when the
    # bytes already match - which is the common case when only the registration was
    # lost - and tolerate a locked destination that is already the file we want.
    $needCopy = $true
    if (Test-Path -LiteralPath $dest) {
        if ((Get-FileHash -LiteralPath $src).Hash -eq (Get-FileHash -LiteralPath $dest).Hash) {
            $needCopy = $false
        }
    }
    if ($needCopy) {
        try {
            Copy-Item -LiteralPath $src -Destination $dest -Force -ErrorAction Stop
        } catch {
            if (-not (Test-Path -LiteralPath $dest)) {
                Write-Mark '[dep]' ("could not place font file: {0}" -f $_.Exception.Message) 'Red'
                return $false
            }
            Write-Note 'destination locked by the font cache; keeping the file already there'
        }
    }

    # Registry value name is a label; the real family comes from the file itself.
    # Read it back off the file so the entry matches what the font actually is.
    $label = Get-RequirementName $Req
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $pfc = New-Object System.Drawing.Text.PrivateFontCollection
        $pfc.AddFontFile($dest)
        if ($pfc.Families.Count -gt 0) { $label = $pfc.Families[0].Name }
        $pfc.Dispose()
    } catch { }

    $key = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    New-ItemProperty -Path $key -Name "$label (TrueType)" -Value $dest -PropertyType String -Force | Out-Null

    # Tell already-running apps a font arrived; without this they only notice on restart.
    #
    # SendMessageTimeout, not SendMessage. A plain SendMessage to HWND_BROADCAST waits
    # for every top-level window on the desktop to acknowledge, so one unresponsive
    # app hangs the bootstrap indefinitely - which is exactly what happened while
    # testing this. SMTO_ABORTIFHUNG plus a short timeout makes the notification
    # best-effort, which is all it ever needed to be: the font is already registered
    # by this point, and any app started afterwards picks it up regardless.
    try {
        Add-Type -Namespace Win32 -Name Font -MemberDefinition @'
[DllImport("gdi32.dll")] public static extern int AddFontResource(string lpFilename);
[DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SendMessageTimeout(
    IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out UIntPtr result);
'@ -ErrorAction Stop
        [Win32.Font]::AddFontResource($dest) | Out-Null
        $res = [UIntPtr]::Zero
        # HWND_BROADCAST, WM_FONTCHANGE, SMTO_ABORTIFHUNG|SMTO_NORMAL, 1s
        [Win32.Font]::SendMessageTimeout([IntPtr]0xffff, 0x001D, [IntPtr]::Zero, [IntPtr]::Zero, 0x0002, 1000, [ref]$res) | Out-Null
    } catch { }

    return $true
}

function Test-Requirement($Req) {
    <#
      Is this dependency already present? A `check` command is the fast path when the
      package puts something on PATH; otherwise fall back to asking the package
      manager, which is authoritative but slower.
    #>
    $check = Get-Prop $Req 'check' $null
    if ($check) {
        if (Get-Command $check -ErrorAction SilentlyContinue) { return $true }
    }

    switch ($Req.kind) {
        'font' {
            return (Test-FontInstalled (Get-Prop $Req 'family' ''))
        }
        'winget' {
            if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { return $false }
            & winget list --id $Req.id --exact --accept-source-agreements 2>&1 | Out-Null
            return ($LASTEXITCODE -eq 0)
        }
        'npm' {
            if ($check) { return $false }   # already probed above
            return [bool](Get-Command (Get-Prop $Req 'package' '') -ErrorAction SilentlyContinue)
        }
        default {
            return [bool](Get-Command (Get-Prop $Req 'name' '') -ErrorAction SilentlyContinue)
        }
    }
}

function Get-RequirementInstallCommand($Req) {
    switch ($Req.kind) {
        'winget' {
            return ("winget install --id {0} --exact --silent --accept-package-agreements --accept-source-agreements" -f $Req.id)
        }
        'npm' {
            return ("npm install -g {0}" -f $Req.package)
        }
        'font' {
            return ("install {0} from the repo (per-user, no elevation)" -f (Get-Prop $Req 'file' ''))
        }
        default { return (Get-Prop $Req 'install' $null) }
    }
}

function Install-Requirement($Req) {
    # Returns $true when the dependency ends up present.
    $name = Get-RequirementName $Req

    if ($Req.kind -eq 'font') {
        if (-not $PSCmdlet.ShouldProcess($name, 'install font for the current user')) { return $false }
        Write-Mark '[dep]' ("installing font {0} ..." -f $name) 'Cyan'
        if (-not (Install-Font $Req)) { return $false }
        if (Test-FontInstalled (Get-Prop $Req 'family' '')) {
            Write-Mark '[dep]' ("{0} installed" -f $name) 'Green'
            return $true
        }
        # Registered, but this process's font list was built at start-up and will not
        # show it. Treat a present file plus registry value as success.
        Write-Mark '[dep]' ("{0} installed (visible to new processes)" -f $name) 'Green'
        return $true
    }

    $tool = 'winget'
    if ($Req.kind -eq 'npm') { $tool = 'npm' }

    if ($Req.kind -eq 'winget' -or $Req.kind -eq 'npm') {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            Write-Mark '[dep]' ("{0} - cannot install, {1} is not available" -f $name, $tool) 'Red'
            return $false
        }
    } else {
        # 'command' kind is advisory only; we never guess how to install it.
        return $false
    }

    if (-not $PSCmdlet.ShouldProcess($name, ("install via " + $tool))) { return $false }

    Write-Mark '[dep]' ("installing {0} via {1} ..." -f $name, $tool) 'Cyan'

    if ($Req.kind -eq 'winget') {
        & winget install --id $Req.id --exact --silent `
            --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 |
            ForEach-Object { Write-Note $_ }
    } else {
        & npm install -g $Req.package 2>&1 | ForEach-Object { Write-Note $_ }
    }

    # An installer edits the persisted PATH, but this process inherited its copy at
    # start-up and will never see the change - so a tool installed a moment ago still
    # looks absent, and anything depending on it fails in the same run. Node is the
    # case that matters: packages installs it, then the claude module immediately
    # needs npm. Re-read PATH from the environment so the rest of the run can see it.
    Update-ProcessPath

    # Trust the post-state, not the exit code: winget reports distinct codes for
    # "already installed" and "reboot required", both of which are fine for us.
    if (Test-Requirement $Req) {
        Write-Mark '[dep]' ("{0} installed" -f $name) 'Green'
        return $true
    }

    Write-Mark '[dep]' ("{0} still missing after install (exit {1})" -f $name, $LASTEXITCODE) 'Red'
    return $false
}

# ------------------------------------------------------------- environment vars

function Resolve-EnvValue($Raw) {
    # {repo} is the one token that cannot be hardcoded in a shared file - it is where
    # this clone happens to live. Everything else is left to the OS to expand.
    return ([string]$Raw).Replace('{repo}', $RepoRoot)
}

function Get-EnvEntries($Module) {
    return @(Get-Prop $Module 'env' @())
}

function Show-EnvVars($Module) {
    foreach ($e in (Get-EnvEntries $Module)) {
        $scope = Get-Prop $e 'scope' 'User'
        $want  = Resolve-EnvValue $e.value
        $have  = [Environment]::GetEnvironmentVariable($e.name, $scope)
        Write-Host ''
        if ($have -eq $want) {
            Write-Mark '[env]' ("{0} = {1}" -f $e.name, $want) 'Green'
        } elseif ([string]::IsNullOrEmpty($have)) {
            Write-Mark '[env]' ("{0} unset - will set ({1})" -f $e.name, $scope) 'Yellow'
            Write-Note ("value: " + $want)
        } else {
            Write-Mark '[env]' ("{0} points elsewhere - will update" -f $e.name) 'Yellow'
            Write-Note ("now:  " + $have)
            Write-Note ("want: " + $want)
        }
        $reason = Get-Prop $e 'reason' ''
        if ($reason) { Write-Note $reason }
    }
}

function Invoke-EnvVars($Module) {
    foreach ($e in (Get-EnvEntries $Module)) {
        $scope = Get-Prop $e 'scope' 'User'
        $want  = Resolve-EnvValue $e.value
        $have  = [Environment]::GetEnvironmentVariable($e.name, $scope)

        Write-Host ''
        if ($have -eq $want) {
            Write-Mark '[env]' ("{0} already set" -f $e.name) 'Green'
            continue
        }

        if ($scope -eq 'Machine') {
            # Machine scope needs elevation; refuse rather than half-fail.
            Write-Mark '[env]' ("{0} - Machine scope needs an elevated run" -f $e.name) 'Yellow'
            $script:MissingDeps += ("env {0} ({1})" -f $e.name, $Module.id)
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($e.name, ("set {0} environment variable" -f $scope))) { continue }

        try {
            [Environment]::SetEnvironmentVariable($e.name, $want, $scope)
            # Also set it for this process so anything later in the run sees it; the
            # persisted value only reaches already-running apps after they restart.
            Set-Item -Path ("Env:" + $e.name) -Value $want
            Write-Mark '[env]' ("{0} set" -f $e.name) 'Green'
            Write-Note ("value: " + $want)
            $script:EnvChanged += $e.name
        } catch {
            $script:Failures += ("env {0}: {1}" -f $e.name, $_.Exception.Message)
            Write-Mark '[env]' ("{0} FAILED" -f $e.name) 'Red'
            Write-Note $_.Exception.Message
        }
    }
}


function Show-Requirements($Module) {
    if (-not ($Module.PSObject.Properties.Name -contains 'requires')) { return }
    if (@($Module.requires).Count -eq 0) { return }

    foreach ($req in @($Module.requires)) {
        $name = Get-RequirementName $req
        Write-Host ''
        if (Test-Requirement $req) {
            Write-Mark '[dep]' ("{0} present" -f $name) 'Green'
            continue
        }

        $auto = Get-Prop $req 'autoInstall' $false
        if ($auto) {
            Write-Mark '[dep]' ("{0} missing - will install" -f $name) 'Yellow'
        } else {
            Write-Mark '[dep]' ("{0} missing" -f $name) 'Yellow'
        }
        Write-Note (Get-Prop $req 'reason' '')
        $cmd = Get-RequirementInstallCommand $req
        if ($cmd) { Write-Note ("install with: " + $cmd) }
    }
}

function Invoke-Requirements($Module) {
    if (-not ($Module.PSObject.Properties.Name -contains 'requires')) { return }
    if (@($Module.requires).Count -eq 0) { return }

    foreach ($req in @($Module.requires)) {
        $name = Get-RequirementName $req
        Write-Host ''

        if (Test-Requirement $req) {
            Write-Mark '[dep]' ("{0} present" -f $name) 'Green'
            continue
        }

        $auto = Get-Prop $req 'autoInstall' $false
        if ($SkipPackages -or -not $auto) {
            $script:MissingDeps += ("{0} ({1})" -f $name, $Module.id)
            Write-Mark '[dep]' ("{0} missing" -f $name) 'Yellow'
            Write-Note (Get-Prop $req 'reason' '')
            $cmd = Get-RequirementInstallCommand $req
            if ($cmd) { Write-Note ("install with: " + $cmd) }
            continue
        }

        # An autoInstall that was asked for and did not work is a genuine failure, not
        # just a note - it should show up in the exit code.
        if (-not (Install-Requirement $req)) {
            if ($WhatIfPreference) {
                $script:MissingDeps += ("{0} ({1})" -f $name, $Module.id)
            } else {
                $script:Failures += ("{0}: install failed ({1})" -f $name, $Module.id)
            }
        }
    }
}


# ----------------------------------------------------------------------- apply

function Invoke-Reload($Module, $Platform) {
    Write-Head ("reloading: " + $Module.id)
    $any = $false

    foreach ($l in @(Resolve-ModuleLinks $Module $Platform)) {
        $st = Get-LinkState $l.SourceFull $l.TargetFull
        if ($st.State -ne 'Linked' -and $st.State -ne 'Upgrade') {
            Write-Mark '[skip]' $l.TargetFull 'DarkGray'
            Write-Note 'not currently linked; run without -Reload first'
            continue
        }
        if ($l.Kind -eq 'dir') { continue }
        if (-not $PSCmdlet.ShouldProcess($l.TargetFull, 'nudge watcher by re-creating the link')) { continue }

        try {
            $mech = Reset-Link $l.TargetFull $l.SourceFull $l.Kind
            if ($mech -eq 'skipped-dir' -or $mech -eq 'absent') { continue }
            $any = $true
            $script:Reloaded++
            Write-Mark '[nudge]' $l.TargetFull 'Green'
        } catch {
            $script:Failures += ("reload {0}: {1}" -f $l.TargetFull, $_.Exception.Message)
            Write-Mark '[FAIL]' $l.TargetFull 'Red'
            Write-Note $_.Exception.Message
        }
    }

    if (-not $any) { Write-Note 'nothing to nudge' }
}

function Invoke-Module($Module, $Platform) {
    Write-Head ("applying: " + $Module.id)

    foreach ($l in @(Resolve-ModuleLinks $Module $Platform)) {
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

    Invoke-EnvVars $Module
    Invoke-Requirements $Module
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
    if ($Reload) { Invoke-Reload $m $platform } else { Invoke-Module $m $platform }
}

if (-not $Reload) { Save-Modules $selected }


# --------------------------------------------------------------------- summary

Write-Head 'summary'
Write-Host ("  linked      {0}" -f $script:Applied)
Write-Host ("  already ok  {0}" -f $script:AlreadyOk)
if ($Reload) { Write-Host ("  nudged      {0}" -f $script:Reloaded) }

$hardlinked = @($script:Fallbacks | Where-Object { $_ -like '*(HardLink)' })
if ($hardlinked.Count -gt 0) {
    Write-Host ''
    Write-Host '  Symlinks unavailable - used hardlinks instead:' -ForegroundColor Yellow
    foreach ($f in $hardlinked) { Write-Host ("    " + $f) -ForegroundColor Yellow }
    Write-Host '    A hardlink breaks silently if a tool replaces the file rather than' -ForegroundColor DarkGray
    Write-Host '    editing it in place, and edits then stop reaching the repo.' -ForegroundColor DarkGray
    Write-Host '    For real symlinks, turn on Developer Mode (Settings > System > For' -ForegroundColor DarkGray
    Write-Host '    developers) - no elevation needed, mklink honours it - then re-run;' -ForegroundColor DarkGray
    Write-Host '    this script detects the hardlinks and upgrades them in place.' -ForegroundColor DarkGray
    Write-Host '    Failing that, run it once via sudo or from an elevated shell.' -ForegroundColor DarkGray
}

if ($script:Conflicts.Count -gt 0) {
    Write-Host ''
    Write-Host ("  Skipped {0} conflict(s):" -f $script:Conflicts.Count) -ForegroundColor Red
    foreach ($c in $script:Conflicts) { Write-Host ("    " + $c) -ForegroundColor Red }
    Write-Host '    Re-run with -Force to back these up and link.' -ForegroundColor DarkGray
}

if ($script:MissingDeps.Count -gt 0) {
    Write-Host ''
    Write-Host ("  {0} dependency/ies still missing:" -f $script:MissingDeps.Count) -ForegroundColor Yellow
    foreach ($d in $script:MissingDeps) { Write-Host ("    " + $d) -ForegroundColor Yellow }
    if ($SkipPackages) {
        Write-Host '    (-SkipPackages was set; re-run without it to install)' -ForegroundColor DarkGray
    }
}

if ($script:Failures.Count -gt 0) {
    Write-Host ''
    Write-Host ("  {0} failure(s):" -f $script:Failures.Count) -ForegroundColor Red
    foreach ($f in $script:Failures) { Write-Host ("    " + $f) -ForegroundColor Red }
}

Write-Host ''
if ($script:Conflicts.Count -gt 0 -or $script:Failures.Count -gt 0) { exit 1 }
exit 0
