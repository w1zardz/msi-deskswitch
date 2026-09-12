using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

internal static class HeadphonesOverlayTests {
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr window,IntPtr after,int x,int y,int width,int height,uint flags);
    [DllImport("user32.dll")] static extern IntPtr GetTopWindow(IntPtr window);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr window,uint relation);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr window,int index);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr window,int message,IntPtr wparam,IntPtr lparam);
    sealed class Cover : Form {
        protected override bool ShowWithoutActivation {get{return true;}}
    }
    static int checks;
    static void Check(bool success,string message) {
        if(!success) throw new Exception(message);
        checks++;
    }
    static bool Above(IntPtr upper,IntPtr lower) {
        // Only compare the two windows owned by this test; do not inspect other apps.
        for(IntPtr window=GetTopWindow(IntPtr.Zero);window!=IntPtr.Zero;window=GetWindow(window,2)) {
            if(window==upper) return true;
            if(window==lower) return false;
        }
        throw new Exception("Test windows were not found in the window order.");
    }
    static void Pump(int milliseconds) {
        var clock=Stopwatch.StartNew();
        while(clock.ElapsedMilliseconds<milliseconds) {Application.DoEvents(); Thread.Sleep(10);}
    }
    [STAThread] static int Main() {
        try {
            Application.EnableVisualStyles();
            using(var hud=new HeadphonesOverlay()) using(var cover=new Cover()) {
                int activated=0,painted=0;
                hud.Activated += delegate {activated++;};
                hud.Paint += delegate {painted++;};
                hud.ShowLevel(102);
                Check(hud.Visible && IsWindowVisible(hud.Handle),"First volume gesture did not show the native window after hidden startup.");
                Check(painted>0,"First gesture did not paint the overlay immediately.");
                Check(!hud.ShowInTaskbar,"Overlay appeared in the taskbar.");
                Check((GetWindowLong(hud.Handle,-20)&0x080000A0)==0x080000A0,"Overlay lost NOACTIVATE, TOOLWINDOW or TRANSPARENT style.");
                Check(SendMessage(hud.Handle,0x84,IntPtr.Zero,IntPtr.Zero)==new IntPtr(-1),"Overlay intercepted mouse hit testing.");

                cover.ShowInTaskbar=false;
                cover.FormBorderStyle=FormBorderStyle.None;
                cover.StartPosition=FormStartPosition.Manual;
                cover.Bounds=hud.Bounds;
                cover.Show();
                Check(SetWindowPos(cover.Handle,new IntPtr(-1),0,0,0,0,0x0013),"Could not arrange the covering test window.");
                Check(Above(cover.Handle,hud.Handle),"The regression scenario did not cover the overlay.");
                hud.ShowLevel(107);
                Check(Above(hud.Handle,cover.Handle),"Next volume gesture left the overlay behind another topmost window.");
                cover.Hide();

                Pump(650);
                hud.ShowLevel(112);
                Pump(650);
                Check(hud.Visible && IsWindowVisible(hud.Handle),"A newer gesture did not extend the dismissal timer.");
                Pump(650);
                Check(!hud.Visible && !IsWindowVisible(hud.Handle),"Overlay remained visible after the last gesture timed out.");
                hud.ShowLevel(117);
                Check(hud.Visible && IsWindowVisible(hud.Handle),"Overlay did not reappear on a later gesture.");
                hud.Dismiss();
                Check(!hud.Visible && !IsWindowVisible(hud.Handle),"Explicit dismissal did not hide the native window.");
                Check(activated==0,"Overlay stole focus.");
            }
            Console.WriteLine("Passed "+checks+" native overlay checks, including hidden startup and a covering topmost window.");
            return 0;
        } catch(Exception error) {Console.Error.WriteLine(error); return 1;}
    }
}
