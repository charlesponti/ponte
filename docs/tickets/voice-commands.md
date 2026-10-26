# Voice commands and snippets — full ticket

**Linear: WYA-218** · https://linear.app/wyattbose/issue/WYA-218

**Status: parked by Charles on 26 October 2026.** He is not comfortable with the idea yet and wants to revisit it.
This file exists so the thinking, the spec and the open decisions survive until then. GitHub #16 tracks the same
work; it stays open and unstarted.

No code has been written for this. Nothing in the app behaves differently because of this document.

---

## The problem

The engine gives you a transcript. Writing needs more than that: a paragraph break without reaching for the keyboard,
the ability to say "no, scratch that", and the same address pasted without dictating it a fifth time.

Every one of those is a rule applied to text we already have — the machinery `Vocabulary` already uses. It is the
cheapest feature in the backlog with the largest change to what the app feels like: something you write *with*,
rather than something that transcribes at you.

## The risk that decides everything

**False positives.** "New paragraph" is not a phrase anyone says by accident; "period" and "comma" are. A dictation
app that eats a word out of someone's sentence is worse than one with no commands at all. Three rules follow, and the
first two are enforced in code rather than by the default file:

1. A trigger is **at least two words**.
2. Matching is **whole-phrase and case-insensitive**, punctuation ignored.
3. A trigger is never a phrase people say in ordinary speech. This one cannot be enforced by code — only by what
   ships, and by saying so in the README.

## What it does

- **Commands** act on the transcript in place: insert a paragraph break, remove the last sentence.
- **Snippets** are spoken triggers that expand to text the user wrote down, with `{date}`, `{time}`, `{clipboard}`,
  `{name}` available inside the expansion.
- **One switch** turns both off. With it off, the transcript is exactly the engine's output.
- **The README lists every phrase.** Nothing fires that is not documented, and every firing is logged.

## Pipeline order (fixed, and documented)

Three transforms touch the text. The order is:

1. **Commands** match the raw engine text — they are instructions about what was said.
2. **Snippets** match what remains — a trigger is spoken text.
3. **`Vocabulary`** replacements apply last, to everything, including inserted boilerplate. Deliberate: if a snippet
   contains a word the user has taught Ponte to spell differently, they meant it everywhere.

A snippet's own text does not re-enter command matching: commands ran first, by design.

## Code shape

- `~/Library/Application Support/Ponte/phrases.json` — one file, two lists (see the decision below). Read with the
  same failure rule as vocabulary: **unreadable means no transforms, never a failed dictation**.
- `VoiceTransform` — pure: `(text, commands, snippets) -> (text, fired: [String])`. `fired` is what the log records.
- `TextPipeline.apply(to:)` — the only place the three stages are composed. Four call sites exist today
  (`AppDelegate.finish`, the live line, `HistoryModel`'s retake, `main.swift`'s `--transcribe`); if each composes the
  stages itself they will drift, which is exactly how Thames ended up with two recorders.
- Snippet matching reuses `Vocabulary`'s whole-word, longest-first matcher rather than growing a second one.

### `scratch that` needs a definition, not code

Delete from the last sentence-ending punctuation before the trigger to the end of the text; with no punctuation,
delete the whole take. It never reaches into a previous dictation — only the current transcript. This is a table of
cases in tests before it is a transform.

Corollaries worth writing as cases: several "scratch that" in a row; a trigger at the very start; a trigger after a
paragraph break; a take that is nothing but triggers.

## Command shortlist

Chosen to be small enough to test exhaustively and large enough to feel like a different app:

| say | get |
|---|---|
| "new paragraph" | `\n\n`, first letter after it capitalised |
| "scratch that" | delete the last sentence |
| "scratch that word" | delete the last word |
| "bullet list" | `- ` at the start, and a new one per item |
| "send it" | stop and paste now (take control, not a text transform) |

Snippets ship empty, with these variables available: `{date}`, `{time}`, `{clipboard}`, `{name}`.

### Deliberately out of the first version

- **Anything needing a language model** ("make that formal"). Parakeet is speech-only, a local LLM is a different
  product with a different cost, and it would break the site's "no network, ever" claim.
- **Single-word triggers**, whatever the file says.
- **Anything that touches another app** ("open Mail", "remind me"). The paste is one event at the end into whatever
  has focus; that is the whole safety story.
- **An escape hatch for saying a trigger literally.** Known limitation: dictate "he said new paragraph and laughed"
  and it fires. The off switch is the answer for now.

### Brainstormed, not scheduled

Text shaping ("next line", "numbered list", "open quotes"…"close quotes", "open bracket", "all caps", "no
punctuation"); more surgery ("scratch the paragraph", "start over", "cancel that"); snippet variables beyond the
four; "insert the clipboard" and "insert my last transcript".

## Six open decisions

1. **One file or two.** The issue originally said `commands.json` and `snippets.json`; one `phrases.json` with both
   lists is one button and one place for a user to look. Recommendation: one file.
2. **Punctuation the trigger carried.** The engine writes `one two three. New paragraph. four five`; deleting the
   phrase alone leaves `three. . four`. Recommendation: remove the trigger with its trailing punctuation and one space
   either side, insert `\n\n`, and capitalise the first letter after the break.
3. **Does the live line run the full pipeline?** Recommendation: yes, all three stages. Cost is nil, and it is the
   only way a live "scratch that" removes words instead of lying until the key is released.
4. **How "never a common word" is enforced.** "Two words minimum" can be code plus a test. "Not a common phrase"
   cannot, without inventing a dictionary. Recommendation: enforce the first in code, the second by what ships and by
   the README, and say so plainly rather than implying a guarantee.
5. **How the user sets this up.** Three options, and this is the one that decides whether it is a feature or a
   developer toy: **(A)** a "Phrases" row in the window with a count and an Edit button that opens the JSON — matches
   how Vocabulary works today; **(B)** a Phrases pane with add/edit/delete rows, which needs a design study and
   Charles's pick before code; **(C)** a teaching mode: say the trigger, then type or dictate the expansion.
   Recommendation: A ships with the feature, B follows as its own studied piece.
6. **Previewing a destructive command.** Should "scratch that" strike the sentence through in the HUD for a second
   before removing it? It converts an irreversible action into a seen one, at almost no cost.

## What must not break

- The paste remains a **single event at the end of the take**; no transform touches the target application.
- The note records the final text, so note and paste agree.
- With no commands and no snippets configured, behaviour is byte-identical to today.
- A malformed or missing file never costs anyone a dictation.

## How it would be verified

Table-driven tests: text with no triggers is untouched; "new paragraph" inserts exactly two newlines; "scratch that"
with and without preceding punctuation; each of the four "scratch that" corollaries; a snippet expands; a snippet
variable resolves; an unknown trigger is left alone; a malformed file yields no transforms; the switch off means raw
text; a single-word command is refused whatever the file says; and the ordering rule holds (a snippet containing a
vocabulary word gets replaced).

Manual: dictate "one two three. new paragraph four five" and check the live line *and* the pasted text; dictate
"scratch that" mid-take and confirm it leaves both.

## Why it was parked

Charles is not yet comfortable with the idea. The thing to settle before code is arguably not technical at all: whether
a dictation app should be interpreting instructions at all, or whether the paragraph break belongs somewhere else
(the HUD? a keyboard shortcut? a second key?). That question is worth answering before the first line of
`VoiceTransform`.
