cmux, with some 5.6-Sol hackery to add a local tmux backing store. It talks directly to tmux without loopback SSH, preserves focus and layout correctly across splits, and keeps tmux alive under launchd when the app quits so workspaces reappear on later relaunches.

I admittedly don't use the full set of cmux's features, but this allows for a nice tmux-but-GUI experience with every open terminal being easily resumable over SSH when I'm not at home.
