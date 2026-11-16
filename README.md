# loop_launcher

Launches each journey path's agent loop. It is a core service with an OS
user of its own, `loop-launcher`, and it holds the model sign-ins. The docking
port, which parses bytes strangers sent, does not: a process that holds
secrets never parses strangers' bytes, and the record is the only channel
between the two.

## What it does

It follows the record from its start for the docking port's `admitted`
entries that start a journey path, and its own `assigned` entries. For each
path started, it:

1. hands the path two users from pools made ahead of time on the box (Nick,
   16 Nov): a **loop user** (`loop-<n>`), one per path, which runs the path's
   loop and holds its token and sign-ins, and owns no files; and its
   journey's **journey user** (`journey-<n>`), shared by the journey's paths,
   which owns the journey's working tree and runs its programs. A journey
   user new to its journey is wiped first. The handout is recorded as an
   `assigned` entry;
2. opens the journey user's programs (`program@journey-<n>`), which the
   airlock's program driver connects to;
3. tells the airlock the path started (`PathStarted`, is_airlock_api), and
   gets back `Ready(token)` or `Rejected`;
4. starts the path's loop (`agent-loop@loop-<n>`) with that token.

After a restart, of loop_launcher or the airlock, every live path goes
through the same steps, skipping what's already done: the airlock reissues the
token, and the loop is started again with it, so a token and the loop holding
it end together.

Both users are held until the journey's `ended` entry, since only `ended`
says a journey is over (RULINGS).

## The `assigned` entry

    {"journeyPath": <hex>, "journey": <hex>, "loopUser": "loop-<n>",
     "journeyUser": "journey-<n>"}

Kind `assigned`, sent only by `loop-launcher`. It roots the path's chain
(Nick, 16 Nov: "amend"): the journal takes the chain's later entries only
from the loop user it names, by the kernel's word on who is on the socket,
until `ended`, and refuses a second `assigned` for the path. The loop is
given its hash, and its first turn follows it. With it, the owner of a file,
read alongside the record, still says which journey wrote it after a pool
user is handed out again.

## Not here yet

- **The box side of `Launcher`**: starting the systemd units, and the
  socket each loop's `OpenFile=` connects to for its path id, token,
  sign-ins, history and live entries. Waits on agent_loop's entry point.
- **A journey's end.** Nothing in the record says which entry ends a
  journey, so a pool user, once handed out, stays held.
- **A path's rules.** Nothing records them yet. The proposal with Nick is
  that the `admitted` entry that starts a path carries them, so a restart
  re-sends the rules the path started under. Until then the caller passes
  `rulesOf`.
- **A stop.** `PathStarted.stopped` keeps the person's stop across a
  restart only if the record holds it; nothing does yet, so it is sent
  `false`.
- **The journey user in `PathStarted`**, for the airlock to hand the program
  driver, which waits on is_airlock_api 0.5.0.
