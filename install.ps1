<#
.SYNOPSIS
Installs nova-nix for the current user on Windows, upgrades it, removes it, or
sets up its store alone.

.DESCRIPTION
Downloads a nova-nix release archive and the release's SHA256SUMS, refuses an
archive that does not match, sets up C:\nix for the store, unpacks the archive
into %LOCALAPPDATA%\Programs\nova-nix and adds its bin directory to the user
Path. Run it again to upgrade: the install is replaced by the release it names.

Runs in Windows PowerShell 5.1 and PowerShell 7.

.PARAMETER Version
The release to install, such as 0.10.0.0. The latest release by default.

.PARAMETER From
A directory holding a release's archive and SHA256SUMS, installed in place of a
download.

.PARAMETER StoreOnly
Sets up C:\nix for the store, and installs nothing.

.PARAMETER Uninstall
Removes nova-nix and the user Path entry this script added. The store is kept.

.PARAMETER RemoveStore
With -Uninstall, also removes the store in C:\nix\store.

.EXAMPLE
powershell -c "irm https://raw.githubusercontent.com/Novavero-AI/install-nova-nix/v1/install.ps1 | iex"

.EXAMPLE
powershell -c "& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Novavero-AI/install-nova-nix/v1/install.ps1))) -Version 0.10.0.0"
#>
param(
    [string]$Version = '',
    [string]$From = '',
    [switch]$StoreOnly,
    [switch]$Uninstall,
    [switch]$RemoveStore
)

# Nothing happens until the last line, so a download cut short does nothing.
# The work is in functions, so the preferences they set do not outlast the
# script in a session that runs it through Invoke-Expression.

$NovaNixRepository = 'Novavero-AI/nova-nix'
$NovaNixStem = 'nova-nix-windows-x64'
$NovaNixArchive = "$NovaNixStem.zip"
# Normalised once, so a LOCALAPPDATA ending in a separator or written with
# forward slashes names the same folder in every open, listing and delete.
$NovaNixRoot = $null
if ($env:LOCALAPPDATA) {
    $NovaNixRoot = [System.IO.Path]::GetFullPath("$env:LOCALAPPDATA\Programs\nova-nix")
}
# nova-nix keeps its store in C:\nix\store whatever the system drive is, and
# only its --store option moves it.
$NovaNixStoreRoot = 'C:\nix'
$NovaNixStore = 'C:\nix\store'
$NovaNixStoreInheritance = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
$FileAttributeDirectory = 0x10
$FileAttributeReparsePoint = 0x400

# SendMessageTimeout arguments that tell every top-level window, Explorer
# among them, that the environment changed, skipping any that hang.
$HwndBroadcast = [IntPtr]0xffff
$WmSettingChange = 0x1a
$SmtoAbortIfHung = 0x2
$SettingChangeTimeoutMs = 5000

function Write-Step([string]$Message) {
    Write-Information -MessageData $Message -InformationAction Continue
}

# A release version: digits separated by dots, with an optional leading v.
# It becomes a path segment of the download URL, so nothing else is let in.
function Test-Release([string]$Value) {
    return $Value -cmatch '\Av?[0-9]+(\.[0-9]+)*\z'
}

