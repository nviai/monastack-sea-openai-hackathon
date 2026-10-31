# Agent UI control

Text agents and verified voice speakers can invoke the requesting app's current
Flutter controls. This is an in-app capability layer, not macOS computer control.

## Try it

Open Chat with agents and ask:

- Open the task board.
- Open the task board, select Meslingo, and search for pronunciation.
- Open notifications.
- Open chat.
- Open the QA agent chat.
- Go to the Dev room.
- Open the task board and create a project named Demo review.

Voice supports the same control discovery through its operate_ui tool. Keep one
active app session for the speaker in the room; ambiguous sessions are rejected.

## Scope

Global navigation opens workspace screens. The bridge discovers enabled visible
buttons, labeled icons, text fields, dropdown options, switches, checkboxes, list
items, InkWell cards, and scroll views. Room navigation calls the same world movement
method as the user's UI. Controls are re-resolved immediately before invocation;
controls on background routes or stale screens cannot be invoked. Password fields
are excluded. Agent chat itself is excluded to prevent recursive prompt submission.

All data mutations still go through existing UI callbacks and backend permissions.
A callback invocation is not a confirmed server-side success. The agent receives
refreshed capabilities after each step and must not repeat ambiguous send/submit
operations. Voice delivery is bound to actor plus presence session, expires quickly,
and uses at-most-once delivery with an app acknowledgment. Lost delivery may require
manual inspection. No claim is made that every custom widget is supported.

Text control is limited to ten steps per request; voice delegation to twelve tool
iterations. Closing the originating chat or signing out stops its text workflow.
UI control labels are shared with the model for the user's request; password values
are not. Voice instructions prohibit reading private UI labels aloud in shared rooms.

## Limitations

Native file pickers, OS permissions, drag-and-drop, unlabeled custom canvas controls,
and arbitrary macOS applications are not automated. The user completes these native
steps. Each screen's ordinary confirmations and permission checks still apply.
Voice UI control requires the current live worker, app presence, and node connection.
The bridge does not independently verify every business transaction after a click.

Function calling uses the official Responses API tool format:
https://developers.openai.com/api/docs/guides/function-calling
