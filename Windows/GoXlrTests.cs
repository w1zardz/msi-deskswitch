using System;
using System.Collections.Generic;
using System.IO;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

internal sealed class FakeGoXlr : IGoXlrApi {
    readonly object gate=new object();
    readonly Dictionary<string,int> levels=new Dictionary<string,int> {{"A",128},{"B",80}};
    public readonly List<string> Writes=new List<string>();
    public readonly ManualResetEvent StatusStarted=new ManualResetEvent(false);
    public readonly ManualResetEvent ReleaseStatus=new ManualResetEvent(false);
    public bool BlockNextStatus,FailNextSet,FailNextStatus;
    public int SetAttempts;
    public int Level(string serial) {lock(gate) {return levels[serial];}}
    public void Level(string serial,int value) {lock(gate) {levels[serial]=value;}}
    public void Remove(string serial) {lock(gate) {levels.Remove(serial);}}
    public GoXlrMixer[] GetMixers(GoXlrOperation operation) {
        var snapshot=new List<GoXlrMixer>();
        bool block;
        lock(gate) {
            if(FailNextStatus) {FailNextStatus=false; throw new Exception("offline");}
            foreach(var pair in levels) snapshot.Add(new GoXlrMixer {Serial=pair.Key,Name="GoXLR",Headphones=pair.Value});
            block=BlockNextStatus; BlockNextStatus=false;
        }
        if(block) {StatusStarted.Set(); if(!ReleaseStatus.WaitOne(4000)) throw new Exception("Test timed out waiting for release.");}
        // Intentionally return even if cancelled: the worker must reject stale status.
        return snapshot.ToArray();
    }
    public void SetHeadphones(string serial,int value,GoXlrOperation operation) {
        lock(gate) {
            SetAttempts++;
            if(FailNextSet) {FailNextSet=false; throw new Exception("HTTP 200 Error");}
            levels[serial]=value; Writes.Add(serial+":"+value);
        }
    }
}

