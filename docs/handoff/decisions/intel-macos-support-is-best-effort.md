# Intel macOS support is best effort

Decided on 2026-10-17: the Intel leg runs weekly and on demand, not on pull
requests, and is not a required check. It took about 14 to 22 minutes
against 8 to 10 for arm64 per PR, and GitHub is retiring its Intel images.
The code keeps supporting Intel.

Reopen when the weekly Intel run fails, or GitHub retires `macos-15-intel`:
then rename the image, or retire the leg and the Intel support claims.
