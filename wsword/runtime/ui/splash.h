// The start screen's background (runtime/ui/splash.mm): the player's own picture (splash.jpg / splash.png in the data
// folder, or Settings > Files > Look's), else the Glass Slate start screen's art (launcher-background.png, WSword's own),
// else the drawn forest clearing (the icon's sword in a stone, the grass moving). Nothing of the game ships for it.
#pragma once
#include "imgui.h"

void splash_load(void);    // after the ImGui renderer backend is up
void splash_unload(void);  // before it shuts down
void splash_draw(ImDrawList *dl, ImVec2 size, float time);
bool splash_is_user(void);  // a picture is shown (the player's, or the Glass Slate art)
#include <string>
std::string splash_custom_path(void);  // (WSword) where Settings > Files > Look puts the player's picture
