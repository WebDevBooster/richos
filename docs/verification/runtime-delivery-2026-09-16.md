# Runtime delivery source verification

Target versions: app 1.2.0 and engine 1.2.0. Platform tested: macOS 15.6 arm64.
This is intermediate source and packaging evidence. Installed acceptance and the
composed desktop journey remain pending.

The public runtime recipe prepares Python, Node, Git and jq without copying
locally installed tool binaries. Downloads have pinned digests. Git and libiconv
are built from the corresponding included public source archives. The runtime
inventory covers regular files and internal symlinks. macOS system tools supply
Bash and the system libraries. No Homebrew library dependency was found by the
builder's Mach-O dependency check.

Verified locally:

- Loro's 205 behavioral cases plus relocation checks using delivered Node.
- ECS's 14 protocol/import cases using delivered Python.
- The live native worker probe using delivered Python and Git with Homebrew
  removed from PATH. The canonical stated-action refusal and valid alternative,
  native permission denial/allow and a real isolated target artifact all passed.
- Seven runtime inventory checks, including modified binaries, unexpected
  fictional private files, an escaping symlink and non-executable commands.
- Four Rust runtime resolver checks, three selected-engine Loro checks and
  33 setup checks, including preservation of synthetic legacy adopter records
  and a complete predecessor backup.
- 546 core library tests passed; one pre-existing ignored case remains ignored.
- All 18 engine archive tests passed with generated runtimes included. Repeated
  builds under different umasks and timezones produced identical bytes. Every
  regular file and symlink was accounted for by tracked source, declared license
  additions or the separately verified runtime inventory.

Packaging testing found differing symlink modes under different umasks and macOS
AppleDouble metadata in intermediate archives. Packaging now normalizes symlink
modes and excludes resource forks, extended attributes and ACL metadata. A
repeated passing determinism run followed the fix.

The installer verifies the 1.2.0 component contracts and runtime inventory before
activation. Known legacy adopter files are preserved at their existing relative
locations. Other customized files remain in the complete predecessor backup.
This preserves source records; it does not perform personal-context migration.

No app release was published, no installed engine pointer was changed and no
private operational store was imported. The normal desktop orchestration path,
account connection, clean OS installation and full acceptance matrix still need
implementation or verification. Presence of four component directories is not
certification of those behaviors.
