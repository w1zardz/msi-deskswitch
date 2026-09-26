using System;
using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

// Native input injection belongs on the isolated Windows CI desktop, never in the
// user's running DeskSwitch session. No monitor, mouse, audio or DDC calls are made.
internal static class PageDownHookTests {
    [StructLayout(LayoutKind.Sequential)] struct KeyboardInput {public ushort Key,Scan; public uint Flags,Time; public UIntPtr Extra;}
    [StructLayout(LayoutKind.Sequential)] struct MouseInput {public int X,Y; public uint Data,Flags,Time; public UIntPtr Extra;}
    [StructLayout(LayoutKind.Explicit)] struct InputUnion {
        [FieldOffset(0)] public KeyboardInput Keyboard;
        [FieldOffset(0)] public MouseInput Mouse;
    }
    [StructLayout(LayoutKind.Sequential)] struct Input {public uint Type; public InputUnion Data;}
    [DllImport("user32.dll",SetLastError=true)] static extern uint SendInput(uint count,Input[] inputs,int size);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
    const int Released=0x8050;
    static int checks;
    sealed class Receiver : NativeWindow, IDisposable {
        public int Releases;
        public Receiver() {CreateHandle(new CreateParams {Caption="DeskSwitch hook test receiver"});}
        protected override void WndProc(ref Message message) {
            if(message.Msg==Released) {Releases++; return;}
            base.WndProc(ref message);
        }
        public void Dispose() {DestroyHandle();}
    }
    static void Check(bool condition,string message) {if(!condition) throw new Exception(message); checks++;}
    static void Pump(int milliseconds) {
        var clock=Stopwatch.StartNew();
        while(clock.ElapsedMilliseconds<milliseconds) {Application.DoEvents(); Thread.Sleep(10);}
    }
    static void Until(Func<bool> condition,string message) {
        var clock=Stopwatch.StartNew();
        while(!condition() && clock.ElapsedMilliseconds<5000) Pump(10);
        Check(condition(),message);
    }
    static void Key(bool down) {Key(0x22,down,true);}
    static void Key(ushort code,bool down,bool extended) {
        var input=new Input {Type=1};
        input.Data.Keyboard=new KeyboardInput {Key=code,Flags=(extended?0x01u:0u) | (down?0u:0x02u)};
        Check(SendInput(1,new[] {input},Marshal.SizeOf(typeof(Input)))==1,"SendInput failed: "+Marshal.GetLastWin32Error());
    }
    static void Press(Receiver receiver,int expected) {
        Key(true); Thread.Sleep(30); Key(false);
        Until(delegate {return receiver.Releases==expected;},"PageDown release was lost or duplicated.");
    }
    static object Field(PageDownHook hook,string name) {
        return typeof(PageDownHook).GetField(name,BindingFlags.Instance | BindingFlags.NonPublic).GetValue(hook);
    }
    static int Generation(PageDownHook hook) {return (int)Field(hook,"generation");}
    static void RemoveNativeHook(PageDownHook hook) {
        // Simulate Windows silently removing the hook; do not tell the owner.
        for(int i=0;i<10;i++) {
            if(UnhookWindowsHookEx((IntPtr)Field(hook,"hook"))) return;
            Thread.Sleep(10);
        }
        throw new Exception("Could not simulate silent hook removal.");
    }
    [STAThread] static int Main(string[] args) {
        if(args.Length!=1 || args[0]!="--allow-input-injection" || Environment.GetEnvironmentVariable("GITHUB_ACTIONS")!="true") {
            Console.Error.WriteLine("Native hook tests require explicit input injection on the isolated GitHub Actions desktop.");
            return 2;
        }
        try {
            using(var receiver=new Receiver()) {
                // Periodic replacement must preserve an in-flight press and recover
                // silent removal without a USB, power, or session notification.
                var hook=new PageDownHook(receiver.Handle,Released,null,250);
                var thread=(Thread)Field(hook,"thread");
                try {
                    Press(receiver,1);
                    Key(true); Pump(60);
                    int generation=Generation(hook);
                    Until(delegate {return Generation(hook)>=generation+2;},"Periodic hook renewal did not run.");
                    Key(true); Pump(60);
                    Check(receiver.Releases==1,"A timer or repeat triggered a switch while PageDown was held.");
                    Key(false);
                    Until(delegate {return receiver.Releases==2;},"Periodic renewal lost the held key's release.");

                    RemoveNativeHook(hook);
                    generation=Generation(hook);
                    Until(delegate {return Generation(hook)>generation;},"Silent removal was not followed by periodic recovery.");
                    Check(receiver.Releases==2,"Recovery itself triggered a switch.");
                    Press(receiver,3);

                    // The UI message loop deliberately stalls beyond the Windows hook
                    // timeout. The dedicated hook still captures both down and up.
                    Exception injectionError=null;
                    var injector=new Thread(delegate() {
                        try {Thread.Sleep(100); Key(true); Thread.Sleep(30); Key(false);}
                        catch(Exception error) {injectionError=error;}
                    });
                    injector.Start();
                    Thread.Sleep(1600);
                    Check(injector.Join(3000),"Input injector did not finish.");
                    if(injectionError!=null) throw injectionError;
                    Check(receiver.Releases==3,"The test UI accidentally pumped messages during its stall.");
                    Until(delegate {return receiver.Releases==4;},"UI stall caused the listener to lose PageDown.");
                    Press(receiver,5);
                } finally {hook.Dispose();}
                Check(!thread.IsAlive,"Dispose left the dedicated listener thread running.");
                hook.Dispose();
                hook.Refresh(PageDownRefresh.Resume);
                Pump(300);
                Check(receiver.Releases==5,"Dispose or refresh after Dispose posted a switch.");

                // With the periodic deadline far away, only each explicit lifecycle
                // event can restore a forcibly removed hook. It must reset stale presses.
                using(var recovered=new PageDownHook(receiver.Handle,Released,null,30000)) {
                    foreach(PageDownRefresh reason in new[] {PageDownRefresh.UsbChanged,PageDownRefresh.Resume,PageDownRefresh.SessionActive}) {
                        Key(true); Pump(50);
                        RemoveNativeHook(recovered);
                        int generation=Generation(recovered);
                        recovered.Refresh(reason);
                        Until(delegate {return Generation(recovered)>generation;},"Lifecycle recovery failed: "+reason);
                        Key(false); Pump(100);
                        Check(receiver.Releases==5,"Lifecycle recovery kept an old press: "+reason);
                        Press(receiver,6);
                        receiver.Releases=5;
                    }
                }
                // A new instance can start after the old thread and hook are gone.
                using(var restarted=new PageDownHook(receiver.Handle,Released,null)) Press(receiver,6);

                // Removal between down/up loses the release. Exercise the periodic
                // recovery path explicitly so no timer can race the unhooked release.
                using(var lostRelease=new PageDownHook(receiver.Handle,Released,null,30000)) {
                    Key(true); Pump(50);
                    RemoveNativeHook(lostRelease);
                    Key(false); Pump(50);
                    Check(receiver.Releases==6,"The release meant to be lost reached a hook.");
                    int generation=Generation(lostRelease);
                    lostRelease.Refresh(PageDownRefresh.Periodic);
                    Until(delegate {return Generation(lostRelease)>generation;},"Periodic recovery after a lost release failed.");
                    try {
                        Key(0xA2,true,false);
                        Until(delegate {return (GetAsyncKeyState(0x11)&0x8000)!=0;},"The Ctrl modifier did not become active.");
                        Key(true); Pump(30); Key(false); Pump(100);
                        Check(receiver.Releases==6,"Stale ownership captured Ctrl+PageDown after a lost release.");
                    } finally {Key(0xA2,false,false);}
                    Until(delegate {return (GetAsyncKeyState(0x11)&0x8000)==0;},"The Ctrl modifier did not release.");
                    Press(receiver,7);
                }
            }
            Console.WriteLine("Passed "+checks+" native PageDown checks: UI stall, held renewal, silent removal, lifecycle and disposal.");
            return 0;
        } catch(Exception error) {Console.Error.WriteLine(error); return 1;}
    }
}