internal static class GoXlrTests {
    static int count;
    static void Check(bool condition,string message) {if(!condition) throw new Exception(message); count++;}
    static void Throws(Action action,string message) {
        bool thrown=false; try {action();} catch(Exception) {thrown=true;}
        Check(thrown,message);
    }
    static GoXlrSettings Config() {return new GoXlrSettings {Enabled=true,Serial="A",Port=14564};}
    static GoXlrAudio Engine(FakeGoXlr fake) {return new GoXlrAudio(Config(),delegate(GoXlrUpdate update){},delegate(int port){return fake;});}
    static void Idle(GoXlrAudio audio) {Check(audio.WaitForIdle(5000),"Worker did not become idle.");}
    static string Status(string value) {return "{\"Status\":{\"mixers\":{\"A\":{\"hardware\":{\"serial_number\":\"A\",\"device_type\":\"Full\"},\"levels\":{\"volumes\":{\"Headphones\":"+value+"}}}}}}";}
    static void Protocol() {
        var mixers=GoXlrApi.ParseMixers(GoXlrApi.Parse(Status("128")));
        Check(mixers.Length==1 && mixers[0].Serial=="A" && mixers[0].Headphones==128,"Valid status did not parse.");
        Check(GoXlrApi.ParseMixers(GoXlrApi.Parse("{\"Status\":{\"mixers\":{}}}")).Length==0,"Empty mixers must remain empty.");
        foreach(var invalid in new string[]{"null","\"128\"","true","1.5","-1","256"}) {
            string value=invalid;
            Throws(delegate {GoXlrApi.ParseMixers(GoXlrApi.Parse(Status(value)));},"Invalid volume accepted: "+value);
        }
        Throws(delegate {GoXlrApi.ParseMixers(GoXlrApi.Parse(Status("128").Replace("\"Headphones\":128","\"System\":128")));},"Missing Headphones accepted.");
        Throws(delegate {GoXlrApi.ParseMixers(GoXlrApi.Parse("{\"mixers\":{}}"));},"Unwrapped GET response accepted for POST.");
        Throws(delegate {GoXlrApi.Parse("{\"Error\":\"device not connected\"}");},"HTTP 200 Error ignored.");
        Throws(delegate {GoXlrApi.Parse("not json");},"Malformed JSON accepted.");
        GoXlrApi.RequireOk(GoXlrApi.Parse("\"Ok\"")); count++;
        Throws(delegate {GoXlrApi.RequireOk(GoXlrApi.Parse("{}"));},"Unknown write response accepted.");
        Throws(delegate {new GoXlrApi(0);},"Port zero accepted.");
        Throws(delegate {new GoXlrApi(65536);},"Out-of-range port accepted.");
    }
    static void HttpReply(string reply,string status,Action<GoXlrApi> check,Action<string> requestCheck) {
        var listener=new TcpListener(IPAddress.Loopback,0); listener.Start();
        int port=((IPEndPoint)listener.LocalEndpoint).Port;
        string captured=null; Exception serverError=null;
        var thread=new Thread(delegate() {
            try {
                using(var client=listener.AcceptTcpClient()) using(var stream=client.GetStream()) {
                    stream.ReadTimeout=4000; stream.WriteTimeout=4000;
                    var reader=new StreamReader(stream,Encoding.UTF8,false,1024,true);
                    string line=reader.ReadLine();
                    if(line!="POST /api/command HTTP/1.1") throw new Exception("Unexpected request: "+line);
                    int length=0;
                    while(!String.IsNullOrEmpty(line=reader.ReadLine())) {
                        if(line.StartsWith("Content-Length:",StringComparison.OrdinalIgnoreCase)) length=Int32.Parse(line.Substring(15).Trim());
                        if(line.StartsWith("Expect:",StringComparison.OrdinalIgnoreCase)) {
                            byte[] interim=Encoding.ASCII.GetBytes("HTTP/1.1 100 Continue\r\n\r\n"); stream.Write(interim,0,interim.Length); stream.Flush();
                        }
                    }
                    var body=new char[length]; int offset=0;
                    while(offset<length) {int read=reader.Read(body,offset,length-offset); if(read==0) throw new Exception("Incomplete body."); offset+=read;}
                    captured=new string(body);
                    byte[] data=Encoding.UTF8.GetBytes(reply);
                    byte[] header=Encoding.ASCII.GetBytes("HTTP/1.1 "+status+"\r\nContent-Type: application/json\r\nContent-Length: "+data.Length+"\r\nLocation: http://127.0.0.1:1/forbidden\r\nConnection: close\r\n\r\n");
                    stream.Write(header,0,header.Length); stream.Write(data,0,data.Length); stream.Flush();
                }
            } catch(Exception error) {serverError=error;}
        }) {IsBackground=true};
        thread.Start();
        try {check(new GoXlrApi(port));}
        finally {listener.Stop(); Check(thread.Join(5000),"Fake HTTP server did not finish.");}
        if(serverError!=null) throw serverError;
        requestCheck(captured);
    }
    static void Http() {
        HttpReply(Status("128"),"200 OK",delegate(GoXlrApi api) {
            Check(api.GetMixers(new GoXlrOperation())[0].Headphones==128,"HTTP status parsing failed.");
        },delegate(string request) {Check(request=="\"GetStatus\"","Incorrect GetStatus JSON.");});
        HttpReply("\"Ok\"","200 OK",delegate(GoXlrApi api) {
            api.SetHeadphones("A",5,new GoXlrOperation()); count++;
        },delegate(string request) {Check(request=="{\"Command\":[\"A\",{\"SetVolume\":[\"Headphones\",5]}]}","SetVolume targets wrong channel or serial.");});
        HttpReply("{\"Error\":\"device offline\"}","200 OK",delegate(GoXlrApi api) {
            Throws(delegate {api.SetHeadphones("A",5,new GoXlrOperation());},"HTTP 200 error ignored by transport.");
        },delegate(string request){});
        HttpReply("{}","302 Found",delegate(GoXlrApi api) {
            Throws(delegate {api.GetMixers(new GoXlrOperation());},"Redirect was followed/accepted.");
        },delegate(string request){});
        HttpReply("{}","500 Error",delegate(GoXlrApi api) {
            Throws(delegate {api.GetMixers(new GoXlrOperation());},"HTTP 500 ignored.");
        },delegate(string request){});
        var listener=new TcpListener(IPAddress.Loopback,0); listener.Start();
        int port=((IPEndPoint)listener.LocalEndpoint).Port;
        var stop=new ManualResetEvent(false);
        var server=new Thread(delegate() {
            try {using(var connection=listener.AcceptTcpClient()) stop.WaitOne(4000);} catch(SocketException) { }
        }) {IsBackground=true};
        server.Start(); var elapsed=Stopwatch.StartNew();
        try {Throws(delegate {new GoXlrApi(port).GetMixers(new GoXlrOperation());},"Silent daemon did not time out.");}
        finally {stop.Set(); listener.Stop(); Check(server.Join(5000),"Timeout server did not finish."); stop.Dispose();}
        Check(elapsed.ElapsedMilliseconds<4000,"HTTP request exceeded bounded timeout.");
    }
    static void QueueAndClamp() {
        var fake=new FakeGoXlr {BlockNextStatus=true};
        using(var audio=Engine(fake)) {
            audio.VolumeKey(0xAF); Check(fake.StatusStarted.WaitOne(2000),"First status not started.");
            audio.VolumeKey(0xAF); audio.VolumeKey(0xAF); audio.VolumeKey(0xAF);
            fake.ReleaseStatus.Set(); Idle(audio);
            Check(fake.Level("A")==148 && fake.Writes.Count==2,"Same-direction burst lost ticks or was not coalesced.");
            Check(fake.Level("B")==80,"Unselected mixer changed.");
            fake.Level("A",250); audio.VolumeKey(0xAF); audio.VolumeKey(0xAF); audio.VolumeKey(0xAE); Idle(audio);
            Check(fake.Level("A")==250,"Opposite directions were combined across upper clamp.");
            fake.Level("A",2); audio.VolumeKey(0xAE); audio.VolumeKey(0xAE); Idle(audio);
            Check(fake.Level("A")==0,"Lower clamp failed.");
            fake.Level("A",90); audio.VolumeKey(0xAF); Idle(audio);
            Check(fake.Level("A")==95,"Worker used cached volume instead of fresh status.");
        }
    }
    static void Mute() {
        var fake=new FakeGoXlr();
        using(var audio=Engine(fake)) {
            audio.VolumeKey(0xAD); Idle(audio); Check(fake.Level("A")==0,"Mute failed.");
            audio.VolumeKey(0xAD); Idle(audio); Check(fake.Level("A")==128,"Mute did not restore confirmed prior volume.");
            fake.Level("A",0); int before=fake.SetAttempts;
            audio.VolumeKey(0xAD); Idle(audio); Check(fake.SetAttempts==before,"Unknown zero volume was raised.");
            fake.Level("A",120); fake.FailNextSet=true;
            audio.VolumeKey(0xAD); Idle(audio); fake.Level("A",0); before=fake.SetAttempts;
            audio.VolumeKey(0xAD); Idle(audio); Check(fake.SetAttempts==before,"Failed mute created restore state.");
            fake.Level("A",100); audio.VolumeKey(0xAD); Idle(audio);
            audio.HardwareChanged(); Idle(audio); before=fake.SetAttempts;
            audio.VolumeKey(0xAD); Idle(audio); Check(fake.SetAttempts==before,"Disconnect retained restore state.");
            fake.Level("A",100); audio.VolumeKey(0xAD); Idle(audio);
            fake.FailNextStatus=true; audio.Refresh(); Idle(audio); before=fake.SetAttempts;
            audio.VolumeKey(0xAD); Idle(audio); Check(fake.SetAttempts==before,"API error retained restore state.");
            fake.Level("A",100); audio.VolumeKey(0xAD); audio.VolumeKey(0xAD); Idle(audio);
            Check(fake.Level("A")==100,"Adjacent mute commands lost their order.");
            audio.VolumeKey(0xAF); audio.VolumeKey(0xAD); audio.VolumeKey(0xAF); Idle(audio);
            Check(fake.Level("A")==5,"Volume ticks were coalesced across mute.");
            fake.Level("A",100); audio.VolumeKey(0xAD); Idle(audio);
        }
        int attempts=fake.SetAttempts;
        using(var audio=Engine(fake)) {audio.VolumeKey(0xAD); Idle(audio); Check(fake.SetAttempts==attempts,"New session retained old mute recovery.");}
    }
    static void Cancellation(Action<GoXlrAudio> cancel,string label) {
        var fake=new FakeGoXlr {BlockNextStatus=true};
        using(var audio=Engine(fake)) {
            audio.VolumeKey(0xAF); Check(fake.StatusStarted.WaitOne(2000),"Status not started: "+label);
            audio.VolumeKey(0xAF); cancel(audio); fake.ReleaseStatus.Set(); Idle(audio);
            Check(fake.SetAttempts==0,"Stale write after "+label);
        }
    }
    static void Failures() {
        Cancellation(delegate(GoXlrAudio audio){var c=audio.Settings;c.Enabled=false;audio.Configure(c);},"disable");
        Cancellation(delegate(GoXlrAudio audio){var c=audio.Settings;c.Serial="B";audio.Configure(c);},"serial change");
        Cancellation(delegate(GoXlrAudio audio){var c=audio.Settings;c.Port=14565;audio.Configure(c);},"port change");
        Cancellation(delegate(GoXlrAudio audio){audio.Suspend(true);},"sleep");
        Cancellation(delegate(GoXlrAudio audio){audio.SuspendSession(true);},"session lock/disconnect");
        var fake=new FakeGoXlr {BlockNextStatus=true,FailNextSet=true};
        using(var audio=Engine(fake)) {
            audio.VolumeKey(0xAF); Check(fake.StatusStarted.WaitOne(2000),"Failure test did not start.");
            audio.VolumeKey(0xAF); audio.VolumeKey(0xAD); fake.ReleaseStatus.Set(); Idle(audio);
            Check(fake.SetAttempts==1 && fake.Writes.Count==0,"Failed write retried or left queued actions.");
            fake.Remove("A"); audio.VolumeKey(0xAF); Idle(audio);
            Check(fake.SetAttempts==1 && audio.OwnsVolumeKeys,"Offline selected mixer changed another device or released system keys.");
        }
        fake=new FakeGoXlr();
        using(var audio=new GoXlrAudio(new GoXlrSettings(),delegate(GoXlrUpdate u){},delegate(int p){return fake;})) {
            audio.Refresh(); Idle(audio); audio.VolumeKey(0xAF); Idle(audio);
            Check(!audio.OwnsVolumeKeys && fake.SetAttempts==0 && audio.Settings.Serial=="","Disabled mode auto-selected a device or changed volume.");
        }
    }
    static void SessionLifecycle() {
        var fake=new FakeGoXlr();
        using(var audio=Engine(fake)) {
            audio.Suspend(true); audio.SuspendSession(true); audio.SuspendSession(false);
            audio.VolumeKey(0xAF); Idle(audio);
            Check(!audio.OwnsVolumeKeys && fake.SetAttempts==0,"Session unlock incorrectly cleared power suspension.");
            audio.Suspend(false); Idle(audio);
            Check(audio.OwnsVolumeKeys && fake.SetAttempts==0,"Wake replayed a suspended volume command.");
            audio.SuspendSession(true); audio.Suspend(true); audio.Suspend(false);
            audio.VolumeKey(0xAF); Idle(audio);
            Check(!audio.OwnsVolumeKeys && fake.SetAttempts==0,"Power resume incorrectly cleared session suspension.");
            audio.SuspendSession(false); Idle(audio);
            Check(audio.OwnsVolumeKeys && fake.SetAttempts==0,"Session reconnect replayed queued commands.");
            audio.VolumeKey(0xAD); Idle(audio); Check(fake.Level("A")==0,"Session mute setup failed.");
            int attempts=fake.SetAttempts;
            audio.SuspendSession(true); audio.SuspendSession(false); Idle(audio);
            audio.VolumeKey(0xAD); Idle(audio);
            Check(fake.SetAttempts==attempts,"Session transition retained mute restore volume.");
        }
    }
    static void KeyEpochs() {
        var fake=new FakeGoXlr();
        using(var audio=Engine(fake)) {
            bool enabled; long revision,reset;
            audio.GetKeyState(out enabled,out revision,out reset);
            audio.Refresh(); Idle(audio);
            long after,resetAfter; audio.GetKeyState(out enabled,out after,out resetAfter);
            Check(after==revision && resetAfter==reset,"Ordinary status refresh changed held-key ownership.");
            var value=audio.Settings; value.Serial="B"; audio.Configure(value); Idle(audio);
            audio.GetKeyState(out enabled,out after,out resetAfter);
            Check(after!=revision && resetAfter==reset,"Configuration must invalidate held keys without losing key-up ownership.");
            audio.VolumeKey(0xAF,revision); Idle(audio);
            Check(fake.SetAttempts==0,"A key from the previous configuration changed the new serial.");
            audio.HardwareChanged(); Idle(audio); audio.GetKeyState(out enabled,out after,out resetAfter);
            Check(resetAfter!=reset,"USB transition did not reset missed key-up state.");
            reset=resetAfter; audio.SuspendSession(true); audio.GetKeyState(out enabled,out after,out resetAfter);
            Check(resetAfter!=reset,"Session transition did not reset missed key-up state.");
            reset=resetAfter; audio.Suspend(true); audio.GetKeyState(out enabled,out after,out resetAfter);
            Check(resetAfter!=reset,"Sleep transition did not reset missed key-up state.");
        }
    }
    static void KeyOwnership() {
        var keys=new GoXlrKeyOwnership(); int actions=0; Action<int> action=delegate(int key){actions++;};
        Check(!keys.Handle(0x22,true,true,action),"PageDown intercepted.");
        Check(!keys.Handle(0xAF,true,false,action),"Disabled volume down swallowed.");
        Check(!keys.Handle(0xAF,true,true,action),"Enabling during a passed held key stole its repeat.");
        Check(!keys.Handle(0xAF,false,true,action),"Enabling during a passed held key stole key-up.");
        Check(keys.Handle(0xAF,true,true,action),"Enabled key not owned.");
        Check(keys.Handle(0xAF,true,false,action),"Owned repeat leaked after disabling.");
        Check(keys.Handle(0xAF,false,false,action),"Owned key-up leaked after disabling.");
        Check(actions==1,"Disabled repeat enqueued a command.");
        Check(keys.Handle(0xAD,true,true,action) && keys.Handle(0xAD,true,true,action),"Mute not owned.");
        keys.Handle(0xAD,false,true,action); Check(actions==2,"Mute auto-repeat toggled multiple times.");
        int before=actions;
        keys.Handle(0xAF,true,true,action); keys.Invalidate();
        Check(keys.Handle(0xAF,true,true,action) && actions==before+1,"Held repeat changed the new configuration after invalidation.");
        Check(keys.Handle(0xAF,false,true,action),"Invalidation lost owned key-up.");
        keys.Handle(0xAF,true,true,action); keys.Handle(0xAF,false,true,action);
        Check(actions==before+2,"Fresh press stayed inert after release.");
        keys.Handle(0xAD,true,true,action); before=actions;
        keys.Reset(); // Previous key-up happened on the lock screen or another KVM host.
        Check(keys.Handle(0xAD,true,true,action) && actions==before+1,"First mute click after reconnect was treated as an old repeat.");
    }
    public static int Main() {
        try {Protocol(); Http(); QueueAndClamp(); Mute(); Failures(); SessionLifecycle(); KeyEpochs(); KeyOwnership(); Console.WriteLine("GoXLR: "+count+" checks passed."); return 0;}
        catch(Exception error) {Console.Error.WriteLine(error); return 1;}
    }
}
