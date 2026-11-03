using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace SpeedDownload;

// The engine reads this generic credential from the same Windows user profile.
internal static class ProxyCredentialStore
{
    private static string Target(string endpoint) => "SpeedDownload.ManualProxy." +
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(endpoint))).ToLowerInvariant();
    private const int Generic = 1;
    private const int PersistLocalMachine = 2;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct Credential
    {
        public int Flags;
        public int Type;
        [MarshalAs(UnmanagedType.LPWStr)] public string? TargetName;
        [MarshalAs(UnmanagedType.LPWStr)] public string? Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public int CredentialBlobSize;
        public IntPtr CredentialBlob;
        public int Persist;
        public int AttributeCount;
        public IntPtr Attributes;
        [MarshalAs(UnmanagedType.LPWStr)] public string? TargetAlias;
        [MarshalAs(UnmanagedType.LPWStr)] public string? UserName;
    }

    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredWrite(ref Credential credential, int flags);
    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredRead(string target, int type, int flags, out IntPtr credential);
    [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredDelete(string target, int type, int flags);
    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr credential);

    public static bool Exists(string endpoint)
    {
        if (CredRead(Target(endpoint), Generic, 0, out var credential)) { CredFree(credential); return true; }
        var error = Marshal.GetLastWin32Error();
        if (error == 1168) return false; // ERROR_NOT_FOUND
        throw new Win32Exception(error);
    }

    public static void Save(string endpoint, string userName, string password)
    {
        if (string.IsNullOrWhiteSpace(userName) || userName.Contains(':') || userName.IndexOfAny(['\r', '\n', '\0']) >= 0 ||
            password.IndexOfAny(['\r', '\n', '\0']) >= 0)
            throw new ArgumentException("Enter a username without colons or line breaks and a password without line breaks.");
        var secret = Encoding.UTF8.GetBytes(userName + "\n" + password);
        try
        {
            if (secret.Length > 2560) throw new ArgumentException("The username and password are too long for Windows Credential Manager.");
            var buffer = Marshal.AllocCoTaskMem(secret.Length);
            try
            {
                Marshal.Copy(secret, 0, buffer, secret.Length);
                var credential = new Credential { Type = Generic, TargetName = Target(endpoint), CredentialBlobSize = secret.Length,
                    CredentialBlob = buffer, Persist = PersistLocalMachine, UserName = userName };
                if (!CredWrite(ref credential, 0)) throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            finally
            {
                for (var i = 0; i < secret.Length; i++) Marshal.WriteByte(buffer, i, 0);
                Marshal.FreeCoTaskMem(buffer);
            }
        }
        finally { CryptographicOperations.ZeroMemory(secret); }
    }

    public static void Delete(string endpoint)
    {
        if (!CredDelete(Target(endpoint), Generic, 0))
        {
            var error = Marshal.GetLastWin32Error();
            if (error != 1168) throw new Win32Exception(error);
        }
    }
}
