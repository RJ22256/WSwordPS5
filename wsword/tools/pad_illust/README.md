# The PS5 controls screen's pad drawing

`runtime/nvn/pad_illust_data.c` is generated here. It needs the game's `Pack/Bootup.pack` (1.8.2):

1. `sarc.py`: Layout/Common.sblarc out of the pack, and `blyt/PaAllControllerTipsNN_00.bflyt` and `timg/__Combined.bntx` out of that.
2. `nn.py`: the two drawings the game shows (`Nt_NNillust_00`, `_01`, RG8), deswizzled, for their hashes.
3. `draw_ds.py`: our own drawing of a two-grip pad (luminance + alpha, 576x288 and 576x100).
4. `ds.py` (with `edit.py`): the labels' lines led to the new button places, and label groups moved, on the three tabs.
5. `render.py`: a rough render of each tab with the drawing, to check the lines and boxes.
6. `gen_c.py`: the pane edits, the hashes and the two PNGs as C.
