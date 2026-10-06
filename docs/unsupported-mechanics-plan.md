# Unsupported mechanics: audit and plan

Audit of the shared deck (`config/decks/enchantress.txt`, 95 cards, all implemented in the mtg gem) against what the arena
UI can play. Re-run it with:

- `bin/rails runner script/audit_deck.rb`: static facts per card (abilities, costs, choices).
- `bin/rails runner script/audit_castable.rb`: can each spell be cast with plenty of mana? Silent when all can.
- `bin/rails runner script/audit_stats.rb`: name, mana cost, power/toughness and loyalty against the Oracle data in
  `../mtg/data`. Silent when everything matches.

The scripts build a sandbox game through `Table`, so they report what a player would actually be offered.

Arena loads the gem from `../mtg` (see `Gemfile`). It used to point at `~/code/mtg`, a separate copy that lacked 12 of the
deck's cards, so the first audit wrongly reported them as unimplemented.

## What was not handled, and what happened to it

### Cards that could not be played

| # | Mechanic | Cards | Outcome |
|---|----------|-------|---------|
| 1 | Targeted spells (auras) | All That Glitters, Ethereal Armor, Ghoulish Impetus, Kenrith's Transformation | Done (step 2). `SpellTargetPrompt`. |
| 2 | Planeswalkers | Calix, Destiny's Hand | Done (step 4). Loyalty abilities, loyalty chip, attacking planeswalkers, two-target abilities (`ActivationPrompt` asks one target at a time). |
| 3 | Activation costs beyond tap / sacrifice / exile this + mana | Bolas's Citadel, Demon of Fate's Design, Nyxborn Behemoth, Khalni Heart Expedition, Indatha Triome | Done (steps 1 and 3). `CostPrompt` for sacrifice and discard; cycling is a real action (`Table#cycle`). |
| 4 | Targeted abilities | Destiny Spinner, Nyx Weaver, Swiftfoot Boots | Done. `ActivationPrompt`. |
| 5 | Playing from exile | Cunning Rhetoric | Done (step 6). Shared exile pile; cards castable from exile are clickable. |
| 6 | Instant speed and responses | Arachnogenesis | Done in part (step 5), see below. |

### Choices that went wrong

Both fixed in step 1: colour choices have an options prompt, and each choice goes to the player who makes it.

### Game flow

Done in step 8:

9. Mulligans (London): each player in turn keeps or mulligans, then puts that many cards on the bottom (`MulliganPrompt`).
   The game starts once both have kept.
10. Concede: a button in the top banner, `Table#concede`.
11. Several blockers on one attacker already worked. New: the attacker's controller orders them, one question at a time
    (`BlockerOrderPrompt`), then divides the damage with number inputs (`DamagePrompt`; lethal to each blocker before
    the next, and a trampler may send the rest at the player). The engine validates the division.

## Instant speed (step 5): what exists

The non-active player gets priority, and a Pass button, only when they could do something (a castable spell or an
activatable ability), and only:

- after a spell or ability goes on the stack (`Table#settle!` stops before each item resolves);
- at declare blockers, even with no creature able to block, when attackers were declared;
- at the end step, after the active player passes it, so the opponent can act before the turn is over.

The bot responds with a castable spell when it has one, and passes otherwise.

Not done: windows in other steps with an empty stack, responding to the opponent's land play, and priority passing for the
active player after a spell resolves.

## Engine audit (step 7): what was fixed

Every card was compared with its Oracle text. Fixed in the mtg gem (each has a spec):

- Wrong stats or costs: Anikthea (4/4), Composer of Spring (1/3, and "six or more" enchantments), Nessian Wanderer (1/3),
  Eternal Witness, Jukai Naturalist, Verduran Enchantress, Font of Fertility's ability cost, Daxos's name.
- Auras: All That Glitters and Ethereal Armor can enchant any creature, not only yours.
- Demon of Fate's Design: pay life for an enchantment once per turn (`Cast` takes `pay_life: true`); sacrifice another
  enchantment for +X/+0.
- Nyxborn Behemoth: sacrifices another enchantment. Nyx Weaver: exiling itself is a cost.
- Cunning Rhetoric: only its controller may cast the exiled card.
- Starfield of Nyx: base power and toughness equal to each permanent's own mana value, and the upkeep return.
- Arachnogenesis: counts only creatures attacking you; prevents combat damage from non-Spiders.
- Destiny Spinner: creature and enchantment spells you control can't be countered.
- Ghoulish Impetus: goads, and returns at the next end step when the enchanted creature dies.
- Calix: the +1 puts the rest on the bottom; the -3 has two targets and returns the exiled card when the enchantment leaves.
- Carpet of Flowers: triggers in the second main phase too (new `Events::SecondMainPhase`).
- Anikthea: "up to one", and the copy is a lasting black 3/3 Zombie.
- Battle at the Helvault: one optional exile per player, until the Saga leaves (it exiled every opposing permanent for good).
- Beseech the Mirror: Bargain, and casting the exiled card for free.
- Abundance (was an empty card): replaces draws, including the turn's draw step.
- Auras that return from exile or a graveyard now ask what to enchant (`Card#return_to_battlefield!`). A token exiled by
  an exile effect no longer crashes it.

Gaps that were closed afterwards:

- Bargain, several targets and modes that take targets all work from the UI: `CastDraft` collects the sacrifice, the modes
  and each target before anything is paid.
- Abundance also replaces the monarch's draw.
- `Choice`s no longer keep a filter lambda (`LookAtTopCards`, `ReturnFromAmong`, `PutOntoBattlefieldFromAmong`), so a game
  with one pending can be copied with `Marshal`. `spec/game/choice_marshal_spec.rb` covers it.
- `Choice::Targeted` now applies hexproof, shroud and protection (`targets? = false` opts a "sacrifice a creature"-style
  choice out; the Eldest Reborn, Ruthless Winnower, Gatekeeper of Malakir and Braids do). Grasp of Fate's choice is now
  a `Targeted` one.

Known gaps:

- Goad is modelled as "attacks each combat if able", which is exact with one opponent.
- Player hexproof and shroud (Leyline of Sanctity) is not modelled; nothing in the deck has it.
- Many `Choice` subclasses that are not `Targeted` but choose a target (the card parser's, older cards) are not filtered.

## Second deck

`config/decks/elves.txt` is playable next to Enchantress (`/games/<id>?deck=elves`, `DECK=elves` for the scripts). Its
playtest turned up twelve engine bugs and ten arena gaps, all fixed: see `docs/elves-deck-playtest.md`.

## Plan

Order is by value for effort. After each step, extend `Bot` to use the new interaction and run the seeded full-game sweep
(`bin/rails runner script/simulate.rb <seed>`, plus the full-game test); that is what found most bugs.

## Status

- [x] 1. Quick fixes
- [x] 2. Targeted spells
- [x] 3. Costs that need a pick
- [x] 4. Planeswalkers
- [x] 5. Instant speed (stack, declare-blockers and end-step windows)
- [x] 6. Exile zone
- [x] 7. Engine audit
- [x] 8. Game flow: mulligans, concede, blocker order
