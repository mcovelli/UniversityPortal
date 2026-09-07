# Migrations

The `University` schema ships with no foreign keys at all and eight tables
with no primary key. These scripts add them.

Run in order:

```bash
# 1. See what's wrong. Read-only, changes nothing.
mysql -h 127.0.0.1 -u root University --table < migrations/001_preflight_checks.sql

# 2. Back up. DDL commits implicitly, so this is the only way back.
mysqldump -h 127.0.0.1 -u root --set-gtid-purged=OFF --single-transaction \
  --routines --triggers --databases University > University_before_keys.sql

# 3. Apply.
mysql -h 127.0.0.1 -u root University < migrations/002_add_keys.sql
```

`003_rollback.sql` drops the constraints again. It does **not** restore the
rows deleted in Phase 2 — that needs the dump from step 2.

## What 002 does

| Phase | Change |
|---|---|
| 1 | Reconciles three column types that made a foreign key impossible |
| 2 | Removes or repairs the ~2,000 rows that would reject a constraint |
| 3 | Adds 6 primary keys (2 keyless tables are scratch — drop is commented out) |
| 4 | Adds 89 foreign keys |
| 5 | Drops the duplicate `Users.Email_2` index |
| 6 | Verifies: expects 89 foreign keys, 0 tables without a primary key |

`004` corrects seven ON DELETE rules, `005` adds soft delete, `006`
creates the two stored procedures the PHP calls, `007` rebuilds
`Student.StudentType`, and `008` retires `StudentHistory`.

## 008 changes the numbers, not just the schema

`StudentHistory` held 6,696 rows against `StudentEnrollment`'s 31,056,
every one of them mirrored by a `COMPLETED` enrolment with the same
grade — a strict subset, recorded twice. The degree audit read the
smaller copy, so 8,931 graded courses and 865 students were invisible to
it.

`008` points `UpdateDegreeAudit` at `StudentEnrollment WHERE Status =
'COMPLETED'` and drops the table. `009` then rebuilds every stored
`DegreeAudit` row, because `008` replaces the procedure without calling
it — immediately after `008`, 1,081 of 1,602 rows still held the figure
computed from `StudentHistory`. Run both:

```bash
# Back up first. DROP TABLE commits implicitly.
mysqldump -h 127.0.0.1 -u root --set-gtid-purged=OFF --single-transaction \
  --routines --triggers --databases University > University_before_008.sql

mysql -h 127.0.0.1 -u root University < migrations/008_retire_studenthistory.sql
mysql -h 127.0.0.1 -u root University < migrations/009_recompute_degree_audits.sql
```

`008` refuses to run if any `StudentHistory` row is not mirrored by a
`COMPLETED` enrolment carrying the same grade, and stops before the drop
rather than after it. `009` refuses to run against the pre-`008`
procedure, and is safe to re-run — the upsert converges.

Then regenerate `University.sql` with `--routines`, or the recreated
procedure is lost.

### Verified

Applied to a clone of the live database on 2026-09-06. Of 1,602
students, 475 were unchanged, 1,127 gained credits and 838 went from
zero to a real figure. **No student lost credits**, which is what a
strict subset predicts. GPAs stayed inside 0.00–4.00, no
`Credits_Remaining` went negative, and one student was checked by hand
against their enrolment rows (24 credits, 2.70 GPA — matched). The guard
was tested by diverging a single grade: it raised `SQLSTATE 45000` and
left the table in place.

Both then applied to `University` itself the same day. Audits carrying
credits went from 521 to 1,358 — matching the 1,358 students who have a
`COMPLETED` enrolment — and the average GPA from 1.037 to 2.408, the
same figure the clone produced. All four post-conditions in `009`
returned zero.

## Always dump with --routines

`mysqldump` includes triggers by default but **not** stored procedures.
A dump taken without `--routines` silently loses `GenerateUserEmail` and
`UpdateDegreeAudit`, and user creation then fails on a fresh install:

