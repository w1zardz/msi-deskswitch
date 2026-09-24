using System;

// Only the dedicated PgDn key switches. Numpad 3 with NumLock off also reports VK_NEXT,
// but without LLKHF_EXTENDED, so RegisterHotKey cannot tell them apart.
internal sealed class PageDownKey {
    public const int VirtualKey = 0x22;
    public const uint Extended = 0x01;
    bool owned;
    // Returns true when the event must be swallowed; trigger fires on release so a held key
    // cannot bounce back on the other host.
    public bool Handle(int key, uint flags, bool down, bool modified, out bool trigger) {
        trigger = false;
        if (key != VirtualKey || (flags & Extended) == 0) return false;
        if (down) {
            if (!owned && modified) return false;
            owned = true;
            return true;
        }
        if (!owned) return false;
        owned = false;
        trigger = true;
        return true;
    }
    public void Reset() { owned = false; }
}
