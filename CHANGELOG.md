# Arc Weave changelog

## 1.0.0

First public release, for WoW Forever.

### New Features
- **Ticks on the swing timer** - Your next-melee abilities (Raptor Strike, Heroic Strike, Maul, Cleave) are drawn on Blizzard's swing bar, so you can see when each comes back and on which swing it lands. Gold means it is back during this swing, amber +N means N swings out, green means ready, blue means queued, red means further out.
- **Off-hand lane** - The same ticks on the off-hand swing bar when you dual-wield, with their own sizing.
- **Tracked abilities** - Add any spell by name or ID. A name follows the rank you know automatically.
- **Queue a next-attack ability** - Pick the ability to queue, then pick which of your abilities arm it. Pressing Mongoose Bite or dropping a trap also queues Raptor Strike for your next swing, and it stays queued even when you spam the button.
- **Pet attack from your own buttons** - Pick the abilities that should also send your pet at your target. Works on their keybinds and on mouse clicks, and the ability itself still casts normally. Keybinds go back to normal in vehicles and pet battles.
- **Picks follow the ability** - Move a picked ability to another button and it keeps working. Put the same ability on two bars and both copies work.
- **Corner markers** - Small icons on picked buttons show what each one does: the pet icon for buttons that send your pet, the queued ability's icon for buttons that queue it.
- **One options window** - Next Melee Weave and Pet Weave each have their own tabs. The window sizes itself to your screen, with a Panel size slider on the Addon tab.

### Good to know
- Needs Blizzard's swing timer turned on for the tick display.
- WoW Forever currently has a Blizzard-side bug where addon settings may not load after launching the game. It affects every addon and Arc Weave cannot work around it. Settings work within a session.
