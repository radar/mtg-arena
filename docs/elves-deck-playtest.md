# Elves deck: playtest findings

The second deck, `config/decks/elves.txt` (100 cards, all implemented in the mtg gem), is played with
`/games/<id>?deck=elves` or `DECK=elves bin/rails runner script/simulate.rb <seed>`. The first player to open a game
chooses its deck; both players share it. `Deck` now reads hyphenated names (`Gilt-Leaf`, `Poison-Tip`), which hid six of
the cards.

Method: seeded bot games (`DECK=elves`), `script/audit_stats.rb` and `script/audit_castable.rb` with that deck, and a read
of every one of the 76 new cards against its Oracle text. Each engine bug was reproduced before it was fixed.

**Status: everything below is fixed.** The elves deck and the Enchantress deck both play seeded games to a winner; the
arena suite plays three of each (`TableTest`), and `PromptsTest` covers the new prompts.

## Engine bugs (mtg gem), all fixed, each with a spec

| # | Card | Bug | Fix |
|---|------|-----|-----|
| E1 | Wellwisher | No mana cost, so it was free. | Cost {1}{G}. |
| E2 | Augur of Autumn | Printed as 3/3 (Oracle: 2/3). | 2/3. |
| E3 | Augur of Autumn | An extra land drop that belongs to Oracle of Mul Daya. | Removed. |
| E4 | Lathril | Triggered on any creature's combat damage to a player. | Only its own damage counts. |
| E5 | Serpent's Soul-Jar | Crashed when an Elf token died. | Tokens are skipped (they cease to exist). |
| E6 | Rhys the Exiled | `Costs::Parser` had no "Sacrifice an Elf": a crash as soon as its costs were read. | The parser reads "Sacrifice a/an <Type>". |
| E7 | Pact of the Serpent | "Choose a creature type" was never asked; X was always 0. | Asks as it resolves (`TypeChoice`). |
| E8 | Plaza of Heroes | The "legendary spells only" mana had no restriction. | `ManaRestriction::LegendarySpell`. |
| E9 | Serpent's Soul-Jar | The 2 life was lost on resolution. | A cost: `{T}, Pay 2 life`. |
| E10 | Thrive | Nothing made the number of targets equal X, or different. | `number_of_targets(x)`, `distinct_targets?`. |
| E11 | Path of Ancestry | Scry rider not modelled. | The mana carries a restriction that is told what it was spent on (`spent_on`). |
| E12 | Harvest Season | Asked for a search of zero lands. | Asks nothing when X is 0. |

Found while fixing the arena gaps:

- Lathril's "tap ten Elves" could include Lathril himself (already tapped for {T}).
- A creature sacrificed as a cost whose death set off a trigger made the spell illegal at sorcery speed ("the stack is not
  empty"): triggers from paying costs no longer count (`Cast#sorcery_speed_reason`).
- `Costs::MultiTap` held a block, so a game with a tap-N-creatures ability on the stack could not be copied with `Marshal`.

## Arena gaps, all closed

| # | Gap | How |
|---|-----|-----|
| A1 | A choice with two answers (`land:`, `elf:`) was "unsupported". | One question per keyword that has a `<keyword>_choices` list, with partial answers kept on the table. |
| A2 | X spells could not be paid. | `XPrompt`, `Table#payment_with_x`, X targets as X identical slots. |
| A3 | Mode choices without labels. | Skemfar Shadowsage and Cultivator of Blades define `modes`. |
| A4 | "You may pay {G}" / "{X}{X}" choices. | `payment_cost` on the choice; the table taps lands and pays; a May that can't be paid is skipped; X asks for a number. Numa's counters are divided like combat damage. |
| A5 | Additional costs that sacrifice. | `SacrificeCostPrompt`; the land is sacrificed after tapping, so Harrow can tap it first. |
| A6 | A search pick had no limit in the prompt. | `upto` is used. |
| A7 | Kicker was never offered. | `KickerPrompt` for mana kickers; sacrifice kickers go through the bargain prompt. |
| A8 | Tap-other-creatures costs were not offered. | `Costs::MultiTap` is a pick cost. |
| A9 | Graveyard abilities were not offered. | The graveyard viewer shows a button per ability; `Card#graveyard_abilities`. |
| A10 | Choices naming a creature type or a colour. | Options built from the types in play; a colour choice offers only the colours it allows. |

Also: the bot no longer picks a card when the view says `max: 0`, and takes fewer cards when a card refuses its first pick
(Myriad Landscape's two lands must share a type).

## Left as is

- Path of Ancestry's scry applies to any spell the restricted mana is spent on, and that mana is spent first, so it can
  be used up on a spell that does not share a type with the commander.
- `audit_stats` on the Enchantress deck prints `Heliod, God of the Sun: P/T /, oracle 5/6`. Heliod is not a creature while
  devotion to white is under five, so it has no power or toughness.
