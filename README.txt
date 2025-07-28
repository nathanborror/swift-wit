
██     ██ ██ ████████
██     ██ ██    ██
██  █  ██ ██    ██
██ ███ ██ ██    ██
 ███ ███  ██    ██

The Wild Information Tracker (WIT) is a content addressable storage tool for managing files within a Wild instance. It's inspired by Linus Torvalds' Git.

Requirements:

- Swift 6.1+
- iOS 18+
- macOS 15+

Config file maintains stable information about a user and their remotes:

    [core]
        version = 1.0
        publicKey = PUBLIC_KEY_STRING
    [user]
        id = USER_ID
        name = Nathan Borror
        email = nathan@example.com
        username = nathan
    [remote "origin"]
        url = http://localhost:8080/USER_ID

Common directory structure is similar to Git. The objects folder is designed to work in a custom location to take advantage of a larger pool of storage:

    ~/
    └ <WORKING_DIR>/
      └ .wild/
        ├ config
        ├ HEAD
        ├ logs
        ├ objects/
        └ remotes/
          └ origin/
            ├ HEAD
            └ logs

The command-line tool will operate similar to IRC's line delimited interface:

    > PULL
    > WRITE foo.txt :This is my foo file
    > WRITE bar.txt :This is my bar file
    > RM baz.txt
    > COMMIT :Updates for the day
    > PUSH origin/main
    > CONFIG SET user.name :Vint Cerf
    > CONFIG SET user.email :vint@example.com
    > CONFIG LS
    > CONFIG CAT user.email
    > LS
