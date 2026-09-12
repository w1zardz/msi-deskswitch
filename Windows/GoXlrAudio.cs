using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

internal sealed class GoXlrSettings {
    public bool Enabled { get; set; }
    public string Serial { get; set; }
    public int Port { get; set; }
    public GoXlrSettings() { Serial=""; Port=14564; }
    public GoXlrSettings Copy() { return new GoXlrSettings {Enabled=Enabled,Serial=Serial,Port=Port}; }
    public void Validate() {
        if (Port<1 || Port>65535) throw new Exception("Порт GoXLR Utility должен быть от 1 до 65535.");
        if (Serial==null) Serial="";
        if (Serial.Length>256 || Serial.IndexOfAny(new char[]{'\r','\n','\0'})>=0) throw new Exception("Некорректный serial GoXLR.");
        if (Enabled && Serial.Length==0) throw new Exception("Сначала явно выбери GoXLR по serial.");
    }
    static string FilePath {
        get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"MSI-DeskSwitch","goxlr.json"); }
    }
    public static GoXlrSettings Load() {
        if (!File.Exists(FilePath)) return new GoXlrSettings();
        var settings=new JavaScriptSerializer().Deserialize<GoXlrSettings>(File.ReadAllText(FilePath));
        if (settings==null) throw new Exception("Пустые настройки GoXLR.");
        settings.Validate(); return settings;
    }
    public void Save() {
        Validate();
        string path=FilePath, temporary=path+".tmp";
        Directory.CreateDirectory(Path.GetDirectoryName(path));
        File.WriteAllText(temporary,new JavaScriptSerializer().Serialize(this),new UTF8Encoding(false));
        if (File.Exists(path)) File.Replace(temporary,path,null); else File.Move(temporary,path);
    }
}

internal sealed class GoXlrMixer {
    public string Serial;
    public string Name;
    public int Headphones;
}

// A cancelled operation cannot attach a later SetVolume request after GetStatus.
internal sealed class GoXlrOperation {
    readonly object gate=new object();
    bool cancelled;
    HttpWebRequest request;
    public void ThrowIfCancelled() { lock(gate) { if(cancelled) throw new OperationCanceledException(); } }
    public void Attach(HttpWebRequest value) {
        lock(gate) { if(cancelled) throw new OperationCanceledException(); request=value; }
    }
    public void Detach(HttpWebRequest value) { lock(gate) { if(request==value) request=null; } }
    public void Cancel() {
        HttpWebRequest active;
        lock(gate) { cancelled=true; active=request; request=null; }
        if(active!=null) active.Abort();
    }
}

internal interface IGoXlrApi {
    GoXlrMixer[] GetMixers(GoXlrOperation operation);
    void SetHeadphones(string serial,int value,GoXlrOperation operation);
}

