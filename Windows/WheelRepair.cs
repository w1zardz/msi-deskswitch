using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

// Logitech HID++ 2.0 feature 0x2121. Only the MX Master 3S on a Bolt receiver.
// Clear diversion and high resolution; preserve inversion and all other bits.
// SmartShift, ratchet, buttons, DPI and pairing are deliberately independent.
internal static class WheelRepair {
    [StructLayout(LayoutKind.Sequential)] struct InterfaceData {
        public uint Size; public Guid ClassGuid; public uint Flags; public IntPtr Reserved;
    }
    [StructLayout(LayoutKind.Sequential)] struct Caps {
        public ushort Usage, UsagePage, InputLength, OutputLength, FeatureLength;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst=17)] public ushort[] Reserved;
        public ushort LinkNodes, InputButtons, InputValues, InputIndices, OutputButtons, OutputValues, OutputIndices, FeatureButtons, FeatureValues, FeatureIndices;
    }
    [StructLayout(LayoutKind.Sequential)] struct Overlapped {
        public IntPtr Internal, InternalHigh; public uint Offset, OffsetHigh; public IntPtr Event;
    }
    [DllImport("hid.dll")] static extern void HidD_GetHidGuid(out Guid guid);
    [DllImport("hid.dll")] static extern bool HidD_GetPreparsedData(SafeFileHandle file, out IntPtr data);
    [DllImport("hid.dll")] static extern bool HidD_FreePreparsedData(IntPtr data);
    [DllImport("hid.dll")] static extern int HidP_GetCaps(IntPtr data, out Caps caps);
    [DllImport("setupapi.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr SetupDiGetClassDevs(ref Guid guid, string enumerator, IntPtr parent, uint flags);
    [DllImport("setupapi.dll",SetLastError=true)] static extern bool SetupDiEnumDeviceInterfaces(IntPtr set, IntPtr device, ref Guid guid, uint index, ref InterfaceData data);
    [DllImport("setupapi.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr set, ref InterfaceData data, IntPtr detail, uint size, out uint required, IntPtr device);
    [DllImport("setupapi.dll")] static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFile(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool ReadFile(SafeFileHandle file,IntPtr buffer,uint size,IntPtr count,IntPtr overlapped);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool WriteFile(SafeFileHandle file,IntPtr buffer,uint size,IntPtr count,IntPtr overlapped);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetOverlappedResult(SafeFileHandle file,IntPtr overlapped,out uint count,bool wait);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool CancelIoEx(SafeFileHandle file,IntPtr overlapped);
    [DllImport("kernel32.dll")] static extern IntPtr CreateEvent(IntPtr security,bool manual,bool initial,string name);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr handle,uint timeout);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);

    static List<string> Paths() {
        var paths=new List<string>(); Guid guid; HidD_GetHidGuid(out guid);
        IntPtr set=SetupDiGetClassDevs(ref guid,null,IntPtr.Zero,0x12);
        if(set==new IntPtr(-1)) return paths;
        try {
            for(uint i=0;;i++) {
                var data=new InterfaceData {Size=(uint)Marshal.SizeOf(typeof(InterfaceData))};
                if(!SetupDiEnumDeviceInterfaces(set,IntPtr.Zero,ref guid,i,ref data)) break;
                uint size; SetupDiGetDeviceInterfaceDetail(set,ref data,IntPtr.Zero,0,out size,IntPtr.Zero);
                IntPtr detail=Marshal.AllocHGlobal((int)size);
                try {
                    Marshal.WriteInt32(detail,IntPtr.Size==8?8:6);
                    if(!SetupDiGetDeviceInterfaceDetail(set,ref data,detail,size,out size,IntPtr.Zero)) continue;
                    string path=Marshal.PtrToStringUni(IntPtr.Add(detail,4));
                    if(path.IndexOf("vid_046d&pid_c548",StringComparison.OrdinalIgnoreCase)>=0) paths.Add(path);
                } finally {Marshal.FreeHGlobal(detail);}
            }
        } finally {SetupDiDestroyDeviceInfoList(set);}
        return paths;
    }

    sealed class Device : IDisposable {
        readonly SafeFileHandle file;
        public Device(string path) {file=CreateFile(path,0xC0000000,3,IntPtr.Zero,3,0x40000000,IntPtr.Zero);}
        public bool IsLongInterface() {
            if(file.IsInvalid) return false;
            IntPtr data;
            if(!HidD_GetPreparsedData(file,out data)) return false;
            try {Caps caps; return HidP_GetCaps(data,out caps)>=0 && caps.UsagePage==0xFF00 && caps.Usage==2 && caps.InputLength==20 && caps.OutputLength==20;}
            finally {HidD_FreePreparsedData(data);}
        }
        byte[] Transfer(byte[] bytes,bool write,uint timeout) {
            IntPtr buffer=Marshal.AllocHGlobal(20), ov=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(Overlapped)));
            IntPtr ev=CreateEvent(IntPtr.Zero,true,false,null);
            try {
                Marshal.StructureToPtr(new Overlapped {Event=ev},ov,false);
                if(write) Marshal.Copy(bytes,0,buffer,20);
                bool started=write?WriteFile(file,buffer,20,IntPtr.Zero,ov):ReadFile(file,buffer,20,IntPtr.Zero,ov);
                if(!started && Marshal.GetLastWin32Error()!=997) return null;
                if(!started && WaitForSingleObject(ev,timeout)!=0) {
                    CancelIoEx(file,ov); uint ignored; GetOverlappedResult(file,ov,out ignored,true); return null;
                }
                uint count;
                if(!GetOverlappedResult(file,ov,out count,true) || count!=20) return null;
                byte[] result=new byte[20]; Marshal.Copy(buffer,result,0,20); return result;
            } finally {CloseHandle(ev);Marshal.FreeHGlobal(ov);Marshal.FreeHGlobal(buffer);}
        }
        public byte[] Request(byte slot,byte feature,byte function,params byte[] parameters) {
            byte[] packet=new byte[20];packet[0]=0x11;packet[1]=slot;packet[2]=feature;packet[3]=(byte)((function<<4)|0x0C);
            Array.Copy(parameters,0,packet,4,parameters.Length);
            if(Transfer(packet,true,600)==null) return null;
            DateTime end=DateTime.UtcNow.AddMilliseconds(650);
            while(DateTime.UtcNow<end) {
                byte[] reply=Transfer(null,false,(uint)Math.Max(1,(end-DateTime.UtcNow).TotalMilliseconds));
                if(reply==null) return null;
                if(reply[1]!=slot) continue;
                if(reply[2]==0xFF && reply[3]==feature && reply[4]==packet[3]) return null;
                if(reply[2]==feature && reply[3]==packet[3]) {byte[] result=new byte[16];Array.Copy(reply,4,result,0,16);return result;}
            }
            return null;
        }
        public void Dispose() {file.Dispose();}
    }

    public static string Run(bool repair) {
        if(repair) foreach(var process in System.Diagnostics.Process.GetProcesses()) using(process) {
            if(process.ProcessName.StartsWith("logioptions",StringComparison.OrdinalIgnoreCase))
                return "Logitech Options is active; its wheel settings take priority.";
        }
        foreach(string path in Paths()) using(var device=new Device(path)) {
            if(!device.IsLongInterface()) continue;
            for(byte slot=1;slot<=6;slot++) {
                byte[] feature=device.Request(slot,0,0,0x21,0x21,0);
                if(feature==null || feature[0]==0) continue;
                byte[] nameFeature=device.Request(slot,0,0,0,5,0);
                if(nameFeature==null || nameFeature[0]==0) continue;
                byte[] length=device.Request(slot,nameFeature[0],0);
                if(length==null || length[0]>80) continue;
                var nameBytes=new List<byte>();
                while(nameBytes.Count<length[0]) {
                    byte[] part=device.Request(slot,nameFeature[0],1,(byte)nameBytes.Count);
                    if(part==null) break;nameBytes.AddRange(part);
                }
                if(nameBytes.Count<length[0]) continue;
                string name=Encoding.UTF8.GetString(nameBytes.ToArray(),0,length[0]);
                if(!name.Equals("MX Master 3S",StringComparison.Ordinal)) continue;
                byte[] mode=device.Request(slot,feature[0],1);
                if(mode==null) continue;
                byte normal=(byte)(mode[0]&~3);
                if(repair && normal!=mode[0]) {
                    if(device.Request(slot,feature[0],2,normal)==null) return "Wheel repair was not acknowledged.";
                    byte[] verified=device.Request(slot,feature[0],1);
                    if(verified==null || verified[0]!=normal) return "Wheel repair verification failed.";
                    return "MX Master 3S wheel restored: " + mode[0] + " -> " + normal + ". SmartShift preserved.";
                }
                return "MX Master 3S wheel mode="+mode[0]+". SmartShift preserved.";
            }
        }
        return "MX Master 3S not available on a Bolt receiver.";
    }
}
