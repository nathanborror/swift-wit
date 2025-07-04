██     ██
██     ██ ██   ██
██  █  ██    ██████
██ ███ ██ ██   ██
 ███ ███  ██   ██

The Wild Information Tracker (Wit) is a content addressable storage tool for managing files within a Wild instance. It's inspired by Linus Torvalds' Git.

Tasks:

- [ ] Test object store for duplicate creation
- [ ] Test workflow for duplicate tree creation
- [ ] Test workflow for fine-grained tree changes
- [ ] Create a manifest and store it in .wit/manifest (untracked)
- [ ] Create a user config file and store it in .wit/user (untracked)
- [ ] Add rebase to check for changes and conflicts that could be on the server
- [ ] Add push to send changes to server, objects before updating head
- [ ] Object store needs custom url so it can store files globally to save space
