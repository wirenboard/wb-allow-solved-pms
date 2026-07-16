# Discourse Solved in Group Messages (PMs)

Re-enables the **“Mark as Solution”** feature inside **private messages** in Discourse—primarily for **group inbox / support mailbox** workflows.

This is intended for setups where incoming support emails are turned into Discourse PMs, staff replies go back out via email, and staff want to mark a reply as the solution inside that PM thread.

---

## What it does

The plugin prepends `Guardian#can_accept_answer?`. For **non-PM topics it does nothing at all** — the call goes straight to core. For **PM topics it replaces core's rules entirely** with the ones below.

- Restores the ability to **accept/unaccept an answer** in PM topics (`can_unaccept_answer?` is covered too, since core defines it in terms of `can_accept_answer?`).
- Lets you restrict:
  - **Which PM topics are eligible** (`solved_pm_target_groups`, `solved_pm_allow_personal_messages`)
  - **Who can mark/unmark solutions** (`solved_pm_actor_groups`, `solved_pm_allow_topic_owner`)

### Relationship to core Solved

Modern Discourse ships Solved in core (bundled `discourse-solved`) and **already supports group PMs** via its own `allow_solved_in_groups` setting. Because this plugin intercepts *every* PM, **core's `allow_solved_in_groups` and `allow_solved_on_all_topics` have no effect inside PMs while this plugin is installed** — including when `solved_pm_enabled` is off, in which case PMs get no solutions at all. If core's own group-PM support is enough for your workflow, you may not need this plugin; it exists for the extra gates (actor groups, topic owner, 1:1 DMs).

---

## Compatibility

- Verified against **Discourse 2026.4.0** (Solved bundled as `plugins/discourse-solved`).
- The plugin patches `Guardian#can_accept_answer?`, whose core signature is `(topic, post)`. If Discourse changes that method's name or signature, the plugin needs a small update; `spec/lib/guardian_patch_spec.rb` asserts the core signature so the drift shows up as a failing test rather than a silent permission change.

---

## Setting value format (important)

`solved_pm_target_groups` and `solved_pm_actor_groups` are `type: group_list`. **Discourse stores these as pipe-delimited group _ids_** (e.g. `44|3`), not names — the admin UI writes ids for you.

For backwards compatibility the plugin **also accepts group names** (case-insensitively) and mixed values, because plugin versions ≤ 0.2.0 shipped group *names* as defaults and left values such as `support|44|3` on live sites. Names and ids resolve to the same thing:

| Stored value | Resolves to |
|---|---|
| `44` | group 44 |
| `support` | the group named `support` |
| `support\|44\|3` | groups 44 and 3 (`support` resolves by name, deduplicated) |
| `no_such_group` | *nothing* → treated as a misconfiguration (see below) |

Entries that match no existing group are dropped, and `0` is never honoured — group 0 is `everyone`, and it is what the stock `SiteSetting.<name>_map` helper silently produces from a value like `support` (`"support".to_i == 0`). Cleaning legacy values up to plain ids is still recommended.

---

## Settings

Go to **Admin → Settings** and search for `solved_pm`.

### `solved_pm_enabled` — Enable Solved in private messages
Master switch for this plugin.

