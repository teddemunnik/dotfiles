# PowerShell profile - versioned in dotfiles, linked to $PROFILE.CurrentUserAllHosts.
#
# AllHosts (profile.ps1, not Microsoft.PowerShell_profile.ps1) so it loads in Windows
# Terminal, the ISE and the VS Code integrated terminal alike. The same file is linked
# into both Windows PowerShell's and PowerShell 7's profile directories.
#
# This file is shared across machines, so everything in it must either be true
# everywhere or guard itself. Anything genuinely local to one machine belongs in
# Microsoft.PowerShell_profile.ps1 next to this file, which is deliberately not
# versioned - PowerShell loads both, AllHosts first.

# --- elevated shells look different -------------------------------------------
# Keyed off the process token, not off which Windows Terminal profile launched the
# shell, so it covers every route to an elevated prompt: `sudo`, Run as
# administrator, a profile with elevate:true. A Windows Terminal profile could only
# style the last of those - and with sudo in Inline mode the elevated shell reuses
# the current tab, so there is no new tab for a profile to style at all.
#
# Defined BEFORE zoxide below, on purpose. zoxide's init wraps whatever `prompt`
# already exists so it can record each directory; redefining `prompt` afterwards
# would throw that wrapper away and silently stop the database ever filling.
$__isElevated = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
                ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($__isElevated) {
    $Host.UI.RawUI.WindowTitle = "ADMIN  -  $($Host.UI.RawUI.WindowTitle)"

    function prompt {
        $esc = [char]27
        $badge = "$esc[1;97;41m ADMIN $esc[0m"          # white on red
        $path  = "$esc[38;5;110m$($ExecutionContext.SessionState.Path.CurrentLocation)$esc[0m"
        "$badge $path$('>' * ($nestedPromptLevel + 1)) "
    }
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
