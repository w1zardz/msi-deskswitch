using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

// Only controls the MSI MAG 322UPF input (VCP 0x60).
// USB sharing requires the monitor's KVM=Auto and the documented cabling.
internal static class MonitorInput {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct Physical {
        public IntPtr Handle;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string Description;
    }
    delegate bool EnumProc(IntPtr monitor, IntPtr dc, IntPtr rect, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr rect, EnumProc proc, IntPtr data);
    [DllImport("dxva2.dll", SetLastError=true)] static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr monitor, out uint count);
    [DllImport("dxva2.dll", SetLastError=true)] static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr monitor, uint count, [Out] Physical[] items);
    [DllImport("dxva2.dll")] static extern bool DestroyPhysicalMonitors(uint count, Physical[] items);
    [DllImport("dxva2.dll", SetLastError=true)] static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr monitor, byte code, out uint type, out uint current, out uint maximum);
    [DllImport("dxva2.dll", SetLastError=true)] static extern bool SetVCPFeature(IntPtr monitor, byte code, uint value);

    static uint Access(uint? target) {
        var batches = new List<Physical[]>();
        var matches = new List<Physical>();
        using (var gate = new Mutex(false, @"Local\MSI322UPF-DeskSwitch-DDC")) {
            bool held = false;
            try {
                try { held = gate.WaitOne(3000); } catch (AbandonedMutexException) { held = true; }
                if (!held) throw new Exception("Monitor command already running. Try again.");
                bool enumerated = EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, delegate(IntPtr mon, IntPtr dc, IntPtr rect, IntPtr data) {
                    uint n;
                    if (!GetNumberOfPhysicalMonitorsFromHMONITOR(mon, out n) || n==0) return true;
                    var items = new Physical[n];
                    if (!GetPhysicalMonitorsFromHMONITOR(mon, n, items)) return true;
                    batches.Add(items);
                    foreach(var item in items) {
                        string name = (item.Description ?? "").Replace(" ", "");
                        if (name.Equals("MSIMAG322UPF", StringComparison.OrdinalIgnoreCase)) matches.Add(item);
                    }
                    return true;
                }, IntPtr.Zero);
                if (!enumerated) throw new Exception("Could not enumerate monitors.");
                if (matches.Count != 1) throw new Exception("Expected exactly one MSI MAG 322UPF; found " + matches.Count + ". No input changed.");
                var display = matches[0];
                if (target.HasValue) {
                    if (target.Value != 15 && target.Value != 16) throw new Exception("Only DP=15 and USB-C=16 are allowed.");
                    if (!SetVCPFeature(display.Handle, 0x60, target.Value)) throw new Win32Exception(Marshal.GetLastWin32Error(), "MSI did not accept the input command.");
                    return target.Value;
                }
                uint type, current, maximum;
                if (!GetVCPFeatureAndVCPFeatureReply(display.Handle, 0x60, out type, out current, out maximum)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot read MSI input.");
                return current;
            } finally {
                foreach (var batch in batches) DestroyPhysicalMonitors((uint)batch.Length, batch);
                if (held) gate.ReleaseMutex();
            }
        }
    }
    public static uint Read() { return Access(null); }
    public static uint Set(uint value) { return Access(value); }
}

internal sealed class HotkeyWindow : NativeWindow, IDisposable {
    [DllImport("user32.dll", SetLastError=true)] static extern bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr window, int id);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
    readonly Action action;
    readonly Action devicesChanged;
    readonly System.Windows.Forms.Timer releaseTimer = new System.Windows.Forms.Timer {Interval=25};
    public HotkeyWindow(Action onHotkey, Action onDevicesChanged) {
        action = onHotkey;
        devicesChanged = onDevicesChanged;
        CreateHandle(new CreateParams { Caption="MSI DeskSwitch Hotkey" });
        // Ctrl+Shift+F11, MOD_NOREPEAT. F12 is reserved by Windows debuggers.
        if (!RegisterHotKey(Handle, 1, 0x4006, 0x7A)) {
            DestroyHandle();
            throw new Exception("Ctrl+Shift+F11 is already used by another app.");
        }
        if (!RegisterHotKey(Handle, 2, 0x4000, 0x22)) {
            UnregisterHotKey(Handle,1); DestroyHandle();
            throw new Exception("PageDown is already used by another app.");
        }
        // Switch after release so a held key cannot bounce back on the other host.
        releaseTimer.Tick += delegate {
            if((GetAsyncKeyState(0x22)&0x8000)==0) {releaseTimer.Stop();action();}
        };
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg==0x312 && m.WParam.ToInt32()==1) action();
        if (m.Msg==0x312 && m.WParam.ToInt32()==2) releaseTimer.Start();
        if (m.Msg==0x219) devicesChanged();
        base.WndProc(ref m);
    }
    public void Dispose() { releaseTimer.Dispose(); UnregisterHotKey(Handle, 1); UnregisterHotKey(Handle, 2); DestroyHandle(); }
}

