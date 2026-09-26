using System;

internal static class PageDownKeyTests {
    static int count;
    static void Check(bool condition, string message) { if (!condition) throw new Exception(message); count++; }
    static int Main() {
        try {
            var keys = new PageDownKey(); bool trigger;
            Check(!keys.Handle(0x22, 0, true, false, out trigger) && !trigger, "Numpad 3 (NumLock off) press was taken.");
            Check(!keys.Handle(0x22, 0, false, false, out trigger) && !trigger, "Numpad 3 (NumLock off) release switched.");
            Check(!keys.Handle(0x63, 0, true, false, out trigger) && !keys.Handle(0x63, 0, false, false, out trigger) && !trigger, "Numpad 3 (NumLock on) switched.");
            Check(keys.Handle(0x22, 1, true, false, out trigger) && !trigger, "Red PgDn press not captured or switched early.");
            Check(keys.Handle(0x22, 1, true, false, out trigger) && !trigger, "Held PgDn repeat switched.");
            Check(keys.Handle(0x22, 1, false, false, out trigger) && trigger, "Red PgDn release did not switch.");
            Check(!keys.Handle(0x22, 1, true, true, out trigger) && !keys.Handle(0x22, 1, false, true, out trigger) && !trigger, "Modified PgDn switched.");
            Check(!keys.Handle(0x22, 1, false, false, out trigger) && !trigger, "Unowned release switched.");
            keys.Handle(0x22, 1, true, false, out trigger);
            Check(keys.Handle(0x22, 1, true, true, out trigger) && !trigger, "Modifier change lost ownership of a held red key.");
            Check(!keys.Handle(0x22, 0, true, false, out trigger) && !trigger, "Numpad event was captured while red key was held.");
            Check(!keys.Handle(0x22, 0, false, false, out trigger) && !trigger, "Numpad release triggered the held red key.");
            Check(keys.Handle(0x22, 1, false, true, out trigger) && trigger, "Captured red key did not switch once on release after modifier change.");
            Check(!keys.Handle(0x22, 1, false, false, out trigger) && !trigger, "Duplicate release switched twice.");
            Check(!keys.Handle(0x41, 1, true, false, out trigger) && !trigger, "Ordinary letter was captured.");
            keys.Handle(0x22, 1, true, false, out trigger); keys.Reset();
            Check(!keys.Handle(0x22, 1, false, false, out trigger) && !trigger, "Reset kept a stale press.");
            Check(keys.Handle(0x22, 1, true, false, out trigger) && !trigger && keys.Handle(0x22, 1, false, false, out trigger) && trigger,
                "Fresh press stopped working after a lifecycle reset.");
            Console.WriteLine("PageDown tests passed: " + count);
            return 0;
        } catch (Exception error) { Console.Error.WriteLine("FAIL: " + error.Message); return 1; }
    }
}
