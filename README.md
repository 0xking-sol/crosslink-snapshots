# crosslink-snapshots

Daily snapshots of the Crosslink feature-net chain database (zebrad v15), so a new node doesnt have to sync from genesis. A full sync takes around half a day right now. With a snapshot its the download plus at most about half an hour to catch up, depending on how old the snapshot is.

**use**

Stop your node, then:

```
curl -fsSLO https://raw.githubusercontent.com/0xking-sol/crosslink-snapshots/main/restore.sh
bash restore.sh
```

It downloads the latest snapshot (about 500 MB), checks the sha256, moves your current chain data aside (it doesnt delete it) and unpacks the new one. Your secret.seed isn't touched. Start your node again and it catches up from the snapshot height.

If your zebrad.toml sets `cache_dir` under `[state]`, pass the same path: `bash restore.sh --cache-dir /path/to/cache_dir`. Without it the script uses the zebrad default, `~/.cache/zebra` on Linux and `~/Library/Caches/zebra` on macOS. You need curl, tar and zstd.

**trust**

A node doesnt re-check a database you copy in, so using a snapshot means trusting whoever made it. Each one is made from a v15 node I run, only after it's checked to be synced and on the same chain as staker.space. Every release lists its tip and finalized block hashes, so compare them with https://crosslink.staker.space or a node you already run before relying on it.

**whats in it**

- Only `state/` and `non_finalized_state/`. No secret.seed, wallet, keys or logs.
- A new snapshot every day, the last 3 are kept.
- For zebrad v15. If a new release changes the database version this needs a new snapshot.