```bash
mysqldump -h 127.0.0.1 -u root --set-gtid-purged=OFF --single-transaction \
  --routines --triggers --databases University > University.sql
```

## Effect on the application

`DeleteUsers.php` deletes from `Users` alone and cleans up nothing else,
which is how the orphans got there. The identity chain is `ON DELETE
CASCADE`, so that statement starts working correctly — but it will now
also remove the user's enrollments, attendance and degree audit.

To block deletion instead, switch the four constraints marked
`[TRANSCRIPT]` in Phase 4 to `ON DELETE RESTRICT`.

## Verified

Applied to a clone of the live database on 2026-09-04: 89 foreign keys
added, zero orphans across all 93 checked references, rollback returns to
zero, and re-applying after rollback succeeds.

---

# 010–012: the rules the schema was missing

The schema had one trigger (it blocks user deletes) and no rule anywhere
for what a registration is allowed to be. These three add 28 more, in the
order that lets each be applied without a data cleanup ahead of it.

```bash
# Back up first. DDL commits implicitly.
mysqldump -h 127.0.0.1 -u root --set-gtid-purged=OFF --single-transaction \
  --routines --triggers --databases University > University_before_010.sql

mysql -h 127.0.0.1 -u root University --table < migrations/010_integrity_triggers.sql
mysql -h 127.0.0.1 -u root University --table < migrations/011_studentmajor_authoritative.sql
mysql -h 127.0.0.1 -u root University --table < migrations/012_registration_rules.sql
```

| File | Adds | Rejects existing rows? |
|---|---|---|
| `010` | Grade foreign key + 10 triggers: enrolment matches its section, course level matches the student, the Student/Undergraduate/Graduate hierarchy stays disjoint | No — every rule holds on all 31,056 rows today, and a guard aborts if that stops being true |
| `011` | Recaches `Student.MajorID` from `StudentMajor` and adds 7 triggers to keep it there | Repairs 1,173 major caches and 140 empty minor caches |
| `012` | The add/drop window, holds, prerequisites, credit load, timetable clashes, and seat accounting — 11 triggers | Yes. See below |

## 010 and 011 change how three pages must be written

`UpdateUsers.php` changed with them, and the order in its student block is
now load-bearing:

1. delete the subtype row being moved away from
2. then change `Student.StudentType` — 010 rejects the reverse order
3. then insert the new subtype row
4. then rewrite `StudentMajor` / `StudentMinor`, which is what sets
   `Student.MajorID` — 011 rejects writing that column directly

`confirm_cart.php` and `drop_course.php` no longer touch `AvailableSeats`.
Migration 012 moves that into triggers so the count changes in the same
statement as the enrolment. **Leaving the PHP as it was charges two seats
for one registration.**

## 012 enforces rules the historical data breaks

A trigger governs new rows only, so these survive and are not repaired:

| Rule | Rows already breaking it |
|---|---|
| Prerequisites met | 13,464 |
| Under the credit ceiling | 1,634 student-semesters |
| No two sections in one timeslot | 1,256 students |
| No hold on the account | 57 students |
| Seats not below zero | 41 sections |

The 41 negative sections are not corruption: `AvailableSeats` plus live
enrolments comes to exactly 40 on every one, so the counter was right and
the sections were genuinely oversold. The floor trigger refuses to make
them worse and lets each drop return a seat, so they recover on their own.

## One thing left open

**312 students** have a `Student.MajorID` and no `StudentMajor` row. Their
majors spread realistically across all ten departments, so it is real
information — but writing declarations for them means inventing 312
declaration dates, 216 for students with no enrolment history to date
from. Left as-is; `011` section 5 lists them.

## Verified

Applied to a clone of the live database on 2026-09-06. 29 triggers
installed, 34 behavioural tests pass (each rule rejects what it should and
accepts what it should), all 63 application pages render with zero fatals
and zero warnings, and a registration and a drop each move the seat count
by exactly one.