internal sealed class GoXlrApi : IGoXlrApi {
    readonly Uri endpoint;
    const int MaxResponse=2097152;
    public GoXlrApi(int port) {
        if(port<1 || port>65535) throw new ArgumentOutOfRangeException("port");
        endpoint=new Uri("http://127.0.0.1:"+port+"/api/command");
    }
    public static object Parse(string json) {
        object response=new JavaScriptSerializer {MaxJsonLength=MaxResponse,RecursionLimit=64}.DeserializeObject(json);
        var map=response as Dictionary<string,object>;
        if(map!=null && map.ContainsKey("Error")) throw new Exception("GoXLR Utility: "+Convert.ToString(map["Error"]));
        return response;
    }
    static Dictionary<string,object> Map(object value,string name) {
        var result=value as Dictionary<string,object>;
        if(result==null) throw new Exception("GoXLR Utility: неверный ответ ("+name+").");
        return result;
    }
    static object Required(Dictionary<string,object> map,string name) {
        object value;
        if(!map.TryGetValue(name,out value)) throw new Exception("GoXLR Utility: в ответе нет "+name+".");
        return value;
    }
    public static GoXlrMixer[] ParseMixers(object response) {
        var status=Map(Required(Map(response,"response"),"Status"),"Status");
        var mixers=Map(Required(status,"mixers"),"mixers");
        var result=new List<GoXlrMixer>();
        foreach(var pair in mixers) {
            if(String.IsNullOrWhiteSpace(pair.Key)) throw new Exception("GoXLR Utility: пустой serial.");
            var mixer=Map(pair.Value,"mixer");
            var levels=Map(Required(mixer,"levels"),"levels");
            var volumes=Map(Required(levels,"volumes"),"volumes");
            object value=Required(volumes,"Headphones");
            if(!(value is int) || (int)value<0 || (int)value>255) throw new Exception("GoXLR Utility: Headphones должен быть целым числом 0–255.");
            string name="GoXLR";
            object hardwareValue;
            if(mixer.TryGetValue("hardware",out hardwareValue)) {
                var hardware=Map(hardwareValue,"hardware"); object type;
                if(hardware.TryGetValue("device_type",out type) && type is string) name+=" "+(string)type;
                object serial;
                if(hardware.TryGetValue("serial_number",out serial) && !String.Equals(serial as string,pair.Key,StringComparison.Ordinal))
                    throw new Exception("GoXLR Utility: serial устройства не совпадает с ключом ответа.");
            }
            result.Add(new GoXlrMixer {Serial=pair.Key,Name=name,Headphones=(int)value});
        }
        result.Sort(delegate(GoXlrMixer a,GoXlrMixer b){return String.CompareOrdinal(a.Serial,b.Serial);});
        return result.ToArray();
    }
    public static void RequireOk(object response) {
        if(!String.Equals(response as string,"Ok",StringComparison.Ordinal)) throw new Exception("GoXLR Utility не подтвердил изменение Headphones.");
    }
    object Send(object command,GoXlrOperation operation) {
        operation.ThrowIfCancelled();
        byte[] body=Encoding.UTF8.GetBytes(new JavaScriptSerializer().Serialize(command));
        var request=(HttpWebRequest)WebRequest.Create(endpoint);
        request.Method="POST"; request.ContentType="application/json"; request.Accept="application/json";
        request.Proxy=null; request.AllowAutoRedirect=false; request.Timeout=1500; request.ReadWriteTimeout=1500;
        request.ContentLength=body.Length;
        operation.Attach(request);
        try {
            using(var stream=request.GetRequestStream()) stream.Write(body,0,body.Length);
            using(var response=(HttpWebResponse)request.GetResponse()) {
                if(response.StatusCode!=HttpStatusCode.OK) throw new Exception("GoXLR Utility: HTTP "+(int)response.StatusCode+".");
                using(var stream=response.GetResponseStream()) using(var bytes=new MemoryStream()) {
                    byte[] buffer=new byte[8192]; int count;
                    while((count=stream.Read(buffer,0,buffer.Length))>0) {
                        if(bytes.Length+count>MaxResponse) throw new Exception("GoXLR Utility: слишком большой ответ.");
                        bytes.Write(buffer,0,count);
                    }
                    operation.ThrowIfCancelled(); return Parse(Encoding.UTF8.GetString(bytes.ToArray()));
                }
            }
        } catch(WebException error) {
            if(error.Response!=null) error.Response.Close();
            operation.ThrowIfCancelled();
            throw new Exception("GoXLR Utility недоступен на 127.0.0.1:"+endpoint.Port+". Проверь запущенный Utility и выбранный порт.",error);
        } finally { operation.Detach(request); }
    }
    public GoXlrMixer[] GetMixers(GoXlrOperation operation) { return ParseMixers(Send("GetStatus",operation)); }
    public void SetHeadphones(string serial,int value,GoXlrOperation operation) {
        if(String.IsNullOrEmpty(serial) || value<0 || value>255) throw new ArgumentException("Invalid Headphones command.");
        var volume=new Dictionary<string,object> {{"SetVolume",new object[]{"Headphones",value}}};
        RequireOk(Send(new Dictionary<string,object> {{"Command",new object[]{serial,volume}}},operation));
    }
}

internal sealed class GoXlrUpdate {
    public long Revision;
    public string Status;
    public bool Error;
    public GoXlrMixer[] Mixers;
    // Present only after a user's volume command was acknowledged (or hit a known limit).
    public int? ConfirmedHeadphones;
}

