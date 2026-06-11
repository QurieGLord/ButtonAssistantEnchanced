# Changelog

## [1.1] - 2026-06-11

This release focuses on making cooldown awareness feel steadier across the main recommendation button and Avada Tracker.

### Highlights

- Improved cooldown display for charge-based abilities, including stack counts and recharge feedback.
- Refined partial recharge states so available charges stay ready while the next stack continues to recharge.
- Fixed charge recharge tracking so the global cooldown is not treated as a restored stack.
- Added separate GCD-finished effect controls for a lighter ready cue after the global cooldown ends.
- Improved Avada Tracker cooldown handling in combat for regular and charge-based spells.
- Added cooldown-ready visual feedback options for Avada Tracker icons.
- Kept next-ready and cooldown-ready effects separate from persistent proc glow styles.
- Added a Classic Blizzard Dark border style for the main button and Avada Tracker.
- Refined idle visual behavior to reduce unwanted flicker when no cooldown is active.
- Corrected the project name spelling to **Button Assistant Enhanced** across addon metadata, docs, and release packaging.
- Updated the release workflow so compact version tags like `v1.1` publish normally.

## [1.0.1] - 2026-06-04

A smoother layout and feedback pass for players who like their UI to stay where they put it.

### Highlights

- Reworked the bounce animation so it feels cleaner and stays centered on the icon.
- Kept Avada Tracker icons steady while the main recommendation button plays its visual feedback.
- Added an in-game layout editor with a grid, optional snap, drag handles, and right-click layout controls.
- Added precise placement controls for the main button and Avada Tracker.
- Added separate scale, row, and column controls for cleaner Avada Tracker setups.
- Added optional Avada Tracker cooldown text with its own font settings.
- Improved Avada Tracker cooldown handling in combat and reduced GCD-like flicker when no tracked cooldown is running.
- Added a quick exit button while layout edit mode is active.
- Refreshed README notes for the new layout workflow.

## [1.0.0] - 2026-06-04

Initial public release of **Button Assistant Enhanced**.

### Highlights

- Added a polished recommendation button for Blizzard Assisted Combat.
- Added readable cooldown sweeps and countdown text for global cooldowns and real spell cooldowns.
- Added combat-safe cooldown display behavior for modern Retail clients.
- Added optional keybind text pulled from the player's action bars, with configurable font style and size.
- Added range and usability feedback so unavailable recommendations are easier to read at a glance.
- Added proc, next-ready, and cooldown-ready visual feedback with configurable styles.
- Added Avada Tracker support for compact secondary cooldown awareness.
- Added customization for button size, scale, opacity, borders, cooldown text, sweep visuals, effects, and tracker layout.
- Added branded addon icon, in-game addon metadata, README presentation, changelog, and release packaging.
- Added a GitHub Actions release workflow for building and publishing the addon zip.

### Notes

Button Assistant Enhanced is designed for modern World of Warcraft Retail and Blizzard's Assisted Combat feature.
