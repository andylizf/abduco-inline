# abduco-inline

`abduco-inline` is a tiny fork of
[abduco](https://www.brain-dump.org/projects/abduco) for long-running terminal
agents and TUIs that should keep using the terminal's native scrollback by
default.

The upstream `abduco` client enters the terminal alternate screen when attaching
to a session. That is useful for full-screen applications, but it prevents the
main terminal scrollback from behaving like a normal shell. This fork keeps the
abduco client on the main screen while preserving abduco's core behavior: start
a process, detach, and reattach later.

Important boundary: `abduco-inline` only changes what the **abduco client** does
while attaching. It does not block, filter, or rewrite terminal control
sequences from the application running inside the session. If the child
application chooses to enter a fullscreen/alternate-screen mode, it still can.
For example, Claude Code's normal inline mode can use native terminal
scrollback, while Claude Code's `/tui fullscreen` mode can still switch to its
own fullscreen UI.

Typical agent usage:

```sh
abduco -A my-agent codex --no-alt-screen
abduco -A my-agent
```

For Claude Code:

```sh
abduco -A my-claude claude
abduco -A my-claude
```

When the wrapped application also has an alternate-screen option, disable it
there as well. For Codex that means `codex --no-alt-screen`.

When the wrapped application intentionally enters fullscreen mode, scrollback
behavior is owned by that application until it exits fullscreen mode.

## Install

Download a pre-built binary from the [releases page](https://github.com/andylizf/abduco-inline/releases):

```sh
# Linux x86_64
curl -Lo abduco https://github.com/andylizf/abduco-inline/releases/latest/download/abduco-linux-x86_64
chmod +x abduco
sudo mv abduco /usr/local/bin/abduco-inline

# macOS arm64
curl -Lo abduco https://github.com/andylizf/abduco-inline/releases/latest/download/abduco-macos-arm64
chmod +x abduco
sudo mv abduco /usr/local/bin/abduco-inline
```

Or build from source (requires a C compiler, no other dependencies):

```sh
./configure && make && sudo make install
```

The installed binary is named `abduco` by default. Rename or symlink to
`abduco-inline` if you want to keep it alongside upstream abduco.

## Automation flags

In addition to all standard abduco flags, `abduco-inline` adds:

### `-d` — dump session output

Print the current scrollback buffer of a running session to stdout and exit.

```sh
abduco-inline -d my-agent
```

### `-d -L <n>` — last N lines

```sh
abduco-inline -d -L 50 my-agent       # last 50 lines
```

### `-d -N <bytes>` — last N bytes

```sh
abduco-inline -d -N 4096 my-agent     # last 4096 bytes
```

(`-L` and `-N` are mutually exclusive.)

### `-K` — send keys to a session

Send keystrokes to a running session without attaching. Accepts key names
(`Enter`, `Tab`, `Esc`, `Up`, `Down`, `C-c`, `C-d`, …) or literal strings.

```sh
abduco-inline -K my-agent "echo hello" Enter
abduco-inline -K my-agent C-c
```

### `-K -x` — literal mode

Send the remaining arguments as raw bytes (space-separated tokens are joined
with a space between them).

```sh
abduco-inline -K -x my-agent $'echo hello\n'
```

### Typical automation loop

```sh
# start agent in background
abduco-inline -n my-agent my-command

# poll output
abduco-inline -d -L 20 my-agent

# send input
abduco-inline -K my-agent "some input" Enter
```

## What changed from upstream

This fork removes the client-side `CSI ? 1049 h/l` alternate-screen enter/leave
sequences from abduco's attach path. It still switches the terminal to raw mode
while attached, forwards input/output through the session pty, and restores the
terminal settings on detach.

It also adds the `-d`/`-K`/`-N`/`-L`/`-x` automation flags described above.

---

# upstream abduco

[abduco](https://www.brain-dump.org/projects/abduco) provides
session management i.e. it allows programs to be run independently
from their controlling terminal. That is programs can be detached -
run in the background - and then later reattached. Together with
[dvtm](https://www.brain-dump.org/projects/dvtm) it provides a
simpler and cleaner alternative to tmux or screen.

![abduco+dvtm demo](https://raw.githubusercontent.com/martanne/abduco/gh-pages/screencast.gif#center)

abduco is in many ways very similar to [dtach](http://dtach.sf.net)
but is a completely independent implementation which is actively maintained,
contains no legacy code, provides a few additional features, has a
cleaner, more robust implementation and is distributed under the
[ISC license](https://raw.githubusercontent.com/martanne/abduco/master/LICENSE)

## News

 * [abduco-0.6](https://www.brain-dump.org/projects/abduco/abduco-0.6.tar.gz)
   [released](https://lists.suckless.org/dev/1603/28589.html) (24.03.2016)
 * [abduco-0.5](https://www.brain-dump.org/projects/abduco/abduco-0.5.tar.gz)
   [released](https://lists.suckless.org/dev/1601/28094.html) (09.01.2016)
 * [abduco-0.4](https://www.brain-dump.org/projects/abduco/abduco-0.4.tar.gz)
   [released](https://lists.suckless.org/dev/1503/26027.html) (18.03.2015)
 * [abduco-0.3](https://www.brain-dump.org/projects/abduco/abduco-0.3.tar.gz)
   [released](https://lists.suckless.org/dev/1502/25557.html) (19.02.2015)
 * [abduco-0.2](https://www.brain-dump.org/projects/abduco/abduco-0.2.tar.gz)
   [released](https://lists.suckless.org/dev/1411/24447.html) (15.11.2014)
 * [abduco-0.1](https://www.brain-dump.org/projects/abduco/abduco-0.1.tar.gz)
   [released](https://lists.suckless.org/dev/1407/22703.html) (05.07.2014)
 * [Initial announcement](https://lists.suckless.org/dev/1403/20372.html)
   on the suckless development mailing list (08.03.2014)

## Download

Either download the latest [source tarball](https://github.com/martanne/abduco/releases),
compile and install it

    ./configure && make && sudo make install

or use one of the distribution provided
[binary packages](https://repology.org/project/abduco/packages).

## Quickstart

In order to create a new session `abduco` requires a session name
as well as an command which will be run. If no command is given
the environment variable `$ABDUCO_CMD` is examined and if not set
`dvtm` is executed. Therefore assuming `dvtm` is located somewhere
in `$PATH` a new session named *demo* is created with:

    $ abduco -c demo

An arbitrary application can be started as follows:

    $ abduco -c session-name your-application

`CTRL-\` detaches from the active session. This detach key can be
changed by means of the `-e` command line option, `-e ^q` would
for example set it to `CTRL-q`.

To get an overview of existing session run `abduco` without any
arguments.

    $ abduco
    Active sessions (on host debbook)
    * Thu    2015-03-12 12:05:20    demo-active
    + Thu    2015-03-12 12:04:50    demo-finished
      Thu    2015-03-12 12:03:30    demo

A leading asterisk `*` indicates that at least one client is
connected. A leading plus `+` denotes that the session terminated,
attaching to it will print its exit status.

A session can be reattached by using the `-a` command line option
in combination with the session name which was used during session
creation.

    $ abduco -a demo

If you encounter problems with incomplete redraws or other
incompatibilities it is recommended to run your applications
within [dvtm](https://github.com/martanne/dvtm) under abduco:

    $ abduco -c demo dvtm your-application

Check out the manual page for further information and all available
command line options.

## Improvements over dtach

 * **session list**, available by executing `abduco` without any arguments,
   indicating whether clients are connected or the command has already
   terminated.

 * the **session exit status** of the command being run is always kept and
   reported either upon command termination or on reconnection
   e.g. the following works:

        $ abduco -n demo true && abduco -a demo
        abduco: demo: session terminated with exit status 0

 * **read only sessions** if the `-r` command line argument is used when
   attaching to a session, then all keyboard input is ignored and the
   client is a passive observer only.

   Note that this is not a security feature, but only a convenient way to
   avoid accidental keyboard input.

   If you want to make your abduco session available to another user
   in a read only fashion, use [socat](http://www.dest-unreach.org/socat/)
   to proxy the abduco socket in a unidirectional (from the abduco server
   to the client, but not vice versa) way.

   Start your to be shared session, make sure only you have access to
   the `private` directory:

        $ abduco -c /tmp/abduco/private/session

   Then proxy the socket in unidirectional mode `-u` to a directory
   where the desired observers have sufficient access rights:

        $ socat -u unix-connect:/tmp/abduco/private/session unix-listen:/tmp/abduco/public/read-only &

   Now the observers can connect to the read-only side of the socket:

        $ abduco -a /tmp/abduco/public/read-only

   communication in the other direction will not be possible and keyboard
   input will hence be discarded.

 * **better resize handling** on shared sessions, resize request are only
   processed if they are initiated by the most recently connected, non
   read only client.

 * **socket recreation** by sending the `SIGUSR1` signal to the server
   process. In case the unix domain socket was removed by accident it
   can be recreated. The simplest way to find out the server process
   id is to look for abduco processes which are reparented to the init
   process.

        $ pgrep -P 1 abduco

   After finding the correct PID the socket can be recreated with

        $ kill -USR1 $PID

   If the abduco binary itself has also been deleted, but a session is
   still running, use the following command to bring back the session:

        $ /proc/$PID/exe

 * **improved socket permissions** the session sockets are by default either
   stored in `$HOME/.abduco` or `/tmp/abduco/$USER` in both cases it is
   made sure that only the owner has access to the respective directory.

## Development

You can always fetch the current code base from the git repository
located at [Github](https://github.com/martanne/abduco/) or
[Sourcehut](https://git.sr.ht/~martanne/abduco).

If you have comments, suggestions, ideas, a bug report, a patch or something
else related to abduco then write to the
[suckless developer mailing list](https://suckless.org/community)
or contact me directly.

### Debugging

The protocol content exchanged between client and server can be dumped
to temporary files as follows:

    $ make debug
    $ ./abduco -n debug [command-to-debug] 2> server-log
    $ ./abduco -a debug 2> client-log

If you want to run client and server with one command (e.g. using the `-c`
option) then within `gdb` the option `set follow-fork-mode {child,parent}`
might be useful. Similarly to get a syscall trace `strace -o abduco -ff
[abduco-cmd]` proved to be handy.

## License

abduco is licensed under the [ISC license](https://raw.githubusercontent.com/martanne/abduco/master/LICENSE)