internal sealed class Tray : ApplicationContext {
    readonly NotifyIcon icon;
    readonly HotkeyWindow hotkey;
    readonly Control dispatch = new Control();
    int busy;
    int wheelBusy;
    string lastWheelStatus;
    readonly System.Windows.Forms.Timer wheelTimer = new System.Windows.Forms.Timer {Interval=1500};
    public Tray() {
        dispatch.CreateControl();
        var menu = new ContextMenuStrip();
        menu.Items.Add("MacBook — PageDown", null, delegate { Switch(16); });
        menu.Items.Add("Windows — DisplayPort", null, delegate { Switch(15); });
        menu.Items.Add("Восстановить прокрутку MX Master 3S", null, delegate { RepairWheel(); });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Выход", null, delegate { ExitThread(); });
        icon = new NotifyIcon { Icon=SystemIcons.Application, Text="MSI: PageDown → MacBook", ContextMenuStrip=menu, Visible=true };
        icon.DoubleClick += delegate { Switch(16); };
        wheelTimer.Tick += delegate {RepairWheel();};
        hotkey = new HotkeyWindow(delegate { Switch(16); }, delegate {RepairWheel();});
        wheelTimer.Start();
    }
    void RepairWheel() {
        if(Interlocked.Exchange(ref wheelBusy,1)!=0) return;
        ThreadPool.QueueUserWorkItem(delegate {
            try {
                string result=WheelRepair.Run(true);
                if(result!=lastWheelStatus) {Program.Log(result);lastWheelStatus=result;}
            } catch(Exception error) {Program.Log("Wheel: "+error.Message);}
            finally {Interlocked.Exchange(ref wheelBusy,0);}
        });
    }
    void Switch(uint target) {
        if (Interlocked.Exchange(ref busy, 1)!=0) return;
        ThreadPool.QueueUserWorkItem(delegate {
            try { MonitorInput.Set(target); Program.Log("Input command accepted: " + target); }
            catch (Exception error) {
                Program.Log("ERROR " + error.Message);
                if (!dispatch.IsDisposed) try {
                    dispatch.BeginInvoke((Action)delegate { icon.ShowBalloonTip(6000,"MSI DeskSwitch",error.Message,ToolTipIcon.Error); });
                } catch (InvalidOperationException) { }
            } finally { Interlocked.Exchange(ref busy,0); }
        });
    }
    protected override void ExitThreadCore() {
        wheelTimer.Dispose(); hotkey.Dispose(); icon.Visible=false; icon.Dispose(); dispatch.Dispose(); base.ExitThreadCore();
    }
}

internal static class Program {
    public static void Log(string message) {
        try {
            string dir=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"MSI-DeskSwitch");
            Directory.CreateDirectory(dir);
            string file=Path.Combine(dir,"status.log");
            if (File.Exists(file) && new FileInfo(file).Length>1048576) File.WriteAllText(file,"");
            File.AppendAllText(file,DateTime.Now.ToString("s")+" "+message+Environment.NewLine);
        } catch (IOException) { }
    }
    [STAThread] public static int Main(string[] args) {
        try {
            string mode=args.Length==0?"tray":args[0].ToLowerInvariant();
            if(mode=="wheel-status" || mode=="repair-wheel") {
                string result=WheelRepair.Run(mode=="repair-wheel"); Log(result);
                if(args.Length>1) File.WriteAllText(Path.GetFullPath(args[1]),result+Environment.NewLine);
                return result.StartsWith("MX Master 3S wheel",StringComparison.Ordinal)?0:1;
            }
            if (mode=="status") {
                string result="MSI MAG 322UPF input="+MonitorInput.Read();
                Log(result);
                if (args.Length>1) File.WriteAllText(Path.GetFullPath(args[1]),result+Environment.NewLine);
                return 0;
            }
            if (mode=="mac" || mode=="windows") { MonitorInput.Set(mode=="mac"?16u:15u); Log("Input command accepted: "+mode); return 0; }
            if (mode!="tray") throw new Exception("Usage: DeskSwitch.exe [tray|status [file]|mac|windows|wheel-status [file]|repair-wheel [file]]");
            bool created;
            using (var mutex=new Mutex(true,@"Local\MSI322UPF-DeskSwitch-Tray",out created)) {
                if (!created) return 0;
                Application.EnableVisualStyles();
                using (var tray=new Tray()) { Log("Ready. PageDown -> MacBook; Ctrl+Shift+F11 backup."); Application.Run(tray); }
            }
            return 0;
        } catch (Exception error) {
            Log("ERROR "+error.Message);
            if (args.Length==0 || args[0]=="tray") MessageBox.Show(error.Message,"MSI DeskSwitch",MessageBoxButtons.OK,MessageBoxIcon.Error);
            return 1;
        }
    }
}
