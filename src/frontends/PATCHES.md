# Local changes to the vendored frontends

`dib8000.[ch]`, `dib0090.[ch]` and `dibx000_common.[ch]` are copied unmodified
from torvalds/linux master (`drivers/media/dvb-frontends/`). Everything they
need from the kernel is provided by the shim in `src/compat/`.

When a patch becomes necessary, list it here, one line per change, so the
files can be re-synced with upstream.

(none so far)