internal sealed class GoXlrAudio : IDisposable {
    sealed class Work { public long Delta; public bool Mute; public bool Refresh; }
    readonly object gate=new object();
    readonly LinkedList<Work> queue=new LinkedList<Work>();
    readonly AutoResetEvent wake=new AutoResetEvent(false);
    readonly ManualResetEvent idle=new ManualResetEvent(true);
    readonly Thread worker;
    readonly Action<GoXlrUpdate> notify;
    readonly Func<int,IGoXlrApi> createApi;
    GoXlrSettings settings;
    GoXlrOperation active;
    GoXlrMixer[] mixers=new GoXlrMixer[0];
    int? restoreVolume;
    long revision;
    long keyResetRevision;
    bool disposed,powerSuspended,sessionSuspended;
    bool Suspended {get {return powerSuspended || sessionSuspended;}}
    public GoXlrAudio(GoXlrSettings value,Action<GoXlrUpdate> update) : this(value,update,delegate(int port){return new GoXlrApi(port);}) { }
    internal GoXlrAudio(GoXlrSettings value,Action<GoXlrUpdate> update,Func<int,IGoXlrApi> factory) {
        value.Validate(); settings=value.Copy(); notify=update; createApi=factory;
        worker=new Thread(Run) {IsBackground=true,Name="GoXLR Headphones"}; worker.Start();
    }
    public GoXlrSettings Settings { get { lock(gate) {return settings.Copy();} } }
    public long Revision { get {lock(gate) {return revision;}} }
    public bool OwnsVolumeKeys { get { lock(gate) {return !disposed && !Suspended && settings.Enabled && settings.Serial.Length>0;} } }
    internal void GetKeyState(out bool enabled,out long currentRevision,out long resetRevision) {
        lock(gate) {
            enabled=!disposed && !Suspended && settings.Enabled && settings.Serial.Length>0;
            currentRevision=revision; resetRevision=keyResetRevision;
        }
    }
    void ClearLocked() {
        revision++;
        queue.Clear(); restoreVolume=null;
        if(active!=null) active.Cancel();
        if(active==null) idle.Set();
    }
    public void Configure(GoXlrSettings value) {
        value.Validate();
        lock(gate) {
            if(disposed) return;
            ClearLocked();
            if(value.Port!=settings.Port) mixers=new GoXlrMixer[0];
            settings=value.Copy();
        }
        Refresh();
    }
    public void HardwareChanged() {
        lock(gate) {if(disposed) return; keyResetRevision++; ClearLocked();}
        Refresh();
    }
    public void Suspend(bool value) {SetSuspended(value,false);}
    public void SuspendSession(bool value) {SetSuspended(value,true);}
    void SetSuspended(bool value,bool session) {
        bool paused;
        lock(gate) {
            if(disposed) return;
            if(session) sessionSuspended=value; else powerSuspended=value;
            keyResetRevision++; ClearLocked(); paused=Suspended;
        }
        if(paused) Publish(null,"GoXLR: приостановлено — сон или неактивный сеанс.",false); else Refresh();
    }
    public void Refresh() {
        lock(gate) {
            if(disposed || Suspended) return;
            foreach(var item in queue) if(item.Refresh) return;
            queue.AddLast(new Work {Refresh=true}); idle.Reset();
        }
        wake.Set();
    }
    public void VolumeKey(int key) {VolumeKey(key,-1);}
    internal void VolumeKey(int key,long expectedRevision) {
        lock(gate) {
            if(disposed || Suspended || !settings.Enabled || settings.Serial.Length==0 || (expectedRevision>=0 && expectedRevision!=revision)) return;
            long delta=key==0xAF?5:key==0xAE?-5:0;
            if(delta==0 && key!=0xAD) return;
            var tail=queue.Last==null?null:queue.Last.Value;
            if(delta!=0 && tail!=null && !tail.Mute && !tail.Refresh && Math.Sign(tail.Delta)==Math.Sign(delta)) tail.Delta+=delta;
            else queue.AddLast(new Work {Delta=delta,Mute=key==0xAD});
            idle.Reset();
        }
        wake.Set();
    }
    void Publish(GoXlrOperation operation,string status,bool error,int? confirmedHeadphones=null) {
        GoXlrUpdate update;
        lock(gate) {
            if(disposed || (operation!=null && operation!=active)) return;
            if(operation!=null) { try {operation.ThrowIfCancelled();} catch(OperationCanceledException) {return;} }
            update=new GoXlrUpdate {Revision=revision,Status=status,Error=error,Mixers=mixers,ConfirmedHeadphones=confirmedHeadphones};
        }
        notify(update);
    }
    void Run() {
        while(true) {
            wake.WaitOne();
            // Coalesce a short burst; opposite directions and mute retain their order.
            Thread.Sleep(25);
            while(true) {
                Work work; GoXlrSettings config; GoXlrOperation operation;
                lock(gate) {
                    if(disposed) return;
                    if(queue.Count==0 || Suspended) {idle.Set(); break;}
                    work=queue.First.Value; queue.RemoveFirst(); config=settings.Copy();
                    operation=new GoXlrOperation(); active=operation;
                }
                try {
                    var api=createApi(config.Port);
                    var discovered=api.GetMixers(operation);
                    operation.ThrowIfCancelled();
                    GoXlrMixer selected=null;
                    foreach(var mixer in discovered) if(mixer.Serial==config.Serial) selected=mixer;
                    lock(gate) {operation.ThrowIfCancelled(); mixers=discovered;}
                    if(config.Serial.Length>0 && selected==null) throw new Exception("GoXLR "+config.Serial+" не подключён. Headphones не изменён.");
                    if(work.Refresh) {
                        string text=selected==null?"GoXLR Utility: выбери устройство по serial.":"Headphones: "+Math.Round(selected.Headphones*100.0/255)+"% · "+config.Serial;
                        if(!config.Enabled) text="Ручка GoXLR выключена. "+text;
                        Publish(operation,text,false); continue;
                    }
                    if(!config.Enabled || selected==null) continue;
                    int current=selected.Headphones,target;
                    if(work.Mute) {
                        int? saved; lock(gate) {operation.ThrowIfCancelled(); saved=restoreVolume;}
                        if(current==0 && !saved.HasValue) {
                            Publish(operation,"Headphones уже 0%. Нет сохранённого уровня — громкость не повышена.",false,0); continue;
                        }
                        target=current>0?0:saved.Value;
                    } else target=(int)Math.Max(0L,Math.Min(255L,(long)current+work.Delta));
                    if(target!=current) {
                        operation.ThrowIfCancelled();
                        api.SetHeadphones(config.Serial,target,operation);
                        lock(gate) {
                            operation.ThrowIfCancelled();
                            restoreVolume=work.Mute && current>0?(int?)current:null;
                        }
                    }
                    selected.Headphones=target;
                    Publish(operation,"Headphones: "+Math.Round(target*100.0/255)+"% · "+config.Serial,false,target);
                } catch(OperationCanceledException) { }
                catch(Exception error) {
                    bool current;
                    lock(gate) {
                        try {operation.ThrowIfCancelled(); current=true;} catch(OperationCanceledException) {current=false;}
                        if(current) {queue.Clear(); restoreVolume=null;}
                    }
                    if(current) Publish(operation,error.Message+" Системная громкость не изменена.",true);
                } finally {
                    lock(gate) {if(active==operation) active=null; if(queue.Count==0) idle.Set();}
                }
            }
        }
    }
    internal bool WaitForIdle(int milliseconds) {return idle.WaitOne(milliseconds);}
    public void Dispose() {
        lock(gate) {if(disposed) return; disposed=true; ClearLocked();}
        wake.Set();
        if(worker.Join(4000)) {wake.Dispose(); idle.Dispose();}
    }
}

