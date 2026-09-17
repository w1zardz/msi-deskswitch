using System;
using System.Collections.Generic;

internal static class WheelRepairTests {
    static int checks;
    static void Check(bool ok,string message) {checks++;if(!ok)throw new Exception(message);}
    sealed class Fixture {
        internal long time;
        internal byte[] sent;
        internal int writes,reads;
        internal bool writable=true;
        internal Func<uint,byte[]> receive;
        internal WheelProtocol protocol;
        internal Fixture() {
            protocol=new WheelProtocol(delegate(byte[] p) {writes++;sent=p;return writable;},
                delegate(uint timeout) {reads++;return receive==null?null:receive(timeout);},delegate {return time;});
        }
        internal byte[] Reply(byte value) {var p=(byte[])sent.Clone();p[4]=value;return p;}
    }
    static void Main() {
        var delayed=new Fixture();
        delayed.receive=delegate(uint timeout) {
            if(timeout<900) {delayed.time+=timeout;return null;}
            delayed.time+=900;return delayed.Reply(15);
        };
        Check(delayed.protocol.Request(2,0,0,0x21,0x21,0)[0]==15,"A Bolt reply delayed by 900 ms must be accepted.");
        Check(delayed.writes==1,"Waiting for a reply must not retransmit.");

        var stale=new Fixture();
        Check(stale.protocol.Request(2,0,0,0x21,0x21,0)==null,"First request times out.");
        byte[] old=stale.Reply(15);
        stale.receive=delegate(uint timeout) {stale.time+=10;return stale.reads==2?old:stale.Reply(3);};
        Check(stale.protocol.Request(2,0,0,0,5,0)[0]==3,"Late ROOT reply must not become the name-feature index.");
        Check(stale.reads==3,"The stale reply must be skipped before accepting the current reply.");

        var noise=new Fixture();
        noise.receive=delegate(uint timeout) {
            noise.time+=5;var p=noise.Reply(9);
            if(noise.reads==1)p[1]=3;
            if(noise.reads==2)p[3]=0;
            return p;
        };
        Check(noise.protocol.Request(2,0,0)[0]==9 && noise.reads==3,"Other devices and unsolicited notifications must be ignored.");

        var bounded=new Fixture();
        bounded.receive=delegate(uint timeout) {
            Check(timeout<=WheelProtocol.ReplyTimeoutMilliseconds,"Read must respect the remaining deadline.");
            bounded.time+=Math.Min(timeout,100);var p=bounded.Reply(0);p[3]=0;return p;
        };
        Check(bounded.protocol.Request(2,0,0)==null,"Notifications must not extend the deadline.");
        Check(bounded.time==WheelProtocol.ReplyTimeoutMilliseconds && bounded.writes==1,"Recovery must stay bounded without repeated writes.");

        var error=new Fixture();
        error.receive=delegate(uint timeout) {return new byte[]{0x10,2,0x8F,error.sent[2],error.sent[3],9,0};};
        Check(error.protocol.Request(2,0,0)==null && error.reads==1,"A matching receiver error must finish the request.");
        var fail=new Fixture {writable=false};
        Check(fail.protocol.Request(2,0,0)==null && fail.reads==0,"Do not wait after a failed write.");

        var ids=new Fixture();ids.receive=delegate(uint timeout) {return ids.Reply(0);};
        var used=new HashSet<int>();
        for(int i=0;i<15;i++) {ids.protocol.Request(2,0,0);used.Add(ids.sent[3]&15);}
        Check(used.Count==15 && !used.Contains(0),"Use all nonzero software IDs before wrapping.");
        ids.protocol.Request(2,0,0);Check((ids.sent[3]&15)==12,"Software IDs must wrap to a valid value.");
        int writes=ids.writes;
        try {ids.protocol.Request(2,0,16);throw new Exception("Invalid function accepted.");} catch(ArgumentException) { }
        try {ids.protocol.Request(2,0,0,new byte[17]);throw new Exception("Oversized packet accepted.");} catch(ArgumentException) { }
        Check(ids.writes==writes,"Reject malformed requests before touching USB.");
        Console.WriteLine("Wheel protocol checks passed: "+checks);
    }
}
