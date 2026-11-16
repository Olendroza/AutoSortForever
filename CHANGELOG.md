# Changelog

## 1.0.0

- Initial release.
- Sorts player bags about a second after any change (loot, selling, moving
  items, gear changes); bank-only updates are ignored.
- Waits while an interaction menu is open by default (merchant, mail, bank,
  auction house, etc.); opening only the bag window does not block sorting.
  `/asf menu on` allows sorting during menus.
- Sorts the bank right after the banker opens; can be toggled with
  `/asf bank on|off`.
- Postponed during combat and while holding an item on the cursor; guarded
  against sort loops. Refused sorts are retried briefly; temporary blockers
  wait without burning retries.
- Detects bags with the client's "Clean Up Bags" option turned off and reports
  them on login and in `/asf status`.
- Lua errors inside the addon are caught and reported once in chat (no spam).
- Commands: `/asf status`, `/asf on|off`, `/asf delay <seconds>`,
  `/asf menu on|off`, `/asf bank on|off` (`/autosort` alias).
- Author: Olendroza.
