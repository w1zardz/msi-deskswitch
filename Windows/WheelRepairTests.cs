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
    sealed class Buttons {
        internal readonly Dictionary<byte,byte[]> states=new Dictionary<byte,byte[]> {
            {0x53,new byte[]{0,0x53,1,0,0x53,1}},
            {0x56,new byte[]{0,0x56,1,0,0x56,1}}
        };
        internal readonly List<byte> changed=new List<byte>();
        internal bool unavailable,noAck,ignoreWrite,changeMapping,changeHighFlags,wrongReadback;
        internal byte badCid,shortCid;
        internal byte[] Request(byte slot,byte feature,byte function,params byte[] p) {
            Check(slot==4,"Recovery must use the discovered slot, not hard-code slot 2.");
            if(feature==0) {
                Check(function==0 && p.Length==3 && p[0]==0x1B && p[1]==4 && p[2]==0,"Resolve the button feature through ROOT.");
                return unavailable?null:new byte[]{7};
            }
            Check(feature==7 && p.Length>=2 && p[0]==0 && states.ContainsKey(p[1]),"Never address other features or controls.");
            byte cid=p[1];
            if(function==2) {
                if(cid==shortCid) return new byte[2];
                var reply=(byte[])states[cid].Clone();
                if(cid==badCid || (wrongReadback && changed.Count>0)) reply[1]=0x52;
                return reply;
            }
            Check(function==3 && p.Length==5 && p[2]==2 && p[3]==0 && p[4]==0,"Write only the temporary DIVERTED valid bit, without remapping.");
            changed.Add(cid);
            if(noAck) return null;
            if(!ignoreWrite) states[cid][2]&=0xFE;
            if(changeMapping) states[cid][4]=0x52;
            if(changeHighFlags) states[cid][5]^=2;
            return new byte[16];
        }
        internal MouseRepairResult Run(bool repair) {return MouseButtonRepair.Run(Request,4,repair);}
    }
    static void TestButtons() {
        var both=new Buttons();
        Check(both.Run(true).Complete && both.changed.Count==2,"Restore both diverted side buttons.");
        Check(both.states[0x53][2]==0 && both.states[0x56][2]==0,"Readback must confirm both diversion bits were cleared.");
        int writes=both.changed.Count;
        Check(both.Run(true).Complete && both.changed.Count==writes,"Healthy buttons must not be written again.");

        var single=new Buttons();single.states[0x53][2]=0;
        Check(single.Run(true).Complete && single.changed.Count==1 && single.changed[0]==0x56,"Only change a diverted control.");
        var preserve=new Buttons();preserve.states[0x53]=new byte[]{0,0x53,0xB1,0x12,0x34,0xA5};
        Check(preserve.Run(true).Complete && preserve.states[0x53][2]==0xB0
            && preserve.states[0x53][3]==0x12 && preserve.states[0x53][4]==0x34 && preserve.states[0x53][5]==0xA5,"Preserve every unrelated flag and the existing remap.");

        var status=new Buttons();
        Check(status.Run(false).Complete && status.changed.Count==0 && status.states[0x53][2]==1,"Status is read-only even when buttons are diverted.");
        var unavailable=new Buttons {unavailable=true};
        Check(!unavailable.Run(true).Complete && unavailable.changed.Count==0,"A missing button feature must not stop retries as healthy.");
        var wrong=new Buttons {badCid=0x56};
        Check(!wrong.Run(true).Complete && wrong.changed.Count==0,"Read and validate both originals before any mutation.");
        var malformed=new Buttons {shortCid=0x53};
        Check(!malformed.Run(true).Complete && malformed.changed.Count==0,"Reject truncated original state without writing.");
        var noAck=new Buttons {noAck=true};
        MouseRepairResult failure=noAck.Run(true);
        Check(!failure.Complete && failure.Message.Contains("Back=00-53-01-00-53-01") && failure.Message.Contains("Forward=00-56-01-00-56-01"),"Keep original states when a write fails and allow retry.");
        var unchanged=new Buttons {ignoreWrite=true};
        Check(!unchanged.Run(true).Complete,"An acknowledged write is insufficient without verified clearance.");
        var remapped=new Buttons {changeMapping=true};
        Check(!remapped.Run(true).Complete,"Detect an unexpected mapping change.");
        var changedFlags=new Buttons {changeHighFlags=true};
        Check(!changedFlags.Run(true).Complete,"Detect unexpected changes in the high flag byte.");
        var foreign=new Buttons {wrongReadback=true};
        Check(!foreign.Run(true).Complete,"Reject readback for a different control.");
    }
    sealed class Thumb {
        internal byte[] state={1,0,0};
        internal int writes;
        internal bool unavailable,unreadable,noAck,ignoreWrite,flipInvert;
        internal byte[] Request(byte slot,byte feature,byte function,params byte[] p) {
            Check(slot==4,"Thumb wheel recovery must use the discovered slot.");
            if(feature==0) {
                Check(function==0 && p.Length==3 && p[0]==0x21 && p[1]==0x50 && p[2]==0,"Resolve the thumb wheel feature through ROOT.");
                return unavailable?null:new byte[]{9};
            }
            Check(feature==9,"Never address other features.");
            if(function==1) {Check(p.Length==0,"Thumb wheel status takes no parameters.");return unreadable?null:(byte[])state.Clone();}
            Check(function==2 && p.Length==2,"Write only the thumb wheel reporting mode and direction.");
            writes++;
            if(noAck) return null;
            if(!ignoreWrite) {state[0]=p[0];state[1]=p[1];}
            if(flipInvert) state[1]^=1;
            return new byte[16];
        }
        internal MouseRepairResult Run(bool repair) {return ThumbWheelRepair.Run(Request,4,repair);}
    }
    static void TestThumbWheel() {
        var diverted=new Thumb();
        Check(diverted.Run(true).Complete && diverted.writes==1 && diverted.state[0]==0,"Return a diverted thumb wheel to native horizontal scrolling.");
        Check(diverted.Run(true).Complete && diverted.writes==1,"A native thumb wheel must not be written again.");
        var inverted=new Thumb();inverted.state[1]=1;
        Check(inverted.Run(true).Complete && inverted.state[0]==0 && inverted.state[1]==1,"Preserve the current thumb wheel direction.");
        var status=new Thumb();
        MouseRepairResult read=status.Run(false);
        Check(read.Complete && status.writes==0 && status.state[0]==1 && read.Message.Contains("DIVERTED"),"Status is read-only and reports thumb wheel diversion.");
        var unavailable=new Thumb {unavailable=true};
        Check(!unavailable.Run(true).Complete && unavailable.writes==0,"A missing thumb wheel feature must not stop retries as healthy.");
        var unreadable=new Thumb {unreadable=true};
        Check(!unreadable.Run(true).Complete && unreadable.writes==0,"Never write without a valid original thumb wheel state.");
        var noAck=new Thumb {noAck=true};
        MouseRepairResult failure=noAck.Run(true);
        Check(!failure.Complete && failure.Message.Contains("Original: 01-00"),"Keep the original thumb wheel state when a write fails.");
        var unchanged=new Thumb {ignoreWrite=true};
        Check(!unchanged.Run(true).Complete,"An acknowledged write is insufficient without verified native mode.");
        var flipped=new Thumb {flipInvert=true};
        Check(!flipped.Run(true).Complete,"Detect an unexpected thumb wheel direction change.");
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
        TestButtons();
        TestThumbWheel();
        Console.WriteLine("Mouse protocol, thumb wheel and button recovery checks passed: "+checks);
    }
}
