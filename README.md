# Auto Sort Forever

Automatic bag sorting for **World of Warcraft: Forever**.

Your bags are sorted about a second after anything changes in them - looting,
selling, moving items around, equipping gear. By default the sort waits while an
interaction menu is open (merchant, mail, bank, etc.), but it still runs while
only the bag window is open; the bank is sorted when the banker opens.

## Commands

| Command | Description |
| --- | --- |
| `/asf` or `/asf status` | Show the current settings |
| `/asf on\|off` | Enable or disable the addon |
| `/asf delay <seconds>` | Delay before sorting (0.2 - 10, default `1.0`) |
| `/asf menu on\|off` | Sort while a menu is open (default off) |
| `/asf bank on\|off` | Sort the bank when the banker opens (default on) |

`/autosort` works as an alias of `/asf`.

## Features

- **Sorts after any bag change** - about a second after you gain, lose or move
  items: loot, purchases, sales, crafting, mail, manual rearranging.
- **Sorts after gear changes** - swapping to a two-handed weapon moves your
  off-hand item into the bags and triggers a sort, even when the total item
  count stays the same.
- **Waits while a menu is open** - by default the sort is postponed while a
  merchant, mailbox, bank, auction house, character or another interaction window
  is open, and runs when it closes. Opening only the bag window does not block
  sorting. Use `/asf menu on` to sort even while such a menu is open.
- **Bank sorted on open** - the bank is sorted right after the banker window
  opens, which is when the client's bank sort works. Can be disabled.
- **Only your own bag changes trigger the bag sort** - bank slot updates are
  ignored, so banking never re-sorts your bags.
- **Combat safe** - a sort due during combat is postponed until combat ends.
- **Cursor safe** - sorting is postponed while you hold an item on the cursor.
- **Checked result** - a sort the client refuses is retried a moment later
  instead of being dropped. Waiting out a blocker (cursor, menu, combat)
  does not use up those retries, so full bags do not stop the sorting.
- **Client sort filter check** - if the client's own "Clean Up Bags"
  option is off for a bag or the backpack, the client skips those slots.
  The addon reports it on login and in `/asf status`.
- **No loops** - bag updates caused by the addon's own sort are ignored for a
  moment, so sorting never triggers another sort.
- **Errors in chat, without spam** - if something inside the addon throws a
  Lua error, it is caught, the addon keeps running, and the message is
  printed once. Repeated identical errors stay quiet, and at most five
  different errors are shown per session.

## Installation

1. Download the latest release.
2. Extract the `AutoSortForever` folder into:
   `World of Warcraft/_forever_/Interface/AddOns/`
3. Restart the game or type `/reload`.
4. If the client marks the addon as out of date, enable
   **Load out of date AddOns** on the character select screen.

## Compatibility

- World of Warcraft: Forever 1.60.1 (Interface `16001`)
- Uses the native `C_Container.SortBags()` and `C_Container.SortBankBags()` API.

## Notes

- Settings are stored in the `AutoSortForeverDB` saved variable.
- The addon has no UI; everything is controlled with the slash commands above.
