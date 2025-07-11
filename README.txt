
██     ██
██     ██ ██   ██
██  █  ██    ██████
██ ███ ██ ██   ██
 ███ ███  ██   ██

The Wild Information Tracker (Wit) is a content addressable storage tool for managing files within a Wild instance. It's inspired by Linus Torvalds' Git.

Config file:

    [core]
        version = 1.0
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
        ├ manifest
        ├ objects/
        └ remotes/
          └ origin/
            ├ HEAD
            ├ logs
            └ manifest

Tasks:

- [x] Test object store for duplicate creation
- [x] Test workflow for duplicate tree creation
- [x] Test workflow for fine-grained tree changes
- [x] Create a manifest and store it in .wit/manifest (untracked)
- [x] Object store needs custom url so it can store files globally to save space
- [ ] Create a user config file and store it in .wild/user (untracked)
- [ ] Add rebase to check for changes and conflicts that could be on the server
- [ ] Add push to send changes to server, objects before updating head
- [ ] Cache log information about remotes locally