# 013: the two things 010–012 left open

The override now has a source: `config.php`'s `get_db()` sets
`SET @nu_override = 1` whenever `$_SESSION['admin_type'] === 'update'`, so
an UpdateAdmin's writes bypass every policy rule from 012 plus the two new
ones below. **This is a PHP change, not a migration — it's already live**,
independent of whether 013 has been applied.

`013_section_scheduling_rules.sql` closes the three constraints flagged in
the table above but not built: no negative seats, no room double-booked in
a timeslot, no faculty double-booked in a timeslot.

```bash
mysqldump -h 127.0.0.1 -u root --set-gtid-purged=OFF --single-transaction \
  --routines --triggers --databases University > University_before_013.sql

mysql -h 127.0.0.1 -u root University --table < migrations/013_section_scheduling_rules.sql
```

| Rule | Pre-existing violations | Shape |
|---|---|---|
| `AvailableSeats >= 0` | 41 sections | Repaired (floored to 0), then a real `CHECK` |
| One section per room per timeslot per semester | 52 groups | Trigger — rejects a new clash, leaves the 52 |
| One section per faculty per timeslot per semester | 131 groups | Trigger — rejects a new clash, leaves the 131 |

The seat repair is not the same kind of move as leaving the room/faculty
clashes alone. `AvailableSeats` is a live counter that 012 already proved
self-corrects to the true capacity — flooring it to 0 doesn't rewrite
anything, it's the value the seat-floor trigger already guarantees those
rows reach. A room or faculty clash is a historical scheduling record with
no way to tell, from the data, which of the two sections was the mistake —
so like the 312 students above, it's left alone rather than guessed at.
Both new triggers honour `@nu_override`.

## Verified

Applied to a clone of the live database on 2026-09-07. 33 triggers
installed (29 + 4), the `CHECK` constraint added, 8 behavioural tests
pass: a clashing insert and a clashing update are both rejected, both are
allowed under `@nu_override`, an ordinary insert/update with no clash
still succeeds, a negative-seat insert is rejected by the `CHECK` (the
pre-existing floor trigger only covers `UPDATE`), and a normal seat
decrement still works. Live database confirmed unchanged (29 triggers,
41 negative sections) — 013 has not been applied there.

# 014: the 312 students

```bash
mysql -h 127.0.0.1 -u root University --table < migrations/014_backfill_major_declarations.sql
```

Writes the `StudentMajor` row the last open item was missing. Splits on
the one thing that told the 312 apart: 96 have enrolment history, so
`DateOfDeclaration` is backfilled from their earliest enrolment -- real
evidence, not a guess. The other 216 have never enrolled in anything and
nothing in the schema carries a date to anchor them to, so they get
`CURDATE()` -- the backfill date, documented as exactly that, not a
claimed memory of the past. Both groups insert through a staging temp
table rather than straight from `Student`, because a direct
`INSERT ... SELECT ... FROM Student` fires 011's sync trigger, which
`UPDATE`s `Student` -- and MySQL refuses to let a trigger update a table
its invoking statement is still reading (error 1442).

**Verified.** Applied to a clone on 2026-09-07: all 312 land, 0 cache
disagreements anywhere in the table afterward.

# 015–018: the rest of the trigger review

Group D (derived data), Group E (audit trail), Group F (login), and the
two items flagged but not built. `config.php` gained a second session
variable alongside `@nu_override` for this batch:

```php
if (session_status() === PHP_SESSION_ACTIVE && isset($_SESSION['user_id'])) {
    $mysqli->query('SET @nu_actor = ' . (int)$_SESSION['user_id']);
}
```

Every logged-in request now tells the database who is making it --
016's audit triggers write this into `AuditLog.ChangedBy`. Without it
every row would read `root`, because every page connects as root.

