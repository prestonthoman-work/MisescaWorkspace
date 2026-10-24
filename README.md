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

Import also takes a PNG, JPG or PDF diagram, from Files or Photos. On device, Misesca traces table outlines and reads the table numbers (Apple Vision), then the user:

1. Taps the room's top-left and bottom-right corners and enters the room width. Depth follows from the diagram's proportions.
2. Checks the tables found: tap one to fix its number, type or size, or tap an empty spot to add one.
3. Taps two line-up points (A and B) and names them.
4. Enters event details and saves. The result is an ordinary layout.

Works best on clean digital exports. Photos of paper taken at an angle aren't straightened, so expect to fix more by hand. Aisles aren't read from diagrams, so aisle widths aren't checked for those events. `Misesca/Resources/harbor-diagram.png` is a sample diagram (also in Settings) used by the tests.
