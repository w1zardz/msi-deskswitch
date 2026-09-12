using System;
using System.ComponentModel;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

// One passive window, reused for each acknowledged GoXLR volume gesture.
internal sealed class HeadphonesOverlay : Form {
    [DllImport("user32.dll",SetLastError=true)] static extern bool SetWindowPos(IntPtr window,IntPtr after,int x,int y,int width,int height,uint flags);
    readonly Timer dismiss = new Timer {Interval=1100};
    readonly Font caption = new Font("Segoe UI",11,FontStyle.Bold);
    readonly float scale;
    int volume;

    public HeadphonesOverlay() {
        Text="Громкость наушников GoXLR";
        FormBorderStyle=FormBorderStyle.None;
        ShowInTaskbar=false;
        StartPosition=FormStartPosition.Manual;
        TopMost=true;
        BackColor=Color.FromArgb(30,33,39);
        Opacity=0.96;
        DoubleBuffered=true;
        AutoScaleMode=AutoScaleMode.None;
        using(var graphics=CreateGraphics()) scale=graphics.DpiX/96f;
        ClientSize=new Size(Px(268),Px(78));
        using(var shape=Rounded(new RectangleF(0,0,Width,Height),Px(18))) Region=new Region(shape);
        dismiss.Tick += delegate {Dismiss();};
    }

    protected override bool ShowWithoutActivation {get {return true;}}
    protected override CreateParams CreateParams {
        get {
            var value=base.CreateParams;
            // NOACTIVATE, TOOLWINDOW and TRANSPARENT: no focus, taskbar entry or intercepted click.
            value.ExStyle |= 0x08000000 | 0x00000080 | 0x00000020;
            return value;
        }
    }
    protected override void WndProc(ref Message message) {
        if(message.Msg==0x84) {message.Result=new IntPtr(-1); return;} // HTTRANSPARENT
        if(message.Msg==0x21) {message.Result=new IntPtr(3); return;} // MA_NOACTIVATE
        base.WndProc(ref message);
    }

    public void ShowLevel(int confirmedVolume) {
        if(IsDisposed || confirmedVolume<0 || confirmedVolume>255) return;
        volume=confirmedVolume;
        var area=Screen.FromPoint(Cursor.Position).WorkingArea;
        Location=new Point(area.Left+(area.Width-Width)/2,area.Bottom-Height-Px(48));
        Invalidate();
        if(!Visible) Show();
        // TopMost alone does not raise an already visible window above other topmost windows.
        // SHOWWINDOW also makes the native window visible after a hidden background launch.
        if(!SetWindowPos(Handle,new IntPtr(-1),0,0,0,0,0x0253))
            throw new Win32Exception(Marshal.GetLastWin32Error(),"Не удалось показать шкалу громкости.");
        Update();
        dismiss.Stop();
        dismiss.Start();
    }

    public void Dismiss() {
        if(IsDisposed) return;
        if(InvokeRequired) {
            try {BeginInvoke((Action)Dismiss);} catch(InvalidOperationException) { }
            return;
        }
        dismiss.Stop(); Hide();
    }
    int Px(float value) {return (int)Math.Round(value*scale);}
    static GraphicsPath Rounded(RectangleF rect,float radius) {
        var path=new GraphicsPath();
        float diameter=radius*2;
        path.AddArc(rect.X,rect.Y,diameter,diameter,180,90);
        path.AddArc(rect.Right-diameter,rect.Y,diameter,diameter,270,90);
        path.AddArc(rect.Right-diameter,rect.Bottom-diameter,diameter,diameter,0,90);
        path.AddArc(rect.X,rect.Bottom-diameter,diameter,diameter,90,90);
        path.CloseFigure();
        return path;
    }
    protected override void OnPaint(PaintEventArgs e) {
        base.OnPaint(e);
        var g=e.Graphics;
        g.SmoothingMode=SmoothingMode.AntiAlias;
        using(var ink=new Pen(Color.FromArgb(222,230,242),Px(2))) {
            g.DrawArc(ink,Px(23),Px(20),Px(20),Px(22),180,180);
            g.DrawLine(ink,Px(23),Px(30),Px(23),Px(40));
            g.DrawLine(ink,Px(43),Px(30),Px(43),Px(40));
            g.DrawRectangle(ink,Px(23),Px(32),Px(4),Px(9));
            g.DrawRectangle(ink,Px(39),Px(32),Px(4),Px(9));
        }
        int percent=(int)Math.Round(volume*100.0/255,MidpointRounding.AwayFromZero);
        TextRenderer.DrawText(g,"Наушники · "+percent+"%",caption,
            new Rectangle(Px(57),Px(18),Px(196),Px(29)),Color.FromArgb(245,247,251),
            TextFormatFlags.Left|TextFormatFlags.VerticalCenter|TextFormatFlags.NoPadding);
        var track=new RectangleF(Px(24),Px(56),Px(220),Px(4));
        using(var path=Rounded(track,Px(2))) using(var brush=new SolidBrush(Color.FromArgb(69,75,86))) g.FillPath(brush,path);
        if(volume>0) {
            track.Width=Math.Max(Px(4),track.Width*volume/255f);
            using(var path=Rounded(track,Px(2))) using(var brush=new SolidBrush(Color.FromArgb(131,190,247))) g.FillPath(brush,path);
        }
    }
    protected override void Dispose(bool disposing) {
        if(disposing) {dismiss.Dispose(); caption.Dispose();}
        base.Dispose(disposing);
    }
}
