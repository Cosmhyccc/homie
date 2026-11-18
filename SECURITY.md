# Security

homie runs locally and makes only the network requests listed in the README's privacy section. If you find anything that sends data elsewhere, reads data it shouldn't, or lets a web page, file or screen content make homie take an action you didn't ask for, please report it privately through **GitHub's "Report a vulnerability"** button on this repository rather than opening a public issue.

Worth knowing:
- The model and voice servers listen on 127.0.0.1 only, with a random key per launch.
- Tool output and screen text are treated as data, never as instructions to homie.
- Memory lives in `~/Library/Application Support/Pixie/Local/memory.json` (mode 0600).