function Test-Link([System.IO.FileSystemInfo]$Item) {
    return [bool]($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

# ---------------------------------------------------------------------------
# Download and verification
# ---------------------------------------------------------------------------

# GitHub answers .../releases/latest with a redirect to the newest release's
# tag. Reading the version from it names one release for both downloads,
# where .../releases/latest/download/ could serve them from two releases if
# one is published in between. Invoke-WebRequest reports a redirect it does
# not follow differently in Windows PowerShell and PowerShell 7, and
# HttpWebRequest returns it the same way in both.
function Get-LatestVersion {
    $url = "https://github.com/$NovaNixRepository/releases/latest"
    $request = [System.Net.WebRequest]::Create($url)
    $request.AllowAutoRedirect = $false
    $response = $request.GetResponse()
    try {
        $status = [int]$response.StatusCode
        $location = $response.Headers['Location']
    } finally {
        $response.Close()
    }
    if ($status -lt 300 -or $status -ge 400) {
        throw "GitHub answered $url with HTTP $status"
    }
    $prefix = "https://github.com/$NovaNixRepository/releases/tag/v"
    if ($null -eq $location -or -not $location.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
        throw "$NovaNixRepository has no release to install"
    }
    $latest = $location.Substring($prefix.Length)
    if (-not (Test-Release $latest)) {
        throw 'the latest release is not tagged with a version'
    }
    return $latest
}

function Save-Download([string]$Url, [string]$Path) {
    Write-Step "Downloading $Url"
    Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing
}

# The checksum on the one line of SHA256SUMS that names the archive. The name
# is compared as a string, since it is full of dots a pattern would let match
# anything.
function Get-ExpectedHash([string]$SumsPath) {
    $found = @(Get-Content -LiteralPath $SumsPath | ForEach-Object {
            $fields = $_.Trim() -split '\s+', 2
            if ($fields.Count -eq 2 -and $fields[1].TrimStart('*') -ceq $NovaNixArchive) {
                $fields[0].ToLowerInvariant()
            }
        })
    if ($found.Count -eq 0) {
        throw "SHA256SUMS lists no checksum for $NovaNixArchive"
    }
    if ($found.Count -ne 1 -or $found[0] -cnotmatch '\A[0-9a-f]{64}\z') {
        throw "SHA256SUMS does not list exactly one checksum for $NovaNixArchive"
    }
    return $found[0]
}

function Assert-Checksum([string]$ArchivePath, [string]$SumsPath) {
    $expected = Get-ExpectedHash -SumsPath $SumsPath
    $actual = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -cne $expected) {
        throw "$NovaNixArchive does not match its checksum in SHA256SUMS (expected $expected, got $actual); refusing to install it"
    }
    Write-Step "$NovaNixArchive matches its checksum in SHA256SUMS"
}

# Runs the nova-nix in the unpacked archive, so one that cannot run here, or
# reports another version, is refused before anything changes.
function Get-ReportedVersion([string]$Executable, [string]$Expected) {
    $output = & $Executable --version
    if ($LASTEXITCODE -ne 0) {
        throw "the nova-nix in $NovaNixArchive does not run on this machine (exit code $LASTEXITCODE)"
    }
    $reported = ($output | Out-String).Trim()
    if (-not $reported.StartsWith('nova-nix ', [System.StringComparison]::Ordinal)) {
        throw "the nova-nix in $NovaNixArchive reports its version as '$reported'"
    }
    if ($Expected -and $reported -cne "nova-nix $Expected") {
        throw "$NovaNixArchive holds $reported, not nova-nix $Expected"
    }
    return $reported
}

# ---------------------------------------------------------------------------
# Files and the install directory
# ---------------------------------------------------------------------------

# Opens an entry without following it when it is a link, and reads its
# attributes and its owner and DACL through that one handle, or writes a
# DACL through it. Get-Acl, Set-Acl, FileSystemInfo.Attributes and the
# listing a directory gives all go by path, which a link or junction put in
# place of an entry redirects.
$NovaNixEntrySource = @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace NovaNix
{
    public static class Entry
    {
        private const uint ReadAttributes = 0x00000080;
        private const uint ReadControl = 0x00020000;
        private const uint WriteDac = 0x00040000;
        private const uint ShareAll = 0x00000007;
        private const uint OpenExisting = 3;
        private const uint OpenReparsePoint = 0x00200000;
        private const uint BackupSemantics = 0x02000000;
        private const int FileObject = 1;
        private const uint OwnerInformation = 0x00000001;
        private const uint DaclInformation = 0x00000004;
        private const uint ProtectedDaclInformation = 0x80000000;
        private const uint DirectoryAttribute = 0x00000010;
        private const uint ReparsePointAttribute = 0x00000400;
        private const uint Delete = 0x00010000;
        private const int FileBasicInfo = 0;
        private const int FileDispositionInfo = 4;
        private const int FileDispositionInfoEx = 21;
        private const uint DispositionDelete = 0x00000001;
        private const uint DispositionPosixSemantics = 0x00000002;
        private const uint DispositionIgnoreReadOnly = 0x00000010;
        private const uint WriteAttributesAccess = 0x00000100;
        private const uint ReadOnlyAttribute = 0x00000001;
        private const uint NormalAttribute = 0x00000080;
        private const int InvalidFunction = 1;
        private const int InvalidParameter = 87;
        private const int NotSupported = 50;
        private const int FileNotFound = 2;
        private const int PathNotFound = 3;
        private const string LongPathPrefix = @"\\?\";

        [StructLayout(LayoutKind.Sequential)]
        private struct FileTime
        {
            public uint Low;
            public uint High;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct FileInformation
        {
            public uint Attributes;
            public FileTime Created;
            public FileTime Accessed;
            public FileTime Written;
            public uint VolumeSerialNumber;
            public uint SizeHigh;
            public uint SizeLow;
            public uint Links;
            public uint IndexHigh;
            public uint IndexLow;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInformation information);

        [DllImport("advapi32.dll")]
        private static extern uint GetSecurityInfo(SafeFileHandle handle, int type, uint information, IntPtr owner, IntPtr group, IntPtr dacl, IntPtr sacl, out IntPtr descriptor);

        [DllImport("advapi32.dll")]
        private static extern uint SetSecurityInfo(SafeFileHandle handle, int type, uint information, IntPtr owner, IntPtr group, IntPtr dacl, IntPtr sacl);

        [StructLayout(LayoutKind.Sequential)]
        private struct BasicInformation
        {
            public long Created;
            public long Accessed;
            public long Written;
            public long Changed;
            public uint Attributes;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetFileInformationByHandle(SafeFileHandle handle, int type, ref uint information, uint size);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetFileInformationByHandle(SafeFileHandle handle, int type, ref byte information, uint size);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetFileInformationByHandle(SafeFileHandle handle, int type, ref BasicInformation information, uint size);

        [DllImport("advapi32.dll")]
        private static extern uint GetSecurityDescriptorLength(IntPtr descriptor);

        [DllImport("kernel32.dll")]
        private static extern IntPtr LocalFree(IntPtr memory);

        private static SafeFileHandle Open(string path, uint access, out int error)
        {
            string name = path.StartsWith(LongPathPrefix, StringComparison.Ordinal) ? path : LongPathPrefix + path;
            SafeFileHandle handle = CreateFileW(name, access, ShareAll, IntPtr.Zero, OpenExisting, OpenReparsePoint | BackupSemantics, IntPtr.Zero);
            error = handle.IsInvalid ? Marshal.GetLastWin32Error() : 0;
            return handle;
        }

        private static SafeFileHandle OpenOrThrow(string path, uint access, string failure)
        {
            int error;
            SafeFileHandle handle = Open(path, access, out error);
            if (handle.IsInvalid)
            {
                handle.Dispose();
                throw new InvalidOperationException(failure + " (Windows error " + error + ")");
            }
            return handle;
        }

        private static uint AttributesOf(SafeFileHandle handle, string path)
        {
            FileInformation information;
            if (!GetFileInformationByHandle(handle, out information))
            {
                throw new InvalidOperationException("the attributes of " + path + " cannot be read (Windows error " + Marshal.GetLastWin32Error() + ")");
            }
            return information.Attributes;
        }

        // Whether there is an entry at path, a link that leads nowhere included.
        public static bool Exists(string path)
        {
            int error;
            using (SafeFileHandle handle = Open(path, ReadAttributes, out error))
            {
                if (!handle.IsInvalid)
                {
                    return true;
                }
                if (error == FileNotFound || error == PathNotFound)
                {
                    return false;
                }
                throw new InvalidOperationException(path + " cannot be opened (Windows error " + error + ")");
            }
        }

        // The attributes of the entry at path itself.
        public static uint Attributes(string path)
        {
            using (SafeFileHandle handle = OpenOrThrow(path, ReadAttributes, path + " cannot be opened"))
            {
                return AttributesOf(handle, path);
            }
        }

        // The owner and DACL of the entry at path itself, in binary form, and
        // its attributes, read through one handle.
        public static byte[] Read(string path, out uint attributes)
        {
            using (SafeFileHandle handle = OpenOrThrow(path, ReadAttributes | ReadControl, path + " cannot be opened, so whose it is cannot be told; leaving the store in place"))
            {
                attributes = AttributesOf(handle, path);
                IntPtr descriptor;
                uint error = GetSecurityInfo(handle, FileObject, OwnerInformation | DaclInformation, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, out descriptor);
                if (error != 0)
                {
                    throw new InvalidOperationException("the owner of " + path + " cannot be read (Windows error " + error + "); leaving the store in place");
                }
                try
                {
                    byte[] bytes = new byte[GetSecurityDescriptorLength(descriptor)];
                    Marshal.Copy(descriptor, bytes, 0, bytes.Length);
                    return bytes;
                }
                finally
                {
                    LocalFree(descriptor);
                }
            }
        }

        // Deletes the entry at path itself, a link and never what it leads
        // to, through a handle that does not follow it. A read-only entry is
        // deleted as it is; where Windows cannot do that in one step, which
        // it can from Windows 10 1809, the read-only attribute is cleared
        // through the same handle first, its other bits kept as they are.
        public static void Remove(string path)
        {
            using (SafeFileHandle handle = OpenOrThrow(path, Delete | ReadAttributes | WriteAttributesAccess, path + " could not be removed: it cannot be opened"))
            {
                uint flags = DispositionDelete | DispositionPosixSemantics | DispositionIgnoreReadOnly;
                if (SetFileInformationByHandle(handle, FileDispositionInfoEx, ref flags, sizeof(uint)))
                {
                    return;
                }
                int error = Marshal.GetLastWin32Error();
                if (error != InvalidParameter && error != InvalidFunction && error != NotSupported)
                {
                    throw new InvalidOperationException(path + " could not be removed (Windows error " + error + ")");
                }
                uint attributes = AttributesOf(handle, path);
                if ((attributes & ReadOnlyAttribute) != 0)
                {
                    BasicInformation basic = new BasicInformation();
                    uint kept = attributes & ~ReadOnlyAttribute & ~DirectoryAttribute & ~ReparsePointAttribute;
                    basic.Attributes = kept == 0 ? NormalAttribute : kept;
                    if (!SetFileInformationByHandle(handle, FileBasicInfo, ref basic, (uint)Marshal.SizeOf(typeof(BasicInformation))))
                    {
                        throw new InvalidOperationException(path + " could not be made writable to remove it (Windows error " + Marshal.GetLastWin32Error() + ")");
                    }
                }
                byte delete = 1;
                if (!SetFileInformationByHandle(handle, FileDispositionInfo, ref delete, 1))
                {
                    throw new InvalidOperationException(path + " could not be removed (Windows error " + Marshal.GetLastWin32Error() + ")");
                }
            }
        }

        // Writes dacl, protected, to the directory at path through a handle
        // that refuses anything but a directory of its own.
        public static void ProtectDirectory(string path, byte[] dacl)
        {
            using (SafeFileHandle handle = OpenOrThrow(path, ReadAttributes | ReadControl | WriteDac, "the permissions of " + path + " could not be written: it cannot be opened to write them"))
            {
                uint attributes = AttributesOf(handle, path);
                if ((attributes & DirectoryAttribute) == 0 || (attributes & ReparsePointAttribute) != 0)
                {
                    throw new InvalidOperationException(path + " is not a directory of its own; move it away, then run this again");
                }
                GCHandle pinned = GCHandle.Alloc(dacl, GCHandleType.Pinned);
                try
                {
                    uint error = SetSecurityInfo(handle, FileObject, DaclInformation | ProtectedDaclInformation, IntPtr.Zero, IntPtr.Zero, pinned.AddrOfPinnedObject(), IntPtr.Zero);
                    if (error != 0)
                    {
                        throw new InvalidOperationException("the permissions of " + path + " could not be written (Windows error " + error + ")");
                    }
                }
                finally
                {
                    pinned.Free();
                }
            }
        }
    }
}
'@

function Import-EntryNative {
    if (-not ('NovaNix.Entry' -as [type])) {
        Add-Type -TypeDefinition $NovaNixEntrySource
    }
}

# The attribute bits of the entry at a path itself, a link not followed, as
# the number Windows keeps: some bits it sets, such as those OneDrive and
# attrib +P use, System.IO.FileAttributes does not define.
function Get-EntryAttribute([string]$Path) {
    Import-EntryNative
    return [NovaNix.Entry]::Attributes($Path)
}

# Deletes a file or a directory tree. Whether each entry is a directory to
# go into is read from the entry itself, through a handle that does not
# follow a link, just before its contents are listed, and each entry is
# deleted through such a handle too, so a link or junction there at that
# moment is removed itself and never followed. The listing goes by path, so
# a junction put in place of a directory between that read and the listing
# would be listed through: what this removes is this user's install, or a
# store the checks before it have shown no other account can change, so
# only this user or an administrator could make that swap.
function Remove-Tree {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)

    if (-not $PSCmdlet.ShouldProcess($Path, 'Remove')) {
        return
    }
    $attributes = Get-EntryAttribute $Path
    if (($attributes -band $FileAttributeDirectory) -and -not ($attributes -band $FileAttributeReparsePoint)) {
        foreach ($child in [System.IO.Directory]::GetFileSystemEntries($Path)) {
            Remove-Tree -Path $child
        }
    }
    [NovaNix.Entry]::Remove($Path)
}

function Test-Install([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    return ($item -is [System.IO.DirectoryInfo]) -and -not (Test-Link $item) -and
        (Test-Path -LiteralPath (Join-Path $Path 'bin\nova-nix.exe') -PathType Leaf)
}

# Refuses to go on when the install directory holds something else, before
# anything is downloaded or changed.
function Assert-InstallRoot([string]$Refusal) {
    if ((Test-Path -LiteralPath $NovaNixRoot) -and -not (Test-Install $NovaNixRoot)) {
        throw "$NovaNixRoot $Refusal"
    }
}

# Moves the unpacked archive into place. The previous install is moved to a
# folder of its own beside it, outside the scratch folder, so that a failed
# or interrupted move leaves it to be put back rather than deleted with the
# scratch folder.
function Move-Install([string]$Staged) {
    $previous = $null
    if (Test-Path -LiteralPath $NovaNixRoot) {
        $previous = "$NovaNixRoot.previous-" + [guid]::NewGuid().ToString('N')
        Move-Item -LiteralPath $NovaNixRoot -Destination $previous
    }
    try {
        Move-Item -LiteralPath $Staged -Destination $NovaNixRoot
    } finally {
        if ($null -ne $previous) {
            Restore-PreviousInstall $previous
        }
    }
}

# Removes the previous install once the new one is in its place, or puts it
# back, naming where it is if that fails too. The error that stopped the
# move is the one reported.
function Restore-PreviousInstall([string]$Previous) {
    if (Test-Path -LiteralPath $NovaNixRoot) {
        try {
            Remove-Tree -Path $Previous
        } catch {
            Write-Warning "could not remove the previous install in ${Previous}: $($_.Exception.Message)"
        }
        return
    }
    try {
        Move-Item -LiteralPath $Previous -Destination $NovaNixRoot
        Write-Step "Put the previous install back in $NovaNixRoot"
    } catch {
        Write-Warning "the previous install is in $Previous; move it back to $NovaNixRoot"
    }
}

# ---------------------------------------------------------------------------
# The user Path
# ---------------------------------------------------------------------------

# The user Path as the registry holds it, with %VARIABLE% references left
# unexpanded so that writing it back keeps them. Reading it through
# [Environment]::GetEnvironmentVariable would expand them, and writing it
# through SetEnvironmentVariable would store it as a plain string.
function Read-UserPath {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    if ($null -eq $key) {
        return ''
    }
    try {
        return [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    } finally {
        $key.Close()
    }
}

# Explorer, and so every program started from it, reads the user Path again
# when told the environment changed; without that a new terminal sees the
# change only after the next sign-in.
function Send-SettingChange {
    if (-not ('NovaNix.NativeMethods' -as [type])) {
        Add-Type -Namespace NovaNix -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern IntPtr SendMessageTimeout(
    IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
    uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
    }
    $result = [UIntPtr]::Zero
    [void][NovaNix.NativeMethods]::SendMessageTimeout(
        $HwndBroadcast, $WmSettingChange, [UIntPtr]::Zero, 'Environment',
        $SmtoAbortIfHung, $SettingChangeTimeoutMs, [ref]$result)
}

function Write-UserPath([string]$Value) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
    try {
        if ($Value) {
            $key.SetValue('Path', $Value, [Microsoft.Win32.RegistryValueKind]::ExpandString)
        } else {
            $key.DeleteValue('Path', $false)
        }
    } finally {
        $key.Close()
    }
    Send-SettingChange
}

# Puts the directory first in the user Path, and in this session's, unless
# it is there already. The rest of the user Path is kept as it is.
function Add-UserPath([string]$Directory) {
    $current = Read-UserPath
    if (@($current -split ';') -contains $Directory) {
        Write-Step "$Directory is already in your user Path"
    } else {
        $updated = if ($current) { "$Directory;$current" } else { $Directory }
        Write-UserPath $updated
        Write-Step "Added $Directory to your user Path"
    }
    if (-not (@($env:Path -split ';') -contains $Directory)) {
        $env:Path = "$Directory;$env:Path"
    }
}

# ---------------------------------------------------------------------------
# The store: C:\nix, writable only by this user, SYSTEM and Administrators
# ---------------------------------------------------------------------------
#
# A directory made at a drive root inherits the root's permissions, which
# on Windows client editions let every signed-in user modify what is in it.
# C:\nix gets a protected DACL instead, which C:\nix\store and everything
# nova-nix puts in it inherit: full control for this user, SYSTEM and
# Administrators, and read and execute for other users. C:\nix itself is
# covered, not only the store, since whoever can rename C:\nix can put
# another store in its place. It is created with that DACL, so it never
# carries the drive root's for another user to create something in.
#
# Only the DACL is written, never the owner or audit sections: an owner may
# write its own directory's DACL with no privilege, which Set-Acl, writing
# every section it can, does not manage for a protected directory.
#
# Every run, install and uninstall alike, establishes before it changes
# anything that the store is this user's: C:\nix and everything below it is
# owned by this user, SYSTEM or Administrators, and no entry grants another
# account a change, inherited grants included, so a C:\nix that still
# carries the drive root's is refused. Anything else, including an entry
# whose owner cannot be read, is refused with nothing changed, on this run
# and on every run after.

function Get-StoreIdentity {
    $wellKnown = [System.Security.Principal.WellKnownSidType]
    return [pscustomobject]@{
        User = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        System = [System.Security.Principal.SecurityIdentifier]::new($wellKnown::LocalSystemSid, $null)
        Administrators = [System.Security.Principal.SecurityIdentifier]::new($wellKnown::BuiltinAdministratorsSid, $null)
        Users = [System.Security.Principal.SecurityIdentifier]::new($wellKnown::BuiltinUsersSid, $null)
    }
}

function Get-StoreGrant {
    $full = [System.Security.AccessControl.FileSystemRights]::FullControl
    $read = [System.Security.AccessControl.FileSystemRights]::ReadAndExecute
    $sids = Get-StoreIdentity
    if ($sids.User.Value -ne $sids.System.Value) {
        [pscustomobject]@{ Sid = $sids.User; Rights = $full }
    }
    [pscustomobject]@{ Sid = $sids.System; Rights = $full }
    [pscustomobject]@{ Sid = $sids.Administrators; Rights = $full }
    [pscustomobject]@{ Sid = $sids.Users; Rights = $read }
}

# The accounts that may own, or be granted changes to, anything in the store.
function Get-TrustedSid {
    $sids = Get-StoreIdentity
    return @($sids.User.Value, $sids.System.Value, $sids.Administrators.Value)
}

# The rights that let an account change an entry, generic ones included.
function Get-WriteRight {
    $specific = [int][System.Security.AccessControl.FileSystemRights]'WriteData, AppendData, WriteExtendedAttributes, DeleteSubdirectoriesAndFiles, WriteAttributes, Delete, ChangePermissions, TakeOwnership'
    $genericAll = 0x10000000
    $genericWrite = 0x40000000
    return $specific -bor $genericAll -bor $genericWrite
}

# The owner and DACL of the entry at a path itself, with its attributes in
# Attributes, a link read as itself and not followed.
function Read-EntrySecurity([string]$Path) {
    Import-EntryNative
    $attributes = [uint32]0
    $bytes = [NovaNix.Entry]::Read($Path, [ref]$attributes)
    return [pscustomobject]@{
        Attributes = $attributes
        Descriptor = [System.Security.AccessControl.RawSecurityDescriptor]::new($bytes, 0)
    }
}

# The owner of a directory can change its DACL whatever the DACL says, so a
# C:\nix or store that another account owns, made before this script ran,
# could be opened up again by them, and one that is a link leads elsewhere.
# Both are refused rather than used.
function Assert-StoreDirectory([string]$Path) {
    $entry = Read-EntrySecurity $Path
    if (-not ($entry.Attributes -band $FileAttributeDirectory) -or ($entry.Attributes -band $FileAttributeReparsePoint)) {
        throw "$Path is not a directory of its own; move it away, then run this again"
    }
    $owner = if ($null -ne $entry.Descriptor.Owner) { $entry.Descriptor.Owner.Value } else { 'no one' }
    if ((Get-TrustedSid) -notcontains $owner) {
        throw "$Path belongs to $owner, not to you, SYSTEM or Administrators, so it could be changed by them; move it away, then run this again"
    }
}

# Dies unless the entry at Path is owned by this user, SYSTEM or
# Administrators and grants no other account a change, inherited grants
# included: a store any other account could have written cannot be trusted,
# whoever made it. Read and execute for Users is no change. The DACL is read
# as Windows keeps it, every allow entry counted, inherit-only and callback
# entries among them, which a FileSecurity built for a file would drop.
function Assert-StoreEntry([string]$Path, [psobject]$Entry, [string[]]$Trusted, [int]$Writes) {
    $untrusted = "so the store in $NovaNixStoreRoot cannot be trusted; move $NovaNixStoreRoot aside, then run this again"
    $owner = if ($null -ne $Entry.Descriptor.Owner) { $Entry.Descriptor.Owner.Value } else { 'no one' }
    if ($Trusted -notcontains $owner) {
        throw "$Path belongs to $owner, $untrusted"
    }
    $dacl = $Entry.Descriptor.DiscretionaryAcl
    if ($null -eq $dacl) {
        throw "$Path has no DACL, which lets every account change it, $untrusted"
    }
    foreach ($ace in $dacl) {
        if (-not ($ace -is [System.Security.AccessControl.KnownAce])) {
            throw "$Path carries an access entry of a kind this installer cannot read, $untrusted"
        }
        if ($ace -is [System.Security.AccessControl.QualifiedAce]) {
            $allows = $ace.AceQualifier -eq [System.Security.AccessControl.AceQualifier]::AccessAllowed
        } else {
            $allows = $ace.AceType -eq [System.Security.AccessControl.AceType]::AccessAllowedCompound
        }
        if ($allows -and ($ace.AccessMask -band $Writes) -and $Trusted -notcontains $ace.SecurityIdentifier.Value) {
            throw "$Path lets $($ace.SecurityIdentifier.Value) change it, $untrusted"
        }
    }
}

# C:\nix and everything below it, links read as themselves and not followed.
function Assert-StoreTree {
    $trusted = Get-TrustedSid
    $writes = Get-WriteRight
    Assert-StoreEntry -Path $NovaNixStoreRoot -Entry (Read-EntrySecurity $NovaNixStoreRoot) -Trusted $trusted -Writes $writes
    $pending = [System.Collections.Generic.Stack[string]]::new()
    $pending.Push($NovaNixStoreRoot)
    while ($pending.Count -gt 0) {
        foreach ($path in [System.IO.Directory]::GetFileSystemEntries($pending.Pop())) {
            $entry = Read-EntrySecurity $path
            Assert-StoreEntry -Path $path -Entry $entry -Trusted $trusted -Writes $writes
            if (($entry.Attributes -band $FileAttributeDirectory) -and -not ($entry.Attributes -band $FileAttributeReparsePoint)) {
                $pending.Push($path)
            }
        }
    }
}

# Establishes that C:\nix and the store are this user's, changing nothing.
function Assert-StoreOwned {
    Import-EntryNative
    Assert-StoreDirectory $NovaNixStoreRoot
    if ([NovaNix.Entry]::Exists($NovaNixStore)) {
        Assert-StoreDirectory $NovaNixStore
    }
    Assert-StoreTree
}

# The protected DACL. Only its access rules are set, so writing it writes
# the DACL alone.
function Get-StoreSecurity {
    $security = [System.Security.AccessControl.DirectorySecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    foreach ($grant in Get-StoreGrant) {
        $security.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
                $grant.Sid, $grant.Rights, $NovaNixStoreInheritance,
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow))
    }
    return $security
}

# Creates C:\nix with its DACL in one call. Windows PowerShell has it on
# DirectoryInfo and PowerShell 7 on FileSystemAclExtensions. When something
# made C:\nix first, this does nothing, and the checks after it find out
# whose it is.
function Initialize-StoreRoot {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleTypes', '', Justification = 'FileSystemAclExtensions is called only in PowerShell 7, which has it.')]
    param()
    $directory = [System.IO.DirectoryInfo]::new($NovaNixStoreRoot)
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        $directory.Create((Get-StoreSecurity))
    } else {
        [System.IO.FileSystemAclExtensions]::Create($directory, (Get-StoreSecurity))
    }
}

# Writes the protected DACL to C:\nix, which its children then inherit,
# through a handle that refuses a C:\nix that is not a directory of its own.
function Protect-StoreRoot {
    Import-EntryNative
    $descriptor = [System.Security.AccessControl.RawSecurityDescriptor]::new((Get-StoreSecurity).GetSecurityDescriptorBinaryForm(), 0)
    $dacl = [byte[]]::new($descriptor.DiscretionaryAcl.BinaryLength)
    $descriptor.DiscretionaryAcl.GetBinaryForm($dacl, 0)
    [NovaNix.Entry]::ProtectDirectory($NovaNixStoreRoot, $dacl)
}

# Windows adds Synchronize to every allow entry, so it is added to the
# expected rights before they are compared.
function Test-StoreAcl {
    $acl = Get-Acl -LiteralPath $NovaNixStoreRoot
    if (-not $acl.AreAccessRulesProtected) {
        return $false
    }
    $rules = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
    $grants = @(Get-StoreGrant)
    if ($rules.Count -ne $grants.Count) {
        return $false
    }
    $synchronize = [int][System.Security.AccessControl.FileSystemRights]::Synchronize
    foreach ($grant in $grants) {
        $matching = @($rules | Where-Object {
                $_.IdentityReference.Value -eq $grant.Sid.Value -and
                $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
                [int]$_.FileSystemRights -eq ([int]$grant.Rights -bor $synchronize) -and
                $_.InheritanceFlags -eq $NovaNixStoreInheritance -and
                $_.PropagationFlags -eq [System.Security.AccessControl.PropagationFlags]::None
            })
        if ($matching.Count -ne 1) {
            return $false
        }
    }
    return $true
}

# The store is shown to be this user's before C:\nix's DACL is written, and
# again after, so a refusal holds on every run.
function Install-Store {
    Import-EntryNative
    if (-not [NovaNix.Entry]::Exists($NovaNixStoreRoot)) {
        Write-Step "Creating $NovaNixStoreRoot for the store, writable only by you, SYSTEM and Administrators"
        Initialize-StoreRoot
    }
    Assert-StoreOwned
    if (Test-StoreAcl) {
        return
    }
    Write-Step "Making $NovaNixStoreRoot writable only by you, SYSTEM and Administrators"
    Protect-StoreRoot
    if (-not (Test-StoreAcl)) {
        throw "the permissions set on $NovaNixStoreRoot did not take effect"
    }
    Assert-StoreTree
}

# What -RemoveStore removes is C:\nix\store and then C:\nix once nothing
# else is in it, so both must be shown to be this user's first: a link
# would be removed while what it leads to is kept, and another account's
# store is theirs.
function Assert-StoreRemovable {
    Import-EntryNative
    if ([NovaNix.Entry]::Exists($NovaNixStoreRoot)) {
        Assert-StoreOwned
    }
}

# nova-nix creates symbolic links, inside store paths and for --out-link,
# which Windows lets a program create only in Developer Mode or elevated.
function Test-SymlinkAllowed {
    $principal = [System.Security.Principal.WindowsPrincipal]::new([System.Security.Principal.WindowsIdentity]::GetCurrent())
    if ($principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        return $true
    }
    $unlock = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -Name AllowDevelopmentWithoutDevLicense -ErrorAction SilentlyContinue
    return ($null -ne $unlock) -and ($unlock.AllowDevelopmentWithoutDevLicense -eq 1)
}

function Write-SymlinkWarning {
    if (-not (Test-SymlinkAllowed)) {
        Write-Warning 'nova-nix makes symbolic links, which Windows allows only in Developer Mode or an elevated shell. Turn on Developer Mode in Settings, under For developers, or building a path that holds a link fails.'
    }
}

# ---------------------------------------------------------------------------
# Install and uninstall
# ---------------------------------------------------------------------------

function Install-NovaNix([string]$Version, [string]$From) {
    Assert-InstallRoot 'exists and does not hold a nova-nix install; move it away, then run this again'
    $programs = Split-Path -Parent $NovaNixRoot
    [void](New-Item -ItemType Directory -Force -Path $programs)
    # Beside the install, so the unpacked archive moves into place by renaming.
    $scratch = Join-Path $programs ('.nova-nix-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $scratch)
    try {
        $zip = Join-Path $scratch $NovaNixArchive
        $sums = Join-Path $scratch 'SHA256SUMS'
        if ($From) {
            Copy-Item -LiteralPath (Join-Path $From $NovaNixArchive) -Destination $zip
            Copy-Item -LiteralPath (Join-Path $From 'SHA256SUMS') -Destination $sums
        } else {
            if (-not $Version) {
                $Version = Get-LatestVersion
            }
            $base = "https://github.com/$NovaNixRepository/releases/download/v$Version"
            Save-Download -Url "$base/$NovaNixArchive" -Path $zip
            Save-Download -Url "$base/SHA256SUMS" -Path $sums
        }
        Assert-Checksum -ArchivePath $zip -SumsPath $sums

        $unpack = Join-Path $scratch 'unpack'
        Expand-Archive -LiteralPath $zip -DestinationPath $unpack
        $staged = Join-Path $unpack $NovaNixStem
        $executable = Join-Path $staged 'bin\nova-nix.exe'
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
            throw "$NovaNixArchive does not hold $NovaNixStem\bin\nova-nix.exe"
        }
        $reported = Get-ReportedVersion -Executable $executable -Expected $Version

        Install-Store
        Move-Install -Staged $staged
        Add-UserPath (Join-Path $NovaNixRoot 'bin')
    } finally {
        if (Test-Path -LiteralPath $scratch) {
            Remove-Tree -Path $scratch
        }
    }
    Write-SymlinkWarning
    Write-Step "$reported is installed in $NovaNixRoot."
    Write-Step 'Open a new terminal to use it.'
}

# Everything that can refuse runs before anything is removed, so a refusal
# leaves the install as it was.
function Uninstall-NovaNix([switch]$RemoveStore) {
    Assert-InstallRoot 'does not hold a nova-nix install; leaving it in place'
    if ($RemoveStore) {
        Assert-StoreRemovable
    }
    $bin = Join-Path $NovaNixRoot 'bin'
    $entries = @((Read-UserPath) -split ';')
    $kept = @($entries | Where-Object { $_ -ne $bin })
    if ($kept.Count -ne $entries.Count) {
        Write-UserPath ($kept -join ';')
        Write-Step "Removed $bin from your user Path"
    }
    $env:Path = (@($env:Path -split ';') | Where-Object { $_ -ne $bin }) -join ';'

    if (Test-Path -LiteralPath $NovaNixRoot) {
        Remove-Tree -Path $NovaNixRoot
        Write-Step "Removed $NovaNixRoot"
    } else {
        Write-Step "nova-nix is not installed in $NovaNixRoot"
    }

    if (-not $RemoveStore) {
        if (Test-Path -LiteralPath $NovaNixStore) {
            Write-Step "The store in $NovaNixStore is kept; -Uninstall -RemoveStore removes it"
        }
        return
    }
    Import-EntryNative
    if ([NovaNix.Entry]::Exists($NovaNixStore)) {
        Remove-Tree -Path $NovaNixStore
        Write-Step "Removed $NovaNixStore"
    }
    if ([NovaNix.Entry]::Exists($NovaNixStoreRoot)) {
        if ([System.IO.Directory]::GetFileSystemEntries($NovaNixStoreRoot).Count -eq 0) {
            Remove-Tree -Path $NovaNixStoreRoot
            Write-Step "Removed $NovaNixStoreRoot"
        } else {
            Write-Step "Left $NovaNixStoreRoot in place: it holds more than the store"
        }
    }
}

function Invoke-NovaNixInstaller([string]$Version, [string]$From, [switch]$StoreOnly, [switch]$Uninstall, [switch]$RemoveStore) {
    $ErrorActionPreference = 'Stop'
    # Windows PowerShell redraws its progress bar for every chunk a download
    # writes, which slows the download many times over.
    $ProgressPreference = 'SilentlyContinue'
    Set-StrictMode -Version Latest
    # GitHub accepts TLS 1.2 or newer, which Windows PowerShell does not
    # always offer by default. The setting is the session's, so it is put
    # back on the way out.
    $sessionProtocols = [System.Net.ServicePointManager]::SecurityProtocol
    [System.Net.ServicePointManager]::SecurityProtocol = $sessionProtocols -bor [System.Net.SecurityProtocolType]::Tls12
    try {
        Invoke-InstallerAction -Version $Version -From $From -StoreOnly:$StoreOnly -Uninstall:$Uninstall -RemoveStore:$RemoveStore
    } finally {
        [System.Net.ServicePointManager]::SecurityProtocol = $sessionProtocols
    }
}

# Checks the arguments and runs the install, the store setup or the
# uninstall they ask for.
function Invoke-InstallerAction([string]$Version, [string]$From, [switch]$StoreOnly, [switch]$Uninstall, [switch]$RemoveStore) {
    if ($Version -eq 'latest') {
        $Version = ''
    }
    if ($Version) {
        if (-not (Test-Release $Version)) {
            throw '-Version must name a release, such as 0.10.0.0, or be latest'
        }
        $Version = $Version -replace '\Av', ''
    }
    if ($From -and $Version) {
        throw '-From and -Version cannot be used together'
    }
    if ($Uninstall -and ($From -or $Version)) {
        throw '-Uninstall takes no -Version or -From'
    }
    if ($StoreOnly -and $Uninstall) {
        throw '-StoreOnly and -Uninstall cannot be used together'
    }
    if ($StoreOnly -and ($From -or $Version)) {
        throw '-StoreOnly takes no -Version or -From'
    }
    if ($RemoveStore -and -not $Uninstall) {
        throw '-RemoveStore goes with -Uninstall'
    }
    if (-not [Environment]::Is64BitOperatingSystem) {
        throw 'nova-nix publishes no archive for 32-bit Windows'
    }
    # The store is all -StoreOnly sets up, so it needs no install folder.
    if ($StoreOnly) {
        Install-Store
        Write-SymlinkWarning
        return
    }
    if (-not $env:LOCALAPPDATA) {
        throw 'LOCALAPPDATA is not set, so there is no folder to install nova-nix in'
    }

    if ($Uninstall) {
        Uninstall-NovaNix -RemoveStore:$RemoveStore
    } else {
        Install-NovaNix -Version $Version -From $From
    }
}

Invoke-NovaNixInstaller -Version $Version -From $From -StoreOnly:$StoreOnly -Uninstall:$Uninstall -RemoveStore:$RemoveStore