- **On**: solutions may be marked in PMs, subject to the rules below.
- **Off**: solutions are blocked in **every** PM — see [Relationship to core Solved](#relationship-to-core-solved).

> Note: `solved_enabled` (core Solved setting) must also be enabled.

---

### `solved_pm_target_groups` — PM group inboxes eligible for Solved
Restricts *which group-message PMs* are eligible. Applies **only to group messages** (PMs addressed to at least one group); 1:1 messages are governed solely by `solved_pm_allow_personal_messages`.

- **Set to one or more groups** (recommended): only PMs addressed to at least one of them are eligible.
- **Left empty**: every group-message PM is eligible.
- **Set but resolving to no group** (e.g. a renamed or deleted group): treated as a **misconfiguration — no group message is eligible** (fail closed), and the plugin logs a warning naming the setting. It is deliberately *not* read as “no restriction configured”.

---

### `solved_pm_actor_groups` — Groups allowed to mark solutions in eligible PMs
Restricts *who can mark/unmark* solutions inside eligible PM topics.

- Members of the listed groups can mark/unmark solutions.
- **Staff can always mark/unmark solutions, regardless of this setting** — this list only ever *adds* people, it cannot be used to restrict staff.
- If empty, only staff (and the topic owner, if `solved_pm_allow_topic_owner` is on) can mark solutions.

---

### `solved_pm_allow_topic_owner` — Allow PM topic owner to mark a solution
Whether the user who started the PM (often the customer) may mark/unmark a solution in it. The topic still has to be eligible.

**Common support configuration:** **Off** if you don’t want customers marking solutions.

---

### `solved_pm_allow_personal_messages` — Allow Solved in 1:1 private messages
Whether solutions are available in **personal (non-group) PMs**. Independent of `solved_pm_target_groups`: you can run a restricted support inbox *and* allow 1:1 DMs at the same time.

- Applies only to **strictly 1:1** messages (exactly two participants, no groups). Group-less PMs with three or more participants are never eligible.
- **Off** (recommended) unless you explicitly want solution-marking in personal DMs.

---

## Eligibility, in short

```
PM has >= 1 allowed group?
├── yes  -> solved_pm_target_groups empty        -> eligible
│          solved_pm_target_groups matches       -> eligible
│          otherwise (incl. unresolvable value)  -> NOT eligible
└── no   -> solved_pm_allow_personal_messages on
            AND exactly 2 participants           -> eligible
            otherwise                            -> NOT eligible

then, in an eligible PM, the solution may be marked by:
  staff (always) | members of solved_pm_actor_groups | the topic owner (if enabled)
```

Guardrails applied before any of the above: the post must be a regular, non-whisper, non-deleted, non-first post belonging to that topic, not authored by the system user; the topic must not be closed or archived; and the user must be able to see both.

---

## Recommended configurations

### Support mailbox (group inbox) only
- `solved_pm_enabled` = ✅
- `solved_pm_target_groups` = `44` *(your support group's id)*
- `solved_pm_actor_groups` = *(empty for staff-only, or the ids of your agent groups)*
- `solved_pm_allow_topic_owner` = ❌ (optional but common)
- `solved_pm_allow_personal_messages` = ❌

### Allow solutions in 1:1 DMs (site-wide)
- `solved_pm_enabled` = ✅
- `solved_pm_target_groups` = *(empty)*
- `solved_pm_actor_groups` = *(your choice)*
- `solved_pm_allow_topic_owner` = ✅/❌ (your choice)
- `solved_pm_allow_personal_messages` = ✅

---

## Upgrading from 0.2.0 to 0.3.0

0.2.0 resolved `group_list` settings by **name only**, so values written by the admin UI (ids) silently resolved to nothing — both group gates were no-ops, and an unresolvable target list meant *every* group PM was eligible. 0.3.0 makes them work, which means **existing values start taking effect**. Before upgrading, re-read your two group settings and confirm they say what you meant:

- `solved_pm_target_groups` — every id/name in it becomes a genuinely eligible inbox.
- `solved_pm_actor_groups` — every id/name in it genuinely starts granting people (e.g. a stale `14` grants all trust-level-4 users).

The settings.yml defaults also changed from `support` / `staff` to empty, which only affects sites that never overrode them.

---

## Development

The specs in `spec/` follow the Discourse plugin convention and need a Discourse **dev/test** checkout — they cannot run on a production container (no test gems):

```bash
cd /path/to/discourse
bin/rake plugin:spec[wb-allow-solved-pms]
```

---

## Installation (Discourse Docker)

### 1) Add the plugin to your `app.yml`

Edit:

- `/var/discourse/containers/app.yml`

Add a `git clone` under `hooks: after_code:`:

```yml
hooks:
  after_code:
    - exec:
        cd: $home/plugins
        cmd:
          - git clone https://github.com/wirenboard/wb-allow-solved-pms.git
```

### 2) Rebuild

```bash
cd /var/discourse
./launcher rebuild app
```
