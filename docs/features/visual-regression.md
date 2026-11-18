# Visual inspection

The former golden-image comparison runner and committed reference images were retired under the testing policy in [ENGINEERING.md](https://github.com/hotschmoe/hotschmoe-setup/blob/master/ENGINEERING.md).

Examples can still render screenshots with their `zig build shot` step for human inspection. Automated checks should drive real programs and assert user-visible behavior rather than compare output snapshots. Run the blocking end-to-end checks with `zig build test -j4`, and the background checks with `zig build test-heavy -j4`.
