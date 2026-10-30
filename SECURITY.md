# Security

WhimsyDesk apps move files on your Mac, so bugs that could lose, expose or misplace files matter.

## Report a problem

Please do not open a public issue. Use GitHub's "Report a vulnerability" button on the Security tab of this repo, so the report stays private.

Include the object, your macOS version, and steps to reproduce.

## What counts

- A file is deleted, overwritten or lost instead of moved.
- Put Back sends a file somewhere unexpected.
- An object reads or touches files it was not given.
- Anything that makes network requests (no object should).
