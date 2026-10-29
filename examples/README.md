# Bank Core examples

Each folder is a small plugin showing one feature. The code to customize comes
first in `main.lua`; connection and reload handling is at the bottom.

| Example | What it does | Where your code goes |
| --- | --- | --- |
| [Standard page](standard-page/main.lua) | Shows an item grid from its rail icon. | Change `page`: title, labels, item IDs and blank slots. |
| [Sidebar](sidebar/main.lua) | Draws a column with a button that opens a page. | Add controls in `drawSidebar` and replace the button action. |
| [Custom page](custom-page/main.lua) | Draws item pictures at custom positions and sizes. | Edit `items` and `drawPage`; bind each picture with `view:BindItem`. |

The samples use eggs and buckets of milk. Pictures without a matching bank stack
have no native item actions. The custom page deliberately hides quantity text
to keep its drawing code short; plugins can read quantities with
`extension:GetBankItems()`.

## Use an example

1. Copy the example closest to your feature.
2. Change the name in `plugin.json` and the registration ID, name and icon in
   `main.lua`. Keep `bankcore` in `optionalDependencies`.
3. Replace the sample data or drawing code. Leave the connection, dependency
   update and shutdown functions in place.

Call `extension:SetPage(page)` when standard-page data changes, or
`extension:Refresh()` when custom-layout data changes. Neither opens a hidden
page. Call `extension:Open()` from your own controls to display it.

## Try them

Install Core as described in the [player guide](../README.md#install). Copy an
example's `main.lua` and `plugin.json` into a separate plugin folder named
`standardpage`, `sidebar` or `custompage`, matching the name in its manifest.
Include a copy of the root `LICENSE` file. No build step is needed.

Enable PrettyUI, Core and the example, then open the bank's All Items tab.

- **Standard page:** click its star icon.
- **Sidebar example:** click its list icon, then **Open page**.
- **Custom page:** click its grid icon and hover either item picture.

For custom layouts, containers holding bound pictures must be click-through.
Core follows their positions, including parent movement and scrolling.

The dependency strings are for local development. Before publishing, replace
`"bankcore"` in `optionalDependencies` with Core's numeric mod.io ID.
The [API reference](../docs/API.md) covers the complete method and callback list.
Try your example in RuneScape before publishing it.

Each example needs only `main.lua`, `plugin.json` and the project's
[BSD-2-Clause license](../LICENSE).
