# loop_launcher

Launches each journey path's agent loop. It is a core service with an OS
user of its own, `loop-launcher`, and it holds the model sign-ins. The docking
station, which parses bytes strangers sent, does not: a process that holds
secrets never parses strangers' bytes, and the logbook is the only channel
between the two.

## What it does

It subscribes to every entry in the logbook from its start (every entry so
far, then each new one as it is recorded). It reads the docking station's
`admitted` entries that start a journey path and its `ended` entries, and
its own `assigned` entries. For each path started, it:

1. hands the path two users from pools made ahead of time on the box (Nick,
   16 Nov): a **loop user** (`loop-<n>`), one per path, which runs the path's
   loop and holds its sign-ins, and owns no files; and a **suit**
   (`suit-<n>`), one per path, contained or open alike, which owns the
   path's working tree and runs its programs (Nick, 16 Nov: every path wears
   a suit of its own). No two paths share either. The suit is wiped first.
   The handout is recorded as an `assigned` entry;
2. opens the suit's programs, which the airlock's program driver connects
   to;
3. starts the path's loop (`agent-loop@loop-<n>`) with the sign-ins the
   rules allow, the rules being those the entry that started it recorded.

It tells the airlock nothing (Nick, 16 Nov: "loop_launcher shouldn't be
using the airlock to record, it should just record itself"). The airlock
reads each path's rules from `admitted` and its users from `assigned`, like
every other service, and the logbook's check on who writes a path's entries
is the only check on who proposed, so no token is handed out.

Every other entry goes to the path whose loop it is for, and to no other:
an entry on the path's chain, which starts at its `assigned` entry and runs
through each entry's `previous`, or an airlock outcome answering a proposal
on that chain. A loop is handed its path's entries so far when it connects,
then each new one. The logbook can't tell which path an entry is about, so
a loop never reads the logbook itself, and can't read another conversation.

After a restart of loop_launcher, every live path goes through the same
steps, skipping what's already done: a loop still running is left running.

Both users are held until the journey's `ended` entry, which the docking
station writes, since only `ended` says a journey is over (RULINGS). Then
the journey's loops are stopped, its programs closed, its users freed, and
its paths dropped, so no later start brings them up again. A freed suit is
wiped before it is handed out again.

## Waiting to start

A path waits, with no users, when no loop user or suit is free, or when
its rules sign in on the Team login and K paths that do already have users
(Nick, 17 Nov: K = 4 for the demo, while K is the only brake). It is
recorded once, as a `waiting-to-start` entry on a chain of its own:

    {"journeyPath": <hex>}

Its `assigned` entry, written when there is room, ends the wait (Nick,
17 Nov), so a path with users never waits. Each journey's `ended` makes
room, and the waiting paths are brought up in the logbook's order, oldest
first. After a restart, who is waiting is read from the logbook, and not
recorded again. Why a path waits goes to the operator's log only. What its
travellers are told, and who tells them, is decided elsewhere.

## The `assigned` entry

    {"journeyPath": <hex>, "journey": <hex>, "loopUser": "loop-<n>",
     "suit": "suit-<n>"}

Kind `assigned`, sent only by `loop-launcher`. It roots the path's chain
(Nick, 16 Nov: "amend"): the logbook takes the chain's later entries only
from the loop user it names, by the kernel's word on who is on the socket,
until `ended`, and refuses a second `assigned` for the path. The loop is
given its hash, and its first turn names it as its previous. With it, the
owner of a file, read alongside the logbook, still says which journey path
wrote it after a pool user is handed out again.

## Not here yet

- **The box side of `Launcher`**: starting the systemd units, and the
  socket each loop's `OpenFile=` connects to for its path id, sign-ins,
  history and live entries. Waits on agent_loop's entry point.
- **A stop.** A person's stop of a path will be an entry loop_launcher
  records itself, so it survives any restart. Who decides a stop isn't
  ruled yet, so its kind and wire wait for that.
