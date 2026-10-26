# Misesca

Everything in its place. An iPhone app that projects an approved event layout onto the ballroom floor at 1:1 scale, guides the crew while they set, then scans the room and flags anything that doesn't match the plan.

## Run it

1. Open `Misesca.xcodeproj` in Xcode on a Mac.
2. Select the **Misesca** target, open **Signing & Capabilities**, choose your team, and change the bundle id (`com.misesca.app`) if Xcode asks for a unique one.
3. Pick a physical iPhone (iOS 17 or later) and run. AR and LiDAR do not work in the Simulator.

Room scanning (Mise Check) needs an iPhone Pro with LiDAR. Other iPhones fall back to checking tables one at a time.

## Layout

```
Misesca/                 App target (SwiftUI, ARKit, RealityKit, RoomPlan)
  App/                   Entry point
  Design/                Palette, type, buttons
  Data/                  EventStore (JSON in Application Support, on device only)
  Features/Events        Events list, import, settings
  Features/Plan          2D plan canvas, plan screen, counts
  Features/SetMode       AR session: alignment, ghosts, placing, check flow
  Features/MiseCheck     RoomPlan capture on the shared ARSession
  Features/Report        Report screen and PDF export
  Features/Onboarding    Three intro screens
  Resources/             Bundled sample layouts
MisescaKit/              Pure Swift logic, no UI: layout model and validation,
                         plan-to-world alignment, table matching, aisle clearance,
                         report wording. Unit tested.
Config/Info.plist
```

## Tests

The matching, alignment, aisle and wording logic lives in `MisescaKit` and runs on the Mac:

```
cd MisescaKit && swift test
```

If the project sits in an iCloud-synced folder (Desktop or Documents) and codesigning the test bundle fails with "resource fork, Finder information, or similar detritus", add `--scratch-path /tmp/misesca-kit-build`.

## Sample layouts

- **Harbor Room Gala**: 90 x 70 ft ballroom, 30 rounds of 8, stage, bar, dance floor, gift table, two aisles.
- **Demo Room Lunch**: 30 x 25 ft room with 7 tables, sized for a classroom or hackathon hall. A is the front wall center, B is the back door center. Edit `Misesca/Resources/demo-room.json` to match the real demo room before demo day.

## Layout file format

Feet, origin at the room's top-left corner in plan view, x to the right, y down the page, rotation in degrees. See the sample files. Optional fields beyond the original spec:

- `reference_points.A.name` / `B.name`: short landmark used in directions ("Table 14 is 3 ft toward the **stage**"). Defaults to the label up to its first comma.
- `aisles[].label`: name used in results ("**Center aisle** is 4 ft. Plan calls for 6 ft.").

Import a layout from the Events screen, or open a `.json` file with Misesca from Files or the share sheet.

## Importing a diagram image or PDF

Import also takes a PNG, JPG or PDF diagram, from Files or Photos, including a phone photo of a printout. Everything runs on the phone.

1. **Corners.** The room's corners are found automatically. Drag any that are off (a magnifier shows the spot); on release they snap onto the walls, or the page edges in a photo. Each side is measured along its length to a fraction of a pixel and fitted with a straight line.
2. **Size.** Either "round tables are 60 in" (or 66 / 72), which works on diagrams with no dimensions, or the room's width and depth, which is the most accurate.
3. **Reading.** The image is straightened (perspective corrected), tables are found from the enclosed shapes in the drawing, each edge is measured to a fraction of a pixel, and table numbers are read inside each table.
   - Shapes are searched at full size, at half size (broken or blurred outlines, big objects) and, for small images, at double size. Text is read across the page and again in overlapping pieces so small labels aren't lost.
   - In a grainy photo, faint lines are also found by their shape (brightness dips sharply across a line, but evenly in a speck of grain), and edges are measured on a lightly smoothed copy.
   - Tables can be round, oval, square or rectangular, at any proportion. Ovals import as oval tables (`oval_table` in layout files, with `length_ft` and `width_ft`). Text that says "table" on a shape makes it a table at any size or shape; "Table 12" gives table number 12. A label written across a table, which cuts its inside in two, is cleared away so the whole table is measured.
   - Unnamed shapes count as tables within wide size limits (rounds 2–10 ft, squares 2–12 ft, long tables up to 24 ft). Chairs hugging a table, an outline enclosing several tables, and squares under 2.75 ft with nothing written on them are left out.
   - Bars, stages and dance floors are found from their names on the diagram, whatever their shape. A floor of six or more matching tiles is a dance floor even unnamed, and its tiles aren't tables. Plans without one of these don't get one.
   - Names on the diagram with no outline found under them (for example "Table 7" or "Bar") are listed as a warning, to add at review.
4. **Review.** Tables are shown on the straightened diagram with the room size. Numbers that couldn't be read are gray with a "?". Tap to fix, add or remove.
5. **Line-up points and details**, then save as a normal layout.

### Measured accuracy

From `MisescaKit/Tests/MisescaKitTests/DiagramAccuracyTests.swift`. Known layouts are drawn in four styles (outlines, chairs around tables, filled tables, faint gray lines). Simulated phone photos add tilt, blur, sensor noise, uneven light and JPEG compression. Every table is compared with the truth.

| Input | Tables found | False tables | Center error (mean / worst) | Numbers read |
|---|---|---|---|---|
| Clean exports, all styles | 100% | 0 | ≤ 0.07 ft / ≤ 0.12 ft | 100% |
| Phone photos, outline and chair styles | 100% | 0 | ≤ 0.11 ft / ≤ 0.24 ft | 96–100% |
| Phone photos, faint gray lines | 94–100% | 0 | up to 0.38 ft / 0.70 ft | 90–100% |

- Faint-line photos are the hard case. The app shows a warning when the round tables measure inconsistently: it appeared on every faint-photo test whose mean error was over 0.2 ft, and never on a sharp image. It can't single out one stray table in an otherwise consistent image.
- Corners dragged up to 21 px off are pulled back to within 1 px.
- On real venue diagrams (Vail Recreation District sample layouts), the dance floor labeled 16' × 16' measures 16.0 × 16.0 ft with the scale taken from the 60" rounds.

### Limits

- Aisles aren't read from diagrams, so aisle widths aren't checked for those events.
- Decorative circles (plants) can be mistaken for rounds on plans with no tables. The room size shown at review, plus a warning when it's implausible, flags this.
- Architectural pieces drawn as filled rectangles or squares 2.75 ft and up (columns, wall stubs) can be read as tables. They're visible at review and can be removed.
- A small square (under 2.75 ft) whose label can't be read, such as a blurred "Table 10" in a photo, is left out rather than guessed. So is a square turned 45° with chairs touching it and a turned label.
- Aisle and Mise Check measurements treat an oval table as the rectangle around it, which errs toward a narrower aisle.
- Accuracy depends on the diagram being drawn to scale. A 60" round drawn at the wrong size makes everything off by the same proportion. Entering the room size avoids that.

`Misesca/Resources/harbor-diagram.png` is a sample diagram (also in Settings).
