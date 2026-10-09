# featime-geo

A small editor over a globe timeline and region timelines, written against
featime's public API only: the library's first real consumer. One command
script (`src/tour.txt`) drives live and pinned links, parameters, chapters,
labeled transactions, the history panel, background rebuilds, and save/load
of the whole world.

```sh
zig build run                  # the tour
zig build run -- my-script.txt # another script
zig build test                 # runs the tour in a temp dir and checks the result
```

Commands: `region new NAME`, `region NAME raise CELL AMOUNT | plant COUNT |
erode | param NAME VALUE | marker POS | chapter NAME | terraform | undo |
redo | history | show | status`, `globe sea METERS | occur REGION | pin
REGION [CHAPTER] | marker POS | rebuild bg|bg-stale | undo | redo | history
| show | status`, `show`, `status`, `save DIR`, `load DIR`.

## What building it taught

- **Links carry their weight.** The globe never calls `refresh`: a region
  edit, a region scrub, a parameter change and an undo all reach the live
  occurrence by themselves, and none of them touch the pinned one. A
  background rebuild is rejected when a region moves meanwhile, and the
  next `state()` recovers.
- **Save/load needs an app-level index.** Containers do not carry display
  names, so the world writes `world.txt` beside them. The globe's header
  manifest (`peekHeader`) tells which region ids it needs before it loads.
- **A mark cannot point at the very start.** `Mark{ .after = null }`
  means the tip, so a chapter or a pin before the first feature is not
  expressible; the editor refuses `chapter` at marker 0. Fixing it means
  a new mark shape on the wire and in containers (open in the roadmap).
- **Two small things the library gained**: `featureAt(idx)` (the editor
  needed the feature before the marker) and history units with a
  `subject` id, so the history panel can say which feature a step touched.
- **Domain modelling note.** An occurrence computed before a sea-level
  change keeps the flooding it computed then; features apply in order.
  Compute display-time derived values at display time instead.
