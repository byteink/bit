# Runs one windowssmoke child on the Windows box and guarantees it does not
# outlive this script (#7824). `windowssmoke.bit` ships it next to the fixtures and
# starts every remote program through it:
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File runchild.ps1 <exe> <timeoutSec> [<redirectTo>]
#
# The child inherits this script's stdout and stderr, so its output reaches the
# harness byte for byte. This script puts ITSELF into a job object with
# JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE ("Causes all processes associated with the job
# to terminate when the last handle to the job is closed", Microsoft Learn,
# JOBOBJECT_BASIC_LIMIT_INFORMATION) before it starts the child. The child and its
# own children are created inside the job, so there is no window between the start
# and the assignment, and the last handle is this process's: whenever it ends, by
# timeout, by a kill or by the SSH session dropping, the whole tree goes with it.
# Nested jobs need Windows 8 or later (Microsoft Learn, Job Objects).
#
# Exit code: the child's; 124 when it ran past <timeoutSec> and was killed, with a
# `wsmoke-run: TIMEOUT` line on stderr; 125 when the job object could not be set up.
# <redirectTo> runs the child as `cmd /c "<exe> > <redirectTo>"`, the raw handle
# redirect the manyprints phase asserts on.
param(
  [Parameter(Mandatory = $true)][string]$Exe,
  [Parameter(Mandatory = $true)][int]$TimeoutSec,
  [string]$RedirectTo = ''
)

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class WsmokeJob {
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern IntPtr CreateJobObjectW(IntPtr attrs, string name);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, int size);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
  [DllImport("kernel32.dll")]
  static extern IntPtr GetCurrentProcess();

  // JobObjectExtendedLimitInformation (9) is 144 bytes on x64; LimitFlags sits at
  // offset 16, after the two 8-byte time limits.
  public static string KillOnClose() {
    IntPtr job = CreateJobObjectW(IntPtr.Zero, null);
    if (job == IntPtr.Zero) { return "CreateJobObjectW " + Marshal.GetLastWin32Error(); }
    IntPtr info = Marshal.AllocHGlobal(144);
    for (int i = 0; i < 144; i++) { Marshal.WriteByte(info, i, 0); }
    Marshal.WriteInt32(info, 16, 0x2000);
    bool set = SetInformationJobObject(job, 9, info, 144);
    int setErr = Marshal.GetLastWin32Error();
    Marshal.FreeHGlobal(info);
    if (!set) { return "SetInformationJobObject " + setErr; }
    if (!AssignProcessToJobObject(job, GetCurrentProcess())) {
      return "AssignProcessToJobObject " + Marshal.GetLastWin32Error();
    }
    return "";  // the job handle stays open until this process exits
  }
}
'@

$err = [WsmokeJob]::KillOnClose()
if ($err -ne '') {
  [Console]::Error.WriteLine("wsmoke-run: cannot make the job object: $err")
  exit 125
}

$path = Join-Path $PWD.Path $Exe
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.UseShellExecute = $false
if ($RedirectTo -eq '') {
  $psi.FileName = $path
} else {
  $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
  $psi.Arguments = '/c ""' + $path + '" > "' + (Join-Path $PWD.Path $RedirectTo) + '""'
}
$p = [System.Diagnostics.Process]::Start($psi)
if (-not $p.WaitForExit($TimeoutSec * 1000)) {
  $p.Kill()
  [Console]::Error.WriteLine("wsmoke-run: TIMEOUT after ${TimeoutSec}s, killed $Exe (pid $($p.Id))")
  exit 124
}
exit $p.ExitCode
