# PowerShell profile - versioned in dotfiles, linked to $PROFILE.CurrentUserAllHosts.
#
# AllHosts (profile.ps1, not Microsoft.PowerShell_profile.ps1) so it loads in Windows
# Terminal, the ISE and the VS Code integrated terminal alike. The same file is linked
# into both Windows PowerShell's and PowerShell 7's profile directories.
#
# This file is shared across machines, so everything in it must either be true
# everywhere or guard itself. Anything genuinely local to one machine belongs in
# profile.local.ps1, which the last block here dot-sources.

# --- completion ---------------------------------------------------------------
# Out of the box Tab is TabCompleteNext, which cycles through matches one at a time
# without showing you what they are; the menu lives on Ctrl+Space. Swap so Tab opens
# the menu - Shift+Tab still steps backwards, and inside the menu the arrow keys
# navigate.
#
# Guarded because profile.ps1 is the AllHosts profile: it also runs in hosts that
# never load PSReadLine, where these cmdlets do not exist.
if (Get-Command Set-PSReadLineKeyHandler -ErrorAction SilentlyContinue) {
    Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
}

# --- zoxide -------------------------------------------------------------------
# Guarded rather than unconditional. The same profile lands on every machine and
# one of them may not have zoxide yet; `bootstrap.ps1 -Modules packages` installs
# it. Until then this block is skipped instead of erroring on every new prompt.
#
# Gives you `z <partial>` to jump to a frecent directory. `zi` picks
# interactively and needs fzf, which the packages module installs alongside.
if (Get-Command zoxide -ErrorAction SilentlyContinue) {
    Invoke-Expression (& { (zoxide init powershell | Out-String) })
}

# --- ushell -------------------------------------------------------------------
# `ushell` enters an Unreal ushell session in the current PowerShell process, for
# whichever engine branch the current directory happens to sit in.
#
# In this shared profile rather than a machine-local one because it costs a machine
# without Unreal nothing: it defines a function and an alias, touches no paths until
# it is called, and where there is no branch to find it simply never gets called.
# The branch is discovered per invocation for the same reason - a machine may have
# several checked out, and each ships its own ushell under Engine\Extras that goes
# with that branch's engine, so there is nothing worth hardcoding.
#
# ushell.bat is the usual entry point, but it starts a cmd.exe session - a new window
# from Explorer, a child process from a shell. Epic also ship ushell as a PowerShell
# module (ushell.psm1 -> channels/flow/nt/boot.ps1) which sets the session up in the
# host shell instead. That is what this uses, so ushell's commands land in the tab
# you are already in and keep the prompt, the history and the Tab binding set above.
function Enter-Ushell {
    [CmdletBinding()]
    param(
        # Where to start looking for a branch and a project. Defaults to the current
        # directory, which is the whole point of the shortcut.
        [string] $Path
    )

    if (Get-Module -Name ushell) {
        Write-Host 'ushell is already loaded in this session.' -ForegroundColor DarkGray
        return
    }

    if (-not $Path) { $Path = $PWD.ProviderPath }
    try {
        $cursor = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    } catch {
        Write-Error "not a path: $Path"
        return
    }

    # One walk up the tree collects both halves. The .uproject is the first one seen
    # on the way up - the project you are actually in - and the branch is the first
    # ancestor with an engine in it, so from <branch>\MyGame\Source you get
    # MyGame.uproject and <branch>, in that order.
    $uproject = $null
    $branch   = $null
    while ($cursor) {
        if (-not $uproject) {
            $found = @(Get-ChildItem -LiteralPath $cursor -Filter '*.uproject' -File -ErrorAction SilentlyContinue)
            if ($found.Count -gt 0) { $uproject = $found[0].FullName }
        }
        if (Test-Path -LiteralPath (Join-Path $cursor 'Engine\Extras\ushell\ushell.psm1')) {
            $branch = $cursor
            break
        }
        $parent = Split-Path -Parent $cursor
        if ($parent -eq $cursor) { break }   # reached the drive root
        $cursor = $parent
    }

    if (-not $branch) {
        Write-Error "no Engine\Extras\ushell in any parent of $Path - cd into a branch first"
        return
    }

    # A project can ship ushell commands of its own, and ushell only finds those
    # through this variable. UGS sets it the same way for its own ushell button; the
    # forward slashes are its doing too - ushell splits the value with Python's
    # shlex, which eats backslashes.
    if ($uproject) {
        $channels = Join-Path (Split-Path -Parent $uproject) 'Build\ushell\channels'
        if (Test-Path -LiteralPath $channels) {
            $env:FLOW_CHANNELS_DIR = $channels.Replace('\', '/')
        }
    }

    # --project= rather than relying on the working directory: ushell infers the
    # project from the cwd, which is right only while the cwd is inside a project,
    # and this is as likely to be run from Engine or the branch root.
    $bootArgs = @()
    if ($uproject) { $bootArgs += "--project=$uproject" }

    $label = if ($uproject) { " ($(Split-Path -Leaf $uproject))" } else { '' }
    Write-Host ("ushell: {0}{1}" -f $branch, $label) -ForegroundColor DarkGray
    Import-Module (Join-Path $branch 'Engine\Extras\ushell\ushell.psm1') -ArgumentList $bootArgs -Global -DisableNameChecking
}

Set-Alias -Name ushell -Value Enter-Ushell

# --- machine-local ------------------------------------------------------------
# Last, so a machine can override anything set above.
#
# profile.local.ps1 is gitignored: it holds the things that are true of one machine
# only - a path that exists nowhere else, a work-only tool's setup. Edit it in
# the repo alongside this file; `bootstrap.ps1 -Modules powershell` links it beside
# each host's profile.ps1, which is why $PSScriptRoot finds it. Machines without one
# skip this silently.
#
# Not dot-sourced from the repo directly, and not named
# Microsoft.PowerShell_profile.ps1 - see the powershell module in
# bootstrap/modules.json for why.
$localProfile = Join-Path $PSScriptRoot 'profile.local.ps1'
if (Test-Path -LiteralPath $localProfile) { . $localProfile }
