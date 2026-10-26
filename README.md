# crosslink-snapshots

Daily snapshots of the Crosslink feature-net chain database (zebrad v15), so a new node doesnt have to sync from genesis. A full sync takes around half a day right now. With a snapshot its the download plus at most about half an hour to catch up, depending on how old the snapshot is.

**use**

Stop your node, then (Linux or macOS):

```
curl -fsSLO https://raw.githubusercontent.com/0xking-sol/crosslink-snapshots/main/restore.sh
bash restore.sh
```

It downloads the latest snapshot (about 500 MB, it resumes if the connection drops), checks the sha256, unpacks it next to your node's data and only then swaps it in. Your current chain data is moved aside, not deleted, and your secret.seed isn't touched. If something fails before the swap nothing changes. Start your node again and it catches up from the snapshot height.

If your zebrad.toml sets `cache_dir` under `[state]`, pass the same path: `bash restore.sh --cache-dir /path/to/cache_dir`. Without it the script uses the zebrad default, `~/.cache/zebra` on Linux and `~/Library/Caches/zebra` on macOS. If your node has never run yet, add `--new`. If it runs in Docker, point `--cache-dir` at the volume's folder and run the script as the user that owns it. You need curl, tar and zstd, and `bash restore.sh --help` has the other options.

**trust**

A node doesnt re-check a database you copy in, so using a snapshot means trusting whoever made it. Each one is made from a v15 node I run, after checking it's synced and on the same chain as staker.space. Once your node is running, ask it for the hash of the finalized block the script names at the end (eg `getblockhash` over RPC) and compare it with https://crosslink.staker.space. That shows you're on the right chain. The rest of the database you're trusting me on.

**whats in it**

- Only `state/` and `non_finalized_state/`. No secret.seed, wallet, keys or logs. v15 keeps the BFT chain inside the database so theres no pos.chain.
- A new snapshot every day, the last 3 are kept.
- For zebrad v15 only. A release that upgrades the network needs new snapshots.
