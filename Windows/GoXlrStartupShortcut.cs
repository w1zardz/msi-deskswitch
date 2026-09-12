using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;

namespace DeskSwitch {
    // Use the Unicode Shell Link interface regardless of the Windows system code page.
    public static class GoXlrStartupShortcut {
        [ComImport, Guid("00021401-0000-0000-C000-000000000046")] class ShellLink { }
        [ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IShellLinkW {
            void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path,int capacity,IntPtr data,uint flags);
            void GetIDList(out IntPtr list);
            void SetIDList(IntPtr list);
            void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder text,int capacity);
            void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string text);
            void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path,int capacity);
            void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string path);
            void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder text,int capacity);
            void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string text);
            void GetHotkey(out short key);
            void SetHotkey(short key);
            void GetShowCmd(out int command);
            void SetShowCmd(int command);
            void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path,int capacity,out int index);
            void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string path,int index);
            void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path,uint reserved);
            void Resolve(IntPtr window,uint flags);
            void SetPath([MarshalAs(UnmanagedType.LPWStr)] string path);
        }
        public static string[] Read(string path) {
            object instance=new ShellLink();
            try {
                ((IPersistFile)instance).Load(path,0);
                var link=(IShellLinkW)instance;
                var target=new StringBuilder(32768); var arguments=new StringBuilder(32768);
                link.GetPath(target,target.Capacity,IntPtr.Zero,4);
                link.GetArguments(arguments,arguments.Capacity);
                return new string[]{target.ToString(),arguments.ToString()};
            } finally {Marshal.FinalReleaseComObject(instance);}
        }
        public static void Write(string path,string target,string arguments) {
            object instance=new ShellLink();
            try {
                var link=(IShellLinkW)instance;
                link.SetPath(target); link.SetArguments(arguments);
                link.SetWorkingDirectory(Path.GetDirectoryName(target));
                link.SetDescription("GoXLR Utility with the saved DeskSwitch profiles");
                ((IPersistFile)instance).Save(path,true);
            } finally {Marshal.FinalReleaseComObject(instance);}
        }
    }
}
