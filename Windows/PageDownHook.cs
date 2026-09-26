using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

internal enum PageDownRefresh { Startup, Periodic, UsbChanged, Resume, SessionActive }

// A low-level hook belongs to the thread that installs it. Keep this message loop
// independent of tray menus, audio, disk I/O and display drivers on the UI thread.
internal sealed class PageDownHook : IDisposable {
    delegate IntPtr HookProc(int code, IntPtr message, IntPtr data);
    [StructLayout(LayoutKind.Sequential)] struct KeyData { public uint Key, Scan, Flags, Time; public UIntPtr Extra; }
    [DllImport("user32.dll", SetLastError=true)] static extern IntPtr SetWindowsHookEx(int id, HookProc callback, IntPtr module, uint thread);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr message, IntPtr data);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr window, int message, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);
    const int RefreshMessage = 0x8002, StopMessage = 0x8003;
    readonly IntPtr destination;
    readonly int releasedMessage, refreshMilliseconds;
    readonly Action<string> report;
    readonly Thread thread;
    readonly HookProc callback;
    readonly PageDownKey key = new PageDownKey();
    readonly object startupGate = new object();
    bool started;
    Exception startupError;
    int stopping, generation;
    IntPtr windowHandle, hook;
    string lastInstallError;

    public PageDownHook(IntPtr destination, int releasedMessage, Action<string> report)
        : this(destination, releasedMessage, report, 30000) { }

    internal PageDownHook(IntPtr destination, int releasedMessage, Action<string> report, int refreshMilliseconds) {
        if(destination==IntPtr.Zero) throw new ArgumentException("A destination window is required.", "destination");
        if(refreshMilliseconds<1) throw new ArgumentOutOfRangeException("refreshMilliseconds");
        this.destination=destination; this.releasedMessage=releasedMessage;
        this.report=report; this.refreshMilliseconds=refreshMilliseconds;
        callback=KeyboardHook;
        thread=new Thread(Run) {IsBackground=true, Name="DeskSwitch PageDown hook"};
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        var deadline=Stopwatch.StartNew();
        lock(startupGate) {
            while(!started && deadline.ElapsedMilliseconds<5000)
                Monitor.Wait(startupGate, (int)Math.Max(1,5000-deadline.ElapsedMilliseconds));
        }
        if(!started || startupError!=null) {
            Dispose();
            throw new InvalidOperationException("Cannot start the PageDown keyboard listener.",
                startupError ?? new TimeoutException("Keyboard listener startup timed out."));
        }
    }

    bool Stopping { get { return Interlocked.CompareExchange(ref stopping,0,0)!=0; } }

    void Run() {
        HookWindow window=null;
        System.Windows.Forms.Timer timer=null;
        try {
            window=new HookWindow(this);
            Interlocked.Exchange(ref windowHandle,window.Handle);
            Install(PageDownRefresh.Startup);
            timer=new System.Windows.Forms.Timer {Interval=refreshMilliseconds};
            // Windows silently removes a timed-out hook and offers no health query.
            // Bound recovery to 30s. Never reset a held key or synthesize a switch here.
            timer.Tick += delegate { if(!Stopping) TryInstall(PageDownRefresh.Periodic); };
            timer.Start();
            lock(startupGate) {started=true; Monitor.PulseAll(startupGate);}
            if(!Stopping) Application.Run();
        } catch(Exception error) {
            lock(startupGate) {
                if(!started) {startupError=error; started=true; Monitor.PulseAll(startupGate);}
            }
            Report("PageDown listener stopped: "+error.Message);
        } finally {
            if(timer!=null) timer.Dispose();
            if(hook!=IntPtr.Zero) {UnhookWindowsHookEx(hook); hook=IntPtr.Zero;}
            key.Reset();
            Interlocked.Exchange(ref windowHandle,IntPtr.Zero);
            if(window!=null) window.Dispose();
        }
    }

    void Install(PageDownRefresh reason) {
        // Install first: a failed replacement must not discard a working listener.
        // Both calls run synchronously on its owning thread, with no message pump
        // between them, so the overlapping registrations cannot process an event twice.
        IntPtr replacement=SetWindowsHookEx(13,callback,GetModuleHandle(null),0);
        if(replacement==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(),"Cannot watch the PageDown key.");
        IntPtr previous=hook;
        hook=replacement;
        bool previousUnhookFailed=previous!=IntPtr.Zero && !UnhookWindowsHookEx(previous);
        // A removed hook may have missed key-up. Keep ownership only across a
        // confirmed replacement; stale ownership would capture modified PageDown.
        if(previousUnhookFailed) key.Reset();
        generation++;
        if(reason!=PageDownRefresh.Periodic || lastInstallError!=null || previousUnhookFailed)
            Report("PageDown listener ready: reason="+reason+" generation="+generation+" previousUnhookFailed="+previousUnhookFailed);
        lastInstallError=null;
    }

    void TryInstall(PageDownRefresh reason) {
        if(reason!=PageDownRefresh.Periodic) key.Reset();
        try {Install(reason);}
        catch(Exception error) {
            if(error.Message!=lastInstallError) Report("PageDown listener recovery failed: "+error.Message);
            lastInstallError=error.Message;
        }
    }

    // Called from any thread; all hook/state changes stay on the listener thread.
    public void Refresh(PageDownRefresh reason) {
        if(Stopping) return;
        IntPtr target=Interlocked.CompareExchange(ref windowHandle,IntPtr.Zero,IntPtr.Zero);
        if(target!=IntPtr.Zero) PostMessage(target,RefreshMessage,new IntPtr((int)reason),IntPtr.Zero);
    }

    static bool Down(int code) {return (GetAsyncKeyState(code)&0x8000)!=0;}
    IntPtr KeyboardHook(int code, IntPtr message, IntPtr data) {
        if(code>=0 && !Stopping) {
            int type=message.ToInt32();
            if(type==0x100 || type==0x104 || type==0x101 || type==0x105) {
                var input=(KeyData)Marshal.PtrToStructure(data,typeof(KeyData));
                if(input.Key==PageDownKey.VirtualKey) {
                    bool modified=Down(0x10) || Down(0x11) || Down(0x12) || Down(0x5B) || Down(0x5C);
                    bool trigger;
                    bool consume=key.Handle((int)input.Key,input.Flags,type==0x100 || type==0x104,modified,out trigger);
                    if(trigger) PostMessage(destination,releasedMessage,new IntPtr(generation),IntPtr.Zero);
                    if(consume) return new IntPtr(1);
                }
            }
        }
        return CallNextHookEx(hook,code,message,data);
    }

    void Report(string message) {
        if(report!=null) ThreadPool.QueueUserWorkItem(delegate {
            // Diagnostics must neither block the listener nor terminate the process.
            try {report(message);} catch(Exception) { }
        });
    }

    public void Dispose() {
        if(Interlocked.Exchange(ref stopping,1)!=0) return;
        IntPtr target=Interlocked.CompareExchange(ref windowHandle,IntPtr.Zero,IntPtr.Zero);
        if(target!=IntPtr.Zero) PostMessage(target,StopMessage,IntPtr.Zero,IntPtr.Zero);
        if(Thread.CurrentThread!=thread && !thread.Join(3000))
            Report("PageDown listener shutdown is still pending.");
    }

    sealed class HookWindow : NativeWindow, IDisposable {
        readonly PageDownHook owner;
        public HookWindow(PageDownHook owner) {
            this.owner=owner;
            CreateHandle(new CreateParams {Caption="DeskSwitch PageDown listener"});
        }
        protected override void WndProc(ref Message message) {
            if(message.Msg==StopMessage) {Application.ExitThread(); return;}
            if(message.Msg==RefreshMessage) {
                if(!owner.Stopping) owner.TryInstall((PageDownRefresh)message.WParam.ToInt32());
                return;
            }
            base.WndProc(ref message);
        }
        public void Dispose() {DestroyHandle();}
    }
}
