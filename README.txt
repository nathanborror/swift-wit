
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
        version = 0.1
        publicKey = PUBLIC_KEY_STRING
    [user]
        id = USER_ID
        name = Nathan Borror
        email = nathan@example.com
    [remote:origin]
        url = http://localhost:8080/USER_ID

Common directory structure is similar to Git. The objects folder is designed to work in a custom location to take advantage of a larger pool of storage:

    ~/
    └ <WORKING_DIR>/
      └ .wild/
        ├ config
        ├ HEAD
        ├ logs
        ├ objects/
          ├ commits/
          ├ trees/
          └ objects/
        └ remotes/
          └ origin/
            ├ HEAD
            └ logs

Example Commit:

    Date: Tue, 02 Dec 2025 12:39:40 -0800
    Content-Type: text/csv; charset=utf8; header=present; profile=commit

    tree,parent,message
    7d39f9572306253fadb22b8fb121ee67440dbb4a231bbb7aadedfe49b2d0c59c,,"User initiated"

Example Tree:

    Content-Type: text/csv; charset=utf8; header=present; profile=tree

    hash,mode,name
    c73805a135247b60e2872b732b00d9e812a229c816eec100f421324028252d22,040000,"Chats"
    848dfc785d33037632c60e588d67f886f7d80655b5b4f98a31035d047d4007af,040000,"Notes"
    ae28c446dda657a89abee85ab5e9e1eefccfdb3b30992d242ba70c761b7e9c26,040000,"Files"
    8befcf61dddd7c138bcd5ff8fd34a8be422d54697f7f5d0b749f304b7f210d13,100644,"README.md"

Example HEAD:

    Date: Tue, 02 Dec 2025 12:39:40 -0800
    Content-Type: text/plain

    53b1ef6a247d7cfb7a63ae3f48440468c5c6848bb5d2ae3d9e3eab3fa5742001

Example logs:

    Date: Tue, 02 Dec 2025 12:39:40 -0800
    Content-Type: text/csv; charset=utf8; header=present; profile=logs

    timestamp,hash,parent,message
    1765556813.282666,261601e78b6923c67afee30f9b98a6299c367a10e205e99eb70792539459a7ac,,"Initial commit"
    1765556813.288764,0a81cdb262557cc13a54801e2643ad08ee91603311d423a1ee7af371d47602bf,261601e78b6923c67afee30f9b98a6299c367a10e205e99eb70792539459a7ac,"Deleted documents"

