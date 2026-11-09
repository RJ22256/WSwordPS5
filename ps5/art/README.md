# The home screen's artwork

The player's own WSword artwork (two looping videos, 1920x1080 and 600x900), as the PS5 home screen takes it. The home screen
shows still pictures for a homebrew title, so these are frames of the videos:

- `background-source.png`: the 1920x1080 video's frame at 3 s. `ps5/sce_sys/pic0.dds` and `pic1.dds` are this scaled
  to 3840x2160 and BC7-encoded: the backdrop while WSword is selected and while it starts.
- `icon-source.png`: the 600x900 cover's frame at 3 s, fitted into 512x512 over the background's starry sky (its left
  side, with no sword in it). `ps5/sce_sys/icon0.png` is this.

Made again with PS5_Vulkan's `tools/prepare-assets.sh --icon ps5/art/icon-source.png --background ps5/art/background-source.png --output-directory ps5/sce_sys`
(its pinned bc7enc_rdo; `tools/setup-asset-dependencies.sh` builds it).
