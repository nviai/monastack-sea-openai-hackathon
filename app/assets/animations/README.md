`agent-mouth.riv` comes from the Rive Flutter 0.14.11 example `lip-sync.riv` (Rive, MIT license; see RIVE-LICENSE.txt).

Only the isolated **Mouth** artboard and its `numViseme` input are instantiated. The prerecorded Lip-sync demo artboards and audio timelines are never played. Pose 0 is closed, 3 slightly open, 2 medium and 1 wide. The app drives these poses from LiveKit participant audio levels; this is amplitude-driven mouth articulation, not phoneme recognition.

The face is composited on the office agent's actual head using its existing skin/hair palette. The previous little-machine indicator has been removed.

Source: https://github.com/rive-app/rive-flutter/tree/master/example/assets
