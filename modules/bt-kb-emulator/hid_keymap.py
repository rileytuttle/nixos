"""
X11/Tk keysym name -> USB HID Usage ID (Keyboard/Keypad page, 0x07).

Two separate tables, used differently by keygrab.py:

- KEYMAP: physical key -> usage code. Keysyms that differ only because
  Shift was held (e.g. 'a' vs 'A', '1' vs 'exclam') map to the SAME usage
  code, because HID reports the physical key plus a separate modifier bit
  -- the receiving phone applies its own shift logic. We do NOT infer the
  modifier state from these names.

- MODIFIER_MASK: modifier keysym name -> bit in the HID report's modifier
  byte. These are tracked as a held/released set from their own
  KeyPress/KeyRelease events (NOT read from Tk's event.state bitmask,
  which is layout/WM dependent and unreliable across systems).
"""

# Modifier byte bits (first byte of the 8-byte boot keyboard report).
MOD_LEFT_CTRL = 0x01
MOD_LEFT_SHIFT = 0x02
MOD_LEFT_ALT = 0x04
MOD_LEFT_GUI = 0x08
MOD_RIGHT_CTRL = 0x10
MOD_RIGHT_SHIFT = 0x20
MOD_RIGHT_ALT = 0x40
MOD_RIGHT_GUI = 0x80

MODIFIER_MASK = {
    "Control_L": MOD_LEFT_CTRL,
    "Control_R": MOD_RIGHT_CTRL,
    "Shift_L": MOD_LEFT_SHIFT,
    "Shift_R": MOD_RIGHT_SHIFT,
    "Alt_L": MOD_LEFT_ALT,
    "Alt_R": MOD_RIGHT_ALT,
    "ISO_Level3_Shift": MOD_RIGHT_ALT,  # AltGr on most layouts
    "Super_L": MOD_LEFT_GUI,
    "Super_R": MOD_RIGHT_GUI,
    "Meta_L": MOD_LEFT_GUI,
    "Meta_R": MOD_RIGHT_GUI,
}

# Letters a-z -> 0x04-0x1D. Same usage whether shifted (capital) or not,
# since Tk gives us e.g. keysym 'A' for Shift+a -- lowercase it first.
_LETTERS = {chr(ord("a") + i): 0x04 + i for i in range(26)}

# Digits row, unshifted names '1'-'0' and their shifted symbol names,
# both pointing at the same physical-key usage code.
_DIGITS = {
    "1": 0x1E, "exclam": 0x1E,
    "2": 0x1F, "at": 0x1F,
    "3": 0x20, "numbersign": 0x20,
    "4": 0x21, "dollar": 0x21,
    "5": 0x22, "percent": 0x22,
    "6": 0x23, "asciicircum": 0x23,
    "7": 0x24, "ampersand": 0x24,
    "8": 0x25, "asterisk": 0x25,
    "9": 0x26, "parenleft": 0x26,
    "0": 0x27, "parenright": 0x27,
}

_PUNCT = {
    "Return": 0x28, "KP_Enter": 0x28,
    "Escape": 0x29,
    "BackSpace": 0x2A,
    "Tab": 0x2B,
    "space": 0x2C,
    "minus": 0x2D, "underscore": 0x2D,
    "equal": 0x2E, "plus": 0x2E,
    "bracketleft": 0x2F, "braceleft": 0x2F,
    "bracketright": 0x30, "braceright": 0x30,
    "backslash": 0x31, "bar": 0x31,
    "semicolon": 0x33, "colon": 0x33,
    "apostrophe": 0x34, "quotedbl": 0x34,
    "grave": 0x35, "asciitilde": 0x35,
    "comma": 0x36, "less": 0x36,
    "period": 0x37, "greater": 0x37,
    "slash": 0x38, "question": 0x38,
}

_FUNCTION = {f"F{i}": 0x3A + (i - 1) for i in range(1, 13)}  # F1-F12

_NAV = {
    "Caps_Lock": 0x39,
    "Print": 0x46,
    "Scroll_Lock": 0x47,
    "Pause": 0x48,
    "Insert": 0x49,
    "Home": 0x4A,
    "Page_Up": 0x4B,
    "Delete": 0x4C,
    "End": 0x4D,
    "Page_Down": 0x4E,
    "Right": 0x4F,
    "Left": 0x50,
    "Down": 0x51,
    "Up": 0x52,
}

KEYMAP = {}
KEYMAP.update(_LETTERS)
KEYMAP.update(_DIGITS)
KEYMAP.update(_PUNCT)
KEYMAP.update(_FUNCTION)
KEYMAP.update(_NAV)


def usage_for_keysym(keysym: str):
    """Return the HID usage code for a Tk keysym, or None if unmapped."""
    return KEYMAP.get(keysym) or KEYMAP.get(keysym.lower())


# ASCII character -> physical key, for the non-interactive sender (see
# btkb_send.py). keygrab.py does NOT use this: it gets a keysym per physical
# key from X11 and must not infer the modifier from the character, whereas
# here we start from the character and have to synthesize the Shift.
_SHIFTED_CHARS = {
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5",
    "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
    "_": "minus", "+": "equal", "{": "bracketleft", "}": "bracketright",
    "|": "backslash", ":": "semicolon", '"': "apostrophe",
    "~": "grave", "<": "comma", ">": "period", "?": "slash",
}

_LITERAL_CHARS = {
    "-": "minus", "=": "equal", "[": "bracketleft", "]": "bracketright",
    "\\": "backslash", ";": "semicolon", "'": "apostrophe", "`": "grave",
    ",": "comma", ".": "period", "/": "slash",
    " ": "space", "\n": "Return", "\t": "Tab",
}


def usage_for_char(ch: str):
    """(usage_code, needs_shift) for one ASCII character, or None if unmapped."""
    if ch in _SHIFTED_CHARS:
        return KEYMAP[_SHIFTED_CHARS[ch]], True
    if ch in _LITERAL_CHARS:
        return KEYMAP[_LITERAL_CHARS[ch]], False
    # .isupper() is true for plenty of characters this US-layout keymap has
    # no key for ("E" is fine, "É" is not), so look the lowercase form up
    # rather than indexing and trusting it to be there.
    if ch.isupper():
        usage = KEYMAP.get(ch.lower())
        return (usage, True) if usage is not None else None
    usage = KEYMAP.get(ch)
    return (usage, False) if usage is not None else None