// Track ownership through key-up, including a settings change while a key is held.
internal sealed class GoXlrKeyOwnership {
    sealed class Held {public bool Owned; public bool Inert;}
    readonly Dictionary<int,Held> held=new Dictionary<int,Held>();
    public void Invalidate() {foreach(var state in held.Values) state.Inert=true;}
    public void Reset() {held.Clear();}
    public bool Handle(int key,bool down,bool enabled,Action<int> action) {
        if(key<0xAD || key>0xAF) return false;
        Held state;
        bool repeated=held.TryGetValue(key,out state);
        if(down) {
            if(!repeated) {state=new Held {Owned=enabled}; held[key]=state;}
            if(state.Owned && !state.Inert && enabled && (key!=0xAD || !repeated)) action(key);
        } else {if(!repeated) return false; held.Remove(key);}
        return state.Owned;
    }
}

internal sealed class GoXlrVolumeHook : IDisposable {
    delegate IntPtr HookProc(int code,IntPtr message,IntPtr data);
    [StructLayout(LayoutKind.Sequential)] struct KeyData {public uint Key,Scan,Flags,Time; public UIntPtr Extra;}
    [DllImport("user32.dll",SetLastError=true)] static extern IntPtr SetWindowsHookEx(int id,HookProc callback,IntPtr module,uint thread);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook,int code,IntPtr message,IntPtr data);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);
    readonly GoXlrAudio audio;
    readonly HookProc callback;
    readonly GoXlrKeyOwnership ownership=new GoXlrKeyOwnership();
    long keyRevision,keyResetRevision;
    IntPtr hook;
    public GoXlrVolumeHook(GoXlrAudio value) {
        audio=value; callback=Handle;
        hook=SetWindowsHookEx(13,callback,GetModuleHandle(null),0);
        if(hook==IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(),"Не удалось подключить клавиши громкости GoXLR.");
    }
    IntPtr Handle(int code,IntPtr message,IntPtr data) {
        if(code>=0) {
            int type=message.ToInt32();
            if(type==0x100 || type==0x104 || type==0x101 || type==0x105) {
                var key=(KeyData)Marshal.PtrToStructure(data,typeof(KeyData));
                if(key.Key>=0xAD && key.Key<=0xAF) {
                    bool enabled; long revision,reset;
                    audio.GetKeyState(out enabled,out revision,out reset);
                    if(reset!=keyResetRevision) ownership.Reset();
                    else if(revision!=keyRevision) ownership.Invalidate();
                    keyRevision=revision; keyResetRevision=reset;
                    if(ownership.Handle((int)key.Key,type==0x100 || type==0x104,enabled,delegate(int pressed){audio.VolumeKey(pressed,revision);})) return new IntPtr(1);
                }
            }
        }
        return CallNextHookEx(hook,code,message,data);
    }
    public void Dispose() {if(hook!=IntPtr.Zero) {UnhookWindowsHookEx(hook); hook=IntPtr.Zero;}}
}