```bash
mysqldump -h 127.0.0.1 -u root --set-gtid-purged=OFF --single-transaction \
  --routines --triggers --databases University > University_before_015.sql

mysql -h 127.0.0.1 -u root University --table < migrations/015_degree_audit_refresh.sql
mysql -h 127.0.0.1 -u root University --table < migrations/016_audit_trail.sql
mysql -h 127.0.0.1 -u root University --table < migrations/017_login_lockout.sql
mysql -h 127.0.0.1 -u root University --table < migrations/018_fix_major_name.sql
```

| File | Adds |
|---|---|
| `015` | `trg_SE_after_update_audit` -- calls `UpdateDegreeAudit` when a grade lands, so the stored audit stops depending on the student visiting that one page. Also drops `CreditsEarned` from the four load tables (`FullTimeUG`/`PartTimeUG`/`FullTimeGrad`/`PartTimeGrad`) -- 973 of 982 `FullTimeUG` rows already disagreed with it, nothing in the app reads it, and `DegreeAudit.Credits_Completed` is the same number, correctly. |
| `016` | Three audit triggers: `Users` (address/email/status/role, old value and new), `StudentEnrollment` (every grade change), `StudentHold` (placed and cleared). Needs `@nu_actor`. |
| `017` | `trg_Login_before_update_lockout` -- sets `MustReset = 1` once `LoginAttempts` reaches 3, so the lockout holds even if a future write path forgets to set it. `login.php` already does this correctly; this makes it true regardless of which file writes `Login`. |
| `018` | Renames `Major.MajorName` for `MajorID 1` from "Mathematics Minor" to "Mathematics" -- a copy-paste from `Minor.MinorName`, which already carries that exact name correctly on its own table. |

## UpdateUsers.php and CreateUsers.php also changed

`UpdateUsers.php`'s student block used `REPLACE INTO Undergraduate` /
`REPLACE INTO Graduate`. `REPLACE` deletes any existing row with that
primary key before reinserting it, and both tables cascade that delete
onto their load table (`FullTimeUG`/`PartTimeUG`/`FullTimeGrad`/
`PartTimeGrad`) -- so saving a student's edit, even one that never
touched their enrollment type, silently deleted their `MaxCredits`/
`MinCredits`/`Year` row, and nothing recreated it. Fixed as an upsert
that only changes the columns being edited: an unchanged type now
leaves the load row untouched, and an actual type switch removes the
stale row from the old table and creates a fresh one in the new table
with sensible defaults, matching what `CreateUsers.php` sets at
creation.

Nothing had ever been affected on the live database as of this
migration (0 students missing both a `FullTimeUG`/`PartTimeUG` row and
both a `FullTimeGrad`/`PartTimeGrad` row) -- this was a live landmine
that had not yet gone off, not a repair.

`CreateUsers.php` no longer inserts `CreditsEarned` -- the column 015
drops.

## Verified

Applied to a clone of the live database on 2026-09-07. 39 triggers
installed (33 + 6), `Major.MajorID 1` reads "Mathematics" afterward.
Behavioural tests: `UpdateDegreeAudit` fires on a grade change and does
not fire on a plain drop or a status-only change; `Users`/
`StudentEnrollment`/`StudentHold` writes land in `AuditLog` with the
actor and old/new values, a no-op `Users` update logs nothing;
`LoginAttempts = 3` locks the account even without `MustReset` set
explicitly, and an explicit unlock (`0`/`0` together) is not clobbered.
`UpdateUsers.php`'s fix verified through the real page, not just SQL: a
no-op save of an UpdateAdmin-edited student now leaves `FullTimeUG`
untouched (previously destroyed), and a real type switch removes the
old load row and creates the new one. All checks run with zero fatals
and zero warnings. Live database confirmed unchanged (33 triggers,
`MajorID 1` still "Mathematics Minor", `CreditsEarned` still present)
-- none of 014–018 has been applied there.
