New version of my improvisation software made in MMMAudio.

In order for this to work, this `instrument` directory needs to be inside the `mmmaudio` repo main directory.

This repo might have a slightly different pixi dependency file than what is in the `mmmaudio` repo, so this repo contains a `pixi.toml` to be used. It can be moved to the `mmmaudio` repo using: (from the `mmmaudio` repo directory) `cp instrument/pixi.toml .`

The entry point is running from the `mmaudio` repo main directory: `pixi run python instrument/Instrument.py`