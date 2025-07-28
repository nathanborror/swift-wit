
██     ██ ██ ████████
██     ██ ██    ██
██  █  ██ ██    ██
██ ███ ██ ██    ██
 ███ ███  ██    ██

The Wild Information Tracker (Wit) is a content addressable storage tool for managing files within a Wild instance. It's inspired by Linus Torvalds' Git.

Requirements:

- Swift 6.1+
- iOS 18+
- macOS 15+

Config file:

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

Directory structure:

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

Tasks:

- [x] Test object store for duplicate creation
- [x] Test workflow for duplicate tree creation
- [x] Test workflow for fine-grained tree changes
- [x] Object store needs custom url so it can store files globally to save space
- [x] Add memcache to RemoteDisk
- [x] Logs should be IRC-like (e.g. `<datetime> COMMIT <hash> <parent> <tree> <kind> <filename> <mimetype?> :<message>`)
- [x] Config parser
- [x] Rename `Reference` to `File`
- [ ] Fix rebase
- [ ] Add flags to Commit object
- [x] Log parser
- [ ] Build working directory for authenticated user

Client:

The client is designed to be a self sustaining interface to a specific repository.

It offers a high-level line delimited interface similar to IRC.

Example owner usage:

    PULL
    WRITE foo.txt :This is my foo file
    WRITE bar.txt :This is my bar file
    RM baz.txt
    COMMIT :Updates for the day
    PUSH origin/main
    CONFIG SET user.name :Vint Cerf
    CONFIG SET user.email :vint@example.com
    CONFIG LS
    CONFIG CAT user.email
    LS
